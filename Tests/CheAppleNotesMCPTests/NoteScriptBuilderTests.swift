import Testing
@testable import CheAppleNotesMCP

@Suite struct NoteScriptBuilderTests {

    // MARK: - Folders

    @Test func listFoldersScriptIteratesAccountsAndFolders() {
        let s = NoteScriptBuilder.listFolders()
        #expect(s.contains("tell application \"Notes\""))
        #expect(s.contains("repeat with a in accounts"))
        #expect(s.contains("repeat with f in folders of a"))
    }

    @Test func listFoldersScriptReportsSharedFlag() {
        let s = NoteScriptBuilder.listFolders()
        #expect(s.contains("shared of f"))
    }

    @Test func createFolderUsesDefaultAccountWhenOmitted() {
        let s = NoteScriptBuilder.createFolder(title: "Inbox", account: nil)
        #expect(s.contains("at default account"))
        #expect(s.contains("\"Inbox\""))
    }

    @Test func createFolderScopesToNamedAccount() {
        let s = NoteScriptBuilder.createFolder(title: "Inbox", account: "iCloud")
        #expect(s.contains("at account \"iCloud\""))
    }

    @Test func renameFolderSetsNameByID() {
        let s = NoteScriptBuilder.renameFolder(id: "x-coredata://abc/ICFolder/p1", newTitle: "New")
        #expect(s.contains("set name of folder id \"x-coredata://abc/ICFolder/p1\""))
        #expect(s.contains("to \"New\""))
    }

    @Test func deleteFolderRefusesWhenNonEmpty() {
        let s = NoteScriptBuilder.deleteFolder(id: "folder-id")
        #expect(s.contains("count of notes of f"))
        #expect(s.contains("count of folders of f"))
        #expect(s.contains("Folder is not empty"))
        #expect(s.contains("notes"))
        #expect(s.contains("subfolders"))
        #expect(s.contains("delete f"))
    }

    // MARK: - Notes CRUD

    @Test func createNoteIntoFolderAndAccount() {
        let s = NoteScriptBuilder.createNote(title: "T", bodyHTML: "<p>B</p>", folderName: "Inbox", account: "iCloud")
        #expect(s.contains("folder \"Inbox\" of account \"iCloud\""))
        #expect(s.contains("{name:\"T\", body:\"<p>B</p>\"}"))
    }

    @Test func createNoteDefaultsWhenNoTargetGiven() {
        let s = NoteScriptBuilder.createNote(title: "T", bodyHTML: "B", folderName: nil, account: nil)
        #expect(s.contains("default folder of default account"))
    }

    @Test func updateNoteEmitsOnlyRequestedFields() {
        let titleOnly = NoteScriptBuilder.updateNote(id: "id", newTitle: "NewT", newBodyHTML: nil)
        #expect(titleOnly.contains("set name of n to \"NewT\""))
        #expect(!titleOnly.contains("set body of n"))

        let bodyOnly = NoteScriptBuilder.updateNote(id: "id", newTitle: nil, newBodyHTML: "<p>X</p>")
        #expect(bodyOnly.contains("set body of n to \"<p>X</p>\""))
        #expect(!bodyOnly.contains("set name of n"))
    }

    @Test func deleteNoteTargetsByID() {
        let s = NoteScriptBuilder.deleteNote(id: "abc")
        #expect(s.contains("delete note id \"abc\""))
    }

    @Test func moveNoteIncludesTargetAccount() {
        let s = NoteScriptBuilder.moveNote(id: "abc", toFolderName: "Done", account: "iCloud")
        #expect(s.contains("move note id \"abc\""))
        #expect(s.contains("folder \"Done\" of account \"iCloud\""))
    }

    @Test func moveNoteFallsBackWithoutAccount() {
        let s = NoteScriptBuilder.moveNote(id: "abc", toFolderName: "Done", account: nil)
        #expect(s.contains("to folder \"Done\""))
        #expect(!s.contains("of account"))
    }

    // MARK: - Notes read fallback

    @Test func listNotesInFolderEmitsRepeatLoop() {
        let s = NoteScriptBuilder.listNotesInFolder(folderName: "Inbox", account: nil, limit: nil)
        #expect(s.contains("repeat with n in notes of folder \"Inbox\""))
    }

