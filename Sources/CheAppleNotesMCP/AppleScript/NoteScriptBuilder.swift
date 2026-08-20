import Foundation

/// Compose AppleScript source for Notes.app operations.
///
/// Conventions:
/// - IDs are the `x-coredata://...` URL, which corresponds to `ZIDENTIFIER` in
///   SQLite. Targets use `note id "..."` rather than name lookup for
///   reliability.
/// - `account` parameter disambiguates when folder names collide across
///   accounts (iCloud vs On My Mac). Omit to use the first match.
/// - Results are returned as AppleScript records/lists that parse to Swift via
///   NSAppleEventDescriptor conversion, or as bare strings for single-value
///   returns.
enum NoteScriptBuilder {

    /// AppleScript target expression for a folder/account pair. A nil folder
    /// targets the account's default folder; a nil account lets Notes pick
    /// the first name match / the default account.
    private static func target(folder: String?, account: String?) -> String {
        switch (folder, account) {
        case (let f?, let a?):
            return "folder \(AppleScriptEscape.quote(f)) of account \(AppleScriptEscape.quote(a))"
        case (let f?, nil):
            return "folder \(AppleScriptEscape.quote(f))"
        case (nil, let a?):
            return "default folder of account \(AppleScriptEscape.quote(a))"
        case (nil, nil):
            return "default folder of default account"
        }
    }

    // MARK: - Folders

    static func listFolders() -> String {
        """
        tell application "Notes"
            set out to {}
            repeat with a in accounts
                set aname to name of a
                repeat with f in folders of a
                    set fname to name of f
                    set fid to id of f
                    set fshared to (shared of f) as string
                    set end of out to aname & "\t" & fname & "\t" & fid & "\t" & fshared
                end repeat
            end repeat
            return out
        end tell
        """
    }

    static func createFolder(title: String, account: String?) -> String {
        let target = account.map { "account \(AppleScriptEscape.quote($0))" } ?? "default account"
        return """
        tell application "Notes"
            set f to make new folder with properties {name:\(AppleScriptEscape.quote(title))} at \(target)
            return id of f
        end tell
        """
    }

    static func renameFolder(id: String, newTitle: String) -> String {
        """
        tell application "Notes"
            set name of folder id \(AppleScriptEscape.quote(id)) to \(AppleScriptEscape.quote(newTitle))
            return id of folder id \(AppleScriptEscape.quote(id))
        end tell
        """
    }

    static func deleteFolder(id: String) -> String {
        """
        tell application "Notes"
            set f to folder id \(AppleScriptEscape.quote(id))
            set noteCount to count of notes of f
            set subfolderCount to count of folders of f
            if noteCount > 0 or subfolderCount > 0 then
                error "Folder is not empty: contains " & noteCount & " notes and " & subfolderCount & " subfolders"
            end if
            delete f
            return "deleted"
        end tell
        """
    }

    // MARK: - Notes (write)

    static func createNote(title: String, bodyHTML: String, folderName: String?, account: String?) -> String {
        """
        tell application "Notes"
            set n to make new note with properties {name:\(AppleScriptEscape.quote(title)), body:\(AppleScriptEscape.quote(bodyHTML))} at \(target(folder: folderName, account: account))
            return id of n
        end tell
        """
    }

