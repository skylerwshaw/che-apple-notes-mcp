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
            // get_note is a SQLite-backed read, so it needs the flush like any
            // other. It only passed without one while canonical ids missed in
            // SQLite and fell through to AppleScript
            // ([#7](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/7)).
            try await settleForNotesFlush()

            let get = try await client.callTool(
                name: "get_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!get.isError)
            #expect(get.text.contains("After"))
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
            try await settleForNotesFlush()

            let get = try await client.callTool(
                name: "get_note",
                arguments: #"{"id":"\#(row.id)"}"#
            )
            #expect(!get.isError)
            #expect(get.text.contains(renamed))
        }
    }
}
