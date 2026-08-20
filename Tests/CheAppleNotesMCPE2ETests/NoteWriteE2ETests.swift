import Foundation
import Testing

@Suite(.serialized) struct NoteWriteE2ETests {

    @Test func createNoteReturnsID() async throws {
        try await withFixtureFolder { client, fixture in
            let result = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"NewNote","body_text":"hi","folder":"\#(fixture.name)"}"#
            )
            #expect(!result.isError)

            struct Dto: Decodable { let id: String; let title: String }
            let dto = try JSONDecoder().decode(Dto.self, from: Data(result.text.utf8))
            #expect(!dto.id.isEmpty)
            #expect(dto.title == "NewNote")
        }
    }

    @Test func updateNoteChangesTitle() async throws {
        try await withFixtureFolder { client, fixture in
            let createResult = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Before","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(createResult.text.utf8))

            let update = try await client.callTool(
                name: "update_note",
                arguments: #"{"id":"\#(created.id)","title":"After"}"#
            )
            #expect(!update.isError)
            // get_note is a SQLite-backed read; a rename takes 4-8s to reach
            // NoteStore.sqlite, so poll rather than sleep a fixed interval.
            let renamedVisible = try await eventually {
                let get = try await client.callTool(
                    name: "get_note",
                    arguments: #"{"id":"\#(created.id)"}"#
                )
                return !get.isError && get.text.contains("After")
            }
            #expect(renamedVisible)
        }
    }

    @Test func deleteNoteRemovesByID() async throws {
        try await withFixtureFolder { client, fixture in
            let createResult = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Doomed","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(createResult.text.utf8))

            let delete = try await client.callTool(
                name: "delete_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!delete.isError)
        }
    }

    @Test func moveNoteChangesFolder() async throws {
        try await withFixtureFolder { client, fixture in
            // Create a secondary destination folder within the same process.
            let destName = "__CheMCPTest_\(UUID().uuidString.uppercased())__dest"
            let destCreate = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(destName)"}"#
            )
            struct FolderDto: Decodable { let id: String }
            let destFolder = try JSONDecoder().decode(FolderDto.self, from: Data(destCreate.text.utf8))

            let noteCreate = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Mover","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct NoteDto: Decodable { let id: String }
            let note = try JSONDecoder().decode(NoteDto.self, from: Data(noteCreate.text.utf8))

            let move = try await client.callTool(
                name: "move_note",
                arguments: #"{"id":"\#(note.id)","folder":"\#(destName)"}"#
            )
            #expect(!move.isError)

            // Clean up the extra destination folder (and its note).
            _ = try? await client.callTool(
                name: "delete_note",
                arguments: #"{"id":"\#(note.id)"}"#
            )
            _ = try? await client.callTool(
                name: "delete_folder",
                arguments: #"{"id":"\#(destFolder.id)"}"#
            )
        }
    }

    @Test func updateNoteThenImmediateGetNoteReturnsUpdatedTitle() async throws {
        // Read-repair acceptance for
        // [#11](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/11)
        // (ADR 0002): get_note on an id this server just wrote reads live
        // via AppleScript, so no settle sleep or polling is needed even
        // though the SQLite store lags a rename by 4-8s.
        try await withFixtureFolder { client, fixture in
            let createResult = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Before","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(createResult.text.utf8))
            #expect(created.id.hasPrefix("x-coredata://"))

            let update = try await client.callTool(
                name: "update_note",
                arguments: #"{"id":"\#(created.id)","title":"After"}"#
            )
            #expect(!update.isError)

            // Deliberately no settleForNotesFlush()/eventually(): the whole
            // point is that the immediate read is already fresh.
            let get = try await client.callTool(
                name: "get_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!get.isError)
            struct Fetched: Decodable { let title: String; let source: String? }
            let fetched = try JSONDecoder().decode(Fetched.self, from: Data(get.text.utf8))
            #expect(fetched.title == "After")
            #expect(fetched.source == "applescript")
        }
    }

    @Test func deleteNoteThenImmediateGetNoteShowsRecentlyDeleted() async throws {
        // Read-repair acceptance for
        // [#11](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/11)
        // (ADR 0002). Notes soft-deletes: `delete note` moves the note to
        // Recently Deleted and AppleScript still resolves its id there, so
        // not-found is unachievable via the live path (and post-flush SQLite
        // filters ZMARKEDFORDELETION, falling through to the same AppleScript
        // read). The contract is therefore: the live read must show the note
        // out of its original folder immediately, not serve the stale SQLite
        // row that still places it there. Folder equality with the localized
        // "Recently Deleted" name is deliberately not asserted.
        try await withFixtureFolder { client, fixture in
            let createResult = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Gone","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(createResult.text.utf8))

            let delete = try await client.callTool(
                name: "delete_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!delete.isError)

            // Deliberately no settle sleep: while the SQLite store still
            // holds the pre-delete row, the read must come from AppleScript
            // and reflect the delete.
            let get = try await client.callTool(
                name: "get_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!get.isError)
            struct Fetched: Decodable { let folder: String; let source: String }
            let fetched = try JSONDecoder().decode(Fetched.self, from: Data(get.text.utf8))
            #expect(fetched.source == "applescript")
            #expect(fetched.folder != fixture.name)
        }
    }

    @Test func createdNoteListsWithCanonicalIDThatRoundTrips() async throws {
        // Acceptance for [#5](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/5):
        // a note created via create_note shows up in list_notes with an `id`
        // in the constructed canonical URI form (store UUID host, mirroring
        // Folder), so a listing id round-trips into update_note. Mirrors
        // `createdFolderListsWithCanonicalIDThatRoundTrips`.
        try await withFixtureFolder { client, fixture in
            let title = "__CheMCPTest_\(UUID().uuidString.uppercased())__note"
            let create = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"\#(title)","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            #expect(!create.isError)
            try await settleForNotesFlush()

            let list = try await client.callTool(
                name: "list_notes",
                arguments: #"{"folder_id":"\#(fixture.id)"}"#
            )
            #expect(!list.isError)

            struct Row: Decodable { let id: String; let title: String }
            let rows = try JSONDecoder().decode([Row].self, from: Data(list.text.utf8))
            let row = try #require(rows.first { $0.title == title })
            #expect(row.id.hasPrefix("x-coredata://"))
            #expect(row.id.contains("/ICNote/p"))

            // Round-trip the listing id into update_note.
            let renamed = "\(title)renamed"
            let update = try await client.callTool(
                name: "update_note",
                arguments: #"{"id":"\#(row.id)","title":"\#(renamed)"}"#
            )
            #expect(!update.isError)
            // Renames take 4-8s to become visible to SQLite reads; poll.
            let renamedVisible = try await eventually {
                let get = try await client.callTool(
                    name: "get_note",
                    arguments: #"{"id":"\#(row.id)"}"#
                )
                return !get.isError && get.text.contains(renamed)
            }
            #expect(renamedVisible)
        }
    }
}
