import Foundation
import Darwin
import KeyPortCore
@testable import KeyPort
import XCTest

final class SSHConfigServiceTests: XCTestCase {
    func testOrderedRelayWritesOwnerOnlyManifestAndProxyCommand() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-ssh-config-relay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let source = home.appendingPathComponent("bundled-relay")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'KeyPortSSHRelay/1\\n'\n".utf8)
            .write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)

        let nodeID = UUID(uuidString: "53000000-0000-4000-8000-000000000001")!
        let accountID = UUID(uuidString: "53000000-0000-4000-8000-000000000002")!
        let profileID = UUID(uuidString: "53000000-0000-4000-8000-000000000003")!
        let firstEndpointID = UUID(uuidString: "53000000-0000-4000-8000-000000000004")!
        let secondEndpointID = UUID(uuidString: "53000000-0000-4000-8000-000000000005")!
        let first = Endpoint(
            id: firstEndpointID,
            nodeID: nodeID,
            address: "127.0.0.1",
            port: 40101,
            protocol: .ssh,
            networkScope: .lan
        )
        let second = Endpoint(
            id: secondEndpointID,
            nodeID: nodeID,
            address: "127.0.0.1",
            port: 40102,
            protocol: .ssh,
            networkScope: .lan
        )
        let profile = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "relay-fixture",
            routePolicy: .automatic(networkScope: .lan),
            candidateEndpointIDs: [firstEndpointID, secondEndpointID]
        )
        let topology = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "Relay fixture", roles: [.sshHost])],
            endpoints: [first, second],
            sshAccounts: [SSHAccount(id: accountID, nodeID: nodeID, username: "deploy")],
            sshConnectionProfiles: [profile]
        )
        let server = ServerConnection(
            id: profileID,
            name: "Relay fixture",
            host: first.address,
            port: Int(first.port),
            username: "deploy",
            alias: "relay-fixture",
            status: .authorized
        )
        let key = SSHKeyRecord(
            id: "key-fixture",
            deviceID: "device-fixture",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAAFixture key-fixture",
            fingerprint: "SHA256:fixture",
            privateKeyPath: "/tmp/fixture-key",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )
        let authorization = Authorization(
            serverID: profileID,
            keyID: key.id,
            fingerprint: key.fingerprint,
            remoteComment: "fixture",
            status: .authorized
        )
        let service = SSHConfigService(
            paths: paths,
            relayHelperSourcePath: source.path,
            dependencyExecutor: ContentAwareVersionProbeExecutor()
        )

        try await service.write(
            servers: [server],
            keys: [key],
            authorizations: [authorization],
            topology: topology
        )

        let config = try String(contentsOf: paths.managedConfig, encoding: .utf8)
        let manifestData = try Data(contentsOf: paths.sshRelayManifest)
        let manifest = try HostV6.CanonicalJSON.decode(
            SSHPreconnectRelayManifest.self,
            from: manifestData
        )
        XCTAssertTrue(config.contains("ProxyCommand '\(paths.sshRelayHelper.path)'"))
        XCTAssertTrue(config.contains("--profile-id \(profileID.uuidString)"))
        XCTAssertEqual(manifest.configurations.first?.candidates.map(\.endpointID), [firstEndpointID, secondEndpointID])
        let dependencyReport = await service.relayDependencyReport()
        let healthReport = await service.configurationHealth()
        XCTAssertEqual(dependencyReport.status, .ready)
        XCTAssertEqual(healthReport.status, .ready)
        XCTAssertEqual(fileMode(paths.sshRelayManifest), 0o600)
        XCTAssertEqual(fileMode(paths.sshRelayHelper), 0o700)

        try Data("#!/bin/sh\nprintf 'wrong-helper\\n'\n".utf8).write(to: paths.sshRelayHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.sshRelayHelper.path)
        try await service.write(
            servers: [server],
            keys: [key],
            authorizations: [authorization],
            topology: topology
        )
        let repairedDependencyReport = await service.relayDependencyReport()
        XCTAssertEqual(repairedDependencyReport.status, .ready)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.sshRelayManifest.path)
        let insecureManifestHealth = await service.configurationHealth()
        XCTAssertEqual(insecureManifestHealth.status, .relayManifestInvalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.sshRelayManifest.path)
        try FileManager.default.removeItem(at: paths.sshRelayManifest)
        let missingManifestHealth = await service.configurationHealth()
        XCTAssertEqual(missingManifestHealth.status, .relayManifestInvalid)
    }

    func testMissingRelayDependencyFailsClosedBeforeReplacingManagedConfig() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-ssh-config-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        let original = "Host preserved\n    HostName preserved.example\n"
        try Data(original.utf8).write(to: paths.managedConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.managedConfig.path)

        let profileID = UUID(uuidString: "53100000-0000-4000-8000-000000000001")!
        let accountID = UUID(uuidString: "53100000-0000-4000-8000-000000000002")!
        let nodeID = UUID(uuidString: "53100000-0000-4000-8000-000000000003")!
        let endpointID = UUID(uuidString: "53100000-0000-4000-8000-000000000004")!
        let topology = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "Missing", roles: [.sshHost])],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: nodeID,
                address: "127.0.0.1",
                port: 40103,
                protocol: .ssh
            )],
            sshAccounts: [SSHAccount(id: accountID, nodeID: nodeID, username: "deploy")],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: profileID,
                accountID: accountID,
                sshAlias: "missing-relay",
                routePolicy: .automatic(networkScope: nil),
                candidateEndpointIDs: [endpointID]
            )]
        )
        let server = ServerConnection(
            id: profileID,
            name: "Missing",
            host: "127.0.0.1",
            port: 40103,
            username: "deploy",
            alias: "missing-relay",
            status: .authorized
        )
        let key = SSHKeyRecord(
            id: "key-missing",
            deviceID: "device",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAAFixture key-missing",
            fingerprint: "SHA256:missing",
            privateKeyPath: "/tmp/key",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )
        let authorization = Authorization(
            serverID: profileID,
            keyID: key.id,
            fingerprint: key.fingerprint,
            remoteComment: "fixture",
            status: .authorized
        )
        let service = SSHConfigService(paths: paths)

        do {
            try await service.write(
                servers: [server],
                keys: [key],
                authorizations: [authorization],
                topology: topology
            )
            XCTFail("Missing relay dependency unexpectedly replaced the managed config")
        } catch SSHConfigError.relayDependencyUnavailable {
            // Expected: a new relay route must not replace the previous config.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try String(contentsOf: paths.managedConfig, encoding: .utf8), original)
        let dependencyReport = await service.relayDependencyReport()
        XCTAssertEqual(dependencyReport.status, .missing)
    }

    func testRepairableRelayDependencyIsInstalledOwnerOnly() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-ssh-config-repair-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let source = home.appendingPathComponent("bundled-relay")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'KeyPortSSHRelay/1\\n'\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)

        let service = SSHConfigService(
            paths: paths,
            relayHelperSourcePath: source.path,
            dependencyExecutor: VersionProbeExecutor()
        )

        let before = await service.relayDependencyReport()
        XCTAssertEqual(before.status, .repairable)

        try await service.repairRelayDependency()

        let after = await service.relayDependencyReport()
        XCTAssertEqual(after.status, .ready)
        XCTAssertEqual(fileMode(paths.sshRelayHelper), 0o700)
    }

    private func fileMode(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o777)
    }
}

private struct VersionProbeExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        ProcessExecutionResult(
            ending: .exited(0),
            stdout: Data("KeyPortSSHRelay/1\n".utf8),
            stderr: Data(),
            duration: 0.001
        )
    }
}

private struct ContentAwareVersionProbeExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        let contents = try? String(contentsOf: URL(fileURLWithPath: request.executable), encoding: .utf8)
        let version = contents?.contains("wrong-helper") == true
            ? "not-a-keyport-helper\n"
            : "KeyPortSSHRelay/1\n"
        return ProcessExecutionResult(
            ending: .exited(0),
            stdout: Data(version.utf8),
            stderr: Data(),
            duration: 0.001
        )
    }
}
