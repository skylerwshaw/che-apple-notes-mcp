import Foundation
import Testing

/// Happy-path coverage for `prepare_share_note` / `prepare_share_folder`.
/// These tools click the real `File → Share Note...` / `File → Share
/// Folder...` menu item in Notes.app, which opens the macOS share picker
/// popover. We dismiss it with Escape after asserting the tool response, so
/// it doesn't linger and steal focus/clicks from other E2E suites driving
/// Notes.app UI in the same run.
@Suite(.serialized) struct ShareWorkflowE2ETests {

    private struct PreparedDTO: Decodable { let prepared: Bool; let id: String }

    @Test func prepareShareNoteOpensShareMenuForFixtureNote() async throws {
        try await withFixtureFolder { client, fixture in
            let created = try await client.callTool(
                name: "create_note",
                arguments: #"{"title":"ShareMe","body_text":"x","folder":"\#(fixture.name)"}"#
            )
            struct Created: Decodable { let id: String }
            let dto = try JSONDecoder().decode(Created.self, from: Data(created.text.utf8))

            let result = try await client.callTool(
                name: "prepare_share_note",
                arguments: #"{"id":"\#(dto.id)"}"#
            )
            #expect(!result.isError)

            let prepared = try JSONDecoder().decode(PreparedDTO.self, from: Data(result.text.utf8))
            #expect(prepared.prepared == true)
            #expect(prepared.id == dto.id)

            dismissSharePopover()
        }
    }

    @Test func prepareShareFolderOpensShareMenuForFixtureFolder() async throws {
        try await withFixtureFolder { client, fixture in
            let result = try await client.callTool(
                name: "prepare_share_folder",
                arguments: #"{"id":"\#(fixture.id)"}"#
            )
            #expect(!result.isError)

            let prepared = try JSONDecoder().decode(PreparedDTO.self, from: Data(result.text.utf8))
            #expect(prepared.prepared == true)
            #expect(prepared.id == fixture.id)

            dismissSharePopover()
        }
    }
}

/// Best-effort dismissal of the share picker popover prepare_share_* leaves
/// open, so it doesn't interfere with other E2E suites' AppleScript UI
/// scripting. Silent on failure — nothing to assert on, and worst case the
/// popover stays open exactly as it would without this call. Shells out to
/// osascript (rather than the server's internal NotesController) to keep
/// this test target black-box, matching every other file in this suite.
private func dismissSharePopover() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", #"tell application "System Events" to key code 53"#]
    try? proc.run()
    proc.waitUntilExit()
}
