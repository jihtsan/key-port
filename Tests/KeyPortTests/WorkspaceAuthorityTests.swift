import Foundation
import XCTest
import KeyPortCore
import KeyPortInterface
@testable import KeyPort

@MainActor final class WorkspaceAuthorityTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(device: String = "local") -> TopologySnapshot {
        let node = UUID(), endpoint = UUID(), account = UUID(), profile = UUID()
        return .init(nodes: [.init(id: node, name: "Existing server", roles: [.sshHost])],
            profiles: [.init(id: device, nodeID: UUID(), name: "Existing Mac", isCurrent: true)],
            endpoints: [.init(id: endpoint, nodeID: node, address: "existing.example", port: 22, protocol: .ssh)],
            services: [.init(id: UUID(), nodeID: node, name: "Database", protocol: .postgresql)],
            sshAccounts: [.init(id: account, nodeID: node, username: "admin")],
            sshConnectionProfiles: [.init(id: profile, accountID: account, sshAlias: "existing", routePolicy: .fixed(endpointID: endpoint))],
            sshKeys: [.init(id: "key", deviceID: device, kind: .ed25519, publicKey: "ssh-ed25519 AQID fixture", fingerprint: PublicKeyParser.parse("ssh-ed25519 AQID fixture")!.fingerprint, privateKeyPath: "/local/private-key", origin: .generated, isLocallyAvailable: true)])
    }
    func testTopologyMigrationPreservesUnexposedFactsBacksUpAndRunsOnlyOnce() throws {
        let root = try home(), paths = KeyPortPaths(home: root); try paths.prepareDirectories()
        let initial = fixture()
        let bytes = try WorkspaceStore.encoder().encode(initial); try bytes.write(to: paths.topologySnapshot)
        var store: WorkspaceStore? = try WorkspaceStore(home: root)
        XCTAssertEqual(store!.topology.services, initial.services)
        XCTAssertEqual(store!.topology.sshAccounts, try WorkspaceStore.decoder().decode(TopologySnapshot.self, from: bytes).sshAccounts)
        XCTAssertEqual(store!.workspace.graph.paths.count, 1)
        XCTAssertEqual(store!.state.deviceID, "local")
        XCTAssertEqual(try Data(contentsOf: paths.topologySnapshot), bytes)
        let files = try FileManager.default.contentsOfDirectory(at: paths.applicationSupport, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("migration-backup-") }.count, 1)
        try store!.renameDevice("local", name: "Renamed Mac")
        store = nil
        try Data("broken-old-source".utf8).write(to: paths.topologySnapshot)
        let reopened = try WorkspaceStore(home: root)
        XCTAssertEqual(reopened.topology.profiles.first?.name, "Renamed Mac")
        XCTAssertEqual(reopened.topology.services, initial.services)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.snapshot.path))
    }
    func testUnsupportedSchemaAndDuplicateIdentitiesCannotPublishWorkspace() throws {
        for duplicate in [false, true] {
            let root = try home(), paths = KeyPortPaths(home: root); try paths.prepareDirectories()
            var value = fixture()
            if duplicate { value.nodes.append(value.nodes[0]) } else { value.schemaVersion = 99 }
            let bytes = try WorkspaceStore.encoder().encode(value); try bytes.write(to: paths.topologySnapshot)
            XCTAssertThrowsError(try WorkspaceStore(home: root))
            XCTAssertEqual(try Data(contentsOf: paths.topologySnapshot), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.applicationSupport.appendingPathComponent("workspace-v1.json").path))
        }
    }
    func testDamagedLegacySourceDoesNotPublishAnEmptyWorkspace() throws {
        let root = try home(), paths = KeyPortPaths(home: root); try paths.prepareDirectories()
        try Data("broken".utf8).write(to: paths.topologySnapshot)
        XCTAssertThrowsError(try WorkspaceStore(home: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.applicationSupport.appendingPathComponent("workspace-v1.json").path))
        XCTAssertEqual(try String(contentsOf: paths.topologySnapshot), "broken")
    }
    func testPilotMigrationPreservesPathsKeysTrustAndAuthorizationWithoutParallelStateWrites() throws {
        let root = try home(), paths = KeyPortPaths(home: root)
        let pilotPaths = KeyPortPaths(home: paths.applicationSupport.appendingPathComponent("AccessPilot")); try pilotPaths.prepareDirectories()
        var pilot = WorkspaceStore.State(); let server = UUID().uuidString, id = UUID().uuidString
        let parsed = PublicKeyParser.parse("ssh-ed25519 AQID fixture")!
        pilot.keys = [.init(id: "pilot-key", deviceID: pilot.deviceID, kind: .ed25519, publicKey: "ssh-ed25519 AQID fixture", fingerprint: parsed.fingerprint, privateKeyPath: "/pilot/key", isInAgent: false, origin: .generated, isLocallyAvailable: true)]
        pilot.connections = [.init(id: id, serverID: server, alias: "pilot", description: "Existing pilot", address: "pilot.example", port: 22, account: "root", keyID: "pilot-key", verification: "verified", checkedAt: Date())]
        pilot.authorizations["\(server)|root|pilot-key"] = "installed"; pilot.defaultPaths = [server: id]
        let source = pilotPaths.applicationSupport.appendingPathComponent("access-pilot-v1.json")
        let bytes = try JSONEncoder().encode(pilot); try bytes.write(to: source)
        let store = try WorkspaceStore(home: root)
        XCTAssertEqual(store.state.connections.first?.id, id)
        XCTAssertEqual(store.state.keys.first?.privateKeyPath, "/pilot/key")
        XCTAssertEqual(store.topology.authorizations.first?.remoteState, .authorized)
        try store.remove(id)
        XCTAssertTrue(store.topology.sshConnectionProfiles.first!.isDeleted)
        XCTAssertEqual(store.topology.authorizations.first?.remoteState, .authorized)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testCloudMergeRestoresOnlyLocalEvidenceAndRetainsServices() async throws {
        let root = try home(), paths = KeyPortPaths(home: root); try paths.prepareDirectories()
        let local = fixture(); try WorkspaceStore.encoder().encode(local).write(to: paths.topologySnapshot)
        var remote = fixture(device: "remote")
        remote.accessVerifications = [.init(accountID: remote.sshAccounts[0].id, deviceID: "remote", profileID: remote.sshConnectionProfiles[0].id, endpointID: remote.endpoints[0].id, status: .authorized, lastCheckedAt: Date())]
        remote.sshKeys[0].id = "remote-key"
        let cloud = WorkspaceCloudFixture(remote: remote)
        let store = try WorkspaceStore(home: root, cloud: cloud)
        await store.synchronize()
        guard case .succeeded = store.syncState else { return XCTFail("Sync failed: \(store.syncState)") }
        XCTAssertEqual(store.topology.services.count, 2)
        XCTAssertNil(store.topology.sshKeys.first { $0.id == "remote-key" }?.privateKeyPath)
        XCTAssertEqual(store.topology.sshKeys.first { $0.id == "key" }?.privateKeyPath, "/local/private-key")
        XCTAssertFalse(store.workspace.graph.paths.contains { $0.verification == .verified })
        XCTAssertTrue(store.topology.accessVerifications.isEmpty)
    }
    func testCloudResponseDoesNotOverwriteDeviceRenameMadeWhileAwaitingNetwork() async throws {
        let root = try home(), paths = KeyPortPaths(home: root); try paths.prepareDirectories()
        let initial = fixture(); try WorkspaceStore.encoder().encode(initial).write(to: paths.topologySnapshot)
        let cloud = BlockingWorkspaceCloud(remote: initial)
        let store = try WorkspaceStore(home: root, cloud: cloud)
        let sync = Task { await store.synchronize() }
        await cloud.waitUntilStarted()
        try store.renameDevice("local", name: "New local name")
        await cloud.finish()
        await sync.value
        XCTAssertEqual(store.topology.profiles.first { $0.id == "local" }?.name, "New local name")
    }
    func testRepeatedTrustRefreshKeepsStableCloudIdentity() throws {
        let store = try WorkspaceStore(home: home())
        let parsed = PublicKeyParser.parse("ssh-ed25519 AQID fixture")!
        let trust = WorkspaceStore.Trust(serverID: UUID().uuidString, address: "host.example", port: 22,
            key: .init(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: "host.example ssh-ed25519 AQID"))
        try store.trust(trust)
        let old = store.topology
        try store.trust(trust)
        XCTAssertEqual(store.topology.hostKeyTrusts.first?.id, old.hostKeyTrusts.first?.id)
        XCTAssertEqual(TopologyCloudMetadataSnapshotPolicy.merge(local: store.topology, remote: old).hostKeyTrusts.count, 1)
    }
    func testAccountAuthorizationIsSharedAcrossAddressesAndDeletingPathDoesNotRevoke() throws {
        let store = try WorkspaceStore(home: home())
        let key = SSHKeyRecord(id: "key", deviceID: store.state.deviceID, kind: .ed25519, publicKey: "ssh-ed25519 AQID fixture", fingerprint: PublicKeyParser.parse("ssh-ed25519 AQID fixture")!.fingerprint, privateKeyPath: "/local/key", isInAgent: false, origin: .generated, isLocallyAvailable: true)
        try store.addKey(key)
        var draft = AccessFormDraft(); draft.alias = "test"; draft.account = "root"; draft.address = "first.example"
        let server = UUID().uuidString
        let first = try store.save(draft: draft, serverID: server, key: key)
        draft.address = "second.example"
        _ = try store.save(draft: draft, serverID: server, key: key)
        try store.record(.installed, serverID: server, account: "root", keyID: key.id)
        XCTAssertEqual(store.topology.activeAccounts.count, 1)
        XCTAssertEqual(store.topology.authorizations.count, 1)
        try store.remove(first)
        XCTAssertEqual(store.topology.authorizations.first?.remoteState, .authorized)
        XCTAssertEqual(store.topology.activeAccounts.count, 1)
        XCTAssertEqual(store.topology.activeConnectionProfiles.count, 1)
    }
}

