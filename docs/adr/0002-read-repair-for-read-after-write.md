# Read-repair for read-after-write; reads are otherwise eventually consistent

Reads come from the Notes SQLite store, which Notes.app flushes lazily (a rename was measured taking 4-8s to become visible to SQLite-backed reads; creates typically settle in under a second). AppleScript writes return before that flush, so `update_note` followed by `get_note` could return the pre-write value ([#11](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/11)). The post-write passive WAL checkpoint never mitigated this: it ran on a read-only handle, which checkpoints nothing while still returning `SQLITE_OK` ([#12](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/12)).

**Decision:** the server keeps a short-lived record of note ids it has itself written (create, update, move, delete, undo/redo, batch). `get_note` for a recently written id reads live state via AppleScript instead of SQLite, then reverts to the SQLite path once the record expires. This restores read-after-write consistency for the server's own writes with no API change and no added write latency. Every other read tool (`list_notes`, `search_notes`, `list_notes_quick`) remains eventually consistent, and says so in its tool description. The no-op checkpoint is deleted.

## Considered Options

- **Document the staleness and accept it.** Rejected as the whole answer: mutate-then-confirm is the dominant agent pattern, and clients have no settle hook, so documentation alone just describes a trap. Kept for the list/search tools, where eventual consistency is a normal contract.
- **Block write handlers until the write is observable in SQLite.** Rejected: it waits up to the measured 4-8s on another process's idle flush, and on timeout it must return success-with-possibly-stale-data anyway, which is the documentation option plus a latency tax. The fresh state is available immediately via AppleScript; waiting for a disk cache to catch up to data we can fetch live buys nothing.
- **A `fresh: true` argument on `get_note`.** Rejected as the primary fix: the default path stays silently stale and freshness depends on the caller thinking to ask. Its mechanism (the AppleScript live read) is exactly what read-repair uses, triggered automatically by the server, which knows what it wrote.

## Consequences

- Read-after-write consistency holds only for writes made through this server instance. Edits from other devices or apps still lag until Core Data flushes; that is inherent to reading a store another process owns.
- `get_note` on a just-deleted id reflects the delete immediately instead of serving the stale SQLite row. Verified empirically: Notes soft-deletes (`delete note` moves the note to Recently Deleted, where AppleScript still resolves its id), so the live read returns the note located in Recently Deleted rather than not-found. This matches the server's steady-state behavior, since the SQLite note query filters `ZMARKEDFORDELETION` and post-flush reads fall through to the same AppleScript path.
- A recently written id pays an AppleScript roundtrip on `get_note` until its tracking entry expires, even when the flush has already landed. The entry TTL must comfortably exceed the measured 4-8s flush lag.
- [#12](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/12) resolves as pure deletion: nothing pretends to establish freshness anymore.
