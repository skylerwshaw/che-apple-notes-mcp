import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Table-driven completeness test over every mutating tool
/// ([#25](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/25)):
/// asserts each one's undo-tracking policy against `undo_history` depth,
/// whether declared undoable or declared exempt. This is the enforcement
/// the old scattered `record` call sites lacked — a future write tool added
/// without routing through `WriteCommit` fails this table instead of being
/// silently stale.
@Suite struct WriteCommitCoverageTests {

    private func withHarness<T>(
        _ body: (CheAppleNotesMCPServer, FakeNotesApp) async throws -> T
    ) async throws -> T {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeNotesApp(storeUUID: FixtureStore.storeUUID, nextPK: 1000)
        let server = await CheAppleNotesMCPServer(
            sqlite: try NotesStoreReader(at: url),
            scripting: fake
        )
        return try await body(server, fake)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func undoDepth(_ server: CheAppleNotesMCPServer) async throws -> Int {
        let history = try object(try await server.executeToolCall(name: "undo_history", arguments: [:]))
        return try #require(history["undo_depth"] as? Int)
    }

    @Test func singleNoteWritesEachRecordExactlyOneUndoEntry() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 1, title: "Original")

            let calls: [(String, [String: Value])] = [
                ("create_note", ["title": .string("New"), "body_text": .string("x")]),
                ("update_note", ["id": .string(id), "title": .string("Renamed")]),
                ("move_note", ["id": .string(id), "folder": .string("Elsewhere")]),
                ("delete_note", ["id": .string(id)])
            ]
            for (name, args) in calls {
                let before = try await undoDepth(server)
                _ = try await server.executeToolCall(name: name, arguments: args)
                let after = try await undoDepth(server)
                #expect(after == before + 1, "\(name) should record exactly one undo entry")
            }
        }
    }

    @Test func batchWritesRecordNoUndoEntryButStillMarkIDsFresh() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 1, title: "Batch Target", folder: "Root A")

            let before = try await undoDepth(server)
            _ = try await server.executeToolCall(name: "create_notes_batch", arguments: [
                "notes": .array([.object(["title": .string("B1")])])
            ])
            _ = try await server.executeToolCall(name: "move_notes_batch", arguments: [
                "ids": .array([.string(id)]), "folder": .string("Archive")
            ])
            _ = try await server.executeToolCall(name: "delete_notes_batch", arguments: [
                "ids": .array([.string(id)])
            ])
            let after = try await undoDepth(server)

            // Declared policy: batches stay un-undoable.
            #expect(after == before)

            // Still tracked fresh for read-repair, proxied by get_note
            // serving the live (post-delete) state instead of stale SQLite.
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["source"] as? String == "applescript")
        }
    }

    @Test func folderAndShareWritesRecordNoUndoEntry() async throws {
        try await withHarness { server, fake in
            let noteID = fake.seedNote(pk: 1, title: "Shared Target")

            let before = try await undoDepth(server)
            let folder = try object(try await server.executeToolCall(name: "create_folder", arguments: [
                "title": .string("New Folder")
            ]))
            let folderID = try #require(folder["id"] as? String)
            _ = try await server.executeToolCall(name: "update_folder", arguments: [
                "id": .string(folderID), "title": .string("Renamed Folder")
            ])
            _ = try await server.executeToolCall(name: "prepare_share_note", arguments: ["id": .string(noteID)])
            _ = try await server.executeToolCall(name: "delete_folder", arguments: ["id": .string(folderID)])
            let after = try await undoDepth(server)

            // Declared policy: folders and share-prep stay outside undo —
            // there's no live-folder-read path for read-repair to protect.
            #expect(after == before)
        }
    }
}
