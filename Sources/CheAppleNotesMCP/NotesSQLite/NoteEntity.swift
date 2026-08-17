import Foundation

/// Identifier used by AppleScript (`note id "x-coredata://..."`). Persisted in
/// the SQLite column ZIDENTIFIER. We surface this directly to callers so a note
/// returned from SQLite can be targeted by AS write tools.
typealias NoteID = String

/// Construct the canonical ID (ADR 0001): the Core Data URI form that
/// Notes.app's AppleScript dictionary consumes as `folder id "..."` / `note id
/// "..."`. The URI host is the persistent store UUID (Z_METADATA.Z_UUID), NOT
/// the account UUID; Notes rejects URIs built with the account UUID, verified
/// against real AppleScript-returned ids. SQLite ZIDENTIFIER stores just the
/// bare UUID, which write tools cannot consume. Shared by `Folder` and `Note`.
func coreDataURI(store: String?, entity: String, pk: Int64, fallback: String) -> String {
    guard let store, !store.isEmpty else {
        return fallback  // write ops may fail
    }
    return "x-coredata://\(store)/\(entity)/p\(pk)"
}

struct Account {
    let pk: Int64           // Z_PK
    let name: String        // ZNAME
    let identifier: String  // ZIDENTIFIER (e.g., "LocalAccount", "<icloud-uuid>")
}

struct Folder {
    let pk: Int64
    let identifier: String  // ZIDENTIFIER
    let title: String       // ZTITLE2 or ZTITLE
    let accountPK: Int64?   // ZACCOUNT4 or similar FK
    let accountName: String?
    let storeUUID: String?  // Z_METADATA.Z_UUID, host of the canonical URI
    let parentPK: Int64?    // ZPARENT FK for nested folders
    let isHiddenContainer: Bool
    let sortOrder: Int?
    /// True when the folder participates in a CloudKit share — either the user
    /// owns it (ZSERVERSHAREDATA present) or it was shared with them
    /// (ZZONEOWNERNAME present). AppleScript `shared of folder` is preferred
    /// when available; SQLite heuristic is a fallback.
    let shared: Bool

    var appleScriptID: String {
        coreDataURI(store: storeUUID, entity: "ICFolder", pk: pk, fallback: identifier)
    }
}

struct Note {
    let pk: Int64
    let identifier: NoteID  // ZIDENTIFIER (UUID only)
    let title: String
    let folderPK: Int64?
    let folderName: String?
    let accountName: String?
    let storeUUID: String?  // Z_METADATA.Z_UUID, host of the canonical URI
    let creationDate: Date?
    let modificationDate: Date?
    let isPinned: Bool
    let isPasswordProtected: Bool
    let snippet: String?  // ZSNIPPET from SQLite (preview line)
    /// True when this note (or its enclosing folder) participates in a CloudKit
    /// share. See `Folder.shared` for the heuristic.
    let shared: Bool

    var appleScriptID: String {
        coreDataURI(store: storeUUID, entity: "ICNote", pk: pk, fallback: identifier)
    }

    /// Optional body payload. Populated by `get_note` or `list_notes` with
    /// `include_body=true`. nil means not requested; empty string means empty note.
    var bodyText: String?
    var bodyHTML: String?

    /// Set to true when the note is locked (body is AES-encrypted and we didn't
    /// attempt decode) or when protobuf decode failed. Callers may fall back to
    /// AppleScript for body.
    var bodyDecodeError: Bool = false
}

struct Attachment {
    let pk: Int64
    let identifier: String
    let filename: String?
    let typeUTI: String?
    let parentNotePK: Int64?
    /// Local path inside `~/Library/Group Containers/group.com.apple.notes/Accounts/<acct>/Media/<attach>/`.
    /// Requires FDA to read.
    var localPath: String?
}
