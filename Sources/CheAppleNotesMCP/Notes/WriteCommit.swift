import Foundation

/// The single route every mutation takes (CONTEXT.md "Commit point"). Owns
/// the `NotesScripting` adapter for the write side, the `UndoStack`, the
/// `RecentWrites` read-repair set, and the `NotesStoreReader?` used for
/// pre-write capture. Performing a write and recording its consequences
/// (freshness, undo state) is one act here, not two steps a caller could
/// forget to pair.
///
/// Coverage line is exactly "does Notes change": every method here mutates
/// Notes.app. `Server` keeps its own direct `scripting` reference only for
/// live reads (`getNoteFull`, `getNoteBody`, `listFolders`,
/// `listNotesInFolder`), which this module has no reason to touch.
///
/// Declared, not implied by omission: batch writes stay un-undoable (making
/// them undoable is a separate feature with its own semantics questions),
/// and folder / share-prep writes stay outside both undo and read-repair
/// (there's no live-folder-read path to repair against). Each such policy is
/// a one-line comment at the call site instead of a silently absent one.
final class WriteCommit {
    private let scripting: NotesScripting
    private let sqlite: NotesStoreReader?
    private let undoStack = UndoStack()
    private let recentWrites = RecentWrites()

    init(scripting: NotesScripting, sqlite: NotesStoreReader?) {
        self.scripting = scripting
        self.sqlite = sqlite
    }

    // MARK: - Read surface

    func isFresh(_ id: String) -> Bool { recentWrites.isFresh(id) }
    func history() -> [String] { undoStack.history() }
    func undoDepth() -> Int { undoStack.undoDepth() }
    func redoDepth() -> Int { undoStack.redoDepth() }

    // MARK: - Notes

    func create(title: String, bodyHTML: String, folder: String?, account: String?) throws -> String {
        let id = try scripting.createNote(title: title, bodyHTML: bodyHTML, folder: folder, account: account)
        undoStack.record(.create(id: id))
        recentWrites.record(id)
        return id
    }

    func update(id: String, newTitle: String?, newBodyHTML: String?) throws {
        let prior = capturePriorState(id: id)
        _ = try scripting.updateNote(id: id, newTitle: newTitle, newBodyHTML: newBodyHTML)
        undoStack.record(.update(
            id: id, oldTitle: prior.title, oldBodyHTML: prior.bodyHTML, newTitle: newTitle, newBodyHTML: newBodyHTML
        ))
        recentWrites.record(id)
    }

    func delete(id: String) throws {
        let prior = capturePriorState(id: id)
        try scripting.deleteNote(id: id)
        undoStack.record(.delete(
            id: id, title: prior.title, bodyHTML: prior.bodyHTML, folder: prior.folder, account: prior.account
        ))
        recentWrites.record(id)
    }

    func move(id: String, toFolder: String, account: String?) throws {
        let prior = capturePriorState(id: id)
        _ = try scripting.moveNote(id: id, toFolderName: toFolder, account: account)
        undoStack.record(.move(id: id, fromFolder: prior.folder, account: account, toFolder: toFolder))
        recentWrites.record(id)
    }

    /// Best-effort pre-write capture, shared by every inverting write.
    /// All fields nil together on failure (no Full Disk Access, stale row) —
    /// that's what marks the resulting undo entry degraded.
    private func capturePriorState(id: String) -> (title: String?, bodyHTML: String?, folder: String?, account: String?) {
        guard let sqlite, let existing = try? sqlite.getNote(identifier: id) else {
            return (nil, nil, nil, nil)
        }
        return (existing.title, existing.bodyHTML, existing.folderName, existing.accountName)
    }

    // MARK: - Batch (declared: un-undoable, still tracked fresh)

    func createBatch(_ entries: [(title: String, bodyHTML: String, folder: String?, account: String?)]) throws -> [String] {
        let ids = try scripting.createNotesBatch(entries)
        for id in ids { recentWrites.record(id) }
        return ids
    }

    func moveBatch(_ ids: [String], toFolder: String, account: String?) throws {
        try scripting.moveNotesBatch(ids, toFolderName: toFolder, account: account)
        for id in ids { recentWrites.record(id) }
    }

    func deleteBatch(_ ids: [String]) throws {
        try scripting.deleteNotesBatch(ids)
        for id in ids { recentWrites.record(id) }
    }

    // MARK: - Folders (declared: outside undo and read-repair)

    func createFolder(title: String, account: String?) throws -> String {
        try scripting.createFolder(title: title, account: account)
    }

    func renameFolder(id: String, newTitle: String) throws -> String {
        try scripting.renameFolder(id: id, newTitle: newTitle)
    }

    func deleteFolder(id: String) throws {
        try scripting.deleteFolder(id: id)
    }

    // MARK: - Share workflow (declared: outside undo and read-repair)

    func prepareShareNote(id: String) throws {
        try scripting.prepareShareNote(id: id)
    }

    func prepareShareFolder(id: String) throws {
        try scripting.prepareShareFolder(id: id)
    }

    // MARK: - Undo/redo replay
    //
    // `Server`'s handleUndo/handleRedo own the inversion rule (which case
    // performs which scripting call) and the peek-before-refuse dance for
    // [#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24).
    // These are the commit-point half: run the scripting call and record its
    // consequences the same way every forward write does. `applyDelete`
    // serves both undo-of-create and redo-of-delete; `applyUpdate` and
    // `applyMove` serve both directions of their pair — the inversion is
    // just which captured fields the caller passes in.

    func popForUndo() -> UndoStack.Operation? { undoStack.popForUndo() }
    func peekForRedo() -> UndoStack.Operation? { undoStack.peekForRedo() }
    func popForRedo() -> UndoStack.Operation? { undoStack.popForRedo() }

    func applyDelete(id: String) throws {
        try scripting.deleteNote(id: id)
        recentWrites.record(id)
    }

    func applyUpdate(id: String, title: String?, bodyHTML: String?) throws {
        _ = try scripting.updateNote(id: id, newTitle: title, newBodyHTML: bodyHTML)
        recentWrites.record(id)
    }

    func applyMove(id: String, toFolder: String, account: String?) throws {
        _ = try scripting.moveNote(id: id, toFolderName: toFolder, account: account)
        recentWrites.record(id)
    }

    /// Undo-of-delete: recreates the note, which mints a new id. Rewrites
    /// the redo entry `popForUndo` already pushed (still carrying the
    /// deleted id) to carry the new one instead — otherwise redo re-deletes
    /// the stale id and no-ops while the recreated note survives
    /// ([#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24) #1).
    func applyRecreate(title: String?, bodyHTML: String?, folder: String?, account: String?) throws -> String {
        let newID = try scripting.createNote(title: title ?? "", bodyHTML: bodyHTML ?? "", folder: folder, account: account)
        recentWrites.record(newID)
        undoStack.replaceTopOfRedo(.delete(id: newID, title: title, bodyHTML: bodyHTML, folder: folder, account: account))
        return newID
    }
}
