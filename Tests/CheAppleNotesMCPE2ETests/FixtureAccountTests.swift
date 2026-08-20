import Foundation
import Testing

/// Guards the `list_folders` key the fixture's account check depends on.
/// If `account_name` ever changes shape, every account reads as absent and the
/// suite silently degrades to the default account instead of failing loudly,
/// so this is worth pinning even though it is only parsing.
@Suite struct FixtureAccountTests {

    /// Shape produced by `folderToDict` on the server's SQLite path.
    static let sample = """
        [
          {"id":"x-coredata://X/ICFolder/p1","title":"Notes","account_name":"iCloud","shared":false},
          {"id":"x-coredata://X/ICFolder/p2","title":"Scratch","account_name":"On My Mac","shared":false},
          {"id":"x-coredata://X/ICFolder/p3","title":"Orphan","account_name":"","shared":false}
        ]
        """

    @Test func readsAccountNamesFromListFoldersPayload() {
        let names = accountNames(inListFoldersJSON: Self.sample)
        #expect(names == ["iCloud", "On My Mac"])
    }

    @Test func treatsEmptyAccountNameAsAbsent() {
        // A blank account_name is what the server emits for `accountName == nil`.
        // Counting it would make `accountExists("")` true, which is meaningless.
        #expect(!accountNames(inListFoldersJSON: Self.sample).contains(""))
    }

    @Test func malformedPayloadYieldsNoAccounts() {
        // Must be empty rather than a crash: the caller reads this as "not
        // present" and falls back to the default account.
        #expect(accountNames(inListFoldersJSON: "not json").isEmpty)
        #expect(accountNames(inListFoldersJSON: #"{"error":"nope"}"#).isEmpty)
    }
}
