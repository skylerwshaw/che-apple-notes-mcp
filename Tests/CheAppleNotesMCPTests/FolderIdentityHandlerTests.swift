import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Handler-level tests for canonical folder identity
/// ([#2](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/2)):
/// drive `list_folders` through the server dispatch over a fixture-backed
/// `NotesStoreReader` and assert the public JSON shape. This is the test
/// seam the rest of the nested-folder work builds on.
@Suite struct FolderIdentityHandlerTests {

    private struct Row: Decodable {
        let id: String
        let uuid: String
        let title: String
        let account_name: String
        let parent_id: String?
        let parent_pk: Int64?
        let path: String
        let is_hidden: Bool
        let sort_order: Int?
        let shared: Bool
    }

    private func listFolders(_ args: [String: Value] = [:]) async throws -> [Row] {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await CheAppleNotesMCPServer(sqlite: try NotesStoreReader(at: url))
        let json = try await server.executeToolCall(name: "list_folders", arguments: args)
        return try JSONDecoder().decode([Row].self, from: Data(json.utf8))
    }

    // The URI host is the persistent store UUID, shared by every account in
    // the store; rows stay distinct via their pk.
    private func canonicalID(pk: Int64) -> String {
        "x-coredata://\(FixtureStore.storeUUID)/ICFolder/p\(pk)"
    }

    @Test func everyRowCarriesCanonicalIdentityFields() async throws {
        // Assert key *presence* (not just decodability) so a null-vs-missing
        // regression can't hide behind optional decoding.
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await CheAppleNotesMCPServer(sqlite: try NotesStoreReader(at: url))
        let json = try await server.executeToolCall(name: "list_folders", arguments: [:])
        let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        #expect(!rows.isEmpty)
        for row in rows {
            for key in ["id", "uuid", "parent_id", "path", "parent_pk"] {
                #expect(row.keys.contains(key), "missing \(key) in \(row)")
            }
            let id = try #require(row["id"] as? String)
            #expect(id.hasPrefix("x-coredata://") && id.contains("/ICFolder/p"))
        }
    }

    @Test func canonicalIDMatchesConstructedURIForm() async throws {
        let rows = try await listFolders()
        let rootA = try #require(rows.first { $0.uuid == "folder-uuid-10" })
        #expect(rootA.id == canonicalID(pk: 10))
        #expect(rootA.title == "Root A")
    }

    @Test func rootFolderHasNullParentIDAndTitleAsPath() async throws {
        let rows = try await listFolders()
        let rootA = try #require(rows.first { $0.uuid == "folder-uuid-10" })
        #expect(rootA.parent_id == nil)
        #expect(rootA.parent_pk == nil)
        #expect(rootA.path == "Root A")
    }

    @Test func childParentIDIsParentsCanonicalIDAndPathIsThreeDeep() async throws {
        let rows = try await listFolders()
        let grandchild = try #require(rows.first { $0.uuid == "folder-uuid-12" })
        #expect(grandchild.parent_id == canonicalID(pk: 11))
        #expect(grandchild.parent_pk == 11)
        #expect(grandchild.path == "Root A/Child A1/Grandchild A1a")
    }

    @Test func duplicateTitlesInSiblingBranchesYieldDistinctPaths() async throws {
        let rows = try await listFolders()
        let archives = rows.filter { $0.title == "Archive" }
        #expect(Set(archives.map { $0.path }) == ["Root A/Archive", "Root B/Archive"])
        #expect(Set(archives.map { $0.id }).count == 2)
    }

    @Test func missingParentRowDegradesToRootBehavior() async throws {
        let rows = try await listFolders()
        let orphan = try #require(rows.first { $0.uuid == "folder-uuid-17" })
        #expect(orphan.parent_id == nil)
        #expect(orphan.path == "Orphan")
        // Raw FK is still reported for diagnostics / backward compatibility.
        #expect(orphan.parent_pk == 999)
    }

    @Test func accountsRemainIsolated() async throws {
        // Same title in two accounts → distinct canonical IDs (distinct pks
        // under the shared store-UUID host) and account-scoped paths.
        let all = try await listFolders()
        let rootAs = all.filter { $0.title == "Root A" }
        #expect(rootAs.count == 2)
        #expect(Set(rootAs.map { $0.id }) == [canonicalID(pk: 10), canonicalID(pk: 20)])
        #expect(rootAs.allSatisfy { $0.path == "Root A" })

        // Account filter still scopes the listing.
        let local = try await listFolders(["account": .string("On My Mac")])
        #expect(local.map { $0.uuid } == ["folder-uuid-20"])
    }

    @Test func hiddenContainerAndSortOrderBehaviorUnchanged() async throws {
        // Hidden containers are still emitted with the is_hidden flag, and the
        // listing keeps the SQL (sort_order, title) ordering.
        let rows = try await listFolders(["account": .string("iCloud")])
        let hidden = try #require(rows.first { $0.uuid == "folder-uuid-18" })
        #expect(hidden.is_hidden)
        #expect(rows.map { $0.title } == [
            "Recently Deleted",
            "Archive", "Child A1", "Grandchild A1a", "Root A",
            "Archive", "Root B",
            "Empty",
            "Orphan",
        ])
    }

    @Test func sharedFilterStillWorksAndKeepsFullPaths() async throws {
        // shared=true returns only the shared folder, but its path/parent_id
        // are still resolved against the full store: the unshared parent
        // must not degrade the shared child to a root.
        let rows = try await listFolders(["shared": .bool(true)])
        let archive = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(archive.uuid == "folder-uuid-15")
        #expect(archive.path == "Root B/Archive")
        #expect(archive.parent_id == canonicalID(pk: 14))

        let unshared = try await listFolders(["shared": .bool(false)])
        #expect(!unshared.contains { $0.uuid == "folder-uuid-15" })
        #expect(unshared.contains { $0.uuid == "folder-uuid-10" })
    }
}
