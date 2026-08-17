import Foundation
import Testing
import MCP
@testable import CheAppleNotesMCP

/// Handler-level unit tests that exercise error paths requiring the
/// SQLite-unavailable branch. Uses the test-only `init(sqlite:)` seam to
/// force `sqlite = nil` without depending on real Full Disk Access state.
///
/// Added as part of #6 hardening — Findings 10 and 11 from the #3 round-2
/// verification report identified these handler error paths as uncovered by
/// either unit or E2E tests.
@Suite struct ServerHandlerTests {

    /// Error-message substring shared by all three scenarios — mirrors the
    /// spec R4 requirement that the tool SHALL return an error containing
    /// `requires Full Disk Access`.
    private let fdaRequiredSubstring = "requires Full Disk Access"

    @Test func getShareMetadataThrowsFeatureRequiresSQLiteWhenSqliteUnavailable() async throws {
        // Finding 10 regression guard: spec R4 scenario — "Tool errors with
        // clear message when SQLite unavailable".
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = ["identifier": .string("00000000-0000-0000-0000-000000000000")]
        do {
            _ = try await server.executeToolCall(name: "get_share_metadata", arguments: args)
            Issue.record("expected featureRequiresSQLite throw but got success")
        } catch let error as NotesServerError {
            guard case .featureRequiresSQLite(let feature) = error else {
                Issue.record("expected featureRequiresSQLite but got \(error)")
                return
            }
            #expect(feature == "get_share_metadata")
            #expect(error.errorDescription?.contains(fdaRequiredSubstring) == true)
        }
    }

    @Test func listFoldersThrowsFeatureRequiresSQLiteWhenSharedFilterSetWithoutSqlite() async throws {
        // Finding 11 regression guard: AppleScript fallback must refuse the
        // shared filter loudly — prior to #3 round-1 fix `efa7c61` this
        // silently dropped the param.
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = ["shared": .bool(true)]
        do {
            _ = try await server.executeToolCall(name: "list_folders", arguments: args)
            Issue.record("expected featureRequiresSQLite throw but got success")
        } catch let error as NotesServerError {
            guard case .featureRequiresSQLite(let feature) = error else {
                Issue.record("expected featureRequiresSQLite but got \(error)")
                return
            }
            #expect(feature == "list_folders shared filter")
            #expect(error.errorDescription?.contains(fdaRequiredSubstring) == true)
        }
    }

    // MARK: - Share workflow tool registration (#4)

    @Test func toolListIncludesShareWorkflowHelpers() async throws {
        // Spec `apple-notes-sharing-workflow` SHALL provide prepare_share_note
        // and prepare_share_folder. Probe via executeToolCall reaching the
        // dispatch switch — an unknown-tool error means the case was missed.
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = [:]
        // Call without required "id" so we get invalidArgument (registered)
        // rather than unknownTool (missing). Either way proves the tool is
        // dispatched; we only fail on unknownTool.
        for tool in ["prepare_share_note", "prepare_share_folder"] {
            do {
                _ = try await server.executeToolCall(name: tool, arguments: args)
                Issue.record("expected missing-id error for \(tool) but got success")
            } catch let error as NotesServerError {
                if case .unknownTool(let name) = error {
                    Issue.record("tool \(name) not registered in executeToolCall dispatch")
                }
                // invalidArgument (missing id) is the expected path.
            }
        }
    }

    @Test func toolListExcludesDirectShareCreationTools() async throws {
        // Spec `apple-notes-sharing-workflow` SHALL NOT provide
        // create_share_link / invite_participant / revoke_share /
        // list_participants. Verify the dispatch switch returns unknownTool
        // for each — spec scenario R(SHALL NOT) guard.
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = [:]
        for forbidden in ["create_share_link", "invite_participant", "revoke_share", "list_participants"] {
            do {
                _ = try await server.executeToolCall(name: forbidden, arguments: args)
                Issue.record("forbidden tool \(forbidden) executed without error")
            } catch let error as NotesServerError {
                guard case .unknownTool(let name) = error else {
                    Issue.record("expected unknownTool for \(forbidden) but got \(error)")
                    return
                }
                #expect(name == forbidden)
            }
        }
    }

    @Test func listNotesThrowsFeatureRequiresSQLiteWhenSharedFilterSetWithoutSqlite() async throws {
        // Finding 11 regression guard — list_notes variant.
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = ["folder": .string("AnyFolder"), "shared": .bool(false)]
        do {
            _ = try await server.executeToolCall(name: "list_notes", arguments: args)
            Issue.record("expected featureRequiresSQLite throw but got success")
        } catch let error as NotesServerError {
            guard case .featureRequiresSQLite(let feature) = error else {
                Issue.record("expected featureRequiresSQLite but got \(error)")
                return
            }
            #expect(feature == "list_notes shared filter")
            #expect(error.errorDescription?.contains(fdaRequiredSubstring) == true)
        }
    }

    @Test func listNotesThrowsFeatureRequiresSQLiteWhenRecursiveSetWithoutSqlite() async throws {
        // #3 — recursive subtree expansion has no AppleScript fallback.
        let server = await CheAppleNotesMCPServer(sqlite: nil)
        let args: [String: Value] = ["folder_id": .string("x-coredata://store/ICFolder/p1"), "recursive": .bool(true)]
        do {
            _ = try await server.executeToolCall(name: "list_notes", arguments: args)
            Issue.record("expected featureRequiresSQLite throw but got success")
        } catch let error as NotesServerError {
            guard case .featureRequiresSQLite(let feature) = error else {
                Issue.record("expected featureRequiresSQLite but got \(error)")
                return
            }
            #expect(feature == "list_notes recursive")
            #expect(error.errorDescription?.contains(fdaRequiredSubstring) == true)
        }
    }
}
