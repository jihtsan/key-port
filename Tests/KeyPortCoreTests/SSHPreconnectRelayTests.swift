import Foundation
import XCTest
@testable import KeyPortCore

final class SSHPreconnectRelayTests: XCTestCase {
    private let nodeID = UUID(uuidString: "52000000-0000-4000-8000-000000000001")!
    private let accountID = UUID(uuidString: "52000000-0000-4000-8000-000000000002")!
    private let profileID = UUID(uuidString: "52000000-0000-4000-8000-000000000003")!
    private let firstEndpointID = UUID(uuidString: "52000000-0000-4000-8000-000000000004")!
    private let secondEndpointID = UUID(uuidString: "52000000-0000-4000-8000-000000000005")!

    func testBuilderPreservesExplicitCandidateOrderAndTarget() throws {
        let first = Endpoint(
            id: firstEndpointID,
            nodeID: nodeID,
            address: "192.0.2.10",
            port: 2222,
            protocol: .ssh,
            networkScope: .publicNetwork
        )
        let second = Endpoint(
            id: secondEndpointID,
            nodeID: nodeID,
            address: "2001:db8::10",
            port: 22,
            protocol: .ssh,
            networkScope: .publicNetwork
        )
        let profile = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "fixture",
            routePolicy: .automatic(networkScope: .publicNetwork),
            candidateEndpointIDs: [secondEndpointID, firstEndpointID]
        )
        let topology = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "Fixture", roles: [.sshHost])],
            endpoints: [first, second],
            sshAccounts: [SSHAccount(id: accountID, nodeID: nodeID, username: "deploy")],
            sshConnectionProfiles: [profile]
        )
        let server = ServerConnection(
            id: profileID,
            name: "Fixture",
            host: second.address,
            port: Int(second.port),
            username: "deploy",
            alias: "fixture"
        )

        let configuration = try XCTUnwrap(
            SSHPreconnectRelayConfigurationBuilder.make(
                profile: profile,
                nodeID: nodeID,
                server: server,
                topology: topology,
                operationID: UUID(uuidString: "52000000-0000-4000-8000-000000000006")!
            )
        )

        XCTAssertEqual(configuration.candidates.map(\.endpointID), [secondEndpointID, firstEndpointID])
        XCTAssertEqual(configuration.target.host, "2001:db8::10")
        XCTAssertEqual(configuration.target.port, 22)
        XCTAssertTrue(configuration.matchesForwardingTarget(host: "[2001:db8::10]", port: 22))
    }

    func testFixedAndLegacyAutomaticProfilesDoNotProduceRelayConfiguration() throws {
        let endpoint = Endpoint(
            id: firstEndpointID,
            nodeID: nodeID,
            address: "fixture.example.com",
            port: 22,
            protocol: .ssh
        )
        let account = SSHAccount(id: accountID, nodeID: nodeID, username: "deploy")
        let server = ServerConnection(
            id: profileID,
            name: "Fixture",
            host: endpoint.address,
            username: account.username,
            alias: "fixture"
        )
        let topology = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "Fixture", roles: [.sshHost])],
            endpoints: [endpoint],
            sshAccounts: [account]
        )

        let fixed = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "fixed",
            routePolicy: .fixed(endpointID: firstEndpointID)
        )
        XCTAssertNil(try SSHPreconnectRelayConfigurationBuilder.make(
            profile: fixed,
            nodeID: nodeID,
            server: server,
            topology: topology
        ))

        let legacyAutomatic = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "automatic",
            routePolicy: .automatic(networkScope: nil)
        )
        XCTAssertNil(try SSHPreconnectRelayConfigurationBuilder.make(
            profile: legacyAutomatic,
            nodeID: nodeID,
            server: server,
            topology: topology
        ))
    }

    func testConfigurationRejectsUnsafeHostAndDuplicateCandidate() throws {
        let candidate = SSHPreconnectRelayCandidate(
            endpointID: firstEndpointID,
            host: "127.0.0.1",
            port: 22
        )
        let unsafe = SSHPreconnectRelayConfiguration(
            operationID: UUID(),
            profileID: profileID,
            target: SSHPreconnectRelayTarget(host: "127.0.0.1;touch", port: 22),
            candidates: [candidate]
        )
        XCTAssertThrowsError(try unsafe.validate()) {
            XCTAssertEqual($0 as? SSHPreconnectRelayConfigurationError, .invalidHost)
        }

        let duplicate = SSHPreconnectRelayConfiguration(
            operationID: UUID(),
            profileID: profileID,
            target: SSHPreconnectRelayTarget(host: "127.0.0.1", port: 22),
            candidates: [candidate, candidate]
        )
        XCTAssertThrowsError(try duplicate.validate()) {
            XCTAssertEqual($0 as? SSHPreconnectRelayConfigurationError, .duplicateCandidate)
        }
    }

    func testManifestRejectsDuplicateProfilesAndKeepsNoCredentialFields() throws {
        let configuration = SSHPreconnectRelayConfiguration(
            operationID: UUID(),
            profileID: profileID,
            target: SSHPreconnectRelayTarget(host: "127.0.0.1", port: 22),
            candidates: [SSHPreconnectRelayCandidate(
                endpointID: firstEndpointID,
                host: "127.0.0.1",
                port: 22
            )]
        )
        let manifest = SSHPreconnectRelayManifest(
            configurations: [configuration, configuration]
        )
        XCTAssertThrowsError(try manifest.validate()) {
            XCTAssertEqual($0 as? SSHPreconnectRelayConfigurationError, .duplicateCandidate)
        }

        let data = try HostV6.CanonicalJSON.encode(
            SSHPreconnectRelayManifest(configurations: [configuration])
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("privateKey"))
        XCTAssertFalse(json.contains("known_hosts"))
    }
}
