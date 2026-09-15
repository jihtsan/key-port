import Foundation
import Darwin
import XCTest
import KeyPortCore
import KeyPortInterface
@testable import KeyPort

@MainActor final class WorkspacePolicyTests: XCTestCase {
    private func fixture() throws -> (WorkspaceStore, String, SSHKeyRecord) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("policy space \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let source = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("KeyPortSSHRelay")
        let helper = home.appendingPathComponent("Source App.app/Contents/Helpers/KeyPortSSHRelay")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: helper)
        let store = try WorkspaceStore(home: home, relayHelper: helper)
        let parsed = PublicKeyParser.parse("ssh-ed25519 AQID fixture")!
        let key = SSHKeyRecord(id: "key", deviceID: store.state.deviceID, kind: .ed25519, publicKey: "ssh-ed25519 AQID fixture", fingerprint: parsed.fingerprint, privateKeyPath: "/tmp/key", isInAgent: false, origin: .generated, isLocallyAvailable: true)
        try store.addKey(key)
        var draft = AccessFormDraft(); draft.alias = "fixture"; draft.account = "user"; draft.address = "192.0.2.1"; draft.additionalAddresses = ["192.0.2.2"]
        let server = UUID().uuidString
        _ = try store.save(draft: draft, serverID: server, key: key)
        try store.record(.installed, serverID: server, account: draft.account, keyID: key.id)
        return (store, server, key)
    }
    private func verify(_ store: WorkspaceStore, _ c: WorkspaceStore.Connection) throws {
        let parsed = PublicKeyParser.parse("ssh-ed25519 BAUG host")!
        try store.trust(.init(serverID: c.serverID, address: c.address, port: c.port, key: .init(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: "\(c.address) ssh-ed25519 BAUG")))
        try store.checked(c.id, success: true)
    }
    func testAutomaticAliasSharesCommandAndOnlyIncludesVerifiedCandidates() async throws {
        let (store, _, _) = try fixture()
        XCTAssertEqual(store.topology.activeConnectionProfiles.count, 1)
        let rows = store.state.connections
        XCTAssertThrowsError(try store.command(for: rows[0]))
        try verify(store, rows[0])
        XCTAssertEqual(try store.command(for: rows[1]), "ssh fixture")
        let config = try String(contentsOf: store.installation.managed)
        XCTAssertTrue(config.contains("ProxyCommand")); XCTAssertFalse(config.contains(".app/"))
        let manifest = try currentManifest(store)
        XCTAssertEqual(manifest.configurations[0].candidates.map(\.host), [rows[0].address])
        try verify(store, rows[1])
        XCTAssertEqual(try currentManifest(store).configurations[0].candidates.count, 2)
        let r = try await ProcessExecutor().execute(.init(executable: "/usr/bin/ssh", arguments: ["-G", "-F", store.installation.userConfig.path, "fixture"], limits: .sshDefault))
        XCTAssertTrue(r.succeeded)
        let output = String(decoding: r.stdout, as: UTF8.self)
        XCTAssertTrue(output.contains("hostkeyalias keyport-node-")); XCTAssertTrue(output.contains("proxycommand '"))
        let unrelated = try await ProcessExecutor().execute(.init(executable: "/usr/bin/ssh", arguments: ["-G", "-F", store.installation.userConfig.path, "unrelated"], limits: .sshDefault))
        XCTAssertFalse(String(decoding: unrelated.stdout, as: UTF8.self).contains("keyport-node-"))
        XCTAssertFalse(String(decoding: unrelated.stdout, as: UTF8.self).contains("KeyPortSSHRelay-"))
        try store.checked(rows[0].id, success: false, identityMismatch: true)
        XCTAssertThrowsError(try store.command(for: rows[1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.installation.managed.path))
    }
    func testOrderFixedRemovalAndRevocationInvalidateOldFiles() throws {
        let (store, server, key) = try fixture()
        let rows = store.state.connections
        for row in rows { try verify(store, row) }
        let manifestPath = try manifestURL(store)
        let diagnostic = try store.writeConfiguration(for: rows[0])
        try store.updatePolicy(profileID: rows[0].profileID!, endpoints: [rows[1].endpointID!, rows[0].endpointID!], automatic: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.path))
        XCTAssertEqual(try currentManifest(store).configurations[0].candidates.map(\.host), [rows[1].address, rows[0].address])
        try store.setDefault(rows[1].id)
        let fixed = try String(contentsOf: store.installation.managed)
        XCTAssertTrue(fixed.contains(rows[1].address)); XCTAssertFalse(fixed.contains("ProxyCommand"))
        try store.remove(rows[1].id)
        XCTAssertEqual(store.state.connections.count, 1)
        XCTAssertThrowsError(try store.command(for: rows[0]))
        try store.updatePolicy(profileID: rows[0].profileID!, endpoints: [rows[0].endpointID!], automatic: false)
        XCTAssertEqual(try store.command(for: rows[0]), "ssh fixture")
        try store.record(.absent, serverID: server, account: rows[0].account, keyID: key.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.installation.managed.path))
    }

    func testTamperedHelperAndManifestHaveExplicitRepairAndNewDeviceHasNoEvidence() throws {
        let (store, _, _) = try fixture()
        for row in store.state.connections { try verify(store, row) }
        let bin = store.policyInstallation.root.appendingPathComponent("bin")
        let helper = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: helper)
        XCTAssertThrowsError(try store.synchronizeAliases())
        try store.repairPolicyInstallation()
        XCTAssertEqual(try store.command(for: store.state.connections[0]), "ssh fixture")
        try Data("broken".utf8).write(to: manifestURL(store))
        XCTAssertThrowsError(try store.synchronizeAliases())
        try store.repairPolicyInstallation()
        XCTAssertEqual(try currentManifest(store).configurations[0].candidates.count, 2)
        let otherHome = store.paths.applicationSupport.appendingPathComponent("new-device")
        let other = try WorkspaceStore(home: otherHome, deviceID: "other-device")
        try other.importMetadata(store.topology)
        XCTAssertTrue(other.topology.accessVerifications.isEmpty)
        XCTAssertTrue(other.state.connections.allSatisfy { $0.verification == "pending" && $0.policyReady == false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.installation.managed.path))
        XCTAssertTrue(other.topology.sshKeys.allSatisfy { $0.privateKeyPath == nil })
    }
    func testLegacyUpgradeKeepsBothOldDiagnosticIDsIncludingCanonicalSource() throws {
        let (store, _, key) = try fixture()
        for row in store.state.connections { try verify(store, row) }
        var next = store.document
        let p = next.topology.sshConnectionProfiles[0].id, q = UUID()
        let endpoints = next.topology.sshConnectionProfiles[0].candidateEndpointIDs
        let account = next.topology.sshConnectionProfiles[0].accountID
        next.topology.sshConnectionProfiles = [
            .init(id: p, accountID: account, sshAlias: "fixture", routePolicy: .fixed(endpointID: endpoints[0])),
            .init(id: q, accountID: account, sshAlias: "fixture", routePolicy: .fixed(endpointID: endpoints[1]))]
        next.pathKeys[q.uuidString] = key.id
        for i in next.topology.accessVerifications.indices {
            next.topology.accessVerifications[i].profileID = next.topology.accessVerifications[i].endpointID == endpoints[0] ? p : q
            next.topology.accessVerifications[i].policyEvidenceBinding = nil
        }
        try store.commit(next)
        let old = store.topology
        try store.updatePolicy(profileID: p, endpoints: endpoints, automatic: false)
        XCTAssertEqual(store.topology.activeConnectionProfiles.count, 1)
        XCTAssertEqual(Set(store.legacyDiagnosticConnections().map(\.id)), [p.uuidString, q.uuidString])
        for id in [p,q] { XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.keyPortDirectory.appendingPathComponent("path-\(id.uuidString).conf").path)) }
        try store.importMetadata(old)
        XCTAssertEqual(store.topology.activeConnectionProfiles.count, 1)
        XCTAssertEqual(store.state.connections.filter { $0.verification == "verified" }.count, 2)
    }
    func testChangingOnePortRequiresFreshEvidenceAndPreservesOtherEndpoints() throws {
        let (store, _, _) = try fixture()
        for row in store.state.connections { try verify(store, row) }
        let rows = store.state.connections
        let old = rows[0].endpointID!
        let selected = try store.updatePolicy(profileID: rows[0].profileID!, endpoints: rows.map { $0.endpointID! }, automatic: false, ports: [old: 2222])
        XCTAssertNotEqual(selected[0], old)
        XCTAssertEqual(store.topology.activeEndpoints.first { $0.id == old }?.port, 22)
        XCTAssertEqual(store.state.connections.first { $0.endpointID == selected[0] }?.verification, "pending")
        XCTAssertEqual(store.state.connections.first { $0.endpointID == rows[1].endpointID }?.verification, "verified")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.installation.managed.path))
        XCTAssertEqual(store.topology.authorizations.first?.remoteState, .authorized)
    }
    func testOrdinaryInstallationFailureKeepsPreviousGenerationAndReportsSavedIntent() throws {
        let (store, server, _) = try fixture()
        for row in store.state.connections { try verify(store, row) }
        let config = try Data(contentsOf: store.installation.managed)
        let manifest = try manifestURL(store)
        store.installation.beforeWrite = { if $0 == 1 { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try store.rename(serverID: server, alias: "new-name"))
        XCTAssertEqual(store.topology.activeConnectionProfiles.first?.sshAlias, "new-name")
        XCTAssertEqual(try Data(contentsOf: store.installation.managed), config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(store.installationNotice?.contains("上一代") == true)
        store.installation.beforeWrite = nil
        try store.synchronizeAliases()
        XCTAssertEqual(try store.command(for: store.state.connections[0]), "ssh new-name")
        XCTAssertNil(store.installationNotice)
    }
    func testRevocationCannotRecoverOldManifestEvenWhenIncludeRollbackFails() throws {
        var values = Optional(try fixture())
        var store: WorkspaceStore? = values!.0
        let server = values!.1, key = values!.2
        values = nil
        for row in store!.state.connections { try verify(store!, row) }
        let manifest = try manifestURL(store!), home = store!.installation.home
        let pending = store!.policyInstallation.root.appendingPathComponent("pending-workspace.json")
        store!.installation.beforeWrite = { _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try store!.record(.absent, serverID: server, account: "user", keyID: key.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertEqual(try Data(contentsOf: store!.paths.knownHosts), Data())
        XCTAssertEqual(store!.topology.authorizations.first?.remoteState, .revoked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        store = nil
        let recovered = try WorkspaceStore(home: home)
        XCTAssertEqual(recovered.topology.authorizations.first?.remoteState, .revoked)
        try recovered.synchronizeAliases()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovered.installation.managed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
    func testInstalledPolicyUsesRealSSHWithoutSourceAppAndKeepsEstablishedSession() async throws {
        let (initialStore, serverID, _) = try fixture()
        let home = initialStore.installation.home
        let runner = ProcessExecutor()
        @Sendable func run(_ executable: String, _ arguments: [String]) async throws -> ProcessExecutionResult {
            try await runner.execute(.init(executable: executable, arguments: arguments, limits: .sshDefault))
        }
        let hostKey = home.appendingPathComponent("host-key"), clientKey = home.appendingPathComponent("client-key")
        for key in [hostKey, clientKey] {
            let generated = try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
            XCTAssertTrue(generated.succeeded)
        }
        let publicLine = try String(contentsOf: clientKey.appendingPathExtension("pub"))
        let parsed = try XCTUnwrap(PublicKeyParser.parse(publicLine))
        let key = SSHKeyRecord(id: "key", deviceID: initialStore.state.deviceID, kind: .ed25519, publicKey: publicLine.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: parsed.fingerprint, privateKeyPath: clientKey.path, isInAgent: false, origin: .generated, isLocallyAvailable: true)
        try initialStore.addKey(key)
        let port = try reservePort(), unavailable = try reservePort()
        defer { Darwin.close(unavailable.fd) }
        Darwin.close(port.fd)
        let user = NSUserName()
        let config = home.appendingPathComponent("sshd-config")
        let log = home.appendingPathComponent("sshd.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let text = """
        Port \(port.port)
        ListenAddress 127.0.0.1
        HostKey "\(hostKey.path)"
        PidFile "\(home.appendingPathComponent("sshd.pid").path)"
        AuthorizedKeysFile "\(clientKey.appendingPathExtension("pub").path)"
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        PermitRootLogin no
        PermitTTY no
        AllowTcpForwarding no
        UsePAM no
        AllowUsers \(user)
        LogLevel QUIET
        """
        try Data(text.utf8).write(to: config)
        let daemon = Process(); daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        daemon.arguments = ["-D", "-e", "-f", config.path]; daemon.standardInput = FileHandle.nullDevice
        daemon.standardOutput = logHandle; daemon.standardError = logHandle
        try daemon.run()
        defer { if daemon.isRunning { daemon.terminate() }; daemon.waitUntilExit() }
        var ready = false
        for _ in 0..<30 {
            if try await run("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(port.port)]).succeeded { ready = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, (try? String(contentsOf: log)) ?? "no sshd log"); guard ready else { return }
        var next = initialStore.document
        for i in next.topology.endpoints.indices {
            next.topology.endpoints[i].address = "127.0.0.1"
            next.topology.endpoints[i].port = UInt16(i == 0 ? unavailable.port : port.port)
        }
        next.topology.sshAccounts[0].username = user
        try initialStore.commit(next)
        try initialStore.record(.installed, serverID: serverID, account: user, keyID: key.id)
        let host = try XCTUnwrap(PublicKeyParser.parse(String(contentsOf: hostKey.appendingPathExtension("pub"))))
        for row in initialStore.state.connections {
            try initialStore.trust(.init(serverID: serverID, address: row.address, port: row.port, key: .init(algorithm: host.type, fingerprint: host.fingerprint, knownHostsLine: "[127.0.0.1]:\(row.port) \(host.type) \(host.blob)")))
            try initialStore.checked(row.id, success: true)
        }
        let sshArguments = ["-F", initialStore.installation.userConfig.path, "-o", "BatchMode=yes", "-T", "fixture"]
        // The active config must reference only the stable installation, never the source executable.
        let installed = try String(contentsOf: initialStore.installation.managed)
        XCTAssertFalse(installed.contains(".build")); XCTAssertFalse(installed.contains(".app/"))
        try FileManager.default.removeItem(at: home.appendingPathComponent("Source App.app"))
        async let first = run("/usr/bin/ssh", sshArguments + ["printf FIRST"])
        async let second = run("/usr/bin/ssh", sshArguments + ["printf SECOND"])
        let results = try await [first, second]
        XCTAssertTrue(results.allSatisfy(\.succeeded), results.map { String(decoding: $0.stderr, as: UTF8.self) }.joined())
        XCTAssertEqual(results.map { String(decoding: $0.stdout, as: UTF8.self) }, ["FIRST", "SECOND"])
        initialStore.refreshSelectionEvents()
        XCTAssertTrue(initialStore.workspace.graph.paths.allSatisfy { $0.selectionSummary?.contains(String(port.port)) == true })
        // Wait for an authenticated remote command before replacing local configuration.
        let marker = home.appendingPathComponent("session-started")
        let task = Task { try await run("/usr/bin/ssh", sshArguments + ["touch " + WorkspaceStore.shellQuote(marker.path) + "; sleep 1; printf ALIVE"]) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let authenticated = FileManager.default.fileExists(atPath: marker.path)
        XCTAssertTrue(authenticated)
        guard authenticated else { _ = try await task.value; return }
        // Store revocation is tested separately. This fixture withdraws generated files
        // only after OpenSSH owns an authenticated socket.
        try initialStore.installation.install(entries: [], knownHosts: initialStore.paths.knownHosts)
        try initialStore.invalidateOldPolicyFiles(except: home.appendingPathComponent("unused-generation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initialStore.installation.managed.path))
        let established = try await task.value
        XCTAssertTrue(established.succeeded, String(decoding: established.stderr, as: UTF8.self))
        XCTAssertEqual(String(decoding: established.stdout, as: UTF8.self), "ALIVE")
    }
    private func reservePort() throws -> (fd: Int32, port: Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WorkspaceError.configuration }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0, named == 0 else { Darwin.close(fd); throw WorkspaceError.configuration }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }
    private func manifestURL(_ store: WorkspaceStore) throws -> URL {
        let root = store.policyInstallation.root.appendingPathComponent("generations")
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 1)
        return try XCTUnwrap(dirs.first).appendingPathComponent("manifest.json")
    }
    private func currentManifest(_ store: WorkspaceStore) throws -> SSHPreconnectRelayManifest {
        try JSONDecoder().decode(SSHPreconnectRelayManifest.self, from: Data(contentsOf: manifestURL(store)))
    }
}
