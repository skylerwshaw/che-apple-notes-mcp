import Foundation

/// Descriptor for a freshly-created test fixture folder.
/// `account` is the resolved account name reported by the server, or `nil`
/// when the fixture fell back to the default account.
struct FixtureFolder: Sendable {
    let name: String
    let id: String
    let account: String?
}

/// Errors raised while setting up the fixture.
enum FixtureError: Error, CustomStringConvertible {
    case setupFailed(String)

    var description: String {
        switch self {
        case .setupFailed(let s): return "fixture setup failed: \(s)"
        }
    }
}

/// Yield the thread briefly so Notes.app can flush recent AppleScript writes
/// into NoteStore.sqlite. AppleScript `make note` / `set body` returns before
/// the WAL checkpoint completes — SQLite reads that race the flush get a
/// stale snapshot. Call this after any write inside a test before asserting
/// via SQLite-backed reads (list_notes, search_notes, list_notes_quick,
/// get_note when FDA is granted).
func settleForNotesFlush() async throws {
    try await Task.sleep(nanoseconds: 500_000_000)
}

/// Run `body` inside a freshly created test fixture folder. The folder is
/// named `__CheMCPTest_{UUID}__` so bulk cleanup scripts can recognize it.
/// The folder and all notes inside it are deleted on teardown even if the
/// body throws.
///
/// Account resolution: prefers `On My Mac` (no iCloud sync lag) when
/// available, otherwise falls back to the server's default account. The
/// resolved account is exposed on `FixtureFolder.account` (nil when default).
func withFixtureFolder(
    _ body: (MCPClient, FixtureFolder) async throws -> Void
) async throws {
    let client = try MCPClient()
    _ = try await client.initialize()

    let folderName = "__CheMCPTest_\(UUID().uuidString.uppercased())__"
    let resolvedAccount = try await createFixtureFolder(client: client, folderName: folderName)
    guard let (folderId, account) = resolvedAccount else {
        await client.close()
        throw FixtureError.setupFailed("create_folder failed on both On My Mac and default account")
    }

    let fixture = FixtureFolder(name: folderName, id: folderId, account: account)

    // Give Notes.app a moment to flush the freshly-created folder into
    // NoteStore.sqlite. AppleScript `make folder` returns before the WAL has
    // been checkpointed; SQLite reads that race the flush get an empty result.
    // 500 ms is enough in practice — bump if CI on slower hardware flakes.
    try await Task.sleep(nanoseconds: 500_000_000)

    var bodyError: Error?
    do {
        try await body(client, fixture)
    } catch {
        bodyError = error
    }

    await teardownBestEffort(client: client, fixture: fixture)
    await client.close()

    if let bodyError { throw bodyError }
}

/// Try to create the fixture folder under `On My Mac`; if that account
/// doesn't exist on the host, retry with the server's default account.
/// Returns `(folderId, resolvedAccountName?)` or nil if both attempts fail.
private func createFixtureFolder(client: MCPClient, folderName: String) async throws -> (String, String?)? {
    // Ask whether On My Mac exists rather than probing by attempting a create.
    // A create against a missing account takes ~30s to come back (see #16),
    // which on its own exceeds the client's response deadline, so the probe
    // never reached the fallback below. list_folders reads SQLite, so asking
    // costs milliseconds.
    if await accountExists("On My Mac", client: client) {
        let preferredArgs = #"{"title":"\#(folderName)","account":"On My Mac"}"#
        let preferred = try await client.callTool(name: "create_folder", arguments: preferredArgs)
        if !preferred.isError,
           let id = try? parseFolderId(from: preferred.text), !id.isEmpty
        {
            return (id, "On My Mac")
        }
    }
    // Fallback: let the server pick the default account.
    let fallbackArgs = #"{"title":"\#(folderName)"}"#
    let fallback = try await client.callTool(name: "create_folder", arguments: fallbackArgs)
    if !fallback.isError,
       let id = try? parseFolderId(from: fallback.text), !id.isEmpty
    {
        return (id, nil)
    }
    return nil
}

/// True when any folder in the store reports `name` as its account.
///
/// A false negative is safe: the caller falls back to the default account,
/// which still works, just with the iCloud sync lag that preferring On My Mac
/// exists to avoid. So an account that exists but holds no folders reads as
/// absent, and that is fine.
private func accountExists(_ name: String, client: MCPClient) async -> Bool {
    guard let result = try? await client.callTool(name: "list_folders"), !result.isError
    else { return false }
    return accountNames(inListFoldersJSON: result.text).contains(name)
}

/// Account names in a `list_folders` payload. Split out from the call so the
/// key it depends on is testable without a live server: getting `account_name`
/// wrong would silently make every account look absent.
func accountNames(inListFoldersJSON json: String) -> Set<String> {
    struct Row: Decodable {
        let accountName: String?
        enum CodingKeys: String, CodingKey { case accountName = "account_name" }
    }
    guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return [] }
    return Set(rows.compactMap(\.accountName).filter { !$0.isEmpty })
}

/// Delete every note in the fixture folder, then the folder itself.
/// Silent on failure — the cleanup script (`scripts/cleanup-test-folders.sh`)
/// is the escape hatch.
private func teardownBestEffort(client: MCPClient, fixture: FixtureFolder) async {
    let listArgs = #"{"folder_id":"\#(fixture.id)"}"#
    if let list = try? await client.callTool(name: "list_notes", arguments: listArgs),
       !list.isError,
       let ids = try? parseNoteIds(from: list.text),
       !ids.isEmpty
    {
        let jsonIds = ids.map { "\"\($0)\"" }.joined(separator: ",")
        let batchArgs = "{\"ids\":[\(jsonIds)]}"
        _ = try? await client.callTool(name: "delete_notes_batch", arguments: batchArgs)
    }

    let delArgs = #"{"id":"\#(fixture.id)"}"#
    _ = try? await client.callTool(name: "delete_folder", arguments: delArgs)
}

// MARK: - JSON parsing helpers

private struct FolderResponseDTO: Decodable {
    let id: String
}

private struct NoteListItemDTO: Decodable {
    let id: String
}

private func parseFolderId(from text: String) throws -> String {
    let data = Data(text.utf8)
    return try JSONDecoder().decode(FolderResponseDTO.self, from: data).id
}

private func parseNoteIds(from text: String) throws -> [String] {
    let data = Data(text.utf8)
    return try JSONDecoder().decode([NoteListItemDTO].self, from: data).map { $0.id }
}
