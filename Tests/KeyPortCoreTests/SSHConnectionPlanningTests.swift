import XCTest
@testable import KeyPortCore

final class SSHConnectionPlanningTests: XCTestCase {
    private let nodeID = UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
    private let accountID = UUID(uuidString: "51000000-0000-4000-8000-000000000002")!
    private let lanEndpointID = UUID(uuidString: "51000000-0000-4000-8000-000000000003")!
    private let tailnetEndpointID = UUID(uuidString: "51000000-0000-4000-8000-000000000004")!
    private let profileID = UUID(uuidString: "51000000-0000-4000-8000-000000000005")!

    func testParserAcceptsSafeSSHSubset() throws {
        let intent = try SSHConnectionIntentParser.parse("ssh -p 2222 -l deploy server.example.com")

        XCTAssertEqual(intent.username, "deploy")
        XCTAssertEqual(intent.target, "server.example.com")
        XCTAssertEqual(intent.port, 2222)
    }

    func testParserRejectsShellSyntaxAndUnsupportedOptions() {
        XCTAssertThrowsError(try SSHConnectionIntentParser.parse("ssh root@host; touch /tmp/x")) {
            XCTAssertEqual($0 as? SSHConnectionIntentError, .unsafeSyntax)
        }
        XCTAssertThrowsError(try SSHConnectionIntentParser.parse("ssh -J jump root@host")) {
            XCTAssertEqual($0 as? SSHConnectionIntentError, .unsupportedOption("-J"))
        }
    }

    func testFixedProfileResolvesAliasToAccountAndEndpoint() throws {
        var topology = makeTopology(routePolicy: .fixed(endpointID: tailnetEndpointID))
        topology.sshConnectionProfiles[0].transportPreference = .tailscaleCLI

        let plan = try SSHConnectionPlanner().plan(
            for: SSHConnectionIntent(target: "studio-tailnet-root"),
            in: topology,
            currentDeviceID: "device-current",
            networkEpoch: 7
        )

        XCTAssertEqual(plan.profileID, profileID)
        XCTAssertEqual(plan.accountID, accountID)
        XCTAssertEqual(plan.endpointID, tailnetEndpointID)
        XCTAssertEqual(plan.transport, .tailscaleCLI)
        XCTAssertEqual(plan.reason, .explicitEndpoint)
    }

    func testAutomaticTailnetProfileUsesTailscaleCLITransport() throws {
        let plan = try SSHConnectionPlanner().plan(
            for: SSHConnectionIntent(profileID: profileID),
            in: makeTopology(routePolicy: .fixed(endpointID: tailnetEndpointID)),
            currentDeviceID: "device-current",
            networkEpoch: 0
        )

        XCTAssertEqual(plan.transport, .tailscaleCLI)
    }

    func testManagedConfigIncludesProxyCommandForTailscaleTransport() {
        let server = ServerConnection(
            id: profileID,
            name: "Studio",
            host: "100.117.174.75",
            username: "root",
            alias: "studio-tailnet-root"
        )

        let config = SSHConfigGenerator.managedConfig(entries: [SSHConfigEntry(
            server: server,
            identityPath: "~/.ssh/id_ed25519",
            proxyCommand: "/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p"
        )])

        XCTAssertTrue(config.contains(
            "ProxyCommand /Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p"
        ))
    }

    func testAutomaticProfilePrefersReachabilityEvidenceFromCurrentNetworkEpoch() throws {
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.reachabilityObservations = [ReachabilityObservation(
            endpointID: tailnetEndpointID,
            observerDeviceID: "device-current",
            networkEpoch: 9,
            observedAt: .now,
            wasReachable: true
        )]

        let plans = try SSHConnectionPlanner().plans(
            for: SSHConnectionIntent(profileID: profileID),
            in: topology,
            currentDeviceID: "device-current",
            networkEpoch: 9
        )

        XCTAssertEqual(plans.map(\.endpointID), [tailnetEndpointID, lanEndpointID])
        XCTAssertEqual(plans.first?.reason, .currentNetworkSuccess)
    }

    func testAutomaticProfileUsesExplicitCandidateOrderWithoutReorderingByEvidence() throws {
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [tailnetEndpointID, lanEndpointID]
        topology.reachabilityObservations = [ReachabilityObservation(
            endpointID: lanEndpointID,
            observerDeviceID: "device-current",
            networkEpoch: 9,
            observedAt: .now,
            wasReachable: true
        )]

        let plans = try SSHConnectionPlanner().plans(
            for: SSHConnectionIntent(profileID: profileID),
            in: topology,
            currentDeviceID: "device-current",
            networkEpoch: 9
        )

        XCTAssertEqual(plans.map(\.endpointID), [tailnetEndpointID, lanEndpointID])
        XCTAssertTrue(plans.allSatisfy { $0.reason == .profileCandidateOrder })
    }

