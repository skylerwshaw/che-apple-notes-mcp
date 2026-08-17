import Foundation

/// Centralised SQL templates. `ICFolder`, `ICNote`, `ICAccount` entity IDs are
/// looked up at runtime from `Z_PRIMARYKEY` because Apple can (and occasionally
/// does) renumber them across macOS releases.
enum SQLQueries {
    static let entityIDsQuery = "SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY"

    /// Persistent store UUID — the host of every `x-coredata://` canonical ID.
    /// Core Data keeps exactly one row in Z_METADATA.
    static let storeUUIDQuery = "SELECT Z_UUID FROM Z_METADATA LIMIT 1"

    /// Accounts: name + identifier
    static let listAccounts = """
        SELECT Z_PK, ZNAME, ZIDENTIFIER
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_ENT = :entityID AND ZNAME IS NOT NULL
        ORDER BY ZNAME
        """

    /// Folders. We intentionally select multiple potential title/account FK
    /// columns and pick the non-null one at runtime — schema varies by macOS.
    ///
    /// `shared` is derived via heuristic because Notes' SQLite schema has no
    /// direct boolean. `ZSERVERSHAREDATA IS NOT NULL` means the user owns a
    /// CloudKit share for this folder; `ZZONEOWNERNAME IS NOT NULL` means
    /// someone shared this folder with the user. Either signal is sufficient.
    ///
    /// The query is exposed as `listFoldersBase` + `listFoldersOrderSuffix`
    /// so the reader's shared-filter variant can splice an `AND` clause
    /// before the ORDER BY without string-search fragility. `listFolders`
    /// stays as a backwards-compatible full query for unfiltered callers.
    static let listFoldersBase = """
        SELECT
            f.Z_PK,
            f.ZIDENTIFIER,
            COALESCE(f.ZTITLE2, f.ZTITLE) AS title,
            f.ZOWNER,
            f.ZPARENT,
            f.ZISHIDDENNOTECONTAINER,
            f.ZSORTORDER,
            a.ZNAME AS account_name,
            (f.ZSERVERSHAREDATA IS NOT NULL OR f.ZZONEOWNERNAME IS NOT NULL) AS shared
        FROM ZICCLOUDSYNCINGOBJECT f
        LEFT JOIN ZICCLOUDSYNCINGOBJECT a
            ON a.Z_PK = f.ZOWNER AND a.Z_ENT = :accountEntityID
        WHERE f.Z_ENT = :folderEntityID
        """

    static let listFoldersOrderSuffix = """
        ORDER BY COALESCE(f.ZSORTORDER, 0), title
        """

    static let listFolders = listFoldersBase + "\n" + listFoldersOrderSuffix

    /// List notes in a folder (or all) with basic metadata. Body is fetched
    /// separately via `noteBodyBlob` because it's expensive.
    ///
    /// `shared` heuristic mirrors `listFolders` — see that doc comment.
    static let listNotes = """
        SELECT
            n.Z_PK,
            n.ZIDENTIFIER,
            COALESCE(n.ZTITLE1, n.ZTITLE) AS title,
            n.ZFOLDER,
            f.ZTITLE2 AS folder_title,
            a.ZNAME AS account_name,
            a.ZIDENTIFIER AS account_identifier,
            COALESCE(n.ZCREATIONDATE3, n.ZCREATIONDATE2, n.ZCREATIONDATE1, n.ZCREATIONDATE) AS creation_date,
            COALESCE(n.ZMODIFICATIONDATE1, n.ZMODIFICATIONDATE) AS modification_date,
            n.ZISPINNED,
            n.ZISPASSWORDPROTECTED,
            n.ZSNIPPET,
            (n.ZSERVERSHAREDATA IS NOT NULL OR n.ZZONEOWNERNAME IS NOT NULL) AS shared
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f
            ON f.Z_PK = n.ZFOLDER AND f.Z_ENT = :folderEntityID
        LEFT JOIN ZICCLOUDSYNCINGOBJECT a
            ON a.Z_PK = f.ZOWNER AND a.Z_ENT = :accountEntityID
        WHERE n.Z_ENT = :noteEntityID
          AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION = 0)
        """

    /// Single note by identifier.
    static let noteByIdentifier = listNotes + "\n  AND n.ZIDENTIFIER = :identifier LIMIT 1"

    /// Body blob lookup. ZICNOTEDATA.ZNOTE is FK to ZICCLOUDSYNCINGOBJECT.Z_PK
    /// of the note row.
    static let noteBodyBlob = """
        SELECT d.ZDATA, d.ZCRYPTOTAG IS NOT NULL AS encrypted
        FROM ZICNOTEDATA d
        WHERE d.ZNOTE = :notePK
        LIMIT 1
        """

    /// ZICINVITATION carries CloudKit share metadata for the root note/folder
    /// it references via ZROOTOBJECT (FK to ZICCLOUDSYNCINGOBJECT.Z_PK).
    ///
    /// `server_share_data_present` is computed as a bool — we never select the
    /// raw BLOB because spec forbids deserializing CKShare (`apple-notes-sharing-metadata`
    /// requirement: tool SHALL NOT include a decoded representation of
    /// ZSERVERSHAREDATA).
    static let shareMetadataByRootIdentifier = """
        SELECT
            i.ZROOTOBJECTTYPE,
            i.ZTITLE,
            i.ZSNIPPET,
            i.ZSHAREURL,
            i.ZNOTECOUNT,
            i.ZSUBFOLDERCOUNT,
            i.ZRECEIVEDDATE,
            (i.ZSERVERSHAREDATA IS NOT NULL) AS server_share_data_present
        FROM ZICINVITATION i
        JOIN ZICCLOUDSYNCINGOBJECT r
            ON r.Z_PK = i.ZROOTOBJECT
        WHERE r.ZIDENTIFIER = :rootIdentifier
        LIMIT 1
        """

    /// Heuristic check for items without a ZICINVITATION row but still shared
    /// via presence of ZSERVERSHAREDATA (owner) or ZZONEOWNERNAME (participant).
    /// Used as fallback when `shareMetadataByRootIdentifier` returns no row.
    ///
    /// Projects two columns so the reader can populate
    /// `ShareMetadata.serverShareDataPresent` truthfully even on this fallback
    /// path — the aggregate `shared` bit is not enough because it conflates
    /// owner and participant cases.
    ///
    /// `Z_ENT IN (:noteEntityID, :folderEntityID)` guards against ZIDENTIFIER
    /// collision with non-shareable entity kinds (accounts, attachments, etc).
    /// Notes assigns globally-unique UUIDs today so this is defense in depth.
    static let sharedRootObjectHeuristic = """
        SELECT
            (ZSERVERSHAREDATA IS NOT NULL OR ZZONEOWNERNAME IS NOT NULL) AS shared,
            (ZSERVERSHAREDATA IS NOT NULL) AS server_share_data_present
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = :rootIdentifier
          AND Z_ENT IN (:noteEntityID, :folderEntityID)
        LIMIT 1
        """

    /// Core Data stores timestamps as NSDate reference-date (2001-01-01).
    /// Caller converts via `Date(timeIntervalSinceReferenceDate:)`.
    static func coreDataDate(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }
}
