import XCTest
@testable import KeyPortInterface

@MainActor final class FirstAccessFlowTests: XCTestCase {
    private func draft(key: Bool = true) -> AccessFormDraft {
        var value = AccessFormDraft(); value.description = "家里的主路由器"; value.address = "192.0.2.1"
        value.account = "root"; value.existingKey = key; value.password = key ? "" : "fixture-only"
        value.alias = "router-test"; return value
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    func testConfirmationIsConditionalAndMismatchCannotAdvance() async {
        let adapter = TestAccessAdapter(); adapter.needsConfirmation = true
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle()
        guard case .confirmHost = flow.state else { return XCTFail("Confirmation missing") }
        XCTAssertEqual(adapter.logins, 0)
        flow.confirmHost(); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(adapter.confirmations, 1)
        let bad = TestAccessAdapter(); bad.failure = .identityMismatch
        let blocked = FirstAccessFlow(draft: draft(), adapter: bad)
        blocked.submit(draft()); await settle(); blocked.confirmHost(); blocked.retry(); await settle()
        XCTAssertEqual(blocked.state, .failed(.identityMismatch)); XCTAssertEqual(bad.logins, 0); XCTAssertEqual(bad.installs, 0)
    }
    func testHostCancellationPreservesNonsecretFieldsAndClearsPassword() async {
        let adapter = TestAccessAdapter(); adapter.needsConfirmation = true
        let flow = FirstAccessFlow(draft: draft(key: false), adapter: adapter)
        flow.submit(draft(key: false)); await settle(); flow.cancel()
        XCTAssertEqual(flow.state, .form); XCTAssertEqual(flow.draft.password, "")
        XCTAssertEqual(flow.draft.alias, "router-test"); XCTAssertEqual(flow.draft.address, "192.0.2.1")
        XCTAssertEqual(adapter.logins, 0)
        XCTAssertEqual(flow.draft.description, "家里的主路由器")
    }
    func testFailuresNeverBecomeSuccessAndNoAuthorizationBeforeLogin() async {
        for failure in [AccessFlowFailure.unreachable, .authentication, .authorization, .verification, .authorizationUnknown] {
            let adapter = TestAccessAdapter(); adapter.failure = failure
            let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
            flow.submit(draft()); await settle()
            XCTAssertEqual(flow.state, .failed(failure), "\(failure)")
            XCTAssertEqual(flow.draft.password, "")
            if failure == .unreachable || failure == .authentication { XCTAssertEqual(adapter.installs, 0); XCTAssertEqual(flow.authorization, .absent) }
            if failure == .verification { XCTAssertEqual(flow.authorization, .installed) }
        }
    }
    func testPartialSuccessRetryReconcilesAndDoesNotReinstall() async {
        let adapter = TestAccessAdapter(); adapter.failure = .verification
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle()
        XCTAssertEqual(flow.authorization, .installed); XCTAssertEqual(adapter.installs, 1)
        adapter.failure = nil; flow.retry(); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(adapter.installs, 1); XCTAssertEqual(adapter.statusChecks, 2)
    }
    func testUnknownInstallOutcomeReconcilesBeforeRetry() async {
        let adapter = TestAccessAdapter(); adapter.failure = .authorizationUnknown
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle()
        XCTAssertEqual(flow.authorization, .unknown)
        adapter.failure = nil; flow.retry(); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(adapter.installs, 1)
    }
    func testAuthorizationKeysIgnoreAddressButSeparateAccountDeviceAndServer() async {
        let adapter = TestAccessAdapter()
        let first = FirstAccessFlow(draft: draft(), adapter: adapter)
        first.submit(draft()); await settle(); XCTAssertEqual(adapter.installs, 1)
        var secondAddress = draft(); secondAddress.address = "2001:db8::1"
        let second = FirstAccessFlow(draft: secondAddress, adapter: adapter)
        second.submit(secondAddress); await settle(); XCTAssertEqual(second.state, .success); XCTAssertEqual(adapter.installs, 1)
        var secondAccount = draft(); secondAccount.account = "deploy"
        let third = FirstAccessFlow(draft: secondAccount, adapter: adapter)
        third.submit(secondAccount); await settle(); XCTAssertEqual(adapter.installs, 2)
        adapter.deviceID = "other-device"
        let fourth = FirstAccessFlow(draft: draft(), adapter: adapter)
        fourth.submit(draft()); await settle(); XCTAssertEqual(adapter.installs, 3)
        adapter.serverID = "other-server"
        let fifth = FirstAccessFlow(draft: draft(), adapter: adapter)
        fifth.submit(draft()); await settle(); XCTAssertEqual(adapter.installs, 4)
    }
    func testCancellationAtEveryStepIgnoresLateCallback() async {
        for step in [AccessFlowStep.login, .authorization, .verification] {
            let adapter = TestAccessAdapter(); adapter.hold = step
            let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
            flow.submit(draft()); await settle(); XCTAssertEqual(flow.state, .running(step))
            flow.cancel()
            let cancelled = flow.state
            adapter.release(); await settle()
            XCTAssertEqual(flow.state, cancelled)
            if step == .login { XCTAssertEqual(adapter.installs, 0); XCTAssertEqual(flow.state, .form) }
            if step == .authorization { XCTAssertEqual(flow.authorization, .unknown); XCTAssertEqual(flow.state, .cancelled) }
            if step == .verification { XCTAssertEqual(flow.authorization, .installed); XCTAssertEqual(flow.state, .cancelled) }
        }
    }
    func testLateInstallationThenRetryDoesNotDuplicate() async {
        let adapter = TestAccessAdapter(); adapter.hold = .authorization
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle(); flow.cancel()
        adapter.release(); await settle() // deliberately non-cooperative remote completion
        adapter.hold = nil; flow.retry(); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(adapter.installs, 1)
    }
    func testPasswordRetryReturnsToFormWithoutImplicitCredentialReuse() async {
        let adapter = TestAccessAdapter(); adapter.failure = .authentication
        let flow = FirstAccessFlow(draft: draft(key: false), adapter: adapter)
        flow.submit(draft(key: false)); await settle(); flow.retry(); await settle()
        XCTAssertEqual(flow.state, .form); XCTAssertEqual(adapter.logins, 1)
        XCTAssertEqual(flow.draft.password, ""); XCTAssertNotNil(flow.draft.validationMessage)
    }
    func testHandoffWaitsForActualAdapterCompletionAndSupportsRecovery() async {
        let adapter = TestAccessAdapter()
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.performHandoff(); XCTAssertEqual(adapter.terminalCalls, 0)
        flow.submit(draft()); await settle()
        adapter.holdHandoff = true
        flow.performHandoff(); await settle(); XCTAssertEqual(flow.handoff, .opening)
        flow.performHandoff(copy: true); XCTAssertEqual(adapter.copyCalls, 0)
        adapter.handoffFails = true; adapter.release(); await settle(); XCTAssertEqual(flow.handoff, .terminalUnavailable)
        flow.performHandoff(copy: true); await settle(); XCTAssertEqual(flow.handoff, .copying)
        adapter.release(); await settle(); XCTAssertEqual(flow.handoff, .copyFailed)
        adapter.handoffFails = false
        flow.performHandoff(copy: true); await settle(); adapter.release(); await settle()
        XCTAssertEqual(flow.handoff, .copied); XCTAssertEqual(flow.state, .success)
    }
    func testEditingToDifferentServerDoesNotReusePartialAuthorizationDisplay() async {
        let adapter = TestAccessAdapter(); adapter.failure = .verification
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle(); XCTAssertEqual(flow.authorization, .installed)
        flow.edit(); adapter.serverID = "different-server"; adapter.failure = .authentication
        flow.submit(draft()); await settle()
        XCTAssertEqual(flow.authorization, .absent); XCTAssertEqual(flow.state, .failed(.authentication))
    }
    func testUnknownStatusStopsBeforeInstall() async {
        let adapter = TestAccessAdapter(); adapter.statusUnknown = true
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle()
        XCTAssertEqual(flow.state, .failed(.authorizationUnknown)); XCTAssertEqual(adapter.installs, 0)
    }
    func testConfirmedAliasIsOneTargetForSuccessAndBothHandoffs() async {
        var input = draft(); input.description = "我的服务器"; input.alias = "Confirmed_Router"
        let adapter = TestAccessAdapter()
        let flow = FirstAccessFlow(draft: input, adapter: adapter)
        flow.submit(input); await settle()
        XCTAssertEqual(flow.state, .success)
        XCTAssertEqual(flow.draft.alias, "Confirmed_Router")
        XCTAssertEqual(flow.command, "ssh " + flow.draft.alias)
        flow.performHandoff(); await settle()
        flow.performHandoff(copy: true); await settle()
        XCTAssertEqual(adapter.commands, [flow.command, flow.command])
        XCTAssertEqual(flow.handoff, .copied)
    }
    func testFlowCannotBypassAliasDirectoryOrEmptyAlias() async {
        let adapter = TestAccessAdapter()
        let directory = AliasDirectory(entries: [.init(alias: "router-test", source: .sshConfiguration)])
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter, aliasDirectory: directory)
        flow.submit(draft()); await settle()
        XCTAssertEqual(flow.state, .form); XCTAssertEqual(adapter.logins, 0)
        var input = draft(); input.alias = ""; input.description = "中文不能生成别名"
        flow.submit(input); await settle()
        XCTAssertEqual(flow.state, .form); XCTAssertEqual(adapter.logins, 0)
    }
    func testDescriptionAndAddressEditRetainsAliasIdentityAndAuthorization() async {
        let adapter = TestAccessAdapter(); adapter.failure = .verification
        let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle()
        let key = flow.authorizationKey; let command = flow.command
        flow.edit(); var edited = flow.draft
        edited.description = "更改后的中文说明"; edited.address = "2001:db8::2"
        adapter.failure = nil; flow.submit(edited); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(flow.authorizationKey, key)
        XCTAssertEqual(flow.command, command); XCTAssertEqual(adapter.installs, 1)
        XCTAssertEqual(flow.draft.description, edited.description)
    }
    func testCancelledFormKeepsEvenInvalidNonsecretInputWithoutKeepingPassword() {
        let flow = FirstAccessFlow(draft: draft(), adapter: TestAccessAdapter())
        var input = draft(key: false); input.alias = "我的服务器"; input.description = "修改过的中文说明"
        flow.retainForm(input); flow.close()
        XCTAssertEqual(flow.draft.alias, input.alias); XCTAssertEqual(flow.draft.description, input.description)
        XCTAssertEqual(flow.draft.password, ""); XCTAssertEqual(flow.state, .form)
    }
    func testEditingOwnStoredAliasDoesNotBlockAccessOrRenameLegacyAlias() async {
        let adapter = TestAccessAdapter()
        let directory = AliasDirectory(entries: [.init(alias: "legacy.host", source: .managed, ownerID: "legacy")])
        var input = draft(); input.alias = "legacy.host"; input.editingEntryID = "legacy"
        let flow = FirstAccessFlow(draft: input, adapter: adapter, aliasDirectory: directory)
        flow.submit(input); await settle()
        XCTAssertEqual(flow.state, .success); XCTAssertEqual(flow.command, "ssh legacy.host")
    }
    func testCloseRejectsLateHandoff() async {
        let adapter = TestAccessAdapter(); let flow = FirstAccessFlow(draft: draft(), adapter: adapter)
        flow.submit(draft()); await settle(); adapter.holdHandoff = true
        flow.performHandoff(); await settle(); flow.close(); adapter.release(); await settle()
        XCTAssertEqual(flow.handoff, .opening) // no false completion after closing
    }
}

