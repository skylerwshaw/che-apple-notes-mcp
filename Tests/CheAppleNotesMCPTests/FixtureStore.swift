import Foundation
import SQLite3
import Testing

/// Builds a minimal Notes-compatible SQLite database in a temp file for
/// driving `NotesStoreReader` (and server handlers over it) without touching
/// the real Notes store. Real NoteStore.sqlite has ~150 columns; we only
/// create the handful the queries under test touch.
///
/// Contents:
/// - Share-metadata note rows (participant / owner / unshared); see
///   `NotesStoreReaderTests`.
/// - A folder hierarchy across two accounts, modeling duplicate folder names
///   in sibling branches, a three-deep chain, an empty folder, an orphan
///   (missing parent row), and a hidden container:
///
///   iCloud (icloud-account-uuid)
///   ├── Root A (pk 10)
///   │   ├── Child A1 (pk 11)
///   │   │   └── Grandchild A1a (pk 12)
///   │   └── Archive (pk 13)
///   ├── Root B (pk 14)
///   │   └── Archive (pk 15, shared with us)
///   ├── Empty (pk 16)
///   ├── Orphan (pk 17, ZPARENT=999 which doesn't exist)
///   └── Recently Deleted (pk 18, hidden container)
///
///   On My Mac (local-account-uuid)
///   └── Root A (pk 20)
enum FixtureStore {
    /// Persistent store UUID (Z_METADATA.Z_UUID) — the host of every
    /// canonical `x-coredata://` ID, shared by all accounts in the store.
    static let storeUUID = "fixture-store-uuid"
    static let iCloudAccountUUID = "icloud-account-uuid"
    static let localAccountUUID = "local-account-uuid"

    static func makeURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CheMCPFixture-\(UUID().uuidString).sqlite")
    }

    /// Run one SQL statement against an open writer handle; each DDL / INSERT
    /// is individually asserted.
    private static func runStatement(_ sql: String, on db: OpaquePointer?) {
        var stmt: OpaquePointer?
        let prepOK = sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        #expect(prepOK, "prepare failed for: \(sql)")
        let stepRC = sqlite3_step(stmt)
        #expect(stepRC == SQLITE_DONE, "step rc=\(stepRC) for: \(sql)")
        sqlite3_finalize(stmt)
    }

    /// Build the fixture at `url` with a separate read-write SQLite handle;
    /// the `NotesStoreReader` under test then re-opens it read-only via its
    /// existing init path.
    static func build(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        var writer: OpaquePointer?
        let openRC = sqlite3_open_v2(
            url.path,
            &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        #expect(openRC == SQLITE_OK, "open writer rc=\(openRC)")
        defer { sqlite3_close(writer) }

        runStatement("CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME VARCHAR)", on: writer)
        runStatement("CREATE TABLE Z_METADATA (Z_VERSION INTEGER, Z_UUID VARCHAR, Z_PLIST BLOB)", on: writer)
        runStatement("INSERT INTO Z_METADATA (Z_VERSION, Z_UUID) VALUES (1, '\(storeUUID)')", on: writer)
        runStatement("""
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                Z_PK INTEGER PRIMARY KEY,
                Z_ENT INTEGER,
                Z_OPT INTEGER,
                ZIDENTIFIER VARCHAR,
                ZNAME VARCHAR,
                ZTITLE VARCHAR,
                ZTITLE2 VARCHAR,
                ZOWNER INTEGER,
                ZPARENT INTEGER,
                ZISHIDDENNOTECONTAINER INTEGER,
                ZSORTORDER INTEGER,
                ZSERVERSHAREDATA BLOB,
                ZZONEOWNERNAME VARCHAR
            )
            """, on: writer)
        runStatement("""
            CREATE TABLE ZICINVITATION (
                Z_PK INTEGER PRIMARY KEY,
                Z_ENT INTEGER,
                Z_OPT INTEGER,
                ZROOTOBJECT INTEGER,
                ZROOTOBJECTTYPE VARCHAR,
                ZTITLE VARCHAR,
                ZSNIPPET VARCHAR,
                ZSHAREURL VARCHAR,
                ZNOTECOUNT INTEGER,
                ZSUBFOLDERCOUNT INTEGER,
                ZRECEIVEDDATE TIMESTAMP,
                ZSERVERSHAREDATA BLOB
            )
            """, on: writer)

        // Entity IDs: ICAccount=11 ICNote=12 ICFolder=15 to mimic the real schema.
        runStatement("INSERT INTO Z_PRIMARYKEY VALUES (11, 'ICAccount')", on: writer)
        runStatement("INSERT INTO Z_PRIMARYKEY VALUES (12, 'ICNote')", on: writer)
        runStatement("INSERT INTO Z_PRIMARYKEY VALUES (15, 'ICFolder')", on: writer)

        // Accounts.
        runStatement("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNAME, ZIDENTIFIER)
            VALUES (1, 11, 'iCloud', '\(iCloudAccountUUID)')
            """, on: writer)
        runStatement("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNAME, ZIDENTIFIER)
            VALUES (2, 11, 'On My Mac', '\(localAccountUUID)')
            """, on: writer)

        // Folder hierarchy (see type doc comment for the tree diagram).
        // Columns: pk, title, owner, parent, sort, hidden, zoneOwner.
        let folders: [(Int64, String, Int64, Int64?, Int, Int, String?)] = [
            (10, "Root A", 1, nil, 1, 0, nil),
            (11, "Child A1", 1, 10, 1, 0, nil),
            (12, "Grandchild A1a", 1, 11, 1, 0, nil),
            (13, "Archive", 1, 10, 2, 0, nil),
            (14, "Root B", 1, nil, 2, 0, nil),
            (15, "Archive", 1, 14, 1, 0, "shared-by-someone"),
            (16, "Empty", 1, nil, 3, 0, nil),
            (17, "Orphan", 1, 999, 4, 0, nil),
            (18, "Recently Deleted", 1, nil, 0, 1, nil),
            (20, "Root A", 2, nil, 1, 0, nil),
        ]
        for (pk, title, owner, parent, sort, hidden, zoneOwner) in folders {
            let parentSQL = parent.map(String.init) ?? "NULL"
            let zoneOwnerSQL = zoneOwner.map { "'\($0)'" } ?? "NULL"
            runStatement("""
                INSERT INTO ZICCLOUDSYNCINGOBJECT
                    (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE2, ZOWNER, ZPARENT,
                     ZISHIDDENNOTECONTAINER, ZSORTORDER, ZZONEOWNERNAME)
                VALUES (\(pk), 15, 'folder-uuid-\(pk)', '\(title)', \(owner),
                        \(parentSQL), \(hidden), \(sort), \(zoneOwnerSQL))
                """, on: writer)
        }

        // Share-metadata note rows (see NotesStoreReaderTests).
        // Participant-side note: shared (someone shared it with us) but
        // ZSERVERSHAREDATA is NULL because we aren't the CKShare owner.
        runStatement("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZSERVERSHAREDATA, ZZONEOWNERNAME)
            VALUES (100, 12, 'participant-note-uuid', NULL, 'shared-by-someone')
            """, on: writer)
        // Owner-side note: we own a CKShare, so ZSERVERSHAREDATA is non-null.
        runStatement("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZSERVERSHAREDATA, ZZONEOWNERNAME)
            VALUES (101, 12, 'owner-note-uuid', X'01020304', NULL)
            """, on: writer)
        // Unshared note: both signals NULL.
        runStatement("""
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZSERVERSHAREDATA, ZZONEOWNERNAME)
            VALUES (102, 12, 'unshared-note-uuid', NULL, NULL)
            """, on: writer)
    }
}