    @Test func listNotesInFolderScriptReportsSharedFlag() {
        let s = NoteScriptBuilder.listNotesInFolder(folderName: "Inbox", account: nil, limit: nil)
        #expect(s.contains("shared of n"))
    }

    @Test func getNoteFullScriptReportsSharedFlag() {
        let s = NoteScriptBuilder.getNoteFull(id: "note-1")
        #expect(s.contains("shared of n"))
    }

    @Test func listNotesInFolderLimitEmitsExit() {
        let s = NoteScriptBuilder.listNotesInFolder(folderName: "Inbox", account: "iCloud", limit: 10)
        #expect(s.contains("count of out) ≥ 10"))
        #expect(s.contains("of account \"iCloud\""))
    }

    @Test func getNoteBodyReturnsBodyProperty() {
        let s = NoteScriptBuilder.getNoteBody(id: "note-1")
        #expect(s.contains("return body of note id \"note-1\""))
    }

    // MARK: - Batch

    @Test func createNotesBatchEmitsOnePerEntry() {
        let entries = [
            (title: "A", bodyHTML: "a", folder: Optional<String>.none, account: Optional<String>.none),
            (title: "B", bodyHTML: "b", folder: Optional("F"), account: Optional<String>.none)
        ]
        let s = NoteScriptBuilder.createNotesBatch(entries: entries)
        #expect(s.contains("{name:\"A\", body:\"a\"}"))
        #expect(s.contains("{name:\"B\", body:\"b\"}"))
        #expect(s.contains("default folder of default account"))
        #expect(s.contains("folder \"F\""))
    }

    @Test func deleteNotesBatchLoopsOverIDs() {
        let s = NoteScriptBuilder.deleteNotesBatch(ids: ["id1", "id2", "id3"])
        #expect(s.contains("delete note id \"id1\""))
        #expect(s.contains("delete note id \"id2\""))
        #expect(s.contains("delete note id \"id3\""))
    }

    @Test func moveNotesBatchAppliesSameTarget() {
        let s = NoteScriptBuilder.moveNotesBatch(ids: ["a", "b"], toFolderName: "Archive", account: "On My Mac")
        #expect(s.contains("move note id \"a\" to folder \"Archive\" of account \"On My Mac\""))
        #expect(s.contains("move note id \"b\" to folder \"Archive\" of account \"On My Mac\""))
    }

    // MARK: - Share workflow helpers (#4)

    @Test func prepareShareNoteActivatesAndOpensShareMenu() {
        let s = NoteScriptBuilder.prepareShareNote(id: "x-coredata://abc/ICNote/p1")
        // Step 1: activate Notes under a bounded timeout so we can report
        // "Notes.app did not activate" if it never comes forward.
        #expect(s.contains("with timeout of"))
        #expect(s.contains("activate"))
        // Step 2: focus the note so the Share menu item targets the right one.
        #expect(s.contains("show note id \"x-coredata://abc/ICNote/p1\""))
        // Step 3: System Events triggers File → Share Note... menu item.
        #expect(s.contains("tell application \"System Events\""))
        #expect(s.contains("tell process \"Notes\""))
        #expect(s.contains("Share Note"))
        // Spec scenarios require specific error strings on failure.
        #expect(s.contains("share menu unavailable"))
        #expect(s.contains("Notes.app did not activate"))
    }

    @Test func prepareShareFolderActivatesAndOpensShareMenu() {
        let s = NoteScriptBuilder.prepareShareFolder(id: "x-coredata://abc/ICFolder/p9")
        #expect(s.contains("with timeout of"))
        #expect(s.contains("activate"))
        // Folder variant uses `show folder id` + Share Folder... menu item.
        #expect(s.contains("show folder id \"x-coredata://abc/ICFolder/p9\""))
        #expect(s.contains("Share Folder"))
        // Folder-specific error per spec.
        #expect(s.contains("folder not found"))
        #expect(s.contains("share menu unavailable"))
        #expect(s.contains("Notes.app did not activate"))
    }

    @Test func specialCharactersInTitleAreQuotedSafely() {
        let s = NoteScriptBuilder.createNote(title: "say \"hi\"", bodyHTML: "", folderName: nil, account: nil)
        #expect(s.contains("\"say \\\"hi\\\"\""))
    }
}
