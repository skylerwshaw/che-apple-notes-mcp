import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// `list_notes_quick` resolves a named range to a date filter and hands it to
/// SQLite; no Scripting is involved. The fake is injected empty so a
/// regression that reaches for Scripting fails here instead of quietly
/// talking to a live Notes.app.
@Suite struct ListNotesQuickTests {

    private func withFixtureServer<T>(
        _ body: (CheAppleNotesMCPServer) async throws -> T
    ) async throws -> T {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await CheAppleNotesMCPServer(
            sqlite: try NotesStoreReader(at: url),
            scripting: FakeNotesApp(storeUUID: FixtureStore.storeUUID)
        )
        return try await body(server)
    }

    private func rows(_ json: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    @Test func listNotesQuickTodayKeepsOnlyTodaysNote() async throws {
        try await withFixtureServer { server in
            let result = try rows(try await server.executeToolCall(
                name: "list_notes_quick", arguments: ["range": .string("today")]
            ))
            #expect(result.compactMap { $0["title"] as? String } == ["Root A Note"])
        }
    }

    @Test func listNotesQuickRecentSpansThirtyDays() async throws {
        try await withFixtureServer { server in
            let result = try rows(try await server.executeToolCall(
                name: "list_notes_quick", arguments: ["range": .string("recent")]
            ))
            // 10 days ago is in, 90 days ago and the undated rows are out.
            #expect(Set(result.compactMap { $0["title"] as? String })
                    == ["Root A Note", "Grandchild Note"])
        }
    }

    @Test func listNotesQuickThisWeekStartsAtTheWeekBoundary() async throws {
        try await withFixtureServer { server in
            let result = try rows(try await server.executeToolCall(
                name: "list_notes_quick", arguments: ["range": .string("this_week")]
            ))
            // A week is at most 7 days, so 10 days ago is out whatever the
            // weekday, and build time is in.
            #expect(result.compactMap { $0["title"] as? String } == ["Root A Note"])
        }
    }

    @Test func listNotesQuickPinnedIgnoresDatesEntirely() async throws {
        try await withFixtureServer { server in
            let result = try rows(try await server.executeToolCall(
                name: "list_notes_quick", arguments: ["range": .string("pinned")]
            ))
            #expect(result.compactMap { $0["title"] as? String } == ["Root B Note"])
        }
    }

    @Test func listNotesQuickRejectsAnUnknownRange() async throws {
        try await withFixtureServer { server in
            do {
                _ = try await server.executeToolCall(
                    name: "list_notes_quick", arguments: ["range": .string("yesterday")]
                )
                Issue.record("expected invalidArgument throw but got success")
            } catch let error as NotesServerError {
                guard case .invalidArgument(let message) = error else {
                    Issue.record("expected invalidArgument but got \(error)")
                    return
                }
                #expect(message.contains("recent/today/this_week/pinned"))
            }
        }
    }
}