@MainActor private final class TestAccessAdapter: FirstAccessAdapter {
    let isSimulation = true
    var deviceID = "device-1"
    var serverID = "server-1"
    var needsConfirmation = false
    var statusUnknown = false
    var failure: AccessFlowFailure?
    var hold: AccessFlowStep?
    var holdHandoff = false
    var handoffFails = false
    var confirmations = 0, logins = 0, installs = 0, statusChecks = 0, terminalCalls = 0, copyCalls = 0
    var keys: Set<AccessAuthorizationKey> = []
    var commands: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func inspectHost(address: String, port: String) async throws -> AccessHostIdentity {
        if failure == .unreachable || failure == .identityMismatch { throw failure! }
        return .init(serverID: serverID, fingerprint: "fixture-only", needsConfirmation: needsConfirmation)
    }
    func confirmHost(_ identity: AccessHostIdentity) async throws { confirmations += 1 }
    func login(draft: AccessFormDraft, identity: AccessHostIdentity) async throws {
        logins += 1; if hold == .login { await pause() }
        if failure == .authentication { throw failure! }
    }
    func authorizationStatus(for key: AccessAuthorizationKey) async throws -> AccessAuthorizationStatus {
        statusChecks += 1; if statusUnknown { return .unknown }; return keys.contains(key) ? .installed : .absent
    }
    func authorize(_ key: AccessAuthorizationKey) async throws {
        if hold == .authorization { await pause() }
        if failure == .authorization { throw failure! }
        if keys.insert(key).inserted { installs += 1 }
        if failure == .authorizationUnknown { throw failure! }
    }
    func verify(_ key: AccessAuthorizationKey, address: String, port: String) async throws {
        if hold == .verification { await pause() }
        if failure == .verification { throw failure! }
    }
    func openTerminal(command: String) async throws {
        commands.append(command); terminalCalls += 1; if holdHandoff { await pause() }
        if handoffFails { throw AccessFlowFailure.unreachable }
    }
    func copyCommand(_ command: String) async throws {
        commands.append(command); copyCalls += 1; if holdHandoff { await pause() }
        if handoffFails { throw AccessFlowFailure.unreachable }
    }
    func cancel() {} // intentionally ignores cancellation to exercise late callbacks
    private func pause() async { await withCheckedContinuation { continuation = $0 } }
    func release() { let saved = continuation; continuation = nil; saved?.resume() }
}
