import Foundation
import Testing

@Suite(.serialized) struct UndoRedoE2ETests {

    @Test func undoReversesLastCreate() async throws {
        try await withFixtureFolder { client, fixture in
            let createResult = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"UndoMe","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct N: Decodable { let id: String }
            _ = try JSONDecoder().decode(N.self, from: Data(createResult.text.utf8))

            let undo = try await client.callTool(name: "undo", arguments: "{}")
            #expect(!undo.isError)
        }
    }

    @Test func redoReappliesUndoneOperation() async throws {
        try await withFixtureFolder { client, fixture in
            _ = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"RedoMe","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            _ = try await client.callTool(name: "undo", arguments: "{}")

            let redo = try await client.callTool(name: "redo", arguments: "{}")
            #expect(!redo.isError)
        }
    }

    @Test func undoHistoryListsRecordedOperations() async throws {
        try await withFixtureFolder { client, fixture in
            _ = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"Traceable","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            let history = try await client.callTool(name: "undo_history", arguments: "{}")
            #expect(!history.isError)
            #expect(history.text.contains("created note"))
        }
    }

    // Acceptance for [#7](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/7):
    // handleDeleteNote captures pre-delete state via `sqlite.getNote` using the
    // canonical id the client passed. While that lookup only matched bare
    // ZIDENTIFIERs it always missed, and undo recreated an untitled, empty note
    // in the default folder instead of the deleted one.
    @Test func undoOfDeleteRestoresTitleAndBody() async throws {
        try await withFixtureFolder { client, fixture in
            let title = "__CheMCPTest_\(UUID().uuidString.uppercased())__doomed"
            let create = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"\#(title)","body_text":"restore me","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(create.text.utf8))
            try await settleForNotesFlush()

            let delete = try await client.callTool(
                name: "delete_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!delete.isError)

            let undo = try await client.callTool(name: "undo", arguments: "{}")
            #expect(!undo.isError)
            try await settleForNotesFlush()

            // Scoped to the fixture folder: the restored note must land back
            // where it was, not in the default folder.
            let list = try await client.callTool(
                name: "list_notes",
                arguments: #"{"folder_id":"\#(fixture.id)","include_body":true}"#
            )
            #expect(!list.isError)
            struct Row: Decodable { let title: String; let body_text: String? }
            let rows = try JSONDecoder().decode([Row].self, from: Data(list.text.utf8))
            let restored = try #require(rows.first { $0.title == title })
            #expect(restored.body_text?.contains("restore me") == true)
        }
    }

    // Second consequence from the same issue: with the capture missing,
    // `oldTitle`/`oldBodyHTML` stayed nil and `NoteScriptBuilder.updateNote`
    // emitted no mutation, so undo reported success and changed nothing.
    @Test func undoOfUpdateRestoresPreviousTitle() async throws {
        try await withFixtureFolder { client, fixture in
            let before = "__CheMCPTest_\(UUID().uuidString.uppercased())__before"
            let create = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"\#(before)","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let created = try JSONDecoder().decode(Created.self, from: Data(create.text.utf8))
            try await settleForNotesFlush()

            let update = try await client.callTool(
                name: "update_note",
                arguments: #"{"id":"\#(created.id)","title":"AfterUpdate"}"#
            )
            #expect(!update.isError)

            let undo = try await client.callTool(name: "undo", arguments: "{}")
            #expect(!undo.isError)
            try await settleForNotesFlush()

            let get = try await client.callTool(
                name: "get_note",
                arguments: #"{"id":"\#(created.id)"}"#
            )
            #expect(!get.isError)
            #expect(get.text.contains(before))
            #expect(!get.text.contains("AfterUpdate"))
        }
    }
}
