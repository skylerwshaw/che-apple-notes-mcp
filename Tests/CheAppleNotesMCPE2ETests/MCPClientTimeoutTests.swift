import Foundation
import Testing

/// Transport-level tests for `MCPClient`. These drive stub servers written as
/// shell scripts, so they never touch Notes.app and run in seconds, unlike the
/// rest of this target.
@Suite(.serialized) struct MCPClientTimeoutTests {

    @Test func silentServerFailsAtTheDeadline() async throws {
        // Reads the request, stays alive, never answers.
        let stub = try StubServer(script: "cat > /dev/null\n")
        let client = try MCPClient(binaryPath: stub.path, responseTimeout: 1.0)
        defer { Task { await client.close() } }

        let started = Date()
        let outcome = await raceAgainstHang(seconds: 5) { await initializeOutcome(client) }

        guard let outcome else {
            Issue.record("initialize() never returned; responseTimeout is not bounding the wait")
            return
        }
        guard case .failure(let error) = outcome else {
            Issue.record("expected a timeout, got a result")
            return
        }
        #expect("\(error)" == "response timeout")
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func serverExitingWithoutReplyingReportsExitNotTimeout() async throws {
        // Consumes the request line, then exits.
        let stub = try StubServer(script: "head -n 1 > /dev/null\n")
        let client = try MCPClient(binaryPath: stub.path, responseTimeout: 10.0)
        defer { Task { await client.close() } }

        let outcome = await raceAgainstHang(seconds: 5) { await initializeOutcome(client) }

        guard let outcome, case .failure(let error) = outcome else {
            Issue.record("expected serverExitedEarly, got \(String(describing: outcome))")
            return
        }
        #expect("\(error)" == "server exited before responding")
    }

    @Test func responseSplitAcrossReadsStillParses() async throws {
        // Answers in two writes with a gap mid-JSON, then stays alive so the
        // follow-up `initialized` notification doesn't hit a closed pipe.
        let stub = try StubServer(script: """
            head -n 1 > /dev/null
            printf '{"jsonrpc":"2.0","id":1,"result":{"protoc'
            sleep 0.3
            printf 'olVersion":"2024-11-05"}}\\n'
            cat > /dev/null

            """)
        let client = try MCPClient(binaryPath: stub.path, responseTimeout: 10.0)
        defer { Task { await client.close() } }

        let outcome = await raceAgainstHang(seconds: 5) { await initializeOutcome(client) }

        guard let outcome else {
            Issue.record("initialize() never returned on a split response")
            return
        }
        #expect(try outcome.get().contains("2024-11-05"))
    }
}

// MARK: - Helpers

/// An executable shell script in a throwaway directory, standing in for the
/// MCP server binary.
private struct StubServer {
    let path: String

    init(script: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPClientStub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("stub-server")
        try ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        path = file.path
    }
}

private func initializeOutcome(_ client: MCPClient) async -> Result<String, Error> {
    do { return .success(try await client.initialize()) } catch { return .failure(error) }
}

/// Wait up to `seconds` for `body`, returning nil if it hasn't finished.
///
/// Deliberately abandons the task rather than awaiting it: the failure being
/// guarded against is a blocking `read(2)` inside `MCPClient`, which task
/// cancellation cannot reach. A task group would hang here just as the bug does.
private func raceAgainstHang<T: Sendable>(
    seconds: Double,
    _ body: @escaping @Sendable () async -> T
) async -> T? {
    let box = ResultBox<T>()
    Task { await box.set(await body()) }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let value = await box.value { return value }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await box.value
}

private actor ResultBox<T: Sendable> {
    var value: T?
    func set(_ newValue: T) { value = newValue }
}
