import Foundation

/// Assemble the flat folder list into a parent → children tree, with account
/// scoping. `ZPARENT` nests folders under other folders; `ZOWNER` links them to
/// an account.
struct FolderHierarchy {

    struct Node {
        let folder: Folder
        var children: [Node]
    }

    /// Group folders by account, preserving hierarchy.
    static func buildByAccount(folders: [Folder]) -> [(accountName: String, roots: [Node])] {
        var byAccount: [String: [Folder]] = [:]
        for f in folders where !f.isHiddenContainer {
            let acct = f.accountName ?? "(unknown)"
            byAccount[acct, default: []].append(f)
        }
        return byAccount
            .map { (name, subset) in (accountName: name, roots: buildTree(subset)) }
            .sorted { $0.accountName < $1.accountName }
    }

    /// Build nested folder nodes from a flat list (folders without a parent or
    /// whose parent isn't in the list become roots).
    static func buildTree(_ folders: [Folder]) -> [Node] {
        let byPK = Dictionary(uniqueKeysWithValues: folders.map { ($0.pk, $0) })
        var childrenOf: [Int64: [Folder]] = [:]
        var roots: [Folder] = []

        for f in folders {
            if let parentPK = f.parentPK, byPK[parentPK] != nil {
                childrenOf[parentPK, default: []].append(f)
            } else {
                roots.append(f)
            }
        }

        func expand(_ f: Folder) -> Node {
            let kids = (childrenOf[f.pk] ?? [])
                .sorted { ($0.sortOrder ?? 0, $0.title) < ($1.sortOrder ?? 0, $1.title) }
                .map { expand($0) }
            return Node(folder: f, children: kids)
        }

        return roots
            .sorted { ($0.sortOrder ?? 0, $0.title) < ($1.sortOrder ?? 0, $1.title) }
            .map { expand($0) }
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
