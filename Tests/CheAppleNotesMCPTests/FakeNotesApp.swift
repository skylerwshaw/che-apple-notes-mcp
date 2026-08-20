import Foundation
@testable import CheAppleNotesMCP

/// In-memory stand-in for Notes.app behind the Scripting seam
/// (`NotesScripting`), so write tools can be driven end to end through
/// `executeToolCall` without a live app.
///
/// Deliberately small: it models only what the server actually observes
/// (identity, titles, bodies, folder membership, and soft delete). Grow it
/// when a test needs more, not before.
///
/// Ids are minted in real Canonical ID grammar
/// (`x-coredata://<store UUID>/ICNote/p<pk>`), so a fake paired with a
/// `FixtureStore` SQLite database can be made to mint ids that the SQLite
/// path also knows, which is how read-repair tests tell "served live" from
/// "served from the store" apart.
///
/// `@unchecked Sendable` with one lock around all state: tool calls arrive
/// serialized, but the seam is `Sendable` and tests may hold the fake across
/// an `await`.
final class FakeNotesApp: NotesScripting, @unchecked Sendable {

    enum FakeError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let id): return "Fake Notes: no such item \(id)"
            }
        }
    }

    /// Notes.app soft-deletes: `delete note` moves the note to Recently
    /// Deleted, where its id still resolves (ADR 0002). The fake does the
    /// same, so delete-then-get reports the note in Recently Deleted rather
    /// than not-found.
    static let recentlyDeletedFolder = "Recently Deleted"

    struct Note {
        var title: String
        var bodyHTML: String
        var folder: String
        var account: String
        var deleted = false
    }

    struct Folder {
        var title: String
        var account: String
    }

    private let lock = NSLock()
    private let storeUUID: String
    private var nextPK: Int64
    private var notes: [String: Note] = [:]
    private var folders: [String: Folder] = [:]

    /// `nextPK` starts high enough to clear `FixtureStore`'s note pks, unless
    /// a test deliberately aims a minted id at one of them.
    init(storeUUID: String = "fake-store-uuid", nextPK: Int64 = 1000) {
        self.storeUUID = storeUUID
        self.nextPK = nextPK
    }

    // MARK: - Test-side inspection and setup

    /// Canonical ID for a note pk in this fake's store, for seeding a note at
    /// an id that a `FixtureStore` row also carries.
    func noteID(pk: Int64) -> String {
        coreDataURI(store: storeUUID, entity: "ICNote", pk: pk, fallback: "note-\(pk)")
    }

    @discardableResult
    func seedNote(
        pk: Int64, title: String, bodyHTML: String = "",
        folder: String = "Notes", account: String = "iCloud"
    ) -> String {
        let id = noteID(pk: pk)
        lock.withLock {
            notes[id] = Note(title: title, bodyHTML: bodyHTML, folder: folder, account: account)
        }
        return id
    }

    func note(_ id: String) -> Note? {
        lock.withLock { notes[id] }
    }

    /// Ids of every note that is not soft-deleted, sorted for a stable
    /// failure message.
    func liveNoteIDs() -> [String] {
        lock.withLock {
            notes.filter { !$0.value.deleted }.keys.sorted()
        }
    }

    // MARK: - Internals

    /// Caller must hold `lock`.
    private func mint(entity: String, prefix: String) -> String {
        let id = coreDataURI(store: storeUUID, entity: entity, pk: nextPK, fallback: "\(prefix)-\(nextPK)")
        nextPK += 1
        return id
    }

    private func mutate<T>(_ id: String, _ body: (inout Note) -> T) throws -> T {
        try lock.withLock {
            guard var n = notes[id] else { throw FakeError.notFound(id) }
            let result = body(&n)
            notes[id] = n
            return result
        }
    }

    // MARK: - Folders

    func listFolders() throws -> [ScriptedFolderRow] {
        lock.withLock {
            folders.map { id, f in
                // Nothing in the fake can become shared, so the flag is a
                // constant until a test needs otherwise.
                ScriptedFolderRow(accountName: f.account, folderName: f.title, folderID: id, shared: false)
            }.sorted { $0.folderID < $1.folderID }
        }
    }

    func createFolder(title: String, account: String?) throws -> String {
        lock.withLock {
            let id = mint(entity: "ICFolder", prefix: "folder")
            folders[id] = Folder(title: title, account: account ?? "iCloud")
            return id
        }
    }

    func renameFolder(id: String, newTitle: String) throws -> String {
        try lock.withLock {
            guard var f = folders[id] else { throw FakeError.notFound(id) }
            f.title = newTitle
            folders[id] = f
            return id
        }
    }

    func deleteFolder(id: String) throws {
        try lock.withLock {
            guard folders.removeValue(forKey: id) != nil else { throw FakeError.notFound(id) }
        }
    }

    // MARK: - Notes (write)

    func createNote(title: String, bodyHTML: String, folder: String?, account: String?) throws -> String {
        lock.withLock {
            let id = mint(entity: "ICNote", prefix: "note")
            notes[id] = Note(
                title: title, bodyHTML: bodyHTML,
                folder: folder ?? "Notes", account: account ?? "iCloud"
            )
            return id
        }
    }

    func updateNote(id: String, newTitle: String?, newBodyHTML: String?) throws -> String {
        try mutate(id) { n in
            if let newTitle { n.title = newTitle }
            if let newBodyHTML { n.bodyHTML = newBodyHTML }
            return id
        }
    }

    func deleteNote(id: String) throws {
        try mutate(id) { n in
            n.deleted = true
            n.folder = Self.recentlyDeletedFolder
        }
    }

    func moveNote(id: String, toFolderName: String, account: String?) throws -> String {
        try mutate(id) { n in
            n.folder = toFolderName
            if let account { n.account = account }
            return id
        }
    }

    // MARK: - Notes (live read)

    func listNotesInFolder(_ folderName: String, account: String?, limit: Int?) throws -> [ScriptedNoteRow] {
        lock.withLock {
            var rows = notes
                .filter { !$0.value.deleted && $0.value.folder == folderName }
                .filter { account == nil || $0.value.account == account }
                .map { id, n in
                    ScriptedNoteRow(
                        id: id, title: n.title,
                        creationDate: "", modificationDate: "", shared: false
                    )
                }
                .sorted { $0.id < $1.id }
            if let limit, rows.count > limit { rows = Array(rows.prefix(limit)) }
            return rows
        }
    }

    func getNoteBody(id: String) throws -> String {
        try lock.withLock {
            guard let n = notes[id] else { throw FakeError.notFound(id) }
            return n.bodyHTML
        }
    }

    func getNoteFull(id: String) throws -> ScriptedNote {
        try lock.withLock {
            guard let n = notes[id] else { throw FakeError.notFound(id) }
            return ScriptedNote(
                title: n.title, bodyHTML: n.bodyHTML,
                creationDate: "", modificationDate: "",
                folderName: n.folder, accountName: n.account, shared: false
            )
        }
    }

    // MARK: - Batch

    func createNotesBatch(_ entries: [(title: String, bodyHTML: String, folder: String?, account: String?)]) throws -> [String] {
        try entries.map {
            try createNote(title: $0.title, bodyHTML: $0.bodyHTML, folder: $0.folder, account: $0.account)
        }
    }

    func deleteNotesBatch(_ ids: [String]) throws {
        for id in ids { try deleteNote(id: id) }
    }

    func moveNotesBatch(_ ids: [String], toFolderName: String, account: String?) throws {
        for id in ids { _ = try moveNote(id: id, toFolderName: toFolderName, account: account) }
    }

    // MARK: - Share workflow

    /// Share preparation only opens a Notes.app panel; the fake just checks
    /// the target resolves, which is the only part the server can observe.
    func prepareShareNote(id: String) throws {
        try lock.withLock {
            guard notes[id] != nil else { throw FakeError.notFound(id) }
        }
    }

    func prepareShareFolder(id: String) throws {
        try lock.withLock {
            guard folders[id] != nil else { throw FakeError.notFound(id) }
        }
    }
}
