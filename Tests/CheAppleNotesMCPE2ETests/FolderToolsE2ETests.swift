import Foundation
import Testing

@Suite(.serialized) struct FolderToolsE2ETests {

    @Test func listFoldersIncludesFixtureFolder() async throws {
        try await withFixtureFolder { client, fixture in
            // Filter by the account the fixture actually landed in. Hosts
            // without "On My Mac" fall back to the server's default (iCloud),
            // so a hardcoded filter would return empty on iCloud-only Macs.
            let args: String = fixture.account.map {
                #"{"account":"\#($0)"}"#
            } ?? "{}"
            let result = try await client.callTool(
                name: "list_folders",
                arguments: args
            )
            #expect(!result.isError)
            #expect(result.text.contains(fixture.name))
        }
    }

    @Test func createFolderReturnsNonEmptyID() async throws {
        // Don't touch the fixture folder — create a second one specifically for
        // this assertion so fixture teardown still works cleanly.
        try await withFixtureFolder { client, _ in
            let tempName = "__CheMCPTest_\(UUID().uuidString.uppercased())__"
            let result = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(tempName)"}"#
            )
            #expect(!result.isError)

            struct FolderDTO: Decodable { let id: String; let title: String }
            let dto = try JSONDecoder().decode(FolderDTO.self, from: Data(result.text.utf8))
            #expect(!dto.id.isEmpty)
            #expect(dto.title == tempName)

            // Clean up the extra folder immediately.
            _ = try? await client.callTool(
                name: "delete_folder",
                arguments: #"{"id":"\#(dto.id)"}"#
            )
        }
    }

    @Test func updateFolderRenamesTheFolder() async throws {
        try await withFixtureFolder { client, fixture in
            let newName = "__CheMCPTest_\(UUID().uuidString.uppercased())__renamed"
            let result = try await client.callTool(
                name: "update_folder",
                arguments: #"{"id":"\#(fixture.id)","title":"\#(newName)"}"#
            )
            #expect(!result.isError)

            struct UpdateDTO: Decodable { let id: String; let title: String }
            let dto = try JSONDecoder().decode(UpdateDTO.self, from: Data(result.text.utf8))
            #expect(dto.id == fixture.id)
            #expect(dto.title == newName)
        }
    }

    @Test func listFoldersIncludesSharedField() async throws {
        try await withFixtureFolder { client, fixture in
            let args: String = fixture.account.map {
                #"{"account":"\#($0)"}"#
            } ?? "{}"
            let result = try await client.callTool(name: "list_folders", arguments: args)
            #expect(!result.isError)

            struct Item: Decodable { let title: String; let shared: Bool }
            let items = try JSONDecoder().decode([Item].self, from: Data(result.text.utf8))
            #expect(!items.isEmpty)
            // Field must be present and decodable as Bool for every folder.
            // We do not assert the value — host environments may have shared folders.
            let fixtureRow = items.first { $0.title == fixture.name }
            #expect(fixtureRow != nil)
        }
    }

    @Test func createdFolderListsWithCanonicalIDThatRoundTrips() async throws {
        // Acceptance for [#2](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/2):
        // a folder created via create_folder shows up in list_folders with an
        // `id` in the constructed canonical URI form, equal to the id
        // AppleScript returned at creation, so a listing id round-trips into
        // update_folder/delete_folder (delete is exercised transitively:
        // teardown deletes via the same id).
        try await withFixtureFolder { client, fixture in
            try await settleForNotesFlush()
            let args: String = fixture.account.map {
                #"{"account":"\#($0)"}"#
            } ?? "{}"
            let result = try await client.callTool(name: "list_folders", arguments: args)
            #expect(!result.isError)

            // uuid/parent_id/path are only present on the SQLite path; keep
            // them optional so the AppleScript-fallback (no FDA) hosts still
            // exercise the id round-trip.
            struct Row: Decodable {
                let id: String
                let title: String
                let uuid: String?
                let parent_id: String?
                let path: String?
            }
            let rows = try JSONDecoder().decode([Row].self, from: Data(result.text.utf8))
            let row = try #require(rows.first { $0.title == fixture.name })

            #expect(row.id == fixture.id)
            #expect(row.id.hasPrefix("x-coredata://"))
            #expect(row.id.contains("/ICFolder/p"))
            if let uuid = row.uuid {
                #expect(!uuid.isEmpty && uuid != row.id)
                #expect(row.parent_id == nil)  // created at account root
                #expect(row.path == fixture.name)
            }

            // Round-trip the listing id into update_folder.
            let renamed = "\(fixture.name)renamed"
            let update = try await client.callTool(
                name: "update_folder",
                arguments: #"{"id":"\#(row.id)","title":"\#(renamed)"}"#
            )
            #expect(!update.isError)

            // Round-trip a listing id into delete_folder, on a second folder
            // so fixture teardown is unaffected.
            let victim = "__CheMCPTest_\(UUID().uuidString.uppercased())__todelete"
            _ = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(victim)"}"#
            )
            try await settleForNotesFlush()
            let relist = try await client.callTool(name: "list_folders", arguments: "{}")
            let victimRow = try #require(
                try JSONDecoder().decode([Row].self, from: Data(relist.text.utf8))
                    .first { $0.title == victim }
            )
            let delete = try await client.callTool(
                name: "delete_folder",
                arguments: #"{"id":"\#(victimRow.id)"}"#
            )
            #expect(!delete.isError)
        }
    }

    @Test func deleteFolderRemovesAnEmptyFolder() async throws {
        try await withFixtureFolder { client, _ in
            // Create a second empty folder dedicated to deletion verification.
            let name = "__CheMCPTest_\(UUID().uuidString.uppercased())__todelete"
            let createResult = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(name)"}"#
            )
            struct FolderDTO: Decodable { let id: String }
            let dto = try JSONDecoder().decode(FolderDTO.self, from: Data(createResult.text.utf8))

            let delete = try await client.callTool(
                name: "delete_folder",
                arguments: #"{"id":"\#(dto.id)"}"#
            )
            #expect(!delete.isError)

            // JSON decode (matches the pattern used by every other E2E test
            // in this suite) — the raw-string contains-check failed against
            // `jsonify`'s prettyPrinted output where `:` is surrounded by
            // spaces (`"deleted" : true`).
            struct DeleteDTO: Decodable { let deleted: Bool; let id: String }
            let deleteDto = try JSONDecoder().decode(DeleteDTO.self, from: Data(delete.text.utf8))
            #expect(deleteDto.deleted)
            #expect(deleteDto.id == dto.id)
        }
    }
}
