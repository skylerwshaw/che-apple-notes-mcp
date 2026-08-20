import AppKit
import Foundation

/// Production adapter for the Scripting seam (`NotesScripting`):
/// dispatches AppleScript sources to Notes.app and unpacks results.
///
/// All write operations go through here. Read fallbacks (when FDA is not
/// granted) also use this class.
///
/// `@unchecked Sendable`: the class holds no state of its own, and every
/// execution funnels through the main thread (see `run(_:)`), which both
/// serializes NSAppleScript's shared OSA component state (concurrent
/// executions were observed crossing their results) and keeps the Apple
/// Event reply wait on the thread whose event queue receives the reply.
final class NotesController: NotesScripting, @unchecked Sendable {

    enum ControllerError: LocalizedError {
        case executionFailed(number: Int, message: String)
        case unexpectedResult(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let number, let message):
                return "AppleScript error \(number): \(message)"
            case .unexpectedResult(let detail):
                return "Unexpected AppleScript result: \(detail)"
            }
        }
    }

    // MARK: - Run

    /// Apple Event reply timeout applied to every script this controller runs.
    /// Must stay safely under the smallest client response deadline (60s in
    /// the E2E MCPClient) so a stalled Apple Event surfaces as an error the
    /// caller can act on instead of silently blowing the caller's deadline
    /// (issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16)). Scripts with their own `with timeout` blocks (the share
    /// preparation flow) keep them: an inner block overrides this outer one
    /// for its scope.
    ///
    /// This bounds the reply wait for a delivered event. It is only
    /// meaningful because `run(_:)` executes on the main thread: waited off
    /// the main thread, the deadline check lives in an event loop that may
    /// never wake (see `run(_:)`), and -1712 can silently never fire.
    static let appleEventTimeoutSeconds = 15

    /// Wrap `source` so each Apple Event it sends waits at most
    /// `appleEventTimeoutSeconds` for its reply. Applies uniformly to every
    /// script rather than per-builder, so no generated script can miss it.
    static func timeoutWrapped(_ source: String) -> String {
        """
        with timeout of \(appleEventTimeoutSeconds) seconds
        \(source)
        end timeout
        """
    }

    /// Executes on the main thread, always. NSAppleScript's reply wait uses
    /// the legacy WaitNextEvent active proc, and Apple Event replies are
    /// delivered to the process's main event queue: a wait pumped on any
    /// other thread intermittently never sees its reply and parks forever in
    /// an untimed mach_msg (which is also why `with timeout`'s -1712 cannot
    /// fire there — the deadline check lives in a loop that never wakes).
    /// Stack-sampled live in issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16): UASRemoteSend →
    /// AEDefaultActiveProc → WaitNextEvent on a cooperative-pool thread,
    /// while an independent osascript got answers from Notes in 0.17s.
    /// osascript runs scripts on its main thread and has never exhibited
    /// this repo's multi-minute stalls; this hop is the same discipline.
    @discardableResult
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        if Thread.isMainThread {
            return try Self.executeOnCurrentThread(source)
        }
        var outcome: Result<NSAppleEventDescriptor, Error>?
        DispatchQueue.main.sync {
            outcome = Result { try Self.executeOnCurrentThread(source) }
        }
        return try outcome!.get()
    }

    private static func executeOnCurrentThread(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: timeoutWrapped(source)) else {
            throw ControllerError.unexpectedResult("failed to compile AppleScript")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
            throw ControllerError.executionFailed(number: number, message: message)
        }
        return result
    }

    func runReturningString(_ source: String) throws -> String {
        let desc = try run(source)
        return desc.stringValue ?? ""
    }

    func runReturningList(_ source: String) throws -> [String] {
        let desc = try run(source)
        guard desc.descriptorType == typeAEList else {
            // Single-element return — wrap
            if let str = desc.stringValue { return [str] }
            return []
        }
        var out: [String] = []
        // AppleScript lists are 1-indexed
        for i in 1...max(desc.numberOfItems, 0) {
            if let item = desc.atIndex(i), let str = item.stringValue {
                out.append(str)
            }
        }
        return out
    }

    // MARK: - Folders

    func listFolders() throws -> [ScriptedFolderRow] {
        let lines = try runReturningList(NoteScriptBuilder.listFolders())
        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 4 else { return nil }
            return ScriptedFolderRow(
                accountName: parts[0],
                folderName: parts[1],
                folderID: parts[2],
                shared: parts[3] == "true"
            )
        }
    }

    func createFolder(title: String, account: String?) throws -> String {
        try runReturningString(NoteScriptBuilder.createFolder(title: title, account: account))
    }

    func renameFolder(id: String, newTitle: String) throws -> String {
        try runReturningString(NoteScriptBuilder.renameFolder(id: id, newTitle: newTitle))
    }

    func deleteFolder(id: String) throws {
        _ = try runReturningString(NoteScriptBuilder.deleteFolder(id: id))
    }

    // MARK: - Notes (write)

    func createNote(title: String, bodyHTML: String, folder: String?, account: String?) throws -> String {
        try runReturningString(NoteScriptBuilder.createNote(
            title: title, bodyHTML: bodyHTML, folderName: folder, account: account
        ))
    }

    func updateNote(id: String, newTitle: String?, newBodyHTML: String?) throws -> String {
        try runReturningString(NoteScriptBuilder.updateNote(
            id: id, newTitle: newTitle, newBodyHTML: newBodyHTML
        ))
    }

    func deleteNote(id: String) throws {
        _ = try runReturningString(NoteScriptBuilder.deleteNote(id: id))
    }

    func moveNote(id: String, toFolderName: String, account: String?) throws -> String {
        try runReturningString(NoteScriptBuilder.moveNote(
            id: id, toFolderName: toFolderName, account: account
        ))
    }

    // MARK: - Notes (read fallback)

    func listNotesInFolder(_ folderName: String, account: String?, limit: Int?) throws -> [ScriptedNoteRow] {
        let lines = try runReturningList(NoteScriptBuilder.listNotesInFolder(
            folderName: folderName, account: account, limit: limit
        ))
        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 5 else { return nil }
            return ScriptedNoteRow(
                id: parts[0], title: parts[1],
                creationDate: parts[2], modificationDate: parts[3],
                shared: parts[4] == "true"
            )
        }
    }

    func getNoteBody(id: String) throws -> String {
        try runReturningString(NoteScriptBuilder.getNoteBody(id: id))
    }

    /// Fetch full note metadata + body in one AppleScript roundtrip.
    /// Used when SQLite is unavailable (FDA not granted). Returns nil if the
    /// note cannot be found or the response is malformed.
    func getNoteFull(id: String) throws -> ScriptedNote {
        let raw = try runReturningString(NoteScriptBuilder.getNoteFull(id: id))
        let parts = raw.components(separatedBy: "\t")
        guard parts.count == 7 else {
            throw ControllerError.unexpectedResult("getNoteFull returned \(parts.count) fields, expected 7")
        }
        return ScriptedNote(
            title: parts[0],
            bodyHTML: parts[1],
            creationDate: parts[2],
            modificationDate: parts[3],
            folderName: parts[4],
            accountName: parts[5],
            shared: parts[6] == "true"
        )
    }

    // MARK: - Batch

    func createNotesBatch(_ entries: [(title: String, bodyHTML: String, folder: String?, account: String?)]) throws -> [String] {
        try runReturningList(NoteScriptBuilder.createNotesBatch(entries: entries))
    }

    func deleteNotesBatch(_ ids: [String]) throws {
        _ = try runReturningString(NoteScriptBuilder.deleteNotesBatch(ids: ids))
    }

    func moveNotesBatch(_ ids: [String], toFolderName: String, account: String?) throws {
        _ = try runReturningString(NoteScriptBuilder.moveNotesBatch(
            ids: ids, toFolderName: toFolderName, account: account
        ))
    }

    // MARK: - Share workflow helpers (#4)

    /// Activate Notes.app and trigger `File → Share Note...` so the user
    /// can complete the share invitation manually. Throws on any step that
    /// fails — caller maps the AppleScript error message to the tool's
    /// JSON error response.
    func prepareShareNote(id: String) throws {
        _ = try runReturningString(NoteScriptBuilder.prepareShareNote(id: id))
    }

    /// Folder variant: activate Notes.app and trigger `File → Share Folder...`.
    func prepareShareFolder(id: String) throws {
        _ = try runReturningString(NoteScriptBuilder.prepareShareFolder(id: id))
    }
}
