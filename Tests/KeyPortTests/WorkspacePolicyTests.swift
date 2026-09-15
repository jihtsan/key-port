import Foundation
import XCTest
import KeyPortCore
import KeyPortInterface
@testable import KeyPort

@MainActor final class WorkspacePolicyTests: XCTestCase {
    private func fixture() throws -> (WorkspaceStore, String, SSHKeyRecord) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("policy space \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("KeyPortSSHRelay")
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
