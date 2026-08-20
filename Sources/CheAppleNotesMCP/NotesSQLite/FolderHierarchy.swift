import Foundation

/// Walk the flat folder list along `ZPARENT` parent → children edges (subtree
/// expansion, path rendering). `ZOWNER` links folders to an account.
struct FolderHierarchy {

    /// Collect the pks of `rootPK` and every descendant folder (the
    /// "subtree"), by expanding parent→children edges built from `folders`.
    /// No recursive SQL — this walks the already-loaded flat list in process
    /// ([#3](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/3)).
    /// Cycle-safe: a pk is enqueued into the result at most once, so corrupt
    /// cyclic `ZPARENT` data can't loop forever.
    static func subtreePKs(of rootPK: Int64, folders: [Folder]) -> Set<Int64> {
        // A hidden container (e.g. "Recently Deleted") never registers as
        // anyone's child, so it can't be silently pulled into someone else's
        // subtree. The root itself is exempt: recursing directly on a hidden
        // container still works, same as non-recursive addressing already does.
        var childrenOf: [Int64: [Int64]] = [:]
        for f in folders where !f.isHiddenContainer {
            if let parentPK = f.parentPK {
                childrenOf[parentPK, default: []].append(f.pk)
            }
        }

        var result: Set<Int64> = []
        var queue = [rootPK]
        while let pk = queue.popLast() {
            guard result.insert(pk).inserted else { continue }
            queue.append(contentsOf: childrenOf[pk] ?? [])
        }
        return result
    }

    /// Slash-joined titles from root to `folder` (e.g. "Coparenting/Jaime/2024"),
    /// walking ZPARENT through `byPK`. Presentation only, never identity (see
    /// CONTEXT.md). Account-scoped by construction: parent chains never cross
    /// accounts. Cycle-safe: stops when a pk repeats. A missing parent row
    /// truncates the walk there, so the folder behaves as a root.
    static func path(of folder: Folder, byPK: [Int64: Folder]) -> String {
        var titles = [folder.title]
        var visited: Set<Int64> = [folder.pk]
        var current = folder
        while let parentPK = current.parentPK,
              let parent = byPK[parentPK],
              visited.insert(parentPK).inserted {
            titles.append(parent.title)
            current = parent
        }
        return titles.reversed().joined(separator: "/")
    }
}
