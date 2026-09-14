import XCTest
@testable import KeyPortInterface
final class AccessFormDraftTests: XCTestCase {
    func testExistingKeyDoesNotRequirePassword() {
        var draft = AccessFormDraft(); draft.alias = "router"; draft.address = "192.0.2.1"; draft.account = "root"
        XCTAssertNotNil(draft.validationMessage)
        draft.existingKey = true
        XCTAssertNil(draft.validationMessage)
        for port in ["0", "65536", "-22", "22x", ""] { draft.port = port; XCTAssertNotNil(draft.validationMessage) }
        draft.port = "22"; draft.address = "2001:db8::1"; XCTAssertNil(draft.validationMessage)
        draft.address = "-oProxyCommand=bad"; XCTAssertNotNil(draft.validationMessage)
    }
    func testPasswordAndAliasValidation() {
        var draft = AccessFormDraft(); draft.alias = "my-router"; draft.address = "router.example"; draft.account = "root"; draft.password = "fixture"
        XCTAssertNil(draft.validationMessage)
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
        var draft = AccessFormDraft(); draft.alias = "router"; draft.address = "!!!"; draft.account = "root"; draft.password = "fixture-only"
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
    func testNewAliasSyntaxIsExplicitAndNeverGeneratedFromDescription() {
        var draft = AccessFormDraft(); draft.address = "192.0.2.1"; draft.account = "root"; draft.existingKey = true
        draft.description = "我的服务器 🔑"
        for invalid in ["", " ", "我的服务器", "🔑", "!!!", "-router", "_router", "1router", "router.local", "router*", "router?", "router test", " router", "router\n", "röuter"] {
            draft.alias = invalid
            XCTAssertNotNil(draft.validationMessage, invalid)
            XCTAssertEqual(draft.alias, invalid)
        }
        for valid in ["a", "Router", "home-router_2", "r1", "a-"] {
            draft.alias = valid; XCTAssertNil(draft.validationMessage, valid)
            draft.description += "新描述"; draft.address = "2001:db8::1"
            XCTAssertEqual(draft.alias, valid)
        }
    }
    func testBothDirectorySourcesAndEditingOnlyOwnEntry() {
        let directory = AliasDirectory(entries: [
            .init(alias: "home-router", source: .managed, ownerID: "router"),
            .init(alias: "home-router", source: .sshConfiguration, ownerID: "router"),
            .init(alias: "external-host", source: .sshConfiguration),
            .init(alias: "old.host", source: .managed, ownerID: "legacy")
        ])
        XCTAssertNotNil(directory.validationMessage(for: "HOME-router"))
        XCTAssertNotNil(directory.validationMessage(for: "External-Host"))
        XCTAssertNil(directory.validationMessage(for: "home-router", editingEntryID: "router"))
        XCTAssertNotNil(directory.validationMessage(for: "external-host", editingEntryID: "router"))
        XCTAssertNil(directory.validationMessage(for: "old.host", editingEntryID: "legacy"))
        XCTAssertNotNil(directory.validationMessage(for: "old.host"))
        XCTAssertNotNil(directory.validationMessage(for: "OLD.host", editingEntryID: "legacy"))
        XCTAssertNotNil(directory.validationMessage(for: "another.old", editingEntryID: "legacy"))
        XCTAssertNotNil(AliasDirectory(entries: directory.entries + [.init(alias: "home-router", source: .sshConfiguration)])
            .validationMessage(for: "home-router", editingEntryID: "router"))
        var draft = AccessFormDraft(); draft.alias = "external-host"; draft.description = "中文说明"
        draft.address = "192.0.2.1"; draft.account = "root"; draft.password = "fixture-only"
        let original = draft; var submission = AccessFormSubmissionState()
        XCTAssertNil(submission.prepare(&draft, directory: directory)); XCTAssertEqual(draft, original)
    }
    func testLegacyMappingIsLosslessAndSearchUsesBothFields() {
        for (name, alias) in [("我的服务器", "legacy.host"), ("🔑", "123-old"), ("", "Mixed_CASE"), ("空别名保留待处理", "")] {
            let mapped = ServerNaming.legacy(id: "existing", displayName: name, existingAlias: alias)
            XCTAssertEqual(mapped.description, name); XCTAssertEqual(mapped.alias, alias)
            XCTAssertEqual(mapped.id, "existing")
        }
        let naming = ServerNaming(id: "router", alias: "home-router", description: "家里的主路由器")
        XCTAssertTrue(naming.matches("HOME")); XCTAssertTrue(naming.matches("主路由")); XCTAssertFalse(naming.matches("not-present"))
        XCTAssertNil(ServerNaming(id: "empty", alias: "empty").visibleDescription)
        XCTAssertNil(ServerNaming(id: "blank", alias: "blank", description: "  \n").visibleDescription)
        let long = String(repeating: "中文说明", count: 100)
        XCTAssertEqual(ServerNaming(id: "long", alias: "long", description: long).visibleDescription, long)
    }
}
