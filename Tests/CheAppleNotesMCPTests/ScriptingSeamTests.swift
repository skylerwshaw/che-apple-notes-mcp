import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Write-path tests driven through `executeToolCall` with `FakeNotesApp`
/// injected at the Scripting seam and a `FixtureStore` database behind the
/// SQLite seam, so both halves of a tool call are reachable without a live
/// Notes.app ([#22](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/22)).
///
/// The fake mints ids in the fixture's own store UUID, which is what lets
/// these tests distinguish "served live from Scripting" from "served from
/// SQLite": the same canonical id carries a different title on each side.
@Suite struct ScriptingSeamTests {

    /// `nextPK` aims the fake's minted ids: the default clears the fixture's
    /// note pks, while a test that wants a minted id to also exist in SQLite
    /// points it straight at a fixture row.
    private func withHarness<T>(
        nextPK: Int64 = 1000,
        _ body: (CheAppleNotesMCPServer, FakeNotesApp) async throws -> T
    ) async throws -> T {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeNotesApp(storeUUID: FixtureStore.storeUUID, nextPK: nextPK)
        let server = await CheAppleNotesMCPServer(
            sqlite: try NotesStoreReader(at: url),
            scripting: fake
        )
        return try await body(server, fake)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - Read-repair (ADR 0002)

    @Test func updateThenGetServesLiveStateNotTheStaleFixtureRow() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 200, title: "Root A Note")
            _ = try await server.executeToolCall(name: "update_note", arguments: [
                "id": .string(id), "title": .string("Renamed Live")
            ])
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            // SQLite still says "Root A Note"; read-repair must not.
            #expect(note["title"] as? String == "Renamed Live")
            #expect(note["source"] as? String == "applescript")
        }
    }

    @Test func deleteThenGetReportsRecentlyDeletedRatherThanNotFound() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 201, title: "Child A1 Note", folder: "Child A1")
            _ = try await server.executeToolCall(name: "delete_note", arguments: ["id": .string(id)])
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["folder"] as? String == FakeNotesApp.recentlyDeletedFolder)
        }
    }

    @Test func idThisServerNeverWroteStillReadsSQLite() async throws {
        try await withHarness { server, fake in
            // Not seeded in the fake at all, so only SQLite can answer.
            let id = fake.noteID(pk: 202)
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["title"] as? String == "Grandchild Note")
            #expect(note["source"] == nil)
        }
    }

    // MARK: - Body repair

    @Test func getNoteFillsAnUndecodableBodyFromScripting() async throws {
        try await withHarness { server, fake in
            // The fixture has no ZICNOTEDATA table, so every fixture row
            // decodes to bodyDecodeError with no body_text, which is the case
            // the fallback exists for.
            // Titles deliberately diverge: metadata must still come from
            // SQLite while only the body is repaired from Scripting.
            let id = fake.seedNote(pk: 203, title: "Live Title", bodyHTML: "<div>live body</div>")
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["title"] as? String == "Archive A Note")
            #expect(note["body_source"] as? String == "applescript_fallback")
            #expect(note["body_html"] as? String == "<div>live body</div>")
            #expect((note["body_text"] as? String)?.contains("live body") == true)
            #expect(note["body_decode_error"] as? Bool == false)
        }
    }

    // MARK: - Undo / redo inversion

    @Test func undoOfCreateDeletesTheNote() async throws {
        try await withHarness { server, fake in
            let created = try object(try await server.executeToolCall(name: "create_note", arguments: [
                "title": .string("Fresh"), "body_text": .string("hi")
            ]))
            let id = try #require(created["id"] as? String)
            #expect(fake.note(id)?.deleted == false)

            let undone = try object(try await server.executeToolCall(name: "undo", arguments: [:]))
            #expect(undone["undone"] as? Bool == true)
            #expect(fake.note(id)?.deleted == true)
        }
    }

    @Test func undoOfDeleteRecreatesAndTracksTheNewlyMintedID() async throws {
        // The recreated note is minted at pk 200, which SQLite also knows as
        // "Root A Note". Serving the recreated title proves undo recorded the
        // *new* id in RecentWrites rather than only the deleted one.
        try await withHarness(nextPK: 200) { server, fake in
            let id = fake.seedNote(pk: 205, title: "Archive B Note", folder: "Archive")
            _ = try await server.executeToolCall(name: "delete_note", arguments: ["id": .string(id)])
            _ = try await server.executeToolCall(name: "undo", arguments: [:])

            let newID = fake.noteID(pk: 200)
            #expect(fake.note(newID)?.title == "Archive B Note")
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(newID)]
            ))
            #expect(note["title"] as? String == "Archive B Note")
            #expect(note["source"] as? String == "applescript")
        }
    }

    @Test func redoOfCreateIsRefused() async throws {
        try await withHarness { server, _ in
            _ = try await server.executeToolCall(name: "create_note", arguments: [
                "title": .string("Fresh"), "body_text": .string("hi")
            ])
            _ = try await server.executeToolCall(name: "undo", arguments: [:])
            let redone = try object(try await server.executeToolCall(name: "redo", arguments: [:]))
            #expect(redone["redone"] as? Bool == false)
            // Not "stack empty": the op was popped and then refused.
            #expect(redone["reason"] as? String == "create redo requires new create call")
        }
    }

    @Test func undoOfRenameRestoresTheOldTitle() async throws {
        try await withHarness { server, fake in
            // The fake's title diverges from SQLite's "Root B Note", so
            // restoring SQLite's is distinguishable from restoring the
            // fake's own pre-write state.
            let id = fake.seedNote(pk: 204, title: "Live Title", folder: "Root B")
            _ = try await server.executeToolCall(name: "update_note", arguments: [
                "id": .string(id), "title": .string("Renamed")
            ])
            #expect(fake.note(id)?.title == "Renamed")

            _ = try await server.executeToolCall(name: "undo", arguments: [:])
            // The old title is the one captured from SQLite before the write.
            #expect(fake.note(id)?.title == "Root B Note")
        }
    }

    // MARK: - Batch

    @Test func createNotesBatchReturnsIDsInEntryOrder() async throws {
        try await withHarness { server, fake in
            let result = try object(try await server.executeToolCall(name: "create_notes_batch", arguments: [
                "notes": .array([
                    .object(["title": .string("First"), "body_text": .string("one")]),
                    .object(["title": .string("Second"), "body_html": .string("<div>two</div>")])
                ])
            ]))
            let ids = try #require(result["ids"] as? [String])
            #expect(result["count"] as? Int == 2)
            #expect(ids == [fake.noteID(pk: 1000), fake.noteID(pk: 1001)])
            #expect(fake.note(ids[0])?.title == "First")
            #expect(fake.note(ids[1])?.title == "Second")
            #expect(fake.note(ids[1])?.bodyHTML == "<div>two</div>")
        }
    }

    @Test func createNotesBatchRejectsAMalformedEntry() async throws {
        try await withHarness { server, fake in
            do {
                _ = try await server.executeToolCall(name: "create_notes_batch", arguments: [
                    "notes": .array([
                        .object(["title": .string("First")]),
                        .string("not an object")
                    ])
                ])
                Issue.record("expected invalidArgument throw but got success")
            } catch let error as NotesServerError {
                guard case .invalidArgument(let message) = error else {
                    Issue.record("expected invalidArgument but got \(error)")
                    return
                }
                #expect(message.contains("notes[] must contain objects"))
            }
            // Parsing fails before any note is created, so the valid entry
            // ahead of the bad one must not have landed.
            #expect(fake.liveNoteIDs().isEmpty)
        }
    }

    @Test func batchMoveRecordsEachIDForReadRepair() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 201, title: "Child A1 Note", folder: "Child A1")
            _ = try await server.executeToolCall(name: "move_notes_batch", arguments: [
                "ids": .array([.string(id)]), "folder": .string("Archive")
            ])
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["folder"] as? String == "Archive")
            #expect(note["source"] as? String == "applescript")
        }
    }

    @Test func batchDeleteRecordsEachIDForReadRepair() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 200, title: "Root A Note", folder: "Root A")
            _ = try await server.executeToolCall(name: "delete_notes_batch", arguments: [
                "ids": .array([.string(id)])
            ])
            let note = try object(try await server.executeToolCall(
                name: "get_note", arguments: ["id": .string(id)]
            ))
            #expect(note["folder"] as? String == FakeNotesApp.recentlyDeletedFolder)
        }
    }
}
