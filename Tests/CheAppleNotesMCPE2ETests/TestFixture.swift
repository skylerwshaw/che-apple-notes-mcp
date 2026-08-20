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

/// One server process shared by every fixture-based E2E test. A fresh server
/// process pays a ~30s Automation/TCC evaluation on its first Apple Event
/// ([#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16)); when each test spawned its own process, every test paid
/// that tax and raced the client's response deadline. One shared process
/// pays it once per test run, and every later call completes in
/// milliseconds. The child process is reaped when the test runner exits
/// (its stdin reaches EOF); tests must not call `close()` on it.
///
/// Tests that need a private process (transport tests, stub servers) keep
/// constructing `MCPClient` directly.
private actor SharedServer {
    static let instance = SharedServer()
    private var client: MCPClient?

    func get() async throws -> MCPClient {
        if let client { return client }
        let fresh = try MCPClient()
        _ = try await fresh.initialize()
        client = fresh
        return fresh
    }
}

/// Run `body` inside a freshly created test fixture folder. The folder is
/// named `__CheMCPTest_{UUID}__` so bulk cleanup scripts can recognize it.
/// The folder and all notes inside it are deleted on teardown even if the
/// body throws.
///
/// The client passed to `body` is the shared server process (see
/// `SharedServer`); the fixture folder is still private to this call.
///
/// Account resolution: prefers `On My Mac` (no iCloud sync lag) when
/// available, otherwise falls back to the server's default account. The
/// resolved account is exposed on `FixtureFolder.account` (nil when default).
func withFixtureFolder(
    _ body: (MCPClient, FixtureFolder) async throws -> Void
) async throws {
    let client = try await SharedServer.instance.get()

    let folderName = "__CheMCPTest_\(UUID().uuidString.uppercased())__"
    let resolvedAccount = try await createFixtureFolder(client: client, folderName: folderName)
    guard let (folderId, account) = resolvedAccount else {
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

    if let bodyError { throw bodyError }
}

/// Try to create the fixture folder under `On My Mac`; if that account isn't
/// present on the host, go straight to the server's default account.
/// Returns `(folderId, resolvedAccountName?)` or nil if both attempts fail.
///
/// `On My Mac` is checked via `list_folders` first rather than attempted
/// blind: a `create_folder` against a nonexistent account round-trips
/// through a failing Apple Event, which can take ~30s to error out, well
/// past the client's response timeout (see issue #15). `list_folders` costs
/// milliseconds (SQLite-backed) or at worst a fast AppleScript listing, and
/// a false negative (account present but empty) is safe: the fixture just
/// falls back to the default account.
func createFixtureFolder(client: MCPClient, folderName: String) async throws -> (String, String?)? {
    if await accountExists(client: client, named: "On My Mac") {
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

private struct FolderAccountDTO: Decodable { let account_name: String? }

/// Whether `list_folders` reports any folder under `accountName`. Any
/// failure (server error, malformed JSON) is treated as absent, since the
/// caller's fallback path is safe either way.
private func accountExists(client: MCPClient, named accountName: String) async -> Bool {
    guard let result = try? await client.callTool(name: "list_folders"), !result.isError else {
        return false
    }
    guard let folders = try? JSONDecoder().decode([FolderAccountDTO].self, from: Data(result.text.utf8)) else {
        return false
    }
    return folders.contains { $0.account_name == accountName }
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
