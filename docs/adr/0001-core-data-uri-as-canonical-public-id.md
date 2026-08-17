# Core Data URIs are the canonical public ID for folders and notes

The MCP reads Apple Notes via SQLite but writes via AppleScript, and AppleScript addresses objects by their Core Data URI (`x-coredata://<store UUID>/<entity>/p<pk>`; the host is the persistent store UUID from `Z_METADATA.Z_UUID`, not an account UUID: Notes rejects URIs built with the account UUID, verified against real AppleScript-returned ids, for both folders and notes). Folders originally published the bare ZIDENTIFIER as `id`, which the folder write tools could not consume; notes published a `x-coredata://.../ICNote/p<pk>` URI as `id` but hosted it on the *account* UUID rather than the store UUID ([#5](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/5)), so `update_note`/`delete_note`/`move_note` failed on an `id` taken from a `list_notes`/`search_notes` listing. Both adopt the store-UUID-hosted form: `id` = constructed Core Data URI (`ICFolder`/`ICNote`), `uuid` = ZIDENTIFIER, `parent_id` in the same URI form.

## Considered Options

- **ZIDENTIFIER (UUID) as public `id`, resolve to the URI at write time.** Rejected: every write would need a SQLite lookup (breaking writes when Full Disk Access is absent), and it would diverge from the established note convention.
- **Expose raw `pk`/`parent_pk` integers.** Rejected: internal Core Data keys clients would have to join themselves, useless as AppleScript write targets.

## Consequences

- Folder and note `id` values from `list_folders`/`list_notes`/`search_notes` round-trip directly into `update_folder`/`delete_folder`/`update_note`/`delete_note`/`move_note`-style AppleScript targets (fixes pre-existing bugs where the wrong host, or no URI form at all, was emitted).
- Constructing the URI requires the persistent store UUID (`Z_METADATA.Z_UUID`), read once when the reader opens the store. (Initially assumed to be the account's ZIDENTIFIER; end-to-end verification showed Notes rejects that form.)
- Paths and titles are never identity: they are presentation-only convenience (see CONTEXT.md).
