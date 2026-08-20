import Foundation
import SQLite3
import Testing
@testable import CheAppleNotesMCP

/// Integration tests that drive `NotesStoreReader` against the shared
/// `FixtureStore` temp database. The goal is to exercise the share-metadata
/// fallback paths with real row shapes that were previously only covered by
/// SQL-string assertions.
///
/// Added as part of #6 hardening — Finding 9 from the #3 round-2
/// verification report pointed out that
/// `sharedRootObjectHeuristicProjectsServerShareDataPresent` only checks
/// SQL text, not runtime behavior on a participant-side fake row (ZZONEOWNERNAME
/// set, ZSERVERSHAREDATA NULL), which is the exact pre-fix BLOCKER case.
@Suite struct NotesStoreReaderTests {

    private func withFixtureReader<T>(_ body: (NotesStoreReader) throws -> T) throws -> T {
        let url = FixtureStore.makeURL()
        try FixtureStore.build(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(try NotesStoreReader(at: url))
    }

    // MARK: - Share metadata

    @Test func getShareMetadataParticipantSideReturnsSharedWithoutServerShareData() throws {
        // Finding-9 regression guard: participant-side row must report
        // isShared=true AND serverShareDataPresent=false. The pre-fix bug
        // hardcoded serverShareDataPresent=false even for owner-side rows,
        // but this test pins the genuine participant case.
        let metadata = try withFixtureReader {
            try $0.getShareMetadata(identifier: "participant-note-uuid")
        }
        #expect(metadata.isShared)
        #expect(metadata.serverShareDataPresent == false)
        // No ZICINVITATION row → optional fields stay nil.
        #expect(metadata.shareURL == nil)
        #expect(metadata.rootObjectType == nil)
    }

    @Test func getShareMetadataOwnerSideReturnsSharedWithServerShareData() throws {
        // Owner-side row: ZSERVERSHAREDATA has bytes → serverShareDataPresent=true.
        let metadata = try withFixtureReader {
            try $0.getShareMetadata(identifier: "owner-note-uuid")
        }
        #expect(metadata.isShared)
        #expect(metadata.serverShareDataPresent)
    }

    @Test func getShareMetadataUnsharedNoteReturnsNotShared() throws {
        // Both signals NULL → fully unshared response.
        let metadata = try withFixtureReader {
            try $0.getShareMetadata(identifier: "unshared-note-uuid")
        }
        #expect(metadata.isShared == false)
        #expect(metadata.serverShareDataPresent == false)
        #expect(metadata.shareURL == nil)
    }

    @Test func getShareMetadataUnknownIdentifierReturnsNotShared() throws {
        // ZIDENTIFIER that isn't in the DB at all → reader falls through the
        // invitation + heuristic paths to ShareMetadata.notShared.
        let metadata = try withFixtureReader {
            try $0.getShareMetadata(identifier: "no-such-uuid")
        }
        #expect(metadata.isShared == false)
        #expect(metadata.serverShareDataPresent == false)
    }

    // MARK: - Folders

    @Test func listFoldersMapsHierarchyAndStoreIdentity() throws {
        let folders = try withFixtureReader { try $0.listFolders() }
        let rootA = try #require(folders.first { $0.pk == 10 })
        #expect(rootA.title == "Root A")
        #expect(rootA.accountName == "iCloud")
        #expect(rootA.storeUUID == FixtureStore.storeUUID)
        #expect(rootA.parentPK == nil)

        let child = try #require(folders.first { $0.pk == 11 })
        #expect(child.parentPK == 10)

        // One store, one UUID: folders in both accounts share the host.
        let localRoot = try #require(folders.first { $0.pk == 20 })
        #expect(localRoot.storeUUID == FixtureStore.storeUUID)
    }

    @Test func listFoldersSharedOnlyFiltersBothWays() throws {
        try withFixtureReader { reader in
            let shared = try reader.listFolders(sharedOnly: true)
            #expect(shared.map { $0.pk } == [15])
            let unshared = try reader.listFolders(sharedOnly: false)
            #expect(!unshared.contains { $0.pk == 15 })
            #expect(unshared.contains { $0.pk == 10 })
        }
    }

    // MARK: - getNote identifier forms

    private func canonicalNoteID(pk: Int64) -> String {
        "x-coredata://\(FixtureStore.storeUUID)/ICNote/p\(pk)"
    }

    // Every `id` the tools hand back is the canonical x-coredata:// form
    // (ADR 0001), so getNote must accept it. Server's undo capture in
    // update/delete/move feeds it exactly that ([#7](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/7)).
    @Test func getNoteMatchesCanonicalID() throws {
        let note = try withFixtureReader {
            try $0.getNote(identifier: canonicalNoteID(pk: 200))
        }
        #expect(note?.pk == 200)
        #expect(note?.title == "Root A Note")
    }

    @Test func getNoteStillMatchesBareIdentifier() throws {
        let note = try withFixtureReader { try $0.getNote(identifier: "note-uuid-200") }
        #expect(note?.pk == 200)
    }

    @Test func getNoteReturnsNilForUnknownID() throws {
        let note = try withFixtureReader {
            try $0.getNote(identifier: canonicalNoteID(pk: 999999))
        }
        #expect(note == nil)
    }

    // A folder's canonical id must not resolve to the note sharing that pk.
    // Matching on the extracted pk alone would ignore the entity segment.
    @Test func getNoteRejectsFolderCanonicalIDWithSamePK() throws {
        let note = try withFixtureReader {
            try $0.getNote(identifier: "x-coredata://\(FixtureStore.storeUUID)/ICFolder/p200")
        }
        #expect(note == nil)
    }
}