    static func updateNote(id: String, newTitle: String?, newBodyHTML: String?) -> String {
        var lines: [String] = []
        lines.append("tell application \"Notes\"")
        lines.append("    set n to note id \(AppleScriptEscape.quote(id))")
        if let title = newTitle {
            lines.append("    set name of n to \(AppleScriptEscape.quote(title))")
        }
        if let html = newBodyHTML {
            lines.append("    set body of n to \(AppleScriptEscape.quote(html))")
        }
        lines.append("    return id of n")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    static func deleteNote(id: String) -> String {
        """
        tell application "Notes"
            delete note id \(AppleScriptEscape.quote(id))
            return "deleted"
        end tell
        """
    }

    static func moveNote(id: String, toFolderName: String, account: String?) -> String {
        """
        tell application "Notes"
            move note id \(AppleScriptEscape.quote(id)) to \(target(folder: toFolderName, account: account))
            return id of note id \(AppleScriptEscape.quote(id))
        end tell
        """
    }

    // MARK: - Notes (read fallback — used when SQLite unavailable)

    static func listNotesInFolder(folderName: String, account: String?, limit: Int?) -> String {
        let limitClause = limit.map { "\nif (count of out) ≥ \($0) then exit repeat" } ?? ""
        return """
        tell application "Notes"
            set out to {}
            repeat with n in notes of \(target(folder: folderName, account: account))\(limitClause)
                set end of out to (id of n) & "\t" & (name of n) & "\t" & ((creation date of n) as string) & "\t" & ((modification date of n) as string) & "\t" & ((shared of n) as string)
            end repeat
            return out
        end tell
        """
    }

    // MARK: - Share workflow helpers (#4)

    /// Activate Notes.app, focus the target note, then trigger the
    /// `File → Share Note...` menu item via System Events. The user finishes
    /// the share (invitee, permission, Send) manually per spec — the tool
    /// never auto-fills anything.
    ///
    /// The script layers three try/on-error blocks so each failure mode
    /// surfaces with a distinct message matching the spec scenarios:
    /// - Activate timeout → "Notes.app did not activate"
    /// - `show note` fails → bubbles the AS error (likely unknown id, or a
    ///   timeout if Notes is busy)
    /// - Menu item missing (or the click itself timing out) → "share menu
    ///   unavailable"
    ///
    /// Every Apple Event in this script runs inside a `with timeout` block —
    /// none of the three steps can hang indefinitely.
    static func prepareShareNote(id: String) -> String {
        prepareShare(
            showLines: "        show note id \(AppleScriptEscape.quote(id))",
            menuNoun: "Note"
        )
    }

    /// Folder variant: activate Notes.app, show the folder, trigger
    /// `File → Share Folder...`. Separate error messages let the caller
    /// distinguish an invalid folder id from a missing menu item.
    static func prepareShareFolder(id: String) -> String {
        prepareShare(
            showLines: """
                    try
                        show folder id \(AppleScriptEscape.quote(id))
                    on error
                        error "folder not found"
                    end try
            """,
            menuNoun: "Folder"
        )
    }

    /// Shared skeleton for the two prepare-share scripts: activate, show the
    /// target item (`showLines`, pre-indented), click `File → Share <noun>...`
    /// with `…`/ellipsis and plain-"Share" (macOS 26) fallbacks.
    private static func prepareShare(showLines: String, menuNoun: String) -> String {
        """
        with timeout of 5 seconds
            try
                tell application "Notes" to activate
            on error
                error "Notes.app did not activate"
            end try
        end timeout
        with timeout of 5 seconds
            tell application "Notes"
        \(showLines)
            end tell
        end timeout
        with timeout of 15 seconds
            tell application "System Events"
                tell process "Notes"
                    try
                        click menu item "Share \(menuNoun)..." of menu "File" of menu bar 1
                    on error
                        try
                            click menu item "Share \(menuNoun)…" of menu "File" of menu bar 1
                        on error
                            try
                                -- macOS 26 renamed the item to plain "Share"
                                click menu item "Share" of menu "File" of menu bar 1
                            on error
                                error "share menu unavailable"
                            end try
                        end try
                    end try
                end tell
            end tell
        end timeout
        return "prepared"
        """
    }

    static func getNoteBody(id: String) -> String {
        """
        tell application "Notes"
            return body of note id \(AppleScriptEscape.quote(id))
        end tell
        """
    }

    /// Single-roundtrip metadata + body fetch, used when SQLite is unavailable.
    /// Returns tab-separated values: title \t body_html \t creation_date \t
    /// modification_date \t folder_name \t account_name \t shared. Fields are
    /// separated by \t because AppleScript records are awkward to parse from
    /// NSAppleEventDescriptor.
    static func getNoteFull(id: String) -> String {
        """
        tell application "Notes"
            set n to note id \(AppleScriptEscape.quote(id))
            set f to container of n
            set a to container of f
            return (name of n) & "\t" & (body of n) & "\t" & ((creation date of n) as string) & "\t" & ((modification date of n) as string) & "\t" & (name of f) & "\t" & (name of a) & "\t" & ((shared of n) as string)
        end tell
        """
    }

    // MARK: - Batch

    static func createNotesBatch(entries: [(title: String, bodyHTML: String, folder: String?, account: String?)]) -> String {
        var lines: [String] = []
        lines.append("tell application \"Notes\"")
        lines.append("    set ids to {}")
        for e in entries {
            lines.append("    set n to make new note with properties {name:\(AppleScriptEscape.quote(e.title)), body:\(AppleScriptEscape.quote(e.bodyHTML))} at \(target(folder: e.folder, account: e.account))")
            lines.append("    set end of ids to id of n")
        }
        lines.append("    return ids")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    static func deleteNotesBatch(ids: [String]) -> String {
        var lines: [String] = []
        lines.append("tell application \"Notes\"")
        for id in ids {
            lines.append("    delete note id \(AppleScriptEscape.quote(id))")
        }
        lines.append("    return \"deleted\"")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    static func moveNotesBatch(ids: [String], toFolderName: String, account: String?) -> String {
        let target = target(folder: toFolderName, account: account)
        var lines: [String] = []
        lines.append("tell application \"Notes\"")
        for id in ids {
            lines.append("    move note id \(AppleScriptEscape.quote(id)) to \(target)")
        }
        lines.append("    return \"moved\"")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
}