    func testAutomaticProfileRejectsDeadCandidateReference() {
        let missingEndpointID = UUID(uuidString: "51000000-0000-4000-8000-000000000099")!
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [missingEndpointID]

        XCTAssertThrowsError(
            try SSHConnectionPlanner().plan(
                for: SSHConnectionIntent(profileID: profileID),
                in: topology,
                currentDeviceID: "device-current",
                networkEpoch: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? SSHConnectionPlanningError,
                .routeCandidateNotFound(missingEndpointID)
            )
        }
    }

    func testAutomaticProfileRejectsCandidateOutsideNode() {
        let otherNodeID = UUID(uuidString: "51000000-0000-4000-8000-000000000010")!
        let otherEndpointID = UUID(uuidString: "51000000-0000-4000-8000-000000000011")!
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.nodes.append(Node(id: otherNodeID, name: "Other", roles: [.sshHost]))
        topology.endpoints.append(Endpoint(
            id: otherEndpointID,
            nodeID: otherNodeID,
            address: "10.0.0.20",
            port: 22,
            protocol: .ssh,
            networkScope: .lan
        ))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [otherEndpointID]

        XCTAssertThrowsError(
            try SSHConnectionPlanner().plan(
                for: SSHConnectionIntent(profileID: profileID),
                in: topology,
                currentDeviceID: "device-current",
                networkEpoch: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? SSHConnectionPlanningError,
                .routeCandidateOutsideNode(otherEndpointID)
            )
        }
    }

    func testAutomaticProfileRejectsNonSSHCandidate() {
        let httpEndpointID = UUID(uuidString: "51000000-0000-4000-8000-000000000012")!
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.endpoints.append(Endpoint(
            id: httpEndpointID,
            nodeID: nodeID,
            address: "192.168.1.10",
            port: 80,
            protocol: .http,
            networkScope: .lan
        ))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [httpEndpointID]

        XCTAssertThrowsError(
            try SSHConnectionPlanner().plan(
                for: SSHConnectionIntent(profileID: profileID),
                in: topology,
                currentDeviceID: "device-current",
                networkEpoch: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? SSHConnectionPlanningError,
                .routeCandidateNotSSH(httpEndpointID)
            )
        }
    }

    func testAutomaticProfileRejectsCandidateWithConflictingNetworkScope() {
        var topology = makeTopology(routePolicy: .automatic(networkScope: .tailnet))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [lanEndpointID]

        XCTAssertThrowsError(
            try SSHConnectionPlanner().plan(
                for: SSHConnectionIntent(profileID: profileID),
                in: topology,
                currentDeviceID: "device-current",
                networkEpoch: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? SSHConnectionPlanningError,
                .routeCandidateScopeMismatch(lanEndpointID)
            )
        }
    }

    func testConnectionProfileDecodesPreCandidatePayloadWithLegacyDefaults() throws {
        let profile = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "studio-tailnet-root",
            routePolicy: .automatic(networkScope: nil)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(profile)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "candidateEndpointIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SSHConnectionProfile.self, from: legacyData)

        XCTAssertEqual(decoded.candidateEndpointIDs, [])
        XCTAssertEqual(decoded.routePolicy, profile.routePolicy)
    }

    func testRefreshAndLegacyProjectionPreserveOrderedCandidates() throws {
        var existing = makeTopology(routePolicy: .automatic(networkScope: nil))
        existing.sshConnectionProfiles[0].candidateEndpointIDs = [tailnetEndpointID, lanEndpointID]
        let legacy = TopologySnapshotMigration.legacyProjection(
            from: existing,
            currentDeviceID: "device-current"
        )

        let refreshed = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: "device-current",
            currentDeviceName: "Current Mac"
        )

