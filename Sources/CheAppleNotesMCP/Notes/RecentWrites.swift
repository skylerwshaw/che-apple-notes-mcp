import Foundation

/// Ids of notes this server instance has itself written, each with the time
/// of the write. Read-repair (ADR 0002,
/// [#11](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/11)):
/// Notes.app flushes AppleScript writes into NoteStore.sqlite lazily (a
/// rename was measured taking 4-8s), so `get_note` for an id written within
/// `ttl` takes the live AppleScript read path instead of SQLite. After the
/// TTL the SQLite path resumes. The default 15s comfortably exceeds the
/// measured flush lag.
///
/// Process-local and unsynchronized, like `UndoStack` (tool calls arrive
/// serialized over stdio). `now` is injectable so expiry is unit-testable
/// without sleeping.
final class RecentWrites {
    private var written: [String: Date] = [:]
    private let ttl: TimeInterval
    private let now: () -> Date

    init(ttl: TimeInterval = 15, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    /// Remember that this server just wrote note `id`. Expired entries are
    /// pruned here, so the map only ever holds ids written within the TTL.
    func record(_ id: String) {
        let cutoff = now().addingTimeInterval(-ttl)
        written = written.filter { $0.value > cutoff }
        written[id] = now()
    }

    /// Whether `id` was written by this server within the TTL, i.e. whether
    /// `get_note` should read it live instead of from SQLite.
    func isFresh(_ id: String) -> Bool {
        guard let writtenAt = written[id] else { return false }
        return now().timeIntervalSince(writtenAt) < ttl
    }
}
