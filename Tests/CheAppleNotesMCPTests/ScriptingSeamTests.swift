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
            // Not "stack empty": the entry was there and got refused.
            #expect(redone["reason"] as? String == "create redo requires new create call")
        }
    }

    // [#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24) #2:
    // a refusal used to pop the entry off the redo stack before refusing it,
    // silently migrating it onto the undo stack. Refusing twice in a row
    // regresses that: a migrated entry would flip to "stack empty" (or a
    // different reason) on the second call instead of refusing identically.
    @Test func refusedCreateRedoLeavesTheEntryOnTheRedoStackRefusableAgain() async throws {
        try await withHarness { server, _ in
            _ = try await server.executeToolCall(name: "create_note", arguments: [
                "title": .string("Fresh"), "body_text": .string("hi")
            ])
            _ = try await server.executeToolCall(name: "undo", arguments: [:])

            let first = try object(try await server.executeToolCall(name: "redo", arguments: [:]))
            let second = try object(try await server.executeToolCall(name: "redo", arguments: [:]))

            #expect(first["reason"] as? String == "create redo requires new create call")
            #expect(second["reason"] as? String == "create redo requires new create call")

            let history = try object(try await server.executeToolCall(name: "undo_history", arguments: [:]))
            #expect(history["undo_depth"] as? Int == 0)
            #expect(history["redo_depth"] as? Int == 1)
        }
    }

    // `Server` fields each tool call on its own `Task` (the vendored SDK's
    // receive loop, not a serializing actor), and `UndoStack` has no lock —
    // so two `redo` calls really can race the same entry between
    // `peekForRedo` and `popForRedo`. This must degrade to a graceful
    // "stack empty" for the loser, not crash the process on a force-unwrap.
    @Test func concurrentRedoCallsRacingTheSameEntryNeverCrash() async throws {
        try await withHarness { server, fake in
            let id = fake.seedNote(pk: 1, title: "Racy", folder: "Root A")
            // A .move undo/redo pair pops and applies (unlike undo-of-create,
            // which refuses without popping), so this actually exercises the
            // peek-then-pop gap.
            _ = try await server.executeToolCall(name: "move_note", arguments: [
                "id": .string(id), "folder": .string("Elsewhere")
            ])
            _ = try await server.executeToolCall(name: "undo", arguments: [:])

            // `CheAppleNotesMCPServer` isn't `Sendable` — deliberately: this
            // test exists to prove concurrent calls into it don't crash, the
            // same shape of access the real MCP SDK performs (a `Task` per
            // incoming request, not an isolating actor).
            nonisolated(unsafe) let server = server
            let jsonResults = await withTaskGroup(of: String?.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try? await server.executeToolCall(name: "redo", arguments: [:])
                    }
                }
                var collected: [String?] = []
                for await r in group { collected.append(r) }
                return collected
            }

            // No crash: every call returned a well-formed response.
            let results = try jsonResults.compactMap { $0 }.map { try object($0) }
            #expect(results.count == 8)
            // At most one call could have actually redone the single entry;
            // the rest must report "stack empty", not crash or corrupt state.
            let succeeded = results.filter { $0["redone"] as? Bool == true }
            #expect(succeeded.count <= 1)
        }
    }

    // [#24](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/24) #1:
    // undo-of-delete recreates under a new id; redo must delete *that* note,
    // not the stale deleted id still sitting in the popped entry.
    @Test func redoAfterUndoOfDeleteDeletesTheRecreatedNoteNotTheStaleID() async throws {
        try await withHarness(nextPK: 200) { server, fake in
            let staleID = fake.seedNote(pk: 205, title: "Archive B Note", folder: "Archive")
            _ = try await server.executeToolCall(name: "delete_note", arguments: ["id": .string(staleID)])
            _ = try await server.executeToolCall(name: "undo", arguments: [:])

            let recreatedID = fake.noteID(pk: 200)
            #expect(fake.note(recreatedID)?.deleted == false)

            let redone = try object(try await server.executeToolCall(name: "redo", arguments: [:]))
            #expect(redone["redone"] as? Bool == true)
            #expect(fake.note(recreatedID)?.deleted == true)
            // The stale id was already deleted before undo ever ran — redo
            // must not have needed (or been able) to touch it again.
            #expect(fake.note(staleID)?.deleted == true)
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
