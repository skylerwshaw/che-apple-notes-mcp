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

    @Test func deleteFolderRefusesFolderContainingOnlySubfolders() async throws {
        // Acceptance for [#4](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/4):
        // a folder whose only contents are subfolders must be refused, not
        // deleted along with its subtree.
        try await withFixtureFolder { client, _ in
            let containerName = "__CheMCPTest_\(UUID().uuidString.uppercased())__container"
            let createResult = try await client.callTool(
                name: "create_folder",
                arguments: #"{"title":"\#(containerName)"}"#
            )
            struct FolderDTO: Decodable { let id: String }
            let container = try JSONDecoder().decode(FolderDTO.self, from: Data(createResult.text.utf8))

            let subName = "__CheMCPTest_\(UUID().uuidString.uppercased())__sub"
            let subId = try createSubfolder(named: subName, parentID: container.id)
            // ponytail: the subfolder above is created by a *second*, independent
            // osascript process rather than the server's own AppleScript engine
            // (create_folder has no parent param). Handing the same folder id to
            // the server's engine right after another process just wrote to it
            // has been observed to wedge Notes.app's Apple Event handling for
            // that object for a long time. A longer settle here is the cheap
            // fix; if it still flakes, serialize subfolder creation through the
            // server itself once create_folder grows a parent_id param.
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let delete = try await client.callTool(
                name: "delete_folder",
                arguments: #"{"id":"\#(container.id)"}"#
            )
            #expect(delete.isError)
            #expect(delete.text.contains("subfolders"))

            // Clean up: subfolder first, then the now-empty container.
            _ = try? await client.callTool(name: "delete_folder", arguments: #"{"id":"\#(subId)"}"#)
            _ = try? await client.callTool(name: "delete_folder", arguments: #"{"id":"\#(container.id)"}"#)
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

/// Create a folder nested inside `parentID`. `create_folder` has no parent
/// parameter (nested creation isn't part of the tool surface yet), so this
/// shells out to osascript directly, matching the black-box pattern
/// `dismissSharePopover` uses in ShareWorkflowE2ETests.swift.
private func createSubfolder(named name: String, parentID: String) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", #"""
        tell application "Notes"
            set p to folder id "\#(parentID)"
            set s to make new folder with properties {name:"\#(name)"} at p
            return id of s
        end tell
        """#]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try proc.run()
    proc.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}
