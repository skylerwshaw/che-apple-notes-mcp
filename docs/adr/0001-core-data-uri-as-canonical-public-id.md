# Core Data URIs are the canonical public ID for folders (and notes)

The MCP reads Apple Notes via SQLite but writes via AppleScript, and AppleScript addresses objects by their Core Data URI (`x-coredata://<store UUID>/<entity>/p<pk>`; for folders the host is the persistent store UUID from `Z_METADATA.Z_UUID`, not an account UUID — Notes rejects folder URIs built with the account UUID, verified against real AppleScript-returned ids). Notes already publish a `x-coredata://.../ICNote/p<pk>` URI as `id` (with the raw ZIDENTIFIER as `uuid`), but host it on the *account* UUID rather than the store UUID; folders published the bare ZIDENTIFIER as `id`, which the folder write tools could not consume. We decided folders adopt the store-UUID-hosted form: `id` = constructed Core Data URI (`ICFolder`), `uuid` = ZIDENTIFIER, `parent_id` in the same URI form.

The note-side account-UUID host is itself the same bug this ADR fixes for folders: confirmed against a live store (`Z_METADATA.Z_UUID` differs from the account `ZIDENTIFIER`; AppleScript rejects the account-UUID form with error -10006), so `update_note`/`delete_note`/`move_note` fail on an `id` taken from a `list_notes`/`search_notes` listing. Tracked as [#5](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/5); not fixed by this ADR, which scopes folders only.

## Considered Options

- **ZIDENTIFIER (UUID) as public `id`, resolve to the URI at write time.** Rejected: every write would need a SQLite lookup (breaking writes when Full Disk Access is absent), and it would diverge from the established note convention.
- **Expose raw `pk`/`parent_pk` integers.** Rejected: internal Core Data keys clients would have to join themselves, useless as AppleScript write targets.

## Consequences

- Folder `id` values from `list_folders` round-trip directly into `update_folder`/`delete_folder`/`move_note`-style AppleScript targets (fixes a pre-existing bug where the UUID form was emitted but the URI form was expected).
- Constructing the URI requires the persistent store UUID (`Z_METADATA.Z_UUID`), read once when the reader opens the store. (Initially assumed to be the account's ZIDENTIFIER; end-to-end verification showed Notes rejects that form.)
- Paths and titles are never identity: they are presentation-only convenience (see CONTEXT.md).
