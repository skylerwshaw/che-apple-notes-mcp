import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Handler-level tests for recursive note listing, folder_path, and
/// name-ambiguity errors ([#3](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/3)):
/// drive `list_notes` through the server dispatch over the fixture-backed
/// `NotesStoreReader` and assert the public JSON shape, mirroring
/// `FolderIdentityHandlerTests`.
@Suite struct RecursiveNoteListingHandlerTests {

    private struct Row: Decodable {
        let uuid: String
        let title: String
        let folder_path: String
    }

    private func listNotes(_ args: [String: Value]) async throws -> [Row] {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await CheAppleNotesMCPServer(sqlite: try NotesStoreReader(at: url))
        let json = try await server.executeToolCall(name: "list_notes", arguments: args)
        return try JSONDecoder().decode([Row].self, from: Data(json.utf8))
    }

    private func canonicalFolderID(pk: Int64) -> String {
        "x-coredata://\(FixtureStore.storeUUID)/ICFolder/p\(pk)"
    }

    // MARK: - Recursive listing

    @Test func recursiveListingReturnsSubtreeExcludingSiblingsAndOtherAccounts() async throws {
        let rows = try await listNotes([
            "folder_id": .string(canonicalFolderID(pk: 10)),
            "recursive": .bool(true)
        ])
        #expect(Set(rows.map { $0.title }) == [
            "Root A Note", "Child A1 Note", "Grandchild Note", "Archive A Note"
        ])
        // Sibling branch (Root B) and the other account's same-titled "Root A"
        // are excluded.
        #expect(!rows.contains { $0.title == "Root B Note" })
        #expect(!rows.contains { $0.title == "Archive B Note" })
        #expect(!rows.contains { $0.title == "Local Root A Note" })
    }

    @Test func recursiveListingOfLeafFolderReturnsJustItself() async throws {
        let rows = try await listNotes([
            "folder_id": .string(canonicalFolderID(pk: 12)),
            "recursive": .bool(true)
        ])
        #expect(rows.map { $0.title } == ["Grandchild Note"])
    }

    // MARK: - Non-recursive behavior unchanged

    @Test func nonRecursiveListingReturnsOnlyDirectFolder() async throws {
        let rows = try await listNotes(["folder_id": .string(canonicalFolderID(pk: 10))])
        #expect(rows.map { $0.title } == ["Root A Note"])
    }

    // MARK: - folder_path

    @Test func everyRowCarriesFolderPath() async throws {
        let rows = try await listNotes([
            "folder_id": .string(canonicalFolderID(pk: 10)),
            "recursive": .bool(true)
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.folder_path) })
        #expect(byTitle["Root A Note"] == "Root A")
        #expect(byTitle["Child A1 Note"] == "Root A/Child A1")
        #expect(byTitle["Grandchild Note"] == "Root A/Child A1/Grandchild A1a")
        #expect(byTitle["Archive A Note"] == "Root A/Archive")
    }

    // MARK: - recursive requires a canonical folder id

    @Test func recursiveWithoutFolderIDThrowsInvalidArgument() async throws {
        do {
            _ = try await listNotes(["recursive": .bool(true)])
            Issue.record("expected invalidArgument throw but got success")
        } catch let error as NotesServerError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument but got \(error)")
                return
            }
        }
    }

    @Test func recursiveWithFolderNameInsteadOfIDThrowsInvalidArgument() async throws {
        do {
            _ = try await listNotes(["folder": .string("Root A"), "recursive": .bool(true)])
            Issue.record("expected invalidArgument throw but got success")
        } catch let error as NotesServerError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument but got \(error)")
                return
            }
        }
    }

    @Test func recursiveWithBareUUIDThrowsInvalidArgument() async throws {
        // ZIDENTIFIER form (not the x-coredata:// canonical id) must also be
        // rejected — recursion requires the canonical form specifically.
        do {
            _ = try await listNotes(["folder_id": .string("folder-uuid-10"), "recursive": .bool(true)])
            Issue.record("expected invalidArgument throw but got success")
        } catch let error as NotesServerError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument but got \(error)")
                return
            }
        }
    }

    @Test func recursiveWithUnknownFolderPKThrowsInvalidArgument() async throws {
        // Well-formed x-coredata:// id whose pk isn't a real folder (wrong
        // entity, stale/deleted folder) must error, not silently match zero
        // notes and look like "this folder is empty".
        do {
            _ = try await listNotes([
                "folder_id": .string(canonicalFolderID(pk: 999999)),
                "recursive": .bool(true)
            ])
            Issue.record("expected invalidArgument throw but got success")
        } catch let error as NotesServerError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument but got \(error)")
                return
            }
        }
    }

    // MARK: - Name-based ambiguity

    @Test func ambiguousFolderNameThrowsAndNamesTheConflict() async throws {
        do {
            _ = try await listNotes(["folder": .string("Archive")])
            Issue.record("expected ambiguousFolderName throw but got success")
        } catch let error as NotesServerError {
            guard case .ambiguousFolderName(let name, _, let paths) = error else {
                Issue.record("expected ambiguousFolderName but got \(error)")
                return
            }
            #expect(name == "Archive")
            #expect(Set(paths) == ["Root A/Archive", "Root B/Archive"])
        }
    }

    @Test func uniqueFolderNameStillResolvesAsBefore() async throws {
        let rows = try await listNotes(["folder": .string("Child A1")])
        #expect(rows.map { $0.title } == ["Child A1 Note"])
    }

    @Test func unknownFolderNameThrowsInvalidArgumentInsteadOfUnfilteredScan() async throws {
        do {
            _ = try await listNotes(["folder": .string("Does Not Exist")])
            Issue.record("expected invalidArgument throw but got success")
        } catch let error as NotesServerError {
            guard case .invalidArgument = error else {
                Issue.record("expected invalidArgument but got \(error)")
                return
            }
        }
    }
}
