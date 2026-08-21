import Foundation

/// A row of `listFolders`, as Scripting reports folders.
struct ScriptedFolderRow {
    let accountName: String
    let folderName: String
    let folderID: String
    let shared: Bool
}

/// A row of `listNotesInFolder`, as Scripting reports notes.
struct ScriptedNoteRow {
    let id: String
    let title: String
    let creationDate: String
    let modificationDate: String
    let shared: Bool
}

/// A whole note as Scripting reports it: metadata plus body in one fetch.
struct ScriptedNote {
    let title: String
    let bodyHTML: String
    let creationDate: String
    let modificationDate: String
    let folderName: String
    let accountName: String
    let shared: Bool
}

/// The Scripting seam (CONTEXT.md): everything the server asks Notes.app to
/// do, as domain operations rather than as a scripting mechanism.
///
/// `NotesController` is the production adapter and speaks AppleScript;
/// `FakeNotesApp` in the unit test target is the second adapter, which is
/// what makes the whole write path reachable without a live Notes.app.
/// Script building, dispatch, and result unpacking stay concrete on
/// `NotesController`. Putting them here would force every adapter to speak
/// AppleScript.
///
/// Twin of the read side's `init(sqlite:)` seam; injected the same way.
protocol NotesScripting: Sendable {
    // Folders
    func listFolders() throws -> [ScriptedFolderRow]
    func createFolder(title: String, account: String?) throws -> String
    func renameFolder(id: String, newTitle: String) throws -> String
    func deleteFolder(id: String) throws

    // Notes (write)
    func createNote(title: String, bodyHTML: String, folder: String?, account: String?) throws -> String
    func updateNote(id: String, newTitle: String?, newBodyHTML: String?) throws -> String
    func deleteNote(id: String) throws
    func moveNote(id: String, toFolderName: String, account: String?) throws -> String

    // Notes (live read)
    func listNotesInFolder(_ folderName: String, account: String?, limit: Int?) throws -> [ScriptedNoteRow]
    func getNoteBody(id: String) throws -> String
    func getNoteFull(id: String) throws -> ScriptedNote

    // Batch
    func createNotesBatch(_ entries: [(title: String, bodyHTML: String, folder: String?, account: String?)]) throws -> [String]
    func deleteNotesBatch(_ ids: [String]) throws
    func moveNotesBatch(_ ids: [String], toFolderName: String, account: String?) throws

    // Share workflow
    func prepareShareNote(id: String) throws
    func prepareShareFolder(id: String) throws
}
