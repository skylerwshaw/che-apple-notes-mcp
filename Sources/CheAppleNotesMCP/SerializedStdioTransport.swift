import Foundation
import Logging
import MCP

/// Serializes frame writes over the SDK's `StdioTransport`.
///
/// `StdioTransport.send` is actor-reentrant: it writes a message in chunks,
/// and when the pipe is full it `await`s (Task.sleep on EAGAIN), letting a
/// concurrent `send` splice its bytes into the middle of the in-progress
/// frame. Any two responses in flight whose combined size exceeds the 64KB
/// pipe buffer can corrupt the stream — observed as two concurrent
/// ~70KB `list_folders` responses interleaved at exactly the 64KB boundary,
/// producing unparseable JSON lines (issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16) fallout, upstream SDK bug).
///
/// This wrapper chains every `send` behind the previous one, so exactly one
/// frame is ever being written. Reads and connection lifecycle delegate
/// straight through.
actor SerializedStdioTransport: Transport {
    nonisolated let logger = Logger(label: "che-apple-notes-mcp.serialized-stdio")

    private let inner: StdioTransport
    private var stream: AsyncThrowingStream<Data, Swift.Error>?
    private var tail: Task<Void, Swift.Error>?

    init(wrapping inner: StdioTransport = StdioTransport()) {
        self.inner = inner
    }

    func connect() async throws {
        try await inner.connect()
        // Captured here because receive() below must be synchronous (protocol
        // shape) and cannot hop to the inner actor.
        stream = await inner.receive()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ data: Data) async throws {
        let previous = tail
        // FIFO: `tail` is read and replaced with no await in between, so
        // every send waits for its predecessor (success or failure alike)
        // before the inner transport writes a single byte of it.
        let next = Task { [inner] in
            _ = try? await previous?.value
            try await inner.send(data)
        }
        tail = next
        try await next.value
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream ?? AsyncThrowingStream { $0.finish() }
    }
}
