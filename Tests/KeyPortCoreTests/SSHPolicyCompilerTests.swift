import XCTest
@testable import KeyPortCore

final class SSHPolicyCompilerTests: XCTestCase {
    func testOnlyCurrentTrustedCandidatesCompileAndAddressEditInvalidatesEvidence() throws {
        let node = UUID(), account = UUID(), profileID = UUID(), endpointID = UUID()
        let parsed = PublicKeyParser.parse("ssh-ed25519 AQID fixture")!
        let endpoint = Endpoint(id: endpointID, nodeID: node, address: "192.0.2.1", port: 22, protocol: .ssh)
        let key = SSHKey(id: "key", deviceID: "local", kind: .ed25519, publicKey: "ssh-ed25519 AQID fixture", fingerprint: parsed.fingerprint, privateKeyPath: "/key", origin: .generated, isLocallyAvailable: true)
        let p = SSHConnectionProfile(id: profileID, accountID: account, sshAlias: "fixture", routePolicy: .automatic(networkScope: nil), candidateEndpointIDs: [endpointID], policyVersion: 1, transportPreference: .direct)
        var t = TopologySnapshot(nodes: [.init(id: node, name: "Fixture", roles: [.sshHost])], endpoints: [endpoint], sshAccounts: [.init(id: account, nodeID: node, username: "user")], sshConnectionProfiles: [p], sshKeys: [key])
        t.hostKeyTrusts = [.init(id: UUID(), endpointID: endpointID, algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: "192.0.2.1 ssh-ed25519 AQID")]
        t.authorizations = [.init(accountID: account, keyID: key.id, fingerprint: key.fingerprint, remoteComment: "", remoteState: .authorized)]
        var v = AccessVerification(accountID: account, deviceID: "local", profileID: profileID, endpointID: endpointID, status: .authorized)
        t.accessVerifications = [v]
        XCTAssertThrowsError(try SSHPolicyCompiler.compile(profile: p, topology: t, deviceID: "local", keyID: "key"))
        v.policyEvidenceBinding = SSHPolicyCompiler.evidence(endpoint: endpoint, fingerprint: parsed.fingerprint, keyFingerprint: key.fingerprint, username: "user")
        t.accessVerifications = [v]
        XCTAssertEqual(try SSHPolicyCompiler.compile(profile: p, topology: t, deviceID: "local", keyID: "key").endpoints.map(\.id), [endpointID])
        t.endpoints[0].address = "192.0.2.2"
        XCTAssertThrowsError(try SSHPolicyCompiler.compile(profile: p, topology: t, deviceID: "local", keyID: "key"))
    }
    func testOwnedManifestRejectsSymlinkAndOversizedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = file.appendingPathExtension("link")
        try Data("1234".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try SSHRelayOwnedFile.read(file, limit: 4).count, 4)
        XCTAssertThrowsError(try SSHRelayOwnedFile.read(file, limit: 3))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SSHRelayOwnedFile.read(link, limit: 4))
    }
}
