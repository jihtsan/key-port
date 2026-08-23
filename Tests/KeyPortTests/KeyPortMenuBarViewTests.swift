import KeyPortCore
@testable import KeyPort
import XCTest

final class KeyPortMenuBarViewTests: XCTestCase {
    func testAuthorizedServiceGroupsIncludeUngroupedAccountsWithoutSectionTitle() throws {
        let ungroupedAccount = ServerConnection(
            name: "Personal Server",
            host: "personal.example.com",
            username: "admin",
            alias: "personal-admin",
            status: .authorized
        )

        let groups = authorizedServiceGroups(from: [ungroupedAccount])
        let group = try XCTUnwrap(groups.first)

        XCTAssertNil(group.title)
        XCTAssertEqual(group.accounts.map(\.id), [ungroupedAccount.id])
    }

    func testWhitespaceOnlyGroupIsTreatedAsUntitled() throws {
        let ungroupedAccount = ServerConnection(
            name: "Whitespace Server",
            host: "whitespace.example.com",
            username: "root",
            alias: "whitespace-root",
            group: "  \n ",
            status: .authorized
        )

        let groups = authorizedServiceGroups(from: [ungroupedAccount])
        let group = try XCTUnwrap(groups.first)

        XCTAssertNil(group.title)
        XCTAssertEqual(group.accounts.map(\.id), [ungroupedAccount.id])
    }
}
