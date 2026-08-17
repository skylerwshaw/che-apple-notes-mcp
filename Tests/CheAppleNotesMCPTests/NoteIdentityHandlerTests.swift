import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Handler-level tests for canonical note identity
/// ([#5](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/5)):
/// drive `list_notes` through the server dispatch over a fixture-backed
/// `NotesStoreReader` and assert the `id` field is built from the persistent
/// store UUID, not the account UUID. Mirrors `FolderIdentityHandlerTests`.
@Suite struct NoteIdentityHandlerTests {

    private struct Row: Decodable {
        let id: String
        let uuid: String
        let title: String
    }

    private func listNotes(_ args: [String: Value] = [:]) async throws -> [Row] {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await CheAppleNotesMCPServer(sqlite: try NotesStoreReader(at: url))
        let json = try await server.executeToolCall(name: "list_notes", arguments: args)
        return try JSONDecoder().decode([Row].self, from: Data(json.utf8))
    }

    // The URI host is the persistent store UUID, shared by every account in
    // the store; rows stay distinct via their pk.
    private func canonicalID(pk: Int64) -> String {
        "x-coredata://\(FixtureStore.storeUUID)/ICNote/p\(pk)"
    }

    @Test func canonicalIDUsesStoreUUIDNotAccountUUID() async throws {
        let rows = try await listNotes(["folder_id": .string("folder-uuid-10")])
        let row = try #require(rows.first { $0.uuid == "note-uuid-200" })
        #expect(row.id == canonicalID(pk: 200))
        #expect(!row.id.contains(FixtureStore.iCloudAccountUUID))
    }

    @Test func everyRowCarriesCanonicalIdentityFields() async throws {
        let rows = try await listNotes()
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.id.hasPrefix("x-coredata://\(FixtureStore.storeUUID)/ICNote/p"))
        }
    }
}
