import Foundation
import SQLite3

/// Runtime capability detection. Probes are cheap but do roundtrip system calls;
/// call `detect()` once at startup and cache the result.
struct Capabilities {
    let sqliteReadable: Bool

    static let noteStoreURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }()

    /// Detect capabilities at startup. Only probes SQLite (fast, ~1ms). The
    /// AppleScript probe is deliberately absent because it would block for up
    /// to 120 s if Notes.app is busy (iCloud sync, indexing); AS access is
    /// checked lazily on first write. Use `--setup` to explicitly test AS
    /// access with a long timeout.
    static func detect() -> Capabilities {
        Capabilities(sqliteReadable: probeSQLiteAccess())
    }

    /// Try to open NoteStore.sqlite read-only. If Full Disk Access has been granted
    /// to the binary (or the parent process that execs it), this returns true.
    /// Uses URI filename + mode=ro to avoid contention with Notes.app's WAL.
    static func probeSQLiteAccess() -> Bool {
        guard FileManager.default.isReadableFile(atPath: noteStoreURL.path) else {
            return false
        }
        let uri = "file:\(noteStoreURL.path)?mode=ro&cache=shared"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        defer { if let db { sqlite3_close(db) } }
        guard rc == SQLITE_OK else { return false }

        // Double-check: run a trivial query. TCC can fail on first read even if open succeeds.
        var stmt: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Dispatch a trivial AppleScript to Notes.app. First call triggers the macOS
    /// Automation consent dialog. Returns true if the script ran to completion.
    static func probeAppleScriptAccess() -> Bool {
        let source = """
        tell application "Notes"
            count of folders
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }
}