        XCTAssertEqual(
            refreshed.connectionProfile(id: profileID)?.candidateEndpointIDs,
            [tailnetEndpointID, lanEndpointID]
        )
        XCTAssertEqual(legacy.servers.first?.host, "100.117.174.75")
    }

    func testRawSSHCommandMatchesNodeAccountAndEndpoint() throws {
        let plan = try SSHConnectionPlanner().plan(
            for: SSHConnectionIntentParser.parse("ssh root@100.117.174.75"),
            in: makeTopology(routePolicy: .automatic(networkScope: nil)),
            currentDeviceID: "device-current",
            networkEpoch: 0
        )

        XCTAssertEqual(plan.accountID, accountID)
        XCTAssertEqual(plan.endpointID, tailnetEndpointID)
        XCTAssertEqual(plan.reason, .exactAddress)
    }

    func testRawSSHCommandWithoutPortUsesSSHDefaultPort() throws {
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.endpoints.append(Endpoint(
            id: UUID(uuidString: "51000000-0000-4000-8000-000000000006")!,
            nodeID: nodeID,
            address: "100.117.174.75",
            port: 2222,
            protocol: .ssh,
            networkScope: .tailnet,
            priority: -1
        ))

        let plan = try SSHConnectionPlanner().plan(
            for: SSHConnectionIntentParser.parse("ssh root@100.117.174.75"),
            in: topology,
            currentDeviceID: "device-current",
            networkEpoch: 0
        )

        XCTAssertEqual(plan.endpointID, tailnetEndpointID)
        XCTAssertEqual(plan.port, 22)
    }

    func testVersionTwoSnapshotMigratesAliasesIntoProfilesAndCoalescesAuthorization() throws {
        let firstProfileID = UUID(uuidString: "52000000-0000-4000-8000-000000000001")!
        let secondProfileID = UUID(uuidString: "52000000-0000-4000-8000-000000000002")!
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let endpoint = Endpoint(
            id: lanEndpointID,
            nodeID: nodeID,
            address: "192.168.1.10",
            port: 22,
            protocol: .ssh
        )
        let payload = LegacyTopologyV2(
            nodes: [Node(id: nodeID, name: "Studio", roles: [.sshHost])],
            endpoints: [endpoint],
            sshAccounts: [
                LegacySSHAccount(
                    id: firstProfileID,
                    nodeID: nodeID,
                    endpointID: endpoint.id,
                    username: "root",
                    alias: "studio-lan-root",
                    createdAt: now,
                    updatedAt: now
                ),
                LegacySSHAccount(
                    id: secondProfileID,
                    nodeID: nodeID,
                    endpointID: endpoint.id,
                    username: "root",
                    alias: "studio-office-root",
                    createdAt: now,
                    updatedAt: now
                ),
            ],
            authorizations: [
                SSHAuthorization(
                    accountID: firstProfileID,
                    keyID: "key-current",
                    fingerprint: "SHA256:key",
                    remoteComment: "current",
                    remoteState: .authorized
                ),
                SSHAuthorization(
                    accountID: secondProfileID,
                    keyID: "key-current",
                    fingerprint: "SHA256:key",
                    remoteComment: "current",
                    remoteState: .authorized
                ),
            ],
            accessVerifications: [
                AccessVerification(
                    accountID: firstProfileID,
                    deviceID: "device-current",
                    status: .authorized,
                    lastCheckedAt: now
                ),
                AccessVerification(
                    accountID: secondProfileID,
                    deviceID: "device-current",
                    status: .unreachable,
                    lastCheckedAt: now.addingTimeInterval(1)
                ),
            ]
        )

        let decoded = try JSONDecoder().decode(
            TopologySnapshot.self,
            from: JSONEncoder().encode(payload)
        )
        let canonicalAccountID = TopologyStableID.sshAccount(nodeID: nodeID, username: "root")

        XCTAssertEqual(decoded.schemaVersion, TopologySnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.activeAccounts.map(\.id), [canonicalAccountID])
        XCTAssertEqual(Set(decoded.activeConnectionProfiles.map(\.id)), [firstProfileID, secondProfileID])
        XCTAssertTrue(decoded.activeConnectionProfiles.allSatisfy { $0.accountID == canonicalAccountID })
        XCTAssertEqual(decoded.authorizations.count, 1)
        XCTAssertEqual(decoded.authorizations.first?.accountID, canonicalAccountID)
        XCTAssertEqual(decoded.accessVerifications.count, 2)
        XCTAssertEqual(
            Set(decoded.accessVerifications.compactMap(\.profileID)),
            [firstProfileID, secondProfileID]
        )
        XCTAssertTrue(decoded.accessVerifications.allSatisfy { $0.accountID == canonicalAccountID })

        let projected = TopologySnapshotMigration.legacyProjection(
            from: decoded,
            currentDeviceID: "device-current"
        )
        XCTAssertEqual(Set(projected.servers.map(\.alias)), ["studio-lan-root", "studio-office-root"])
        XCTAssertEqual(Set(projected.authorizations.map(\.serverID)), [firstProfileID, secondProfileID])
    }

    func testCloudPolicyKeepsAndMergesConnectionProfiles() {
        let old = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "old-alias",
            routePolicy: .fixed(endpointID: lanEndpointID),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10),
            version: 1
        )
        let new = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "new-alias",
            routePolicy: .fixed(endpointID: tailnetEndpointID),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            version: 2
        )

        let sanitized = TopologyCloudMetadataSnapshotPolicy.sanitized(
            TopologySnapshot(sshConnectionProfiles: [old])
        )
        let merged = TopologyCloudMetadataSnapshotPolicy.merge(
            local: sanitized,
            remote: TopologySnapshot(sshConnectionProfiles: [new])
        )

        XCTAssertEqual(sanitized.sshConnectionProfiles, [old])
        XCTAssertEqual(merged.sshConnectionProfiles, [new])
    }

    func testCloudPolicyPreservesOrderedCandidates() {
        let profile = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "ordered",
            routePolicy: .automatic(networkScope: nil),
            candidateEndpointIDs: [tailnetEndpointID, lanEndpointID],
            updatedAt: Date(timeIntervalSinceReferenceDate: 10),
            version: 1
        )
        let remoteProfile = SSHConnectionProfile(
            id: profileID,
            accountID: accountID,
            sshAlias: "ordered",
            routePolicy: .automatic(networkScope: nil),
            candidateEndpointIDs: [lanEndpointID, tailnetEndpointID],
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            version: 2
        )

        let sanitized = TopologyCloudMetadataSnapshotPolicy.sanitized(
            TopologySnapshot(sshConnectionProfiles: [profile])
        )
        let merged = TopologyCloudMetadataSnapshotPolicy.merge(
            local: sanitized,
            remote: TopologySnapshot(sshConnectionProfiles: [remoteProfile])
        )

        XCTAssertEqual(
            sanitized.sshConnectionProfiles.first?.candidateEndpointIDs,
            [tailnetEndpointID, lanEndpointID]
        )
        XCTAssertEqual(
            merged.sshConnectionProfiles.first?.candidateEndpointIDs,
            [lanEndpointID, tailnetEndpointID]
        )
    }

    func testEncryptedTopologyArchivePreservesRoutePolicyAndStripsLocalKeyPath() throws {
        var topology = makeTopology(routePolicy: .automatic(networkScope: nil))
        topology.sshConnectionProfiles[0].candidateEndpointIDs = [tailnetEndpointID, lanEndpointID]
        topology.sshKeys = [SSHKey(
            id: "key-current",
            deviceID: "device-current",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA",
            fingerprint: "SHA256:test",
            privateKeyPath: "/private/key",
            isInAgent: true,
            origin: .generated,
            isLocallyAvailable: true
        )]

        let archive = try MetadataArchiveCodec.seal(
            AppSnapshot(),
            topology: topology,
            password: "test-password",
            iterations: 1_000
        )
        let payload = try MetadataArchiveCodec.openPayload(archive, password: "test-password")
        let archivedProfile = try XCTUnwrap(payload.topology?.connectionProfile(id: profileID))
        let archivedKey = try XCTUnwrap(payload.topology?.sshKeys.first)

        XCTAssertEqual(
            archivedProfile.candidateEndpointIDs,
            [tailnetEndpointID, lanEndpointID]
        )
        XCTAssertNil(archivedKey.privateKeyPath)
        XCTAssertFalse(archivedKey.isInAgent)
        XCTAssertFalse(archivedKey.isLocallyAvailable)
    }

    private func makeTopology(routePolicy: SSHRoutePolicy) -> TopologySnapshot {
        TopologySnapshot(
            nodes: [Node(id: nodeID, name: "Studio", roles: [.sshHost])],
            endpoints: [
                Endpoint(
                    id: lanEndpointID,
                    nodeID: nodeID,
                    address: "192.168.1.10",
                    port: 22,
                    protocol: .ssh,
                    networkScope: .lan,
                    priority: 0
                ),
                Endpoint(
                    id: tailnetEndpointID,
                    nodeID: nodeID,
                    address: "100.117.174.75",
                    port: 22,
                    protocol: .ssh,
                    networkScope: .tailnet,
                    priority: 10
                ),
            ],
            sshAccounts: [SSHAccount(
                id: accountID,
                nodeID: nodeID,
                username: "root"
            )],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: profileID,
                accountID: accountID,
                sshAlias: "studio-tailnet-root",
                routePolicy: routePolicy
            )]
        )
    }
}

private struct LegacyTopologyV2: Encodable {
    let schemaVersion = 2
    let nodes: [Node]
    let endpoints: [Endpoint]
    let sshAccounts: [LegacySSHAccount]
    let authorizations: [SSHAuthorization]
    let accessVerifications: [AccessVerification]
}

private struct LegacySSHAccount: Encodable {
    let id: UUID
    let nodeID: UUID
    let endpointID: UUID
    let username: String
    let alias: String
    let createdAt: Date
    let updatedAt: Date
    var isDeleted = false
    var version = 1
}
