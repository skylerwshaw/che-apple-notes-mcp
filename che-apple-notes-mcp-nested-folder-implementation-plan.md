# Nested Folder Support for `che-apple-notes-mcp`

## Purpose

This document treats nested-folder support for [`PsychQuant/che-apple-notes-mcp`](https://github.com/PsychQuant/che-apple-notes-mcp) as a separate software-development body of work.

The goal is to evolve the MCP from:

- correctly **reading** Apple Notes that happen to live in nested folders,
- exposing a mostly flat folder API,
- and performing writes by folder name,

into an MCP that can safely and explicitly:

- expose folder hierarchy,
- address folders by stable IDs,
- recursively list notes beneath a folder subtree,
- create and move notes using folder IDs,
- create nested folders,
- move folders within the hierarchy,
- and support these operations with tests, safety checks, backward compatibility, and documentation.

The implementation should preserve the repository’s current architectural principle:

> **Read Apple Notes SQLite directly in read-only mode; perform writes through AppleScript.**

Direct writes to Apple Notes’ SQLite/Core Data store should remain out of scope because of CloudKit/Core Data synchronization risk.

---

# 1. Current-State Findings

## 1.1 Nested folders are already understood internally

The SQLite layer already reads the folder parent relationship.

Relevant model:

`Sources/CheAppleNotesMCP/NotesSQLite/NoteEntity.swift`

```swift
struct Folder {
    let pk: Int64
    let identifier: String
    let title: String
    let accountPK: Int64?
    let accountName: String?
    let parentPK: Int64?    // ZPARENT FK for nested folders
    let isHiddenContainer: Bool
    let sortOrder: Int?
    let shared: Bool
}
```

The SQL query already selects `ZPARENT`.

Relevant file:

`Sources/CheAppleNotesMCP/NotesSQLite/SQLQueries.swift`

Conceptually:

```sql
SELECT
    f.Z_PK,
    f.ZIDENTIFIER,
    ...,
    f.ZOWNER,
    f.ZPARENT,
    ...
FROM ZICCLOUDSYNCINGOBJECT f
```

The repository already contains a hierarchy builder:

`Sources/CheAppleNotesMCP/NotesSQLite/FolderHierarchy.swift`

Its purpose is explicitly to turn the flat folder rows into a recursive tree using `ZPARENT`.

Therefore:

- nested folders are **not** an unknown Apple Notes data-model problem;
- the core read model already supports nesting;
- the missing work is primarily API exposure, recursive querying, ID normalization, and write support.

---

## 1.2 Notes inside nested folders are already readable

Notes point directly to their containing folder through `ZFOLDER`.

`NotesStoreReader.listNotes()` already supports filtering by an exact folder identifier / Core Data folder ID.

Conceptually:

```swift
if let pk = folderPKFromURL {
    extras.append("n.ZFOLDER = :folderPK")
}
```

This means a note being inside:

```text
Coparenting
└── Jaime
    └── High Conflict
        └── 2024
```

does not prevent it from being read.

If the MCP knows the exact folder ID for `2024`, it can already do the equivalent of:

```text
list_notes(folder_id: "<2024-folder-id>")
```

and then:

```text
get_note(id: "<note-id>")
```

to fetch the full note.

### Current limitation

`list_notes(folder_id: ...)` is **direct-folder only**.

It does not currently mean:

> “List all notes under this folder and all descendant folders.”

That recursive behavior is one of the highest-value additions.

---

## 1.3 `list_folders` exposes insufficient hierarchy identity

The MCP advertises folder hierarchy, but the current public serialization is effectively flat.

The handler does approximately:

```swift
return jsonify(folders.map(folderToDict))
```

and `folderToDict` exposes values such as:

```swift
[
    "id": f.identifier,
    "title": f.title,
    "account_name": f.accountName ?? "",
    "parent_pk": f.parentPK as Any,
    ...
]
```

The problem is that the child exposes `parent_pk`, while folder responses do not clearly expose each folder’s own `pk` as a first-class public field.

A client may receive:

```json
{
  "id": "child-uuid",
  "title": "2024",
  "parent_pk": 723
}
```

without a clean public field that identifies which returned folder corresponds to `pk = 723`.

The server itself can reconstruct the hierarchy, but MCP clients should not have to reverse-engineer internal Core Data primary keys.

---

## 1.4 Existing folder CRUD is top-level oriented

Current folder operations include:

- `list_folders`
- `create_folder`
- `update_folder`
- `delete_folder`

Current creation accepts:

```text
title
account?
```

but no parent.

The AppleScript builder currently creates a folder at the account level, conceptually:

```applescript
tell application "Notes"
    make new folder with properties {name:"Foo"} at account "iCloud"
end tell
```

There is no current:

- `parent_id` on `create_folder`,
- `move_folder`,
- path-aware creation,
- or nested-folder write API.

---

## 1.5 Note write APIs use folder names

Current note creation and movement resolve folders by name/account.

Conceptually:

```applescript
folder "Archive" of account "iCloud"
```

This is fragile once folder nesting matters.

For example:

```text
Coparenting
└── Archive

Work
└── Archive
```

A folder name alone is not a sufficiently strong identifier.

Stable folder IDs should become the preferred write target.

---

# 2. Design Principles

The implementation should follow these rules.

## 2.1 IDs are canonical; paths are ergonomic

Stable IDs should be the authoritative identity.

Human-readable paths such as:

```text
Coparenting/Jaime/High Conflict/2024
```

should be computed and exposed for convenience, but should not be treated as persistent identity because paths change when folders are renamed or moved.

Recommended public folder fields:

```json
{
  "id": "x-coredata://.../ICFolder/p812",
  "uuid": "...",
  "title": "2024",
  "path": "Coparenting/Jaime/High Conflict/2024",
  "account": "iCloud",
  "parent_id": "x-coredata://.../ICFolder/p723",
  "shared": false
}
```

Optional diagnostic fields may include internal PKs, but agents should not need them.

---

## 2.2 Preserve backward compatibility

Existing folder-name parameters should continue to work where practical.

For example:

```text
move_note(id, folder="Archive", account="iCloud")
```

can remain valid.

But new APIs should prefer:

```text
move_note(id, folder_id="x-coredata://...")
```

If both `folder_id` and `folder` are supplied:

- `folder_id` should win, or
- the server should reject ambiguous mixed addressing.

Prefer explicit validation rather than silent disagreement.

---

## 2.3 Never write Apple Notes SQLite directly

Continue using:

- SQLite for reads,
- AppleScript for writes.

Even though `ZPARENT` is visible in SQLite, do **not** implement folder moves by modifying `ZPARENT` directly.

Apple Notes is backed by Core Data/CloudKit. Bypassing Notes.app for mutation risks:

- incomplete Core Data bookkeeping,
- CloudKit synchronization corruption,
- inconsistent object graphs,
- or future schema incompatibility.

---

## 2.4 Agent-safe APIs should avoid ambiguous names

Whenever the MCP already has an exact object ID, write operations should be able to consume it.

Agents should not be forced to say:

```text
move to folder named "Archive"
```

when they could instead say:

```text
move to folder id X
```

This is especially important in nested hierarchies.

---

# 3. Recommended Implementation Stages

---

# Stage 0: AppleScript Capability Spike

## Objective

Before changing the public API, verify exactly what Apple Notes’ current AppleScript dictionary allows for:

1. creating a folder inside another folder;
2. moving a folder into another folder;
3. moving a nested folder back to the account/root level;
4. targeting folders by AppleScript/Core Data ID rather than name.

This is the only major technical uncertainty.

## Manual experiments

Create temporary test folders in Apple Notes:

```text
MCP Test Parent
MCP Test Destination
```

Then test variants such as:

```applescript
tell application "Notes"
    set p to folder "MCP Test Parent" of account "iCloud"
    make new folder with properties {name:"MCP Test Child"} at p
end tell
```

Test folder movement:

```applescript
tell application "Notes"
    set childFolder to folder "MCP Test Child"
    set destinationFolder to folder "MCP Test Destination"
    move childFolder to destinationFolder
end tell
```

Also test with IDs:

```applescript
tell application "Notes"
    set p to folder id "x-coredata://..."
    make new folder with properties {name:"MCP Test Child By ID"} at p
end tell
```

and:

```applescript
tell application "Notes"
    move folder id "x-coredata://..." to folder id "x-coredata://..."
end tell
```

## Inspect the Notes scripting dictionary if needed

If these fail, inspect Notes.app’s `.sdef` / Script Editor dictionary.

Determine:

- which object classes may contain `folder`,
- whether `move` supports folder objects,
- whether `folder id` is accepted consistently,
- and what the root/account destination syntax is.

## Deliverable

A short implementation note containing:

- supported operations,
- exact working AppleScript syntax,
- unsupported operations,
- macOS version tested.

### Stop condition

If AppleScript does **not** support safe nested-folder mutation:

- keep the read improvements,
- do not implement direct SQLite folder writes,
- optionally consider UI scripting only as a separately gated, explicitly fragile feature.

---

# Stage 1: Normalize Folder Identity

## Objective

Make folders first-class API entities, analogous to notes.

## 1.1 Extend `Folder`

Relevant file:

`Sources/CheAppleNotesMCP/NotesSQLite/NoteEntity.swift`

Current `Folder` lacks enough account identity to construct a canonical AppleScript folder ID.

Add:

```swift
let accountIdentifier: String?
```

Update the folder SQL query to select the account identifier as well as account name.

For example:

```sql
a.ZIDENTIFIER AS account_identifier
```

Then add:

```swift
var appleScriptID: String {
    guard let acct = accountIdentifier, !acct.isEmpty else {
        return identifier
    }
    return "x-coredata://\(acct)/ICFolder/p\(pk)"
}
```

The exact Core Data entity path should be verified against real Notes IDs before finalizing.

## 1.2 Expose both canonical ID and raw UUID

Recommended JSON:

```json
{
  "id": "x-coredata://.../ICFolder/p812",
  "uuid": "raw-zidentifier",
  "title": "2024",
  "account": "iCloud",
  "parent_id": "...",
  "shared": false
}
```

Do not overload one field with different ID formats depending on code path.

## 1.3 Resolve `parent_id`

When serializing folders:

1. build a dictionary by `pk`,
2. look up `parentPK`,
3. convert the parent to its canonical public `id`.

Pseudo-code:

```swift
let byPK = Dictionary(uniqueKeysWithValues: folders.map { ($0.pk, $0) })

func parentID(for folder: Folder) -> String? {
    guard let parentPK = folder.parentPK,
          let parent = byPK[parentPK] else {
        return nil
    }
    return parent.appleScriptID
}
```

Keep `parent_pk` only if useful for diagnostics.

## 1.4 Compute folder paths

Add a utility that computes:

```text
Coparenting/Jaime/High Conflict/2024
```

using ancestor traversal.

Requirements:

- account-scoped,
- cycle-safe,
- stable for the duration of the response,
- path used for presentation only.

## Tests

Add/update tests for:

- root folder has `parent_id = nil`;
- child folder maps parent PK to public parent ID;
- deeply nested path construction;
- duplicate folder names in different branches;
- missing parent falls back to root behavior;
- hidden container filtering remains unchanged;
- multiple accounts remain isolated.

Likely test files:

- `FolderHierarchyTests.swift`
- `NotesStoreReaderTests.swift`
- `ServerHandlerTests.swift`
- `SQLQueriesTests.swift`

---

# Stage 2: Make `list_folders` Actually Hierarchical

## Objective

Wire the already-existing `FolderHierarchy` functionality into the MCP API.

## Option A: `format`

Extend:

```text
list_folders
```

with:

```json
{
  "format": "flat" | "tree"
}
```

Default to `flat` for backward compatibility.

### Flat response

Each folder includes:

- `id`
- `uuid`
- `title`
- `account`
- `parent_id`
- `path`
- metadata

### Tree response

Conceptually:

```json
[
  {
    "account": "iCloud",
    "folders": [
      {
        "id": "...",
        "title": "Coparenting",
        "path": "Coparenting",
        "children": [
          {
            "id": "...",
            "title": "Jaime",
            "path": "Coparenting/Jaime",
            "children": []
          }
        ]
      }
    ]
  }
]
```

Use the existing:

```swift
FolderHierarchy.buildByAccount(...)
```

rather than maintaining two independent hierarchy algorithms.

## Option B: Separate tool

Alternatively:

```text
list_folder_tree
```

could be introduced.

This may produce a cleaner schema but increases API surface.

### Recommendation

Prefer `format: "flat" | "tree"` unless MCP schema ergonomics make recursive output awkward.

## Tests

Verify:

- deeply nested folders;
- multiple accounts;
- hidden folders excluded as today;
- sort order preserved;
- duplicate names are safe because IDs remain unique.

---

# Stage 3: Recursive Note Listing

## Objective

Allow an agent to retrieve an entire folder subtree without manually enumerating each leaf folder.

This is probably the highest-value feature for research/analysis use cases.

## API

Extend:

```text
list_notes
```

with:

```json
{
  "folder_id": "...",
  "recursive": true
}
```

Behavior:

- `recursive = false` or omitted: current exact-folder behavior;
- `recursive = true`: include notes directly in the folder plus all descendants.

Require `folder_id` when `recursive = true`, unless recursive name/path resolution is explicitly supported.

## Implementation option 1: Swift hierarchy expansion

Steps:

1. `listFolders()`
2. resolve root folder
3. collect root PK
4. recursively collect descendant PKs
5. query notes where `ZFOLDER IN (...)`

Advantages:

- reuses `FolderHierarchy`;
- easy to unit test;
- avoids SQLite recursive CTE assumptions.

## Implementation option 2: recursive SQLite CTE

Conceptually:

```sql
WITH RECURSIVE descendants(pk) AS (
    SELECT :rootPK
    UNION ALL
    SELECT f.Z_PK
    FROM ZICCLOUDSYNCINGOBJECT f
    JOIN descendants d ON f.ZPARENT = d.pk
    WHERE f.Z_ENT = :folderEntityID
)
SELECT ...
FROM ZICCLOUDSYNCINGOBJECT n
WHERE n.ZFOLDER IN (SELECT pk FROM descendants)
```

Advantages:

- one SQL query,
- good performance.

Disadvantages:

- adds query complexity,
- harder to reuse existing hierarchy logic,
- requires care around account/entity filtering.

### Recommendation

Use Swift descendant expansion first unless performance measurements show a need for the recursive CTE.

## Return folder path with notes

For recursive results, adding:

```json
"folder_path": "Coparenting/Jaime/High Conflict/2024"
```

to note metadata is highly useful.

This is especially valuable for MCP agents processing a large subtree.

## Tests

Test:

- root contains direct note;
- child contains note;
- grandchild contains note;
- recursive false returns only direct;
- recursive true returns all descendants;
- sibling branch excluded;
- duplicate folder names do not affect results;
- root in account A does not accidentally include account B.

---

# Stage 4: ID-Safe Note Writes

## Objective

Remove folder-name ambiguity from note creation and movement.

## 4.1 Extend `create_note`

Current conceptual API:

```text
create_note(
    title,
    body_text?,
    body_html?,
    folder?,
    account?
)
```

Add:

```text
folder_id?
```

Recommended precedence:

1. `folder_id`
2. `folder + account`
3. account default folder
4. default account/default folder

Reject incompatible combinations where helpful.

## 4.2 Extend `move_note`

Add:

```text
folder_id?
```

Preferred:

```text
move_note(
    id="<note-id>",
    folder_id="<destination-folder-id>"
)
```

Keep existing name-based targeting for compatibility.

## 4.3 Batch APIs

Add folder-ID addressing to:

- `create_notes_batch`
- `move_notes_batch`

Do not leave batch operations name-only while single operations become ID-safe.

## 4.4 AppleScript builder

Add folder-ID helpers.

Example concept:

```swift
static func folderTarget(id: String) -> String {
    "folder id \(AppleScriptEscape.quote(id))"
}
```

Then use:

```applescript
move note id "..." to folder id "..."
```

instead of resolving the destination by name.

## Tests

Cover:

- create in nested folder by ID;
- move note between nested folders;
- duplicate destination folder names;
- folder ID preferred over name;
- invalid folder ID produces useful error;
- cross-account move behavior;
- batch equivalents.

---

# Stage 5: Nested Folder Creation

## Prerequisite

Stage 0 must confirm AppleScript can create a folder at another folder.

## API

Extend:

```text
create_folder(
    title,
    account?,
    parent_id?
)
```

Behavior:

- no `parent_id`: preserve current top-level/account behavior;
- `parent_id`: create inside that exact folder.

Potential convenience parameter later:

```text
parent_path?
```

but IDs should be canonical.

## AppleScript

If supported:

```applescript
tell application "Notes"
    set p to folder id "..."
    set f to make new folder with properties {name:"2026"} at p
    return id of f
end tell
```

## Validation

Before dispatch:

- verify parent exists if SQLite is available;
- verify account compatibility if required;
- reject unsupported shared-folder cases if Apple Notes does not permit mutation;
- return clear errors.

## Result

Return normalized object:

```json
{
  "id": "...",
  "uuid": "...",
  "title": "2026",
  "parent_id": "...",
  "path": "Coparenting/Jaime/2026",
  "account": "iCloud"
}
```

After the AppleScript write, re-read the folder if practical to ensure canonical metadata rather than trusting only the AppleScript return value. (An earlier revision of this plan called `sqlite?.checkpoint()` here; that method was a no-op and was deleted per [#12](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/12). Read-after-write freshness is handled per `docs/adr/0002-read-repair-for-read-after-write.md`.)

## Tests

Test:

- top-level creation unchanged;
- nested creation one level;
- nested creation multiple levels;
- duplicate names allowed in separate branches;
- nonexistent parent;
- cross-account parent/account mismatch;
- path returned correctly.

---

# Stage 6: Folder Movement

## Prerequisite

Stage 0 must confirm Notes AppleScript supports moving folder objects.

## New tool

```text
move_folder(
    id,
    parent_id?
)
```

Semantics:

- `parent_id = X`: move under folder X;
- `parent_id omitted/null`: move to root/default account or require explicit `account`.

A clearer schema may be:

```text
move_folder(
    id,
    parent_id?,
    account?
)
```

with validation preventing ambiguous root moves.

## Critical safety checks

Before any move:

### 1. Cannot move folder into itself

Reject:

```text
id == parent_id
```

### 2. Cannot move folder into its descendant

This must be checked using the hierarchy.

Pseudo-code:

```swift
if descendants(of: source).contains(destination) {
    throw invalidArgument("Cannot move a folder into one of its descendants")
}
```

### 3. Cross-account moves

Determine Notes.app behavior during Stage 0.

Possibilities:

- allowed,
- automatically copied,
- forbidden,
- changes IDs,
- changes CloudKit ownership.

Do not assume.

If behavior is uncertain, reject cross-account movement initially.

### 4. Shared folders

Shared-folder movement may have additional Apple/CloudKit restrictions.

Detect and reject unsupported cases with explicit messages.

## Undo support

The current undo stack handles note operations but not folder operations.

Add folder operation cases, for example:

```swift
case createFolder(id: String)
case renameFolder(id: String, oldTitle: String, newTitle: String)
case moveFolder(id: String, oldParentID: String?, newParentID: String?)
```

Folder deletion undo is more complicated and may remain unsupported unless enough metadata can safely recreate the folder.

Be explicit rather than pretending undo is lossless.

## Tests

Cover:

- move root folder under another folder;
- move nested folder to sibling parent;
- move nested folder to root;
- self-move rejection;
- descendant-cycle rejection;
- cross-account behavior;
- shared-folder behavior;
- undo move if supported.

---

# Stage 7: Folder Deletion Semantics

## Current behavior

`delete_folder` refuses deletion if the folder directly contains notes.

Nested behavior needs to be tested carefully.

Questions:

- Does Notes.app report descendant notes as “notes of folder”?
- Does deletion of a parent folder delete subfolders?
- Does it refuse if child folders exist?
- Does it implicitly move contents?
- What happens to shared folders?

## Recommendation

Do not broaden deletion until behavior is explicitly characterized.

Safer API behavior:

- refuse deletion if folder contains notes **or subfolders**,
- expose:

```text
recursive=false
```

only.

Avoid implementing recursive destructive deletion unless there is a strong use case and explicit confirmation.

Potential error:

```text
Folder is not empty: contains 2 notes and 3 subfolders
```

---

# Stage 8: Folder Path Resolution

## Objective

Improve agent ergonomics while keeping IDs canonical.

Add optional path resolution, likely as a read helper first.

Potential tool:

```text
resolve_folder
```

Input:

```json
{
  "path": "Coparenting/Jaime/High Conflict/2024",
  "account": "iCloud"
}
```

Output:

```json
{
  "id": "...",
  "title": "2024",
  "path": "...",
  "account": "iCloud"
}
```

Alternative: allow `folder_path` in existing tools.

## Ambiguity rules

Path resolution should:

- require account when duplicate root structures exist across accounts;
- fail on ambiguous names;
- never silently choose the first match.

IDs remain the safest way for write operations.

---

# Stage 9: Search Scope by Folder Subtree

## Objective

Make `search_notes` usable for research within a specific folder hierarchy.

Current search is keyword-based and appears oriented around title/snippet matching.

Add:

```text
folder_id?
recursive?
```

Example:

```text
search_notes(
    keywords=["Jaime", "mediation"],
    match_mode="all",
    folder_id="<Coparenting folder>",
    recursive=true
)
```

This is valuable for agentic research.

## Optional future improvement

Separate from nested folders, consider full-body search if the current implementation only searches title/snippet.

That should be its own feature because it affects performance and semantics.

---

# Stage 10: Documentation and MCP Schema Quality

Update:

- README
- tool descriptions
- examples
- caveats
- migration notes

Document clearly:

## Reading

```text
list_folders(format="tree")
```

```text
list_notes(folder_id="...", recursive=true)
```

## ID-safe writes

```text
create_note(..., folder_id="...")
```

```text
move_note(id="...", folder_id="...")
```

## Nested creation

```text
create_folder(title="2026", parent_id="...")
```

## Movement

```text
move_folder(id="...", parent_id="...")
```

## Important semantic statement

Document:

> Folder IDs are canonical. Folder names and paths are convenience selectors and may become ambiguous after renames or when duplicate folder names exist.

---

# 4. Recommended PR Breakdown

Rather than one large PR, submit the work incrementally.

## PR 1: Folder identity and hierarchy API

Scope:

- account identifier in `Folder`,
- canonical folder AppleScript ID,
- parent public ID,
- folder path,
- improved flat output,
- optional tree output,
- tests.

No write behavior changes.

This is low risk and independently useful.

---

## PR 2: Recursive reads

Scope:

- `list_notes(recursive=true)`,
- subtree resolution,
- folder path in note output,
- tests.

Potentially also subtree-scoped `search_notes`.

This is immediately useful for MCP research agents.

---

## PR 3: ID-safe note writes

Scope:

- `folder_id` on create/move note,
- batch equivalents,
- AppleScript builder changes,
- backward-compatible name fallback,
- tests.

This removes ambiguity without changing folder CRUD.

---

## PR 4: Nested folder creation

Only after AppleScript capability has been verified.

Scope:

- `parent_id` on `create_folder`,
- canonical return object,
- tests,
- docs.

---

## PR 5: Folder movement

Scope:

- `move_folder`,
- cycle prevention,
- account/shared-folder rules,
- undo support if reliable,
- tests.

This is the highest-risk feature and should not be bundled with the read-side work.

---

# 5. Suggested Internal Utilities

Several reusable helpers would keep the implementation clean.

## `FolderIndex`

Potential abstraction:

```swift
struct FolderIndex {
    let foldersByPK: [Int64: Folder]
    let foldersByID: [String: Folder]

    func parent(of folder: Folder) -> Folder?
    func children(of folder: Folder) -> [Folder]
    func descendants(of folder: Folder) -> [Folder]
    func ancestors(of folder: Folder) -> [Folder]
    func path(of folder: Folder) -> String
    func isDescendant(_ candidate: Folder, of ancestor: Folder) -> Bool
}
```

This could replace ad hoc tree logic in multiple handlers.

`FolderHierarchy` may evolve into this, or the two may coexist:

- `FolderIndex` for lookup/algorithms,
- `FolderHierarchy` for presentation tree generation.

---

## `FolderSelector`

Normalize public targeting:

```swift
enum FolderSelector {
    case id(String)
    case path(String, account: String?)
    case name(String, account: String?)
}
```

Resolution rules can then live in one place instead of being copied across:

- `list_notes`
- `create_note`
- `move_note`
- batch APIs
- search
- folder writes.

---

# 6. Error Design

Nested APIs need precise errors.

Examples:

```text
Folder not found: <id>
```

```text
Folder name 'Archive' is ambiguous in account 'iCloud'; use folder_id
```

```text
Folder path is ambiguous; specify account
```

```text
Cannot move folder into itself
```

```text
Cannot move folder into one of its descendants
```

```text
Cross-account folder moves are not supported
```

```text
Shared folder cannot be moved by this operation
```

```text
Feature requires Full Disk Access
```

Avoid “first match wins” behavior where ambiguity can alter user data.

---

# 7. Full Disk Access Behavior

The strongest hierarchy/read behavior depends on SQLite access.

With Full Disk Access:

- exact hierarchy is available from `ZPARENT`;
- folder IDs and account metadata can be normalized;
- recursive reads are efficient;
- duplicate names can be disambiguated safely.

Without Full Disk Access:

- AppleScript fallback currently provides a weaker representation;
- hierarchy information may not be available at the same fidelity.

Decide explicitly whether new hierarchy-heavy features:

1. require FDA, or
2. implement a slower AppleScript hierarchy traversal.

### Recommendation

For the first implementation:

- make tree/recursive features require SQLite/FDA if necessary;
- return a clear `featureRequiresSQLite(...)` error rather than silently degrading semantics.

Correctness is more important than pretending feature parity.

---

# 8. Test Strategy

The repository already has useful test separation.

Relevant areas include:

- `FolderHierarchyTests.swift`
- `NoteScriptBuilderTests.swift`
- `NotesStoreReaderTests.swift`
- `SQLQueriesTests.swift`
- `ServerHandlerTests.swift`
- E2E tests

## Unit fixtures should include

At minimum:

```text
iCloud
├── Root A
│   ├── Child A1
│   │   └── Grandchild A1a
│   └── Archive
├── Root B
│   └── Archive
└── Empty
```

and a second account:

```text
On My Mac
└── Root A
```

This catches:

- duplicate names,
- cross-account collisions,
- path resolution,
- recursive descendants.

## Notes fixture

Place notes at:

- Root A
- Child A1
- Grandchild A1a
- Root B/Archive

Then test recursive enumeration.

## Mutation E2E tests

Where practical, create a temporary test account/folder namespace such as:

```text
CHE MCP E2E <UUID>
```

Tests should clean up after themselves.

Be conservative with automated destructive Apple Notes tests.

---

# 9. Backward Compatibility

Do not break existing clients unnecessarily.

## Keep existing parameters

Retain:

- `folder`
- `account`

while adding:

- `folder_id`
- possibly `folder_path`

## Versioning behavior

Document the preferred selector order.

Potential rule:

```text
folder_id > folder_path > folder + account
```

If multiple selectors are supplied and disagree, return an error.

Do not silently prioritize one in a way that could move data to the wrong location.

---

# 10. Security and Data-Safety Considerations

## No direct DB writes

Non-negotiable.

## Destructive folder operations

Treat:

- `delete_folder`
- future recursive delete

as destructive MCP tools.

`move_folder` is non-destructive in intent but can have significant organizational impact.

## Shared folders

Apple CloudKit sharing introduces additional ownership/permission semantics.

Test before supporting all shared-folder mutations.

## Locked notes

Nested-folder changes should not change the existing policy around encrypted/locked note bodies.

## Undo

Current undo is in-memory/process-local.

Do not imply transactional guarantees that do not exist.

Folder mutations should document whether undo is available and reliable.

---

# 11. Scope Boundaries

## In scope

- hierarchy read representation,
- exact parent IDs,
- paths,
- recursive reads,
- ID-safe note writes,
- nested folder creation if AppleScript supports it,
- folder movement if AppleScript supports it,
- safe validation,
- tests and docs.

## Out of scope for initial work

- direct SQLite writes,
- arbitrary CloudKit manipulation,
- automatic recursive folder deletion,
- UI scripting fallback unless separately justified,
- semantic/vector search,
- attachment mutation,
- redesign of Notes synchronization.

---

# 12. Immediate Implementation Order

If beginning work now, use this order.

## Step 1

Run the AppleScript capability spike.

Do **not** wait for its result before beginning read-side improvements.

## Step 2

Implement canonical folder identity:

- account identifier,
- AppleScript folder ID,
- parent public ID,
- path.

## Step 3

Fix `list_folders` hierarchy exposure.

Add tree format if desired.

## Step 4

Implement recursive note enumeration.

This delivers immediate value for MCP-based research agents.

## Step 5

Add `folder_id` to note create/move and batch operations.

## Step 6

If Stage 0 succeeded, add nested folder creation.

## Step 7

Implement folder movement with cycle/account/shared-folder safety.

## Step 8

Refine path selectors/search scoping.

## Step 9

Finalize documentation, E2E coverage, and release notes.

---

# 13. Definition of Done

The feature set is complete when an MCP client can safely perform the following workflow without relying on ambiguous folder names:

```text
1. Enumerate the Apple Notes hierarchy.
2. Identify "Coparenting/Jaime" by stable ID.
3. Recursively list every note beneath that subtree.
4. Retrieve any note body.
5. Create a new note inside an exact nested folder by ID.
6. Move a note between exact nested folders by ID.
7. Create a new child folder beneath an exact parent by ID.
8. Move a folder to a new parent without allowing hierarchy cycles.
9. Receive human-readable paths alongside canonical IDs.
10. Perform all writes through Notes.app/AppleScript, never through direct SQLite mutation.
```

---

# 14. Recommended First Milestone for the Coparenting Research Use Case

For the specific downstream need of allowing an agent to systematically inspect Apple Notes, the minimum useful milestone is much smaller than full CRUD.

Ship first:

```text
list_folders
  -> canonical IDs
  -> parent_id
  -> path
  -> tree output

list_notes
  -> folder_id
  -> recursive=true
  -> folder_path in results

get_note
  -> unchanged
```

That alone would let an agent reliably say:

> “Ingest every note recursively under this Coparenting subtree, preserve its folder path, dates, and stable IDs, and then selectively fetch complete note bodies.”

Full nested mutation can follow later as a separate feature set.

---

# 15. Key Repository Files

Primary files likely involved:

```text
Sources/CheAppleNotesMCP/Server.swift
Sources/CheAppleNotesMCP/AppleScript/NoteScriptBuilder.swift
Sources/CheAppleNotesMCP/AppleScript/NotesController.swift
Sources/CheAppleNotesMCP/NotesSQLite/NoteEntity.swift
Sources/CheAppleNotesMCP/NotesSQLite/NotesStoreReader.swift
Sources/CheAppleNotesMCP/NotesSQLite/SQLQueries.swift
Sources/CheAppleNotesMCP/NotesSQLite/FolderHierarchy.swift
```

Primary tests:

```text
Tests/CheAppleNotesMCPTests/FolderHierarchyTests.swift
Tests/CheAppleNotesMCPTests/NoteScriptBuilderTests.swift
Tests/CheAppleNotesMCPTests/NotesStoreReaderTests.swift
Tests/CheAppleNotesMCPTests/SQLQueriesTests.swift
Tests/CheAppleNotesMCPTests/ServerHandlerTests.swift
Tests/CheAppleNotesMCPE2ETests/
```

---

# 16. Final Architectural Recommendation

The repository is already structurally well positioned for this work.

The most important observation is:

> **Nested folder support is not fundamentally missing from the data layer. It is mostly missing from the public API and write semantics.**

The SQLite model already knows:

- the folder’s PK,
- stable identifier,
- account,
- parent,
- and direct note membership.

The repository already has hierarchy-building code.

Therefore the safest development path is:

1. expose the hierarchy cleanly;
2. add recursive read semantics;
3. normalize folder IDs;
4. make note writes ID-safe;
5. only then add nested folder mutation after AppleScript capability is verified.

That sequencing delivers immediate agentic-analysis value while minimizing risk to users’ Apple Notes data.
