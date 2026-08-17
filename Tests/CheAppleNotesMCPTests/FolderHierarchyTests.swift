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

    @Test func buildTreeReturnsRootWhenFlat() {
        let nodes = FolderHierarchy.buildTree([
            folder(pk: 1, title: "A"),
            folder(pk: 2, title: "B")
        ])
        #expect(nodes.count == 2)
        #expect(nodes.allSatisfy { $0.children.isEmpty })
        #expect(nodes.map { $0.folder.title } == ["A", "B"])
    }

    @Test func buildTreeNestsChildrenByParentPK() {
        let nodes = FolderHierarchy.buildTree([
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "Child", parent: 1),
            folder(pk: 3, title: "Grandchild", parent: 2)
        ])
        #expect(nodes.count == 1)
        #expect(nodes[0].folder.title == "Root")
        #expect(nodes[0].children.count == 1)
        #expect(nodes[0].children[0].folder.title == "Child")
        #expect(nodes[0].children[0].children[0].folder.title == "Grandchild")
    }

    @Test func orphanedFoldersBecomeRoots() {
        // Parent 999 is not present → folder becomes a root
        let nodes = FolderHierarchy.buildTree([
            folder(pk: 1, title: "Orphan", parent: 999),
            folder(pk: 2, title: "Standalone")
        ])
        #expect(nodes.count == 2)
        #expect(Set(nodes.map { $0.folder.title }) == Set(["Orphan", "Standalone"]))
    }

    @Test func childrenSortBySortOrderThenTitle() {
        let nodes = FolderHierarchy.buildTree([
            folder(pk: 1, title: "Root"),
            folder(pk: 2, title: "B child", parent: 1, sortOrder: 2),
            folder(pk: 3, title: "A child", parent: 1, sortOrder: 1),
            folder(pk: 4, title: "C child", parent: 1, sortOrder: 2)
        ])
        let kids = nodes[0].children.map { $0.folder.title }
        #expect(kids == ["A child", "B child", "C child"])
    }

    @Test func buildByAccountGroupsByAccountName() {
        let results = FolderHierarchy.buildByAccount(folders: [
            folder(pk: 1, title: "iNote", account: "iCloud"),
            folder(pk: 2, title: "LNote", account: "On My Mac"),
            folder(pk: 3, title: "iNote2", account: "iCloud")
        ])
        #expect(results.count == 2)
        #expect(results.map { $0.accountName } == ["On My Mac", "iCloud"])

        let iCloud = results.first { $0.accountName == "iCloud" }
        #expect(iCloud?.roots.count == 2)
    }

    @Test func buildByAccountFiltersHiddenContainers() {
        let results = FolderHierarchy.buildByAccount(folders: [
            folder(pk: 1, title: "visible"),
            folder(pk: 2, title: "hidden", hidden: true)
        ])
        let names = results.flatMap { $0.roots.map { $0.folder.title } }
        #expect(names == ["visible"])
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

    @Test func buildByAccountDefaultsUnknownAccountName() {
        let results = FolderHierarchy.buildByAccount(folders: [
            folder(pk: 1, title: "Lost", account: nil)
        ])
        #expect(results.count == 1)
        #expect(results[0].accountName == "(unknown)")
    }
}
