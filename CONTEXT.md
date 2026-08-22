# Apple Notes MCP

An MCP server that exposes Apple Notes to agents: reads go directly against the Notes SQLite store (read-only), writes go through Notes.app via AppleScript. Reads are eventually consistent (Notes.app flushes to SQLite lazily; a rename was measured taking 4-8s to surface), except that `get_note` reads live via AppleScript for ids this server recently wrote, so read-after-write of the server's own writes is consistent (see ADR 0002).

## Language

**Canonical ID**:
The stable public identity of a note or folder, in Core Data URI form (`x-coredata://<store UUID>/<entity>/p<pk>`; the host is the persistent store's UUID, not an account's). The only identity write tools accept. Emitted as `id`.
_Avoid_: AppleScript ID, Core Data ID, pk

**UUID**:
The raw internal identifier (ZIDENTIFIER) of a note or folder. Diagnostic and lookup use only; not a write target. Emitted as `uuid`.
_Avoid_: identifier, raw ID

**Identity**:
The typed result of parsing an incoming id string: which form it is (Canonical ID or UUID), and, when a Canonical ID's URI segment says so, which entity it names. Every tool declares which forms it accepts; the mismatch is rejected at the parse boundary, not wherever the string next gets used.
_Avoid_: id form, identity type

**Path**:
The slash-joined folder titles from root to a folder (e.g. `Coparenting/Jaime/2024`). Presentation and convenience only; never identity, because renames and moves change it.
_Avoid_: full name, location

**Folder**:
A container of notes and other folders within one account. Folder titles are not unique, even among siblings' descendants; only the canonical ID identifies a folder.

**Subtree**:
A folder plus all of its descendant folders, to any depth. "Recursive" operations act on a subtree.
_Avoid_: tree (reserved for the whole hierarchy), children (direct only)

**Account**:
A top-level Notes container (e.g. iCloud, On My Mac). Every folder and note belongs to exactly one account; hierarchy never crosses accounts.

**Commit point**:
The single route every mutation takes. Performing a write and recording its consequences (freshness for read-repair, undo state) is one act; each tool's bookkeeping policy is declared there, never implied by an absent line of code.
_Avoid_: write path, bookkeeping

**Scripting**:
The write-side channel to Notes.app: everything the server asks the app to do (create, rename, move, delete, share preparation, and live reads for freshness). AppleScript is how the production side speaks; the concept is the asking, not the mechanism.
_Avoid_: AppleScript layer, controller, automation
