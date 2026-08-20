import Testing
@testable import CheAppleNotesMCP

@Suite struct FolderHierarchyTests {

    private func folder(
        pk: Int64,
        title: String,
        parent: Int64? = nil,
        account: String? = "iCloud",
        hidden: Bool = false,
        sortOrder: Int? = nil,
        shared: Bool = false
    ) -> Folder {
        Folder(
            pk: pk,
            identifier: "folder-\(pk)",
            title: title,
            accountPK: 1,
            accountName: account,
            storeUUID: "store-uuid",
            parentPK: parent,
            isHiddenContainer: hidden,
            sortOrder: sortOrder,
            shared: shared
        )
    }

    private func byPK(_ folders: [Folder]) -> [Int64: Folder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.pk, $0) })
    }

    @Test func pathJoinsTitlesFromRoot() {
        let folders = [
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "Child", parent: 1),
            folder(pk: 3, title: "Grandchild", parent: 2)
        ]
        let index = byPK(folders)
        #expect(FolderHierarchy.path(of: folders[2], byPK: index) == "Root/Child/Grandchild")
        #expect(FolderHierarchy.path(of: folders[0], byPK: index) == "Root")
    }

    @Test func pathWithMissingParentDegradesToRoot() {
        let orphan = folder(pk: 1, title: "Orphan", parent: 999)
        #expect(FolderHierarchy.path(of: orphan, byPK: byPK([orphan])) == "Orphan")
    }

    @Test func appleScriptIDUsesStoreUUIDHostAndDegradesToIdentifier() {
        let f = folder(pk: 7, title: "F")
        #expect(f.appleScriptID == "x-coredata://store-uuid/ICFolder/p7")

        // Malformed store (no Z_METADATA row): degrade to the raw
        // ZIDENTIFIER rather than emitting a URI with an empty host.
        let degraded = Folder(
            pk: 7, identifier: "folder-7", title: "F", accountPK: 1,
            accountName: "iCloud", storeUUID: nil, parentPK: nil,
            isHiddenContainer: false, sortOrder: nil, shared: false
        )
        #expect(degraded.appleScriptID == "folder-7")
    }

    @Test func pathTerminatesOnParentCycle() {
        // A → B → A: corrupt data must not hang or recurse forever.
        let a = folder(pk: 1, title: "A", parent: 2)
        let b = folder(pk: 2, title: "B", parent: 1)
        let index = byPK([a, b])
        #expect(FolderHierarchy.path(of: a, byPK: index) == "B/A")
        #expect(FolderHierarchy.path(of: b, byPK: index) == "A/B")
    }

    // MARK: - subtreePKs (#3)

    @Test func subtreePKsIncludesRootAndAllDescendants() {
        let folders = [
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "Child", parent: 1),
            folder(pk: 3, title: "Grandchild", parent: 2),
            folder(pk: 4, title: "Sibling", parent: 1)
        ]
        #expect(FolderHierarchy.subtreePKs(of: 1, folders: folders) == [1, 2, 3, 4])
    }

    @Test func subtreePKsExcludesSiblingBranchesAndOtherAccounts() {
        let folders = [
            folder(pk: 10, title: "Root A"),
            folder(pk: 11, title: "Child A1", parent: 10),
            folder(pk: 14, title: "Root B"),
            folder(pk: 20, title: "Root A", account: "On My Mac")
        ]
        #expect(FolderHierarchy.subtreePKs(of: 10, folders: folders) == [10, 11])
    }

    @Test func subtreePKsOfLeafIsJustItself() {
        let folders = [
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "Child", parent: 1)
        ]
        #expect(FolderHierarchy.subtreePKs(of: 2, folders: folders) == [2])
    }

    @Test func subtreePKsExcludesHiddenContainerDescendants() {
        let folders = [
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "Recently Deleted", parent: 1, hidden: true),
            folder(pk: 3, title: "Under Hidden", parent: 2)
        ]
        // pk 3 nests under the hidden container, so it can't be silently
        // pulled into pk 1's subtree.
        #expect(FolderHierarchy.subtreePKs(of: 1, folders: folders) == [1])
        // Recursing directly on the hidden container still works.
        #expect(FolderHierarchy.subtreePKs(of: 2, folders: folders) == [2, 3])
    }

    @Test func subtreePKsTerminatesOnParentCycle() {
        // A → B → A: corrupt data must not hang or recurse forever.
        let folders = [
            folder(pk: 1, title: "A", parent: 2),
            folder(pk: 2, title: "B", parent: 1)
        ]
        #expect(FolderHierarchy.subtreePKs(of: 1, folders: folders) == [1, 2])
    }
}
