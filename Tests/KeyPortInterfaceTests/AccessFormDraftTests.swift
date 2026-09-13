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

extension AccessFormDraftTests {
    func testHostSyntaxAcceptsIPFamiliesAndDNSWithoutNetworkAccess() {
        for host in ["192.168.8.1", "0.0.0.0", "255.255.255.255", "::1", "2001:db8::1", "::ffff:192.0.2.1", "[2001:db8::1]", "fe80::1%en0", "localhost", "router-1", "host.example.", "xn--bcher-kva.example"] {
            XCTAssertTrue(AccessFormDraft.isValidHost(host), host)
        }
        for host in ["!!!", "", " ", "host name", "https://host", "user@host", "host:22", "999.1.1.1", "1.2.3", "192.168.01.1", "1.2.3.4.5", "2001:::1", "[::1]:22", "[::1", "::1%", "::1%en0%1", "-host", "host-", "a..b", "a_b", ".host", String(repeating: "a", count: 64)+".example", Array(repeating: String(repeating: "a", count: 63), count: 5).joined(separator: ".")] {
            XCTAssertFalse(AccessFormDraft.isValidHost(host), host)
        }
    }

    func testInvalidSubmissionPreservesInputsAndSuccessClearsOnlyPasswordWithoutNewError() {
        var draft = AccessFormDraft(); draft.name = "router"; draft.address = "!!!"; draft.account = "root"; draft.password = "fixture-only"
        let original = draft
        var state = AccessFormSubmissionState()
        XCTAssertNil(state.prepare(&draft)); XCTAssertNotNil(state.error); XCTAssertEqual(draft, original)
        draft.address = "192.0.2.1"; state.edited()
        let submission = state.prepare(&draft)
        XCTAssertEqual(submission?.password, "fixture-only")
        XCTAssertEqual(draft.password, ""); XCTAssertEqual(draft.address, "192.0.2.1"); XCTAssertNil(state.error)
        // Closing a notice does not revalidate a cleared credential. A new explicit attempt does.
        XCTAssertNil(state.error)
        XCTAssertNil(state.prepare(&draft)); XCTAssertNotNil(state.error)
        draft.existingKey = true
        XCTAssertNotNil(state.prepare(&draft)); XCTAssertNil(state.error)
    }
}

extension AccessFormDraftTests {
    func testAutomaticAliasHandlesNonASCIIAndSymbolNamesStably() {
        var aliases: Set<String> = []
        for name in ["我的服务器", "另一台服务器", "🔑", "!!!", "---"] {
            var draft = AccessFormDraft(); draft.name = name; draft.address = "192.0.2.1"
            draft.account = "root"; draft.existingKey = true
            let alias = draft.resolvedAlias
            XCTAssertFalse(alias.isEmpty)
            XCTAssertFalse(alias.hasPrefix("-"))
            XCTAssertTrue(aliases.insert(alias).inserted)
            draft.address = "2001:db8::1"
            XCTAssertEqual(draft.resolvedAlias, alias)
            draft.alias = alias
            XCTAssertNil(draft.validationMessage)
            draft.alias = "custom-router"
            XCTAssertEqual(draft.resolvedAlias, "custom-router")
        }
    }
}
