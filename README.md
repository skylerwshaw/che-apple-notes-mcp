# che-apple-notes-mcp

macOS Apple Notes.app MCP Server — **SQLite fast read + AppleScript safe write**, 24 tools (folders, notes CRUD, search, batch, sharing visibility, undo/redo).

## Architecture

| Path | Backend | Operations |
|------|---------|-----------|
| Read | `NoteStore.sqlite` (Core Data, direct) | `list_folders`, `list_notes`, `list_notes_quick`, `get_note`, `search_notes`, `get_share_metadata` |
| Write | AppleScript via `NSAppleScript` | `create_note`, `update_note`, `delete_note`, `move_note`, `*_folder`, `*_batch` |
| Workflow | AppleScript UI automation | `prepare_share_note`, `prepare_share_folder` (activate Notes.app → open native Share sheet) |

**Why dual-track?** AppleScript round-trip is ~50 ms per call — fine for writes but painful for listing. SQLite direct read handles 1000+ notes in <10 ms. Writing to SQLite would corrupt CloudKit sync, so all writes stay on AppleScript.

If Full Disk Access isn't granted, read tools automatically fall back to AppleScript (same result, slower).

## Quick Start

### For Claude Desktop

#### Option A: MCPB One-Click Install (Recommended)

Download the latest `che-apple-notes-mcp.mcpb` from [Releases](https://github.com/PsychQuant/che-apple-notes-mcp/releases) and double-click to install.

#### Option B: Manual Configuration

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-apple-notes-mcp": {
      "command": "/usr/local/bin/CheAppleNotesMCP"
    }
  }
}
```

### For Claude Code (CLI)

#### Option A: Install as Plugin (Recommended)

The plugin includes slash commands (`/new-note`, `/search-notes`, `/list-folders`), a `notes-management` skill, and a SessionStart hook that keeps the binary up-to-date.

Two steps — register the marketplace once, then install the plugin:

```bash
# 1. Register the marketplace (one-time)
claude plugin marketplace add PsychQuant/psychquant-claude-plugins

# 2. Install the plugin
claude plugin install che-apple-notes-mcp@psychquant-claude-plugins
```

> **Inside Claude Code?** The slash-command equivalents `/plugin marketplace add PsychQuant/psychquant-claude-plugins` and `/plugin install che-apple-notes-mcp@psychquant-claude-plugins` work the same way.

> **Note:** The plugin wraps the MCP binary with auto-download. If the binary is not found at `~/bin/CheAppleNotesMCP`, it will be downloaded from GitHub Releases on first use.

#### Option B: Install as standalone MCP

If you only need the MCP server without plugin features:

```bash
# Create ~/bin if needed
mkdir -p ~/bin

# Download the latest release
curl -L https://github.com/PsychQuant/che-apple-notes-mcp/releases/latest/download/CheAppleNotesMCP -o ~/bin/CheAppleNotesMCP
chmod +x ~/bin/CheAppleNotesMCP

# Add to Claude Code
# --scope user    : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --              : separator between claude options and the command
claude mcp add --scope user --transport stdio che-apple-notes-mcp -- ~/bin/CheAppleNotesMCP
```

> **💡 Tip:** Always install the binary to a local directory like `~/bin/`. Avoid placing it in cloud-synced folders (Dropbox, iCloud, OneDrive) as file sync operations can cause MCP connection timeouts.

### Build from Source (Optional)

```bash
git clone https://github.com/PsychQuant/che-apple-notes-mcp.git
cd che-apple-notes-mcp
make release && make install
```

> **⚠️ Swift 6 / Xcode 18 users:** Do not use `swift build` directly — upstream MCP SDK has a concurrency error ([swift-sdk#214](https://github.com/modelcontextprotocol/swift-sdk/issues/214)). The Makefile auto-detects this and falls back to Swift 5 language mode.

On first use, macOS will prompt for **Notes.app automation** access — click "Allow".

Optionally, grant **Full Disk Access** to `~/bin/CheAppleNotesMCP` in System Settings → Privacy & Security → Full Disk Access to enable the SQLite fast path. Run `~/bin/CheAppleNotesMCP --setup` for interactive guidance.

### CLI Mode (No MCP Server)

All 24 tools can be invoked directly from the command line without running the MCP server:

```bash
# Flag-based: --key value pairs
CheAppleNotesMCP --cli list_folders
CheAppleNotesMCP --cli list_notes --limit 10 --sort desc

# JSON via stdin
echo '{"tool":"search_notes","arguments":{"keyword":"meeting"}}' | CheAppleNotesMCP --cli

# Use with Claude Code via shell
claude -p "Run: ~/bin/CheAppleNotesMCP --cli list_notes_quick --range today"
```

Useful for launchd jobs, shell scripts, CI pipelines, and agents that prefer subprocess over MCP protocol. Automation permission still required — run `CheAppleNotesMCP --setup` first if needed.

---

## All 24 Tools

<details>
<summary><b>Folders (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_folders` | List all folders across all accounts (iCloud / On My Mac). Rows carry canonical `id` (`x-coredata://…`, valid for `update_folder`/`delete_folder`), `uuid`, `parent_id`, and `path`. Supports `shared: bool?` filter (v0.2.0). |
| `create_folder` | Create a new folder in an account |
| `update_folder` | Rename a folder |
| `delete_folder` | Delete an empty folder |
</details>

