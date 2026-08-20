import Testing
@testable import CheAppleNotesMCP

/// Pins the bounded-Apple-Event behavior from issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16): every script the
/// controller executes is wrapped in an explicit `with timeout` block so no
/// single Apple Event send can block anywhere near a client's 30s response
/// deadline. Uses pure AppleScript (no `tell application`), so no Apple
/// Events are sent and no live Notes.app is required.
///
/// Serialized because NSAppleScript executions share OSA component state:
/// two scripts run in parallel in one process can cross their results.
@Suite(.serialized) struct NotesControllerTimeoutTests {

    @Test func wrapPutsSourceInsideExplicitTimeoutBlock() {
        let wrapped = NotesController.timeoutWrapped("return \"x\"")
        #expect(wrapped.hasPrefix("with timeout of \(NotesController.appleEventTimeoutSeconds) seconds"))
        #expect(wrapped.contains("return \"x\""))
        #expect(wrapped.hasSuffix("end timeout"))
    }

    @Test func timeoutStaysSafelyUnderTheClientResponseDeadline() {
        // The E2E MCPClient's responseTimeout is 30s; a bounded Apple Event
        // must surface its result well before the client gives up.
        #expect(NotesController.appleEventTimeoutSeconds > 0)
        #expect(NotesController.appleEventTimeoutSeconds < 30)
    }

    @Test func wrappedScriptStillCompilesAndReturnsItsResult() throws {
        // run() wraps every source; a malformed wrapper would break every
        // script in the project, so pin that a trivial script survives it.
        let result = try NotesController().runReturningString("return \"ok\"")
        #expect(result == "ok")
    }

    @Test func wrappedScriptStillSurfacesErrorNumberAndMessage() {
        #expect {
            try NotesController().run("error \"boom\" number 1234")
        } throws: { error in
            guard case NotesController.ControllerError.executionFailed(let number, let message) = error else {
                return false
            }
            return number == 1234 && message.contains("boom")
        }
    }
}
