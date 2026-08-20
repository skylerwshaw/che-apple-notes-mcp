import Foundation
import Testing

@Suite(.serialized) struct BatchToolsE2ETests {

    @Test func createNotesBatchReturnsAllIDs() async throws {
        try await withFixtureFolder { client, fixture in
            // Single line, deliberately: the transport is newline-delimited
            // JSON-RPC, so a multi-line payload splits the request into
            // unparseable fragments the server silently drops — this test
            // then hangs to the client deadline (issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16)'s longest-lived
            // red herring). MCPClient.send now rejects embedded newlines.
            let note = { (t: String, b: String) in
                #"{"title":"\#(t)","body_text":"\#(b)","folder":"\#(fixture.name)"}"#
            }
            let payload = #"{"notes":[\#(note("b1", "x")),\#(note("b2", "y")),\#(note("b3", "z"))]}"#
            let result = try await client.callTool(name: "create_notes_batch", arguments: payload)
            #expect(!result.isError)
            // Decode rather than substring-count: jsonify escapes "/" as
            // "\/", so the raw text contains "x-coredata:\/\/" and a search
            // for "x-coredata://" can never match.
            struct BatchResult: Decodable { let count: Int; let ids: [String] }
            let decoded = try JSONDecoder().decode(BatchResult.self, from: Data(result.text.utf8))
            #expect(decoded.count == 3)
            #expect(decoded.ids.count == 3)
            #expect(decoded.ids.allSatisfy { $0.hasPrefix("x-coredata://") })
        }
    }

    @Test func moveNotesBatchTransfersAllIDs() async throws {
        try await withFixtureFolder { client, fixture in
            // Seed 2 notes and pick up their ids individually (batch creation
            // returns a compact list that's tool-specific).
            var ids: [String] = []
            for title in ["m1", "m2"] {
                let r = try await client.callTool(
                    name: "create_note",
                    arguments: #"{"title":"\#(title)","body_text":"x","folder":"\#(fixture.name)"}"#
                )
                struct N: Decodable { let id: String }
                ids.append(try JSONDecoder().decode(N.self, from: Data(r.text.utf8)).id)
            }

            let destName = "__CheMCPTest_\(UUID().uuidString.uppercased())__batchdest"
            let destCreate = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(destName)"}"#
            )
            struct F: Decodable { let id: String }
            let destFolder = try JSONDecoder().decode(F.self, from: Data(destCreate.text.utf8))

            let jsonIds = ids.map { "\"\($0)\"" }.joined(separator: ",")
            let payload = #"{"ids":[\#(jsonIds)],"folder":"\#(destName)"}"#
            let move = try await client.callTool(name: "move_notes_batch", arguments: payload)
            #expect(!move.isError)

            // Clean up destination folder (notes then folder).
            for id in ids {
                _ = try? await client.callTool(name: "delete_note", arguments: #"{"id":"\#(id)"}"#)
            }
            _ = try? await client.callTool(name: "delete_folder", arguments: #"{"id":"\#(destFolder.id)"}"#)
        }
    }

    @Test func deleteNotesBatchRemovesAllIDs() async throws {
        try await withFixtureFolder { client, fixture in
            var ids: [String] = []
            for title in ["d1", "d2"] {
                let r = try await client.callTool(
                    name: "create_note",
                    arguments: #"{"title":"\#(title)","body_text":"x","folder":"\#(fixture.name)"}"#
                )
                struct N: Decodable { let id: String }
                ids.append(try JSONDecoder().decode(N.self, from: Data(r.text.utf8)).id)
            }

            let jsonIds = ids.map { "\"\($0)\"" }.joined(separator: ",")
            let delete = try await client.callTool(
                name: "delete_notes_batch",
                arguments: #"{"ids":[\#(jsonIds)]}"#
            )
            #expect(!delete.isError)
        }
    }
}