<details>
<summary><b>Notes (7)</b></summary>

| Tool | Description |
|------|-------------|
| `list_notes` | List notes with filters (folder, account, pinned, locked, date range, shared). Every row carries `folder_path`; `recursive: true` (with `folder_id`) lists a folder's entire subtree in one call. |
| `list_notes_quick` | Preset ranges: `recent`, `today`, `this_week`, `pinned` |
| `get_note` | Fetch a single note with full body (text + HTML) and metadata |
| `create_note` | Create a note (body_text XOR body_html), optional folder + account |
| `update_note` | Update title and/or body by id |
| `delete_note` | Delete by id |
| `move_note` | Move a note to a different folder |
</details>

<details>
<summary><b>Search (1)</b></summary>

| Tool | Description |
|------|-------------|
| `search_notes` | SQL LIKE keyword search over title + snippet; `any` or `all` match mode. Supports `shared: bool?` filter (v0.2.0). |
</details>

<details>
<summary><b>Batch (3)</b></summary>

| Tool | Description |
|------|-------------|
| `create_notes_batch` | Create multiple notes in one AppleScript dispatch |
| `move_notes_batch` | Move multiple notes to the same destination folder |
| `delete_notes_batch` | Delete multiple notes |
</details>

<details>
<summary><b>Sharing (3 — new in v0.2.0)</b></summary>

| Tool | Description |
|------|-------------|
| `get_share_metadata` | Read `ZICINVITATION` row (shareURL, invitation counts, receivedDate, serverShareDataPresent) without deserializing the CKShare BLOB. Rejects `x-coredata://…` form loudly — pass the raw UUID. |
| `prepare_share_note` | Activate Notes.app, focus the target note, open `File → Share Note…`. User completes invitation in the native UI (spec forbids auto-fill). |
| `prepare_share_folder` | Same flow for folders (`Share Folder…`). |

All read tools also emit a `shared: Bool` field on every folder/note (derived from AppleScript `shared` property + SQLite heuristic on `ZSERVERSHAREDATA` / `ZZONEOWNERNAME`).

**Explicitly NOT implemented**: `create_share_link`, `invite_participant`, `revoke_share`, `list_participants` — Notes.app's CloudKit container is private. See `openspec/specs/apple-notes-sharing-workflow/` for the Path D rationale.
</details>

<details>
<summary><b>Undo/Redo (3)</b></summary>

| Tool | Description |
|------|-------------|
| `undo` | Revert the most recent write (process-local stack) |
| `redo` | Reapply an undone operation |
| `undo_history` | Show the in-memory undo history |
</details>

## Body Format (Dual-Track)

Input accepts **either** `body_text` (auto-wrapped in `<div>`, newlines → `<br>`) **or** `body_html` (raw, Notes.app normalizes). Not both.

Output returns **both** `body_text` and `body_html` for reads with `include_body=true`.

```jsonc
// Create with plaintext
{"tool":"create_note","arguments":{"title":"Idea","body_text":"Line 1\nLine 2","folder":"Notes"}}

// Returned by get_note
{
  "id": "x-coredata://<acct>/ICNote/p123",
  "uuid": "27CD8E81-4845-4D81-98A4-E8A65F211AB8",
  "title": "Idea",
  "body_text": "Line 1\nLine 2",
  "body_html": "<div>Line 1<br>Line 2</div>",
  "created_at": "2026-04-21T10:00:00Z",
  "modified_at": "2026-04-21T10:00:05Z",
  "folder": "Notes",
  "account": "iCloud",
  "pinned": false,
  "locked": false
}
```

## Permissions

| Permission | Purpose | When triggered |
|------------|---------|----------------|
| **Automation → Notes.app** | All write tools + read fallback | First write call, or `--setup` |
| **Full Disk Access** (recommended) | SQLite fast reads | Manual — System Settings → Privacy & Security → Full Disk Access |

Without Full Disk Access:
- `list_folders`, `list_notes`, `get_note` fall back to AppleScript (same result, 50–500× slower; `list_folders` rows keep the canonical `id` but omit `uuid` / `parent_id` / `path`)
- `list_notes_quick`, `search_notes`, `get_share_metadata` error out (they require SQLite)
- `list_folders` / `list_notes` / `search_notes` with `shared: true|false` throw `featureRequiresSQLite` — AppleScript fallback cannot honor the filter
- `list_notes` with `recursive: true` throws `featureRequiresSQLite` — subtree expansion has no AppleScript hierarchy fallback

## Same-Name Folder Disambiguation

When folder names collide across accounts (e.g., "Notes" on iCloud and On My Mac), pass the `account` parameter:

