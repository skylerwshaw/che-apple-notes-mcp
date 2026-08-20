import Foundation
import Testing

/// Guards the invariant that every MCP tool registered by the server has a
/// corresponding happy-path E2E test elsewhere in this target. When a new tool
/// is added to `CheAppleNotesMCPServer.defineTools()`, update
/// `expectedToolNames` below and add a happy-path test for the new tool.
@Suite(.serialized) struct ToolCoverageE2ETests {

    /// Snapshot of the tool names currently covered by E2E happy-path tests.
    /// Keep in sync with `CheAppleNotesMCPServer.defineTools()`.
    static let expectedToolNames: Set<String> = [
        "list_folders",
        "create_folder",
        "update_folder",
        "delete_folder",
        "list_notes",
        "list_notes_quick",
        "get_note",
        "create_note",
        "update_note",
        "delete_note",
        "move_note",
        "search_notes",
        "create_notes_batch",
        "move_notes_batch",
        "delete_notes_batch",
        "undo",
        "redo",
        "undo_history",
        "get_share_metadata",
        "prepare_share_note",
        "prepare_share_folder",
    ]

    @Test func serverAdvertisesExactlyTheExpectedTools() async throws {
        let client = try MCPClient()
        _ = try await client.initialize()
        defer { Task { await client.close() } }

        let tools = try await client.listTools()
        let actual = Set(tools.map(\.name))

        let missing = Self.expectedToolNames.subtracting(actual)
        let extra = actual.subtracting(Self.expectedToolNames)

        #expect(missing.isEmpty, "missing tools in server: \(missing.sorted())")
        #expect(extra.isEmpty, "server added tools without E2E coverage: \(extra.sorted())")
    }
}
