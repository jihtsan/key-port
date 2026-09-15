import Foundation
import XCTest
import KeyPortCore
import KeyPortInterface
@testable import KeyPort

@MainActor final class WorkspaceAccessTests: XCTestCase {
    private let hostLine = "test.example ssh-ed25519 AAAA fixture-host"
    private let publicLine = "ssh-ed25519 AQID fixture-device"
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyport98-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func key(_ store: WorkspaceStore) throws -> SSHKeyRecord {
        let parsed = PublicKeyParser.parse(publicLine)!
        let key = SSHKeyRecord(id: parsed.fingerprint, deviceID: store.state.deviceID, kind: .ed25519,
            publicKey: publicLine, fingerprint: parsed.fingerprint, privateKeyPath: store.paths.identitiesDirectory.appendingPathComponent("fixture").path,
            isInAgent: false, origin: .generated, isLocallyAvailable: true)
        try store.addKey(key); return key
    }
    private func verify(_ store: WorkspaceStore, _ id: String) throws {
        let c = store.state.connections.first { $0.id == id }!
        let parsed = PublicKeyParser.parse(hostLine)!
        try store.trust(.init(serverID: c.serverID, address: c.address, port: c.port, key: .init(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: "\(c.address) \(parsed.type) \(parsed.blob)")))
        try store.record(.installed, serverID: c.serverID, account: c.account, keyID: c.keyID)
        try store.checked(id, success: true)
    }
    private func draft() -> AccessFormDraft {
        var draft = AccessFormDraft(); draft.alias = "test-server"; draft.description = "验收测试"; draft.address = "test.example"
        draft.account = "test"; draft.password = "synthetic-test-password"; return draft
    }
    func testEnrollmentReconcilesInstallsVerifiesAndPersistsWithoutPassword() async throws {
        let root = try directory()
        var store: WorkspaceStore? = try WorkspaceStore(home: root)
        _ = try key(store!)
        let executor = PilotExecutor([.ok(hostLine), .ok(), .denied, .ok(""), .ok(), .ok()])
        var adapter: OpenSSHFirstAccessAdapter? = OpenSSHFirstAccessAdapter(store: store!, executor: executor, askPassPath: "/usr/bin/true")
        let input = draft()
        let identity = try await adapter!.inspectHost(address: input.address, port: input.port)
        XCTAssertTrue(identity.needsConfirmation)
        XCTAssertTrue(store!.state.trusts.isEmpty)
        try await adapter!.confirmHost(identity)
        try await adapter!.login(draft: input, identity: identity)
        let authorization = AccessAuthorizationKey(deviceID: store!.state.deviceID, serverID: identity.serverID, account: input.account)
        let status = try await adapter!.authorizationStatus(for: authorization)
        XCTAssertEqual(status, .absent)
        try await adapter!.authorize(authorization)
        try await adapter!.verify(authorization, address: input.address, port: input.port)
        XCTAssertEqual(store!.workspace.graph.paths.first?.verification, .verified)
        let command = adapter!.command(for: input)
        XCTAssertEqual(command, "ssh test-server")
        let requests = await executor.requests
        XCTAssertEqual(requests.filter { String(data: $0.standardInput ?? Data(), encoding: .utf8)?.contains(Data(publicLine.utf8).base64EncodedString()) == true }.count, 1)
        for request in requests {
            XCTAssertFalse(request.arguments.joined().contains(input.password))
            XCTAssertFalse(request.environment.values.joined().contains(input.password))
            XCTAssertFalse(String(decoding: request.standardInput ?? Data(), as: UTF8.self).contains(input.password))
            if request.executable == "/usr/bin/ssh" {
                XCTAssertEqual(Array(request.arguments.prefix(2)), ["-F", "/dev/null"])
                XCTAssertTrue(request.arguments.contains("StrictHostKeyChecking=yes"))
            }
        }
        let stateURL = store!.paths.applicationSupport.appendingPathComponent("workspace-v1.json")
        XCTAssertFalse(try String(contentsOf: stateURL).contains(input.password))
        let device = store!.state.deviceID
        adapter!.cancel(); adapter = nil; store = nil
        let restored = try WorkspaceStore(home: root)
        XCTAssertEqual(restored.state.deviceID, device)
        XCTAssertEqual(restored.workspace.graph.paths.first?.verification, .verified)
        XCTAssertEqual(restored.workspace.graph.servers.first?.description, input.description)
    }
    func testBatchAddressesPersistAsIndependentPendingPathsAndPreserveExistingVerification() throws {
        let root = try directory()
        var store: WorkspaceStore? = try WorkspaceStore(home: root)
        let key = try key(store!)
        let server = UUID().uuidString
        var input = draft()
        input.automaticRouting = false
        input.additionalAddresses = ["100.64.0.2", "fd7a:115c:a1e0::2", "TEST.EXAMPLE", "100.64.0.2"]
        let primary = try store!.save(draft: input, serverID: server, key: key)
        XCTAssertEqual(store!.state.connections.count, 3)
        XCTAssertEqual(Set(store!.state.connections.map(\.serverID)), [server])
        XCTAssertTrue(store!.state.connections.allSatisfy { $0.verification == "pending" })
        XCTAssertTrue(store!.state.trusts.isEmpty)
        try verify(store!, primary)
        XCTAssertEqual(store!.state.connections.filter { $0.verification == "verified" }.count, 1)
        var more = draft()
        more.address = "another.example"
        more.additionalAddresses = input.addresses
        _ = try store!.save(draft: more, serverID: server, key: key)
        XCTAssertEqual(store!.state.connections.count, 4)
        XCTAssertEqual(store!.state.connections.first { $0.id == primary }?.verification, "verified")
        XCTAssertEqual(store!.state.defaultPaths?[server], primary)
        let count = store!.state.connections.count
        more.additionalAddresses.append("invalid address")
        XCTAssertThrowsError(try store!.save(draft: more, serverID: server, key: key))
        XCTAssertEqual(store!.state.connections.count, count)
        store = nil
        let restored = try WorkspaceStore(home: root)
        XCTAssertEqual(restored.state.connections.count, 4)
        XCTAssertEqual(restored.state.connections.filter { $0.verification == "pending" }.count, 3)
        XCTAssertEqual(restored.state.connections.first { $0.id == primary }?.verification, "verified")
    }
    func testDefaultPathRenameDeletionAndRestartStayConsistent() throws {
        let root = try directory()
        var store: WorkspaceStore? = try WorkspaceStore(home: root)
        let key = try key(store!)
        let server = UUID().uuidString
        let first = try store!.save(draft: draft(), serverID: server, key: key)
        try verify(store!, first)
        var secondDraft = draft(); secondDraft.address = "second.example"
        let second = try store!.save(draft: secondDraft, serverID: server, key: key)
        try verify(store!, second)
        XCTAssertEqual(try store!.command(for: store!.state.connections[0]), "ssh test-server")
        XCTAssertEqual(try store!.command(for: store!.state.connections[1]), "ssh test-server")
        XCTAssertTrue(try store!.diagnosticCommand(for: store!.state.connections[1]).contains(" -F "))
        XCTAssertTrue(try String(contentsOf: store!.installation.managed).contains("test.example"))
        try store!.setDefault(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store!.paths.keyPortDirectory.appendingPathComponent("path-\(first).conf").path))
        _ = try store!.diagnosticCommand(for: store!.state.connections.first { $0.id == first }!)
        XCTAssertTrue(try String(contentsOf: store!.installation.managed).contains("second.example"))
        try store!.rename(serverID: server, alias: "renamed")
        XCTAssertFalse(try String(contentsOf: store!.installation.managed).contains("Host test-server"))
        XCTAssertTrue(store!.state.connections.allSatisfy { $0.alias == "renamed" })
        store = nil
        store = try WorkspaceStore(home: root)
        try store!.synchronizeAliases()
        XCTAssertEqual(store!.state.defaultPaths?[server], second)
        XCTAssertEqual(try store!.command(for: store!.state.connections.first { $0.id == second }!), "ssh renamed")
        try store!.remove(second)
        XCTAssertNil(store!.state.defaultPaths?[server])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store!.installation.managed.path))
        XCTAssertThrowsError(try store!.command(for: store!.state.connections[0]))
        XCTAssertTrue(try store!.diagnosticCommand(for: store!.state.connections[0]).contains(" -F "))
        XCTAssertEqual(store!.state.keys.count, 1)
    }
    func testConflictingRenamePreservesStateAndConfiguration() throws {
        let store = try WorkspaceStore(home: directory()), key = try key(store)
        let server = UUID().uuidString
        let id = try store.save(draft: draft(), serverID: server, key: key)
        try verify(store, id)
        let original = try String(contentsOf: store.installation.userConfig)
        try Data((original + "\nHost occupied\n HostName other.example\n").utf8).write(to: store.installation.userConfig)
        XCTAssertThrowsError(try store.rename(serverID: server, alias: "occupied"))
        XCTAssertEqual(store.state.connections[0].alias, "test-server")
        XCTAssertTrue(try String(contentsOf: store.installation.managed).contains("Host test-server"))
    }
    func testRepeatedSaveRetainsDefaultAndRequiresFreshVerification() throws {
        let store = try WorkspaceStore(home: directory()), key = try key(store)
        let server = UUID().uuidString
        let id = try store.save(draft: draft(), serverID: server, key: key)
        try verify(store, id)
        let repeated = try store.save(draft: draft(), serverID: server, key: key)
        XCTAssertEqual(id, repeated); XCTAssertEqual(store.state.connections.count, 1)
        XCTAssertEqual(store.state.defaultPaths?[server], id)
        XCTAssertThrowsError(try store.command(for: store.state.connections[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.installation.managed.path))
        try verify(store, id)
        XCTAssertEqual(try store.command(for: store.state.connections[0]), "ssh test-server")
    }
    func testChangedHostStopsBeforeAuthentication() async throws {
        let store = try WorkspaceStore(home: directory()); _ = try key(store)
        let executor = PilotExecutor([.ok(hostLine), .ok("test.example ssh-ed25519 BAUG changed")])
        let adapter = OpenSSHFirstAccessAdapter(store: store, executor: executor)
        let identity = try await adapter.inspectHost(address: "test.example", port: "22")
        try await adapter.confirmHost(identity); adapter.cancel()
        do { _ = try await adapter.inspectHost(address: "test.example", port: "22"); XCTFail("changed host accepted") }
        catch { XCTAssertEqual(error as? AccessFlowFailure, .identityMismatch) }
        let requests = await executor.requests
        XCTAssertTrue(requests.allSatisfy { $0.executable == "/usr/bin/ssh-keyscan" })
    }
    func testNewAddressKeepsNodeAndSkipsInstallationWhenKeyWorks() async throws {
        let store = try WorkspaceStore(home: directory()); let key = try key(store)
        let first = OpenSSHFirstAccessAdapter(store: store, executor: PilotExecutor([.ok(hostLine)]))
        let identity = try await first.inspectHost(address: "test.example", port: "22")
        try await first.confirmHost(identity)
        _ = try store.save(draft: draft(), serverID: identity.serverID, key: key)
        let executor = PilotExecutor([.ok(hostLine), .ok(), .ok(), .ok()])
        let adapter = OpenSSHFirstAccessAdapter(store: store, expectedServerID: identity.serverID, executor: executor)
        var input = draft(); input.editingEntryID = identity.serverID; input.address = "other.example"; input.existingKey = true; input.password = ""
        let other = try await adapter.inspectHost(address: input.address, port: input.port)
        XCTAssertEqual(other.serverID, identity.serverID); XCTAssertTrue(other.needsConfirmation)
        try await adapter.confirmHost(other)
        try await adapter.login(draft: input, identity: other)
        let authorization = AccessAuthorizationKey(deviceID: store.state.deviceID, serverID: other.serverID, account: input.account)
        let status = try await adapter.authorizationStatus(for: authorization)
        XCTAssertEqual(status, .installed)
        try await adapter.verify(authorization, address: input.address, port: input.port)
        XCTAssertEqual(store.workspace.graph.servers.count, 1); XCTAssertEqual(store.workspace.graph.paths.count, 2)
        let requests = await executor.requests
        XCTAssertTrue(requests.allSatisfy { $0.standardInput == nil })
        XCTAssertTrue(try String(contentsOf: store.writeConfiguration(for: store.state.connections.last!)).contains("HostName \"other.example\""))
    }
    func testExistingRemoteKeyIsNotReinstalledEvenWhenLoginWithItFails() async throws {
        let store = try WorkspaceStore(home: directory()); _ = try key(store)
        let adapter = OpenSSHFirstAccessAdapter(store: store, executor: PilotExecutor([.ok(hostLine), .ok(), .denied, .ok(publicLine)]), askPassPath: "/usr/bin/true")
        let identity = try await adapter.inspectHost(address: "test.example", port: "22"); try await adapter.confirmHost(identity)
        try await adapter.login(draft: draft(), identity: identity)
        let status = try await adapter.authorizationStatus(for: .init(deviceID: store.state.deviceID, serverID: identity.serverID, account: "test"))
        XCTAssertEqual(status, .installed)
        adapter.cancel()
    }
    func testWrongPasswordDoesNotAuthorizeOrLeakSecretToDisk() async throws {
        let store = try WorkspaceStore(home: directory()); _ = try key(store)
        let executor = PilotExecutor([.ok(hostLine), .denied])
        let adapter = OpenSSHFirstAccessAdapter(store: store, executor: executor, askPassPath: "/usr/bin/true")
        let identity = try await adapter.inspectHost(address: "test.example", port: "22"); try await adapter.confirmHost(identity)
        do { try await adapter.login(draft: draft(), identity: identity); XCTFail("password accepted") } catch {}
        adapter.cancel()
        XCTAssertTrue(store.state.authorizations.isEmpty)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testPasswordRetryUsesOwnedAliasAfterFirstFailure() async throws {
        let store = try WorkspaceStore(home: directory()); _ = try key(store)
        let executor = PilotExecutor([.ok(hostLine), .denied, .ok(hostLine), .ok()])
        let adapter = OpenSSHFirstAccessAdapter(store: store, executor: executor, askPassPath: "/usr/bin/true")
        let identity = try await adapter.inspectHost(address: "test.example", port: "22"); try await adapter.confirmHost(identity)
        do { try await adapter.login(draft: draft(), identity: identity); XCTFail("password accepted") } catch {}
        adapter.cancel()
        let retry = try await adapter.inspectHost(address: "test.example", port: "22")
        XCTAssertFalse(retry.needsConfirmation)
        try await adapter.login(draft: draft(), identity: retry)
        XCTAssertEqual(store.state.connections.count, 1)
        adapter.cancel()
    }
    func testWrittenConfigurationIsAcceptedByLocalOpenSSH() async throws {
        let store = try WorkspaceStore(home: directory()); let key = try key(store)
        _ = try store.save(draft: draft(), serverID: UUID().uuidString, key: key)
        let config = try store.writeConfiguration(for: store.state.connections[0])
        let result = try await ProcessExecutor().execute(.init(executable: "/usr/bin/ssh", arguments: ["-G", "-F", config.path, "test-server"], limits: .sshDefault))
        XCTAssertTrue(result.succeeded)
        let output = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(output.contains("hostname test.example"))
        XCTAssertTrue(output.contains("user test"))
        XCTAssertTrue(output.contains("passwordauthentication no"))
        XCTAssertTrue(output.contains("stricthostkeychecking true") || output.contains("stricthostkeychecking yes"))
    }
    func testExclusiveStoreAndCorruptionDoNotSilentlyResetData() throws {
        let root = try directory()
        var store: WorkspaceStore? = try WorkspaceStore(home: root)
        XCTAssertThrowsError(try WorkspaceStore(home: root))
        let url = store!.paths.applicationSupport.appendingPathComponent("workspace-v1.json")
        store = nil
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try WorkspaceStore(home: root))
        XCTAssertEqual(try String(contentsOf: url), "invalid")
    }
    func testConfigurationRejectsExpansionAndInjection() {
        for value in ["x\nProxyCommand evil", "x\"", "%h", "x\\y", "\0"] { XCTAssertFalse(WorkspaceStore.safeConfigValue(value)) }
        XCTAssertEqual(WorkspaceStore.shellQuote("a'b"), "'a'\\''b'")
    }
    func testBoundedRunnerMapsCancellationAndTimeoutToFailure() async throws {
        for ending: ProcessExecutionEnding in [.cancelled(forcedKill: false), .timedOut(forcedKill: false)] {
            let runner = ProcessRunner(executor: PilotExecutor([.init(ending: ending, stdout: Data(), stderr: Data(), duration: 0)]))
            do { _ = try await runner.run("/usr/bin/ssh", arguments: []); XCTFail("termination accepted as success") } catch {}
        }
    }
}

private actor PilotExecutor: ProcessExecuting {
    private var results: [ProcessExecutionResult]
    private(set) var requests: [ProcessExecutionRequest] = []
    init(_ results: [ProcessExecutionResult]) { self.results = results }
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        requests.append(request)
        guard !results.isEmpty else { throw WorkspaceError.configuration }
        return results.removeFirst()
    }
}
private extension ProcessExecutionResult {
    static func ok(_ text: String = "") -> Self { .init(ending: .exited(0), stdout: Data(text.utf8), stderr: Data(), duration: 0) }
    static var denied: Self { .init(ending: .exited(255), stdout: Data(), stderr: Data("Permission denied".utf8), duration: 0) }
}
