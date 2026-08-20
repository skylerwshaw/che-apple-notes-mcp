# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Apple Event stalls, root-caused and fixed** ([#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16)): every AppleScript
  now executes on the main thread. NSAppleScript's reply wait pumps a
  WaitNextEvent loop on the calling thread, but Apple Event replies are
  delivered to the process's main event queue: executed from a background
  thread (as every tool call was), the wait intermittently never saw its
  reply and parked forever in an untimed `mach_msg`. Stack-sampled live
  mid-stall while an independent `osascript` got answers from Notes in
  0.17s. This one bug was behind the ~30s first-call delays, the historic
  multi-minute stalls (8-12 min observed), and the gap between the server
  (30s+) and `osascript` (0.18s) running identical scripts. After the fix,
  1200 consecutive Apple Events measured max 1.05s / mean 63ms, first
  calls included; the previous build wedged within 25. Every script is
  also wrapped in `with timeout of 15 seconds`, which only reliably fires
  on the main thread for the same reason. A timing harness
  (`scripts/ae-timing-harness.py`) reproduces all measurements and
  captures stack samples on any future wedge.

### Added

- **Canonical folder identity** ([#2](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/2)): every `list_folders` row now carries `id`
  (Core Data URI `x-coredata://<store-uuid>/ICFolder/p<pk>`, which round-trips
  directly into `update_folder` / `delete_folder`), `uuid` (raw ZIDENTIFIER),
  `parent_id` (parent's canonical URI, `null` for roots and missing parents),
  and `path` (slash-joined titles from root; account-scoped, cycle-safe,
  presentation only). The URI host is the persistent store UUID from
  `Z_METADATA.Z_UUID`; Notes.app rejects URIs built with the account UUID.
  Applies to the SQLite read path; the no-FDA AppleScript fallback still
  emits the canonical `id` (as returned by AppleScript) but cannot supply
  `uuid` / `parent_id` / `path`.

### Changed

- Folder `id` switched from the bare ZIDENTIFIER (which the folder write tools
  could not consume) to the Core Data URI form, mirroring notes. The old value
  is still available as `uuid`; `parent_pk` remains for backward compatibility.

## [0.2.0] - 2026-04-22

### Added (Apple Notes Sharing, fully spec-driven)

- **6 new tools** for CloudKit share visibility + creation assistance:
  - `get_share_metadata` — reads ZICINVITATION row (shareURL, invitation counts, receivedDate, serverShareDataPresent) without deserializing the CKShare BLOB
  - `prepare_share_note` / `prepare_share_folder` — activate Notes.app, focus target, trigger `File → Share Note...` / `Share Folder...` menu so the user completes invitations manually (spec forbids auto-fill)
  - `list_folders` / `list_notes` / `search_notes` accept an optional `shared: bool?` filter
- **Read tools emit `shared: Bool`** on every folder and note (derived from AppleScript `shared` property + SQLite heuristic on `ZSERVERSHAREDATA` / `ZZONEOWNERNAME`)
- New capabilities `apple-notes-sharing-metadata` + `apple-notes-sharing-workflow` in `openspec/specs/`

### Changed

- `NotesStoreReader.getShareMetadata` uses a two-stage lookup: `ZICINVITATION` row (if exists) → heuristic fallback (`ZSERVERSHAREDATA IS NOT NULL OR ZZONEOWNERNAME IS NOT NULL`).
- `SQLQueries.listFolders` split into `listFoldersBase` + `listFoldersOrderSuffix` so the shared filter inserts predicates via composition instead of a fragile `replacingOccurrences` anchor search.
- `sharedRootObjectHeuristic` SQL now filters by `Z_ENT IN (:noteEntityID, :folderEntityID)` to defend against theoretical UUID collision across entity kinds.
- `handleGetShareMetadata` rejects AppleScript-URL-form identifiers (`x-coredata://…`) loudly with a `invalidArgument` error pointing callers at the raw `uuid` field, instead of silently returning `{isShared: false}`.
- AppleScript fallback path for `list_folders` / `list_notes` now throws `featureRequiresSQLite("…shared filter")` when the `shared` param is set but FDA is unavailable; previously dropped the filter silently.
- `deleteFolderRemovesAnEmptyFolder` E2E assertion switched from raw-string `contains` to `JSONDecoder` (the server uses prettyPrinted output, so `"deleted":true` never matched — regression since v0.1.0).

### Explicitly NOT Implemented (spec SHALL NOT)

- `create_share_link`, `invite_participant`, `revoke_share`, `list_participants` — Notes.app's CloudKit container is private; no public API path exists. The workflow-helper pair is the intended escape valve.

### Tests

- **112 unit tests** (up from 86 at v0.1.0) including new `NotesStoreReaderTests` (4 integration tests against temp SQLite fixtures) and `ServerHandlerTests` (5 handler error-path tests via a new `init(sqlite:)` test seam).
- **11 E2E tests** (up from 7), adding `ShareMetadataE2ETests`.

### Known Limits (carried from v0.1.0)

- Locked notes: body decode skipped (AES-encrypted)
- Pin/unpin writes: AppleScript limitation

## [0.1.0] - 2026-04-21

### Added

- Initial release
- **Dual-track architecture**: SQLite fast read + AppleScript safe write
- **18 MCP tools**:
  - Folders: `list_folders`, `create_folder`, `update_folder`, `delete_folder`
  - Notes: `list_notes`, `list_notes_quick`, `get_note`, `create_note`, `update_note`, `delete_note`, `move_note`
  - Search: `search_notes`
  - Batch: `create_notes_batch`, `move_notes_batch`, `delete_notes_batch`
  - Undo/Redo: `undo`, `redo`, `undo_history`
- **Body dual-track**: `body_text` or `body_html` input; both returned on read
- **Capability detection**: auto-probe Full Disk Access at startup, fall back to AppleScript for reads when denied
- **Account disambiguation**: `account` parameter for folder name collisions across iCloud / On My Mac
- `--cli` mode for direct tool invocation without MCP server
- `--setup` mode: probe FDA + trigger Automation permission dialog
- `--version` / `--help`

### Known Limits (v0.1.0)

- Locked notes: body decode skipped (AES-encrypted)
- Pin/unpin writes: AppleScript limitation
- Attachment writes: not supported
- Body HTML from SQLite: plaintext-fidelity only; v0.2.0 will render attribute runs
- 1 MB body cap