private actor WorkspaceCloudFixture: CloudSyncing {
    let remote: TopologySnapshot
    init(remote: TopologySnapshot) { self.remote = remote }
    func availability() async -> CloudSyncAvailability { .available }
    func synchronize(_ local: TopologySnapshot) async throws -> TopologySnapshot { remote }
}

private actor BlockingWorkspaceCloud: CloudSyncing {
    let remote: TopologySnapshot
    var pending: CheckedContinuation<TopologySnapshot, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(remote: TopologySnapshot) { self.remote = remote }
    func availability() async -> CloudSyncAvailability { .available }
    func synchronize(_ local: TopologySnapshot) async throws -> TopologySnapshot {
        await withCheckedContinuation { continuation in
            pending = continuation; waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() { pending?.resume(returning: remote); pending = nil }
}

extension WorkspaceAuthorityTests {
    private func removalFixture() throws -> WorkspaceStore {
        let root = try home(), paths = KeyPortPaths(home: root)
        try paths.prepareDirectories()
        var initial = fixture()
        initial.authorizations = [.init(accountID: initial.sshAccounts[0].id, keyID: "key", fingerprint: initial.sshKeys[0].fingerprint, remoteComment: "", remoteState: .authorized)]
        try WorkspaceStore.encoder().encode(initial).write(to: paths.topologySnapshot)
        return try WorkspaceStore(home: root)
    }
    func testDisconnectDeletesServerChildrenAndAliasesButPreservesSharedKeysAndCloudTombstones() async throws {
        let store = try removalFixture(), original = store.topology
        let id = original.nodes[0].id.uuidString
        try store.checked(original.sshConnectionProfiles[0].id.uuidString, success: true)
        try store.setDefault(original.sshConnectionProfiles[0].id.uuidString)
        let config = try store.writeConfiguration(for: store.state.connections[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        var calls = 0
        try await store.revokeServer(id, disconnect: true) { batch in
            calls += 1; XCTAssertEqual(batch.count, 1)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(store.document.defaultPaths.isEmpty)
        XCTAssertTrue(store.document.pathKeys.isEmpty)
        XCTAssertTrue(store.topology.activeNodes.isEmpty)
        XCTAssertTrue(store.topology.activeAccounts.isEmpty)
        XCTAssertTrue(store.topology.activeEndpoints.isEmpty)
        XCTAssertTrue(store.topology.activeConnectionProfiles.isEmpty)
        XCTAssertTrue(store.topology.services.allSatisfy(\.isDeleted))
        XCTAssertTrue(store.topology.authorizations.allSatisfy { $0.isDeleted && $0.remoteState == .revoked })
        XCTAssertEqual(store.topology.sshKeys, original.sshKeys)
        XCTAssertTrue(store.state.connections.isEmpty)
        XCTAssertTrue(store.workspace.graph.servers.isEmpty)
        let merged = TopologyCloudMetadataSnapshotPolicy.merge(local: store.topology, remote: original)
        XCTAssertTrue(merged.activeNodes.isEmpty)
        XCTAssertTrue(merged.activeAccounts.isEmpty)
        XCTAssertTrue(merged.activeConnectionProfiles.isEmpty)
    }
    func testRevokeOnlyPreservesServerAndPath() async throws {
        let store = try removalFixture(), original = store.topology
        try await store.revokeServer(original.nodes[0].id.uuidString, disconnect: false) { _ in }
        XCTAssertEqual(store.topology.nodes, original.nodes)
        XCTAssertEqual(store.topology.sshConnectionProfiles, original.sshConnectionProfiles)
        XCTAssertEqual(store.topology.authorizations[0].remoteState, .revoked)
        try await store.revokeServer(original.nodes[0].id.uuidString, disconnect: true) { _ in XCTFail("Already revoked") }
        XCTAssertTrue(store.topology.activeNodes.isEmpty)
    }
    func testFailedRevocationDoesNotDeleteServerOrPath() async throws {
        let store = try removalFixture(), original = store.topology
        do {
            try await store.revokeServer(original.nodes[0].id.uuidString, disconnect: true) { _ in throw WorkspaceError.missingKey }
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(store.topology, original)
        XCTAssertFalse(store.serverOperationInProgress)
    }
    func testPartialFailureRetainsCompletedAccountAndRetrySkipsIt() async throws {
        let store = try removalFixture()
        var next = store.document
        let node = next.topology.nodes[0].id
        let account = SSHAccount(id: UUID(), nodeID: node, username: "other")
        next.topology.sshAccounts.append(account)
        next.topology.authorizations.append(.init(accountID: account.id, keyID: "key", fingerprint: next.topology.sshKeys[0].fingerprint, remoteComment: "", remoteState: .authorized))
        try store.commit(next)
        var calls = 0
        do {
            try await store.revokeServer(node.uuidString, disconnect: true) { _ in
                calls += 1
                if calls == 2 { throw WorkspaceError.missingKey }
            }
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(store.topology.activeNodes.count, 1)
        XCTAssertEqual(store.serverAuthorizations(node.uuidString).filter { $0.remoteState == .revoked }.count, 1)
        calls = 0
        try await store.revokeServer(node.uuidString, disconnect: true) { _ in calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.topology.activeNodes.isEmpty)
    }
}


extension WorkspaceAuthorityTests {
    func testDisconnectWorkspaceDeviceRemovesServerRoleButPreservesDeviceAndKeys() async throws {
        for current in [true, false] {
            let store = try removalFixture()
            var next = store.document
            let nodeID = next.topology.nodes[0].id
            next.topology.nodes[0].roles.append(.clientDevice)
            if current { next.topology.profiles[0].nodeID = nodeID }
            else { next.topology.profiles.append(.init(id: "other-device", nodeID: nodeID, name: "Other Mac")) }
            try store.commit(next)
            let original = store.topology
            var called = false
            try await store.revokeServer(nodeID.uuidString, disconnect: true) { _ in called = true }
            XCTAssertTrue(called)
            XCTAssertEqual(store.topology.profiles, original.profiles)
            XCTAssertEqual(store.topology.sshKeys, original.sshKeys)
            let node = try XCTUnwrap(store.topology.activeNodes.first { $0.id == nodeID })
            XCTAssertTrue(node.roles.contains(.clientDevice))
            XCTAssertFalse(node.roles.contains(.sshHost))
            XCTAssertTrue(store.workspace.graph.servers.isEmpty)
            XCTAssertTrue(store.topology.activeAccounts.isEmpty)
            let merged = TopologyCloudMetadataSnapshotPolicy.merge(local: store.topology, remote: original)
            XCTAssertFalse(try XCTUnwrap(merged.activeNodes.first { $0.id == nodeID }).roles.contains(.sshHost))
            let inverse = TopologyCloudMetadataSnapshotPolicy.merge(local: original, remote: store.topology)
            XCTAssertFalse(try XCTUnwrap(inverse.activeNodes.first { $0.id == nodeID }).roles.contains(.sshHost))
            // A later metadata edit on an older peer must not revive the server role.
            var stale = original
            stale.nodes[0].updatedAt = Date().addingTimeInterval(60)
            let newerStale = TopologyCloudMetadataSnapshotPolicy.merge(local: store.topology, remote: stale)
            XCTAssertFalse(newerStale.nodes[0].roles.contains(.sshHost))
            let removed = store.topology
            var draft = AccessFormDraft()
            draft.alias = "rejoined"; draft.account = "admin"; draft.address = "existing.example"
            _ = try store.save(draft: draft, serverID: nodeID.uuidString, key: store.state.keys[0])
            XCTAssertEqual(store.workspace.graph.servers.count, 1)
            let rejoined = TopologyCloudMetadataSnapshotPolicy.merge(local: store.topology, remote: removed)
            XCTAssertTrue(try XCTUnwrap(rejoined.activeNodes.first { $0.id == nodeID }).roles.contains(.sshHost))
            let roundtrip = try WorkspaceStore.decoder().decode(TopologySnapshot.self, from: WorkspaceStore.encoder().encode(removed))
            XCTAssertEqual(roundtrip.nodes[0].removedRoles, [.sshHost])
        }
    }
}
