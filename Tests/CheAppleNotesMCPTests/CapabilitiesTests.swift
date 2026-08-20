import Foundation
import Testing
@testable import CheAppleNotesMCP

@Suite struct CapabilitiesTests {

    @Test func noteStoreURLPointsAtGroupContainer() {
        let path = Capabilities.noteStoreURL.path
        #expect(path.hasSuffix("/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"))
    }

    @Test func noteStoreURLIsRelativeToCurrentUserHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Capabilities.noteStoreURL.path.hasPrefix(home))
    }
}
