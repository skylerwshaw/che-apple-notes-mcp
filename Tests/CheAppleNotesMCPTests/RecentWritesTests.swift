import Foundation
import Testing
@testable import CheAppleNotesMCP

/// Routing decision for read-repair (ADR 0002,
/// [#11](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/11)):
/// `get_note` reads live via AppleScript for ids this server wrote within
/// the TTL, and via SQLite otherwise. The clock is injected so expiry is
/// tested without sleeping and without Notes.app.
@Suite struct RecentWritesTests {

    /// Mutable reference clock the tracker reads through its `now` closure.
    private final class FakeClock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
    }

    private func makeTracker(ttl: TimeInterval = 15) -> (RecentWrites, FakeClock) {
        let clock = FakeClock()
        let tracker = RecentWrites(ttl: ttl, now: { clock.now })
        return (tracker, clock)
    }

    @Test func neverWrittenIdRoutesToSQLite() {
        let (tracker, _) = makeTracker()
        #expect(!tracker.isFresh("x-coredata://store/ICNote/p1"))
    }

    @Test func justWrittenIdRoutesLive() {
        let (tracker, _) = makeTracker()
        tracker.record("x-coredata://store/ICNote/p1")
        #expect(tracker.isFresh("x-coredata://store/ICNote/p1"))
    }

    @Test func writtenIdStillRoutesLiveJustBeforeTTL() {
        let (tracker, clock) = makeTracker(ttl: 15)
        tracker.record("id")
        clock.now += 14.9
        #expect(tracker.isFresh("id"))
    }

    @Test func writtenIdRoutesToSQLiteAfterTTL() {
        let (tracker, clock) = makeTracker(ttl: 15)
        tracker.record("id")
        clock.now += 15.1
        #expect(!tracker.isFresh("id"))
    }

    @Test func rerecordingRefreshesTheTTL() {
        let (tracker, clock) = makeTracker(ttl: 15)
        tracker.record("id")
        clock.now += 10
        tracker.record("id")
        clock.now += 10
        // 20s after the first write, but only 10s after the second.
        #expect(tracker.isFresh("id"))
    }

    @Test func idsExpireIndependently() {
        let (tracker, clock) = makeTracker(ttl: 15)
        tracker.record("old")
        clock.now += 10
        tracker.record("new")
        clock.now += 10
        #expect(!tracker.isFresh("old"))
        #expect(tracker.isFresh("new"))
    }
}
