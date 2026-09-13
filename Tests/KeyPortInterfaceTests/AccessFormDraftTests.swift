import XCTest
@testable import KeyPortInterface
final class AccessFormDraftTests: XCTestCase {
    func testExistingKeyDoesNotRequirePassword() {
        var draft = AccessFormDraft(); draft.name = "router"; draft.address = "192.0.2.1"; draft.account = "root"
        XCTAssertNotNil(draft.validationMessage)
        draft.existingKey = true
        XCTAssertNil(draft.validationMessage)
        for port in ["0", "65536", "-22", "22x", ""] { draft.port = port; XCTAssertNotNil(draft.validationMessage) }
        draft.port = "22"; draft.address = "2001:db8::1"; XCTAssertNil(draft.validationMessage)
        draft.address = "-oProxyCommand=bad"; XCTAssertNotNil(draft.validationMessage)
    }
    func testPasswordAndAliasValidation() {
        var draft = AccessFormDraft(); draft.name = "My Router"; draft.address = "router.example"; draft.account = "root"; draft.password = "fixture"
        XCTAssertNil(draft.validationMessage); XCTAssertEqual(draft.suggestedAlias, "my-router")
        draft.alias = "invalid *"; XCTAssertNotNil(draft.validationMessage)
        draft.alias = "router-1"; XCTAssertNil(draft.validationMessage)
    }
}
