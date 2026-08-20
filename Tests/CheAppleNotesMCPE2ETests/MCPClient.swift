import Foundation

/// MCP JSON-RPC 2.0 client for end-to-end tests.
/// Spawns the debug binary as a child process and exchanges newline-delimited
/// JSON messages over stdio.
///
/// Arguments passed to `callTool` are raw JSON strings to keep the public API
/// `Sendable`-clean under Swift 6 strict concurrency. Callers construct the
/// JSON themselves (string interpolation or `JSONSerialization`).
actor MCPClient {

    // MARK: - Types

    struct ToolInfo: Codable, Sendable {
        let name: String
        let description: String?
    }

    struct CallToolResult: Sendable {
        let text: String
        let isError: Bool
        let rawJSON: String
    }

    enum MCPError: Error, CustomStringConvertible {
        case spawnFailed(String)
        case serverExitedEarly
        case protocolError(String)
        case serverError(code: Int, message: String)
        case responseTimeout

        var description: String {
            switch self {
            case .spawnFailed(let s): return "spawn failed: \(s)"
            case .serverExitedEarly: return "server exited before responding"
            case .protocolError(let s): return "protocol error: \(s)"
            case .serverError(let code, let message): return "server error \(code): \(message)"
            case .responseTimeout: return "response timeout"
            }
        }
    }

    // MARK: - State

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private var nextId: Int = 1
    private var stdoutBuffer = Data()
    private let responseTimeout: TimeInterval
    private var closed = false
    /// Replies read off the wire whose id belongs to another in-flight
    /// request. A shared client (see TestFixture's SharedServer) can have
    /// several requests awaiting concurrently; whichever waiter reads a line
    /// parks non-matching replies here instead of dropping them.
    private var parkedResponses: [Int: [String: Any]] = [:]

    // MARK: - Init

    /// Spawn a new MCP server child process.
    /// - Parameters:
    ///   - binaryPath: absolute path to the built binary. Defaults to
    ///     `$PWD/.build/debug/CheAppleNotesMCP`.
    ///   - responseTimeout: how long a single request waits for its reply.
    ///     The 60s default still bounds a genuine hang (the point of
    ///     [#13](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/13)) while clearing the ~30s Automation/TCC evaluation a
    ///     fresh server process pays on its first Apple Event
    ///     ([#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16)) — a 30s deadline sat exactly on top of that cost, so
    ///     every first call was a photo-finish coin flip.
    init(
        binaryPath: String = MCPClient.defaultBinaryPath,
        responseTimeout: TimeInterval = 60
    ) throws {
        // A child exiting between our liveness check and a pipe write is
        // unavoidable; without this, that write's SIGPIPE kills the entire
        // test runner (signal 13). Ignored process-wide so send() sees EPIPE
        // and can throw serverExitedEarly instead. Idempotent.
        signal(SIGPIPE, SIG_IGN)

        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw MCPError.spawnFailed("\(binaryPath): \(error.localizedDescription)")
        }

        self.process = proc
        self.responseTimeout = responseTimeout
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        // Non-blocking stdout is what makes `responseTimeout` real: a blocking
        // read on a live-but-silent server never returns, so `waitForResponse`
        // never gets to re-check its deadline. Only the parent's read end is
        // affected; the child holds a separate open file description.
        _ = fcntl(self.stdoutHandle.fileDescriptor, F_SETFL, O_NONBLOCK)

        // Drain stderr in background so the server doesn't block on a full pipe.
        // Must be a real Thread, not Task.detached: `availableData` blocks, and
        // a blocked cooperative-pool thread is never returned to the pool — a
        // handful of clients alive at once (parallel suites) can starve the
        // pool and deadlock the whole test run.
        let stderrHandle = stderrPipe.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                // Intentionally discarded; tests do not assert on log output.
                _ = chunk
            }
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    static var defaultBinaryPath: String {
        let cwd = FileManager.default.currentDirectoryPath
        return "\(cwd)/.build/debug/CheAppleNotesMCP"
    }

    /// Whether the child is still running and this client is usable.
    var isAlive: Bool { !closed && process.isRunning }

    /// Terminate the child process. Safe to call multiple times.
    func close() {
        guard !closed else { return }
        closed = true
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Public API

    /// Send `initialize` request per MCP spec. Must be called once before any
    /// other method. Returns the server's `result` as a raw JSON string.
    func initialize() async throws -> String {
        let params = #"{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"CheAppleNotesMCPE2E","version":"1.0"}}"#
        let resultJSON = try await request(method: "initialize", paramsJSON: params)
        // Follow MCP handshake: send the initialized notification (no response).
        try sendNotification(method: "notifications/initialized")
        return resultJSON
    }

    /// Return the tools advertised by the server.
    func listTools() async throws -> [ToolInfo] {
        let resultJSON = try await request(method: "tools/list", paramsJSON: "{}")
        let data = Data(resultJSON.utf8)
        struct Wrapper: Codable { let tools: [ToolInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).tools
    }

    /// Invoke a tool with a raw JSON argument object.
    /// Example: `callTool(name: "create_note", arguments: #"{"title":"T"}"#)`.
    func callTool(name: String, arguments: String = "{}") async throws -> CallToolResult {
        // Compose params inline as raw JSON so we don't cross actor boundary
        // with [String: Any].
        let sanitizedArgs = arguments.isEmpty ? "{}" : arguments
        let escapedName = name.replacingOccurrences(of: "\"", with: "\\\"")
        let paramsJSON = #"{"name":"\#(escapedName)","arguments":\#(sanitizedArgs)}"#
        let resultJSON = try await request(method: "tools/call", paramsJSON: paramsJSON)

        // Extract `content[0].text` and `isError` from the raw JSON result.
        struct CallToolRaw: Codable { let content: [ContentItem]; let isError: Bool? }
        struct ContentItem: Codable { let type: String; let text: String? }
        let data = Data(resultJSON.utf8)
        let decoded = try JSONDecoder().decode(CallToolRaw.self, from: data)
        let text = decoded.content.first?.text ?? ""
        return CallToolResult(text: text, isError: decoded.isError ?? false, rawJSON: resultJSON)
    }

    // MARK: - Wire

    private func request(method: String, paramsJSON: String) async throws -> String {
        let id = nextId
        nextId += 1
        let escapedMethod = method.replacingOccurrences(of: "\"", with: "\\\"")
        let message = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(escapedMethod)","params":\#(paramsJSON)}"#
        try send(message)
        return try await waitForResponse(id: id)
    }

    private func sendNotification(method: String) throws {
        let escapedMethod = method.replacingOccurrences(of: "\"", with: "\\\"")
        let message = #"{"jsonrpc":"2.0","method":"\#(escapedMethod)"}"#
        try send(message)
    }

    /// Writes with write(2) rather than FileHandle so a dead child is a
    /// thrown error, not a fatality: FileHandle.write raises an uncatchable
    /// ObjC exception on a broken pipe, and without `signal(SIGPIPE, SIG_IGN)`
    /// (installed in init) the kernel kills the whole test runner outright —
    /// observed as the full E2E run dying with signal 13 the moment any
    /// child (a deliberately-exiting stub server, a terminated shared
    /// server) went away mid-write.
    private func send(_ jsonLine: String) throws {
        guard !closed else { throw MCPError.serverExitedEarly }
        // The transport is newline-delimited: an embedded newline (e.g. a
        // caller interpolating a multi-line raw string as arguments) splits
        // the request into fragments the server silently discards, and the
        // call hangs to the response deadline. Fail loudly instead.
        guard !jsonLine.contains("\n") else {
            throw MCPError.protocolError("message contains embedded newline; JSON-RPC framing is one line per message")
        }
        var data = Data(jsonLine.utf8)
        data.append(0x0A)
        let fd = stdinHandle.fileDescriptor
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE { throw MCPError.serverExitedEarly }
                    throw MCPError.protocolError("write failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    private func waitForResponse(id: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            if let parked = parkedResponses.removeValue(forKey: id) {
                return try unpackResponse(parked)
            }
            guard let line = try readLine() else {
                try await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
                continue
            }
            guard !line.isEmpty else { continue }

            // Parse just enough to match the id and detect error/result.
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue  // ignore malformed
            }
            guard let responseId = json["id"] as? Int else {
                continue  // notification or malformed — not a reply
            }
            guard responseId == id else {
                parkedResponses[responseId] = json  // another waiter's reply
                continue
            }

            return try unpackResponse(json)
        }
        throw MCPError.responseTimeout
    }

    private func unpackResponse(_ json: [String: Any]) throws -> String {
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown"
            throw MCPError.serverError(code: code, message: message)
        }
        // Re-serialize just the `result` field so callers can re-parse.
        guard let result = json["result"] else {
            throw MCPError.protocolError("response missing result and error")
        }
        let resultData = try JSONSerialization.data(withJSONObject: result)
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }

    /// Read one newline-terminated JSON line from stdout. Returns nil if none is
    /// available yet, so the caller's deadline check keeps running.
    private func readLine() throws -> Data? {
        if let line = takeBufferedLine() { return line }

        // The descriptor is O_NONBLOCK (see init), so this returns immediately.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes {
            read(stdoutHandle.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count < 0 {
            // Nothing readable yet, or the read was interrupted. Either way the
            // caller should poll again rather than treat it as an error.
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw MCPError.protocolError("read failed: \(String(cString: strerror(errno)))")
        }
        if count == 0 {
            // Genuine EOF: the child's stdout write end is closed, so no
            // response can ever arrive.
            throw MCPError.serverExitedEarly
        }
        stdoutBuffer.append(contentsOf: buffer[0..<count])
        return takeBufferedLine()
    }

    /// Pop the first complete line out of `stdoutBuffer`, if there is one.
    /// Partial lines stay buffered so a response split across reads reassembles.
    private func takeBufferedLine() -> Data? {
        guard let idx = stdoutBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(stdoutBuffer[stdoutBuffer.startIndex..<idx])
        stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...idx)
        return line
    }
}
