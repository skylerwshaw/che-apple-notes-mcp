import Foundation
import Testing

/// Regression coverage for issue #15: `createFixtureFolder` must not attempt
/// `create_folder(account: "On My Mac")` when that account isn't present,
/// because a failing account lookup can cost ~30s in the real server, past
/// the client's response timeout. These stub servers never touch Notes.app,
/// so they run in milliseconds regardless of which branch is taken.
@Suite(.serialized) struct FixtureAccountResolutionTests {

    @Test func skipsSlowOnMyMacAttemptWhenAccountAbsent() async throws {
        // list_folders reports no "On My Mac" folder; create_folder for that
        // account sleeps well past the client's timeout, as the real server
        // does when the account doesn't exist (issue #15's -1728 stall).
        let stub = try StubServer(onMyMacPresent: false, onMyMacDelay: 2.0)
        let client = try MCPClient(binaryPath: stub.path, responseTimeout: 0.5)
        defer { Task { await client.close() } }
        _ = try await client.initialize()

        let started = Date()
        let result = try await createFixtureFolder(client: client, folderName: "__CheMCPTest_STUB__")
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 0.5, "took \(elapsed)s — fell into the slow On My Mac attempt instead of skipping it")
        #expect(result?.1 == nil, "expected the default-account fallback, got \(String(describing: result))")
    }

    @Test func stillPrefersOnMyMacWhenPresent() async throws {
        let stub = try StubServer(onMyMacPresent: true, onMyMacDelay: 0)
        let client = try MCPClient(binaryPath: stub.path, responseTimeout: 5.0)
        defer { Task { await client.close() } }
        _ = try await client.initialize()

        let result = try await createFixtureFolder(client: client, folderName: "__CheMCPTest_STUB__")

        #expect(result?.1 == "On My Mac")
    }
}

/// A tiny python3 MCP server standing in for the real one. `list_folders`
/// reports (or omits) an "On My Mac" folder; `create_folder` succeeds
/// instantly for any account except "On My Mac" when absent, where it
/// sleeps `onMyMacDelay` seconds before erroring, mirroring the real -1728
/// stall.
private struct StubServer {
    let path: String

    init(onMyMacPresent: Bool, onMyMacDelay: Double) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FixtureAccountStub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("stub-server.py")
        let listFoldersBody = onMyMacPresent
            ? #"[{"id":"F1","title":"Notes","account_name":"On My Mac"}]"#
            : #"[{"id":"F1","title":"Notes","account_name":"iCloud"}]"#
        let script = """
            #!/usr/bin/env python3
            import sys, json, time

            def send(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                req = json.loads(line)
                method = req.get("method")
                id_ = req.get("id")
                if method == "initialize":
                    send({"jsonrpc": "2.0", "id": id_, "result": {
                        "protocolVersion": "2024-11-05", "capabilities": {},
                        "serverInfo": {"name": "stub", "version": "0"}}})
                elif method == "notifications/initialized":
                    continue
                elif method == "tools/call":
                    name = req["params"]["name"]
                    args = req["params"].get("arguments", {})
                    if name == "list_folders":
                        send({"jsonrpc": "2.0", "id": id_, "result": {
                            "content": [{"type": "text", "text": '\(listFoldersBody)'}],
                            "isError": False}})
                    elif name == "create_folder":
                        account = args.get("account")
                        if account == "On My Mac" and \(onMyMacPresent ? "False" : "True"):
                            time.sleep(\(onMyMacDelay))
                            send({"jsonrpc": "2.0", "id": id_, "result": {
                                "content": [{"type": "text", "text": "AppleScript error -1728"}],
                                "isError": True}})
                        else:
                            payload = json.dumps({"id": "FAKE-ID", "title": args.get("title", ""),
                                                   "account": account or ""})
                            send({"jsonrpc": "2.0", "id": id_, "result": {
                                "content": [{"type": "text", "text": payload}],
                                "isError": False}})
            """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        path = file.path
    }
}