```json
{
  "title": "Shopping list",
  "body_text": "milk, eggs",
  "folder": "Notes",
  "account": "iCloud"
}
```

Available account names typically include `iCloud`, `On My Mac`, plus any configured accounts (Gmail, Yahoo, etc.). Use `list_folders` to inspect.

`list_notes`'s `folder` parameter applies the same rule: if the name matches more than one folder in scope (e.g. two `Archive` folders in different branches of the same account), the call errors naming the conflicting paths instead of silently listing the first match. Pass `folder_id` (from `list_folders`) to address a specific folder unambiguously.

## Recursive Note Listing

`list_notes(folder_id: "...", recursive: true)` returns notes from that folder and every descendant folder (its whole subtree), each carrying a `folder_path`. It requires a canonical `folder_id` (from `list_folders`, not a folder name) and SQLite access; descendant folders are resolved in-process from the already-loaded folder hierarchy, so it's one query regardless of subtree depth.

```json
{
  "folder_id": "x-coredata://.../ICFolder/p42",
  "recursive": true
}
```

## Known Limits

- **Locked notes**: metadata only; body is AES-encrypted and cannot be decoded programmatically.
- **Pin/unpin writes**: AppleScript doesn't expose the `pinned` attribute for writes (read OK).
- **Attachments**: read-only metadata; no upload/replace.
- **Body HTML from SQLite**: approximates via longest-UTF-8-string scan. If you need full HTML fidelity, use AppleScript path (requires reading via a tool that bypasses SQLite).
- **1 MB body cap** per note.
- **CloudKit share creation / invitation / revocation**: explicitly NOT implemented — Notes.app's CKContainer is private. Use `prepare_share_note` / `prepare_share_folder` to open the native Share sheet; the user completes invitations manually.
- Tested on **macOS 13/14/15**; protobuf schema may drift on future macOS.

## Testing

The project ships with two test targets that run under Swift Testing (`@Test` + `#expect`). Swift 6.0 toolchain is required (Xcode 16+ ships it).

```bash
make test-unit      # Pure-function unit tests — safe for CI, no macOS automation needed
make test-e2e       # End-to-end tests — requires running Notes.app + permissions
```

### Unit tests (`CheAppleNotesMCPTests`, 112 tests as of v0.2.0)

Cover AppleScript escaping, body/HTML formatting, protobuf decoding, SQL query templates, folder hierarchy, note entity, attachment locator, capability detection, share metadata JSON shape, and handler error paths (`ServerHandlerTests` uses a new `init(sqlite:)` test seam to drive handlers with a nil SQLite reader). `NotesStoreReaderTests` runs 4 integration tests against temp SQLite fixtures. No Notes.app, no network access.

### E2E tests (`CheAppleNotesMCPE2ETests`, 11 tests as of v0.2.0)

Spawn `.build/debug/CheAppleNotesMCP` as a subprocess and exercise every MCP tool over stdio JSON-RPC. Each test operates inside a dedicated `__CheMCPTest_{UUID}__` folder under **On My Mac** — the folder is created at setup and deleted at teardown. iCloud is intentionally skipped to avoid sync delays. `ShareMetadataE2ETests` covers the `notShared` / `shared=true exclude` / `shared=false include` / `x-coredata rejection` paths.

First-time setup:

1. **Grant Full Disk Access** to the debug binary (so SQLite read path works). Open System Settings → Privacy & Security → Full Disk Access → drag in `.build/debug/CheAppleNotesMCP`.
2. **Grant Automation permission** for Notes.app. Run once: `./.build/debug/CheAppleNotesMCP --setup` — this triggers the system consent dialog.
3. Run `make test-e2e`.

If a test is interrupted and leaves `__CheMCPTest_*__` folders behind:

```bash
./scripts/cleanup-test-folders.sh
```

E2E tests are **not** part of CI — macOS GitHub runners don't have Notes.app permissions. Run them locally before releases.

## Version History

See [CHANGELOG.md](CHANGELOG.md) for full release notes.

| Version | Changes |
|---------|---------|
| v0.2.0 | 6 new sharing tools (`get_share_metadata`, `prepare_share_note`, `prepare_share_folder`, + `shared` filter on `list_folders` / `list_notes` / `search_notes`). `shared: Bool` now on every read. Spec-driven via `openspec/specs/apple-notes-sharing-{metadata,workflow}/`. 112 unit + 11 E2E tests. |
| v0.1.0 | Initial release — 18 tools, dual-track architecture, dual-track body, FDA fallback, undo/redo, batch ops |

## Technical Details

- **Current Version**: v0.2.0
- **macOS**: 13.0 or later
- **Swift**: 6.0+ toolchain (executable target pinned to Swift 5 language mode; test targets use Swift Testing)
- **MCP SDK**: modelcontextprotocol/swift-sdk 0.12.x
- **Architecture**: Universal binary (arm64 + x86_64)
- **Code signing**: ad-hoc (`codesign --sign -`)

## License

MIT © Che Cheng
