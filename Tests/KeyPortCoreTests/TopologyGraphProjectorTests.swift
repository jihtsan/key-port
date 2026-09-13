import Foundation
import XCTest
@testable import KeyPortCore

final class TopologyGraphProjectorTests: XCTestCase {
    private let currentDeviceID = "device-current"
    private let otherDeviceID = "device-other"
    private let hostAID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let hostBID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let addressAID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let addressBID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let identityAID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let identityBID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    private let pinAID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    private let pinBID = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
    private let lineAID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    private let lineBID = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
    private let serviceAID = UUID(uuidString: "60000000-0000-4000-8000-000000000001")!

    func testCurrentDeviceProjectionShowsPersistedAndCandidateAccessSeparately() {
        let query = TopologyGraphQuery(viewMode: .currentDevice)
        let snapshot = TopologyGraphProjector().project(
            envelope: makeEnvelope(),
            currentDeviceID: currentDeviceID,
            query: query
        )

        XCTAssertEqual(
            Set(snapshot.nodes.map(\.kind)),
            Set([.device, .host, .service])
        )
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .device }.map(\.id), [.device(currentDeviceID)])
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .deviceAccess }.count, 1)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .candidateAccess }.count, 1)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .hostService }.count, 1)

        guard let candidate = snapshot.edges.first(where: { $0.isCandidate }) else {
            XCTFail("expected a candidate access edge")
            return
        }
        XCTAssertEqual(candidate.label, "待授权")
        XCTAssertTrue(candidate.status.reasons.contains(.candidateAccess))
    }

    func testExpandedAllDeviceProjectionIncludesAccountsAndActualNodes() {
        let query = TopologyGraphQuery(
            viewMode: .allDevices,
            includesSupportingNodes: true,
            includesActualNodes: true
        )
        let snapshot = TopologyGraphProjector().project(
            envelope: makeEnvelope(),
            currentDeviceID: currentDeviceID,
            query: query
        )

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .device }.count, 2)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .sshAccount }.count, 2)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .actualNode }.count, 1)
        XCTAssertTrue(snapshot.edges.contains { $0.kind == .sshAccountActualNode })

        guard let otherDeviceEdge = snapshot.edges.first(where: {
            $0.kind == .deviceAccess && $0.from == .device(otherDeviceID)
        }) else {
            XCTFail("expected an access edge from the other device")
            return
        }
        XCTAssertEqual(otherDeviceEdge.status.localKey, .unknown)
        XCTAssertEqual(otherDeviceEdge.status.verification, .unknown)
    }

    func testHostKeyAndMergeReviewRemainBlockingStatusFacets() {
        var envelope = makeEnvelope()
        envelope.synced.hostKeyPins[0].state = .replaced
        envelope.synced.mergeReviews = [HostV6.MergeReview(
            id: UUID(uuidString: "70000000-0000-4000-8000-000000000001")!,
            entityType: .host,
            entityID: hostAID.uuidString.lowercased(),
            candidates: [
                HostV6.MergeCandidate(
                    mutationID: UUID(uuidString: "80000000-0000-4000-8000-000000000001")!,
                    vector: ["device/A": 1],
                    isDeleted: false
                ),
                HostV6.MergeCandidate(
                    mutationID: UUID(uuidString: "80000000-0000-4000-8000-000000000002")!,
                    vector: ["device/B": 1],
                    isDeleted: false
                ),
            ],
            isBlocking: true,
            stamp: stamp(20)
        )]

        let snapshot = TopologyGraphProjector().project(
            envelope: envelope,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery(viewMode: .allDevices)
        )
        guard let host = snapshot.nodes.first(where: { $0.id == .host(hostAID) }) else {
            XCTFail("expected host A")
            return
        }
        XCTAssertEqual(host.status.hostTrust, .mismatch)
        XCTAssertEqual(host.status.level, .blocked)
        XCTAssertTrue(host.status.reasons.contains(.mergeReview))
    }

    func testProjectionDoesNotEncodePrivateKeyPathsOrPublicKeyMaterial() throws {
        let query = TopologyGraphQuery(
            viewMode: .allDevices,
            includesSupportingNodes: true,
            includesActualNodes: true
        )
        let snapshot = TopologyGraphProjector().project(
            envelope: makeEnvelope(),
            currentDeviceID: currentDeviceID,
            query: query
        )
        let data = try JSONEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(encoded.contains("/Users/private-key"))
        XCTAssertFalse(encoded.contains("PRIVATE KEY"))
        XCTAssertFalse(encoded.contains("ssh-ed25519 AAAA"))
    }

    func testUnifiedProjectionUsesConnectionProfilesAsDirectedPathEdges() {
        let currentDeviceID = "device-unified-current"
        let currentNodeID = UUID(uuidString: "a0000000-0000-4000-8000-000000000001")!
        let targetNodeID = UUID(uuidString: "a0000000-0000-4000-8000-000000000002")!
        let orphanNodeID = UUID(uuidString: "a0000000-0000-4000-8000-000000000003")!
        let endpointID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
        let firstAccountID = UUID(uuidString: "a2000000-0000-4000-8000-000000000001")!
        let secondAccountID = UUID(uuidString: "a2000000-0000-4000-8000-000000000002")!
        let firstProfileID = UUID(uuidString: "a3000000-0000-4000-8000-000000000001")!
        let secondProfileID = UUID(uuidString: "a3000000-0000-4000-8000-000000000002")!

        var topology = TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "当前 Mac", roles: [.clientDevice]),
                Node(id: targetNodeID, name: "生产服务器", roles: [.sshHost]),
                Node(id: orphanNodeID, name: "未配置服务器", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "当前 Mac",
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: targetNodeID,
                address: "server.example.com",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork
            )],
            sshAccounts: [
                SSHAccount(id: firstAccountID, nodeID: targetNodeID, username: "root"),
                SSHAccount(id: secondAccountID, nodeID: targetNodeID, username: "deploy"),
            ],
            sshConnectionProfiles: [
                SSHConnectionProfile(
                    id: firstProfileID,
                    accountID: firstAccountID,
                    sshAlias: "prod-root",
                    routePolicy: .fixed(endpointID: endpointID)
                ),
                SSHConnectionProfile(
                    id: secondProfileID,
                    accountID: secondAccountID,
                    sshAlias: "prod-deploy",
                    routePolicy: .fixed(endpointID: endpointID)
                ),
            ]
        )

        let projector = TopologyGraphProjector()
        let currentGraph = projector.project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery(viewMode: .currentDevice)
        )

        XCTAssertEqual(currentGraph.edges.filter { $0.kind == .candidateAccess }.count, 2)
        XCTAssertTrue(currentGraph.edges.filter { $0.kind == .candidateAccess }.allSatisfy {
            $0.from == .node(currentNodeID)
                && $0.to == .node(targetNodeID)
                && $0.endpointID == endpointID
                && $0.detectedAt == nil
                && $0.status.reasons.contains(.candidateAccess)
        })
        XCTAssertTrue(currentGraph.edges.filter { $0.kind == .candidateAccess }.allSatisfy {
            $0.supportingReferences.contains(.device(currentDeviceID))
                && (
                    $0.supportingReferences.contains(.sshIdentity(firstAccountID))
                        || $0.supportingReferences.contains(.sshIdentity(secondAccountID))
                )
        })
        XCTAssertEqual(
            Set(currentGraph.edges.compactMap(\.connectionProfileID)),
            Set([firstProfileID, secondProfileID])
        )
        XCTAssertEqual(
            Set(currentGraph.edges.filter { $0.kind == .candidateAccess }.map(\.label)),
            Set(["prod-root", "prod-deploy"])
        )
        XCTAssertFalse(currentGraph.edges.contains {
            $0.from == .node(currentNodeID) && $0.to == .node(orphanNodeID)
        })

        let allDevicesGraph = projector.project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery(
                viewMode: .allDevices,
                includesSupportingNodes: true
            )
        )

        XCTAssertEqual(allDevicesGraph.nodes.filter { $0.kind == .sshAccount }.count, 2)
        XCTAssertFalse(allDevicesGraph.nodes.contains { $0.kind == .host })
        XCTAssertEqual(allDevicesGraph.edges.filter { $0.kind == .candidateAccess }.count, 2)

        topology.hostKeyTrusts = [SSHHostKeyTrust(
            id: UUID(uuidString: "a5000000-0000-4000-8000-000000000001")!,
            endpointID: endpointID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:replaced",
            knownHostsLine: "server.example.com ssh-ed25519 replaced",
            state: .replaced,
            replacedAt: Date(timeIntervalSince1970: 1_787_616_100),
            isDeleted: true
        )]
        let replacedGraph = projector.project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery(viewMode: .currentDevice)
        )
        XCTAssertTrue(replacedGraph.nodes.contains {
            $0.id == .node(targetNodeID)
                && $0.status.hostTrust == .mismatch
                && $0.status.reasons.contains(.hostKeyMismatch)
        })
        XCTAssertTrue(replacedGraph.edges.filter { $0.kind == .candidateAccess }.allSatisfy {
            $0.status.hostTrust == .mismatch
                && $0.status.reasons.contains(.hostKeyMismatch)
        })
    }

    func testGraphEdgeDecodesBeforePathMetadataWasAdded() throws {
        let edge = TopologyGraphEdge(
            id: "access:current:profile",
            from: .node(hostAID),
            to: .node(hostBID),
            kind: .nodeAccess,
            label: "prod-root",
            status: TopologyGraphStatus(sync: .clean),
            connectionProfileID: UUID(uuidString: "a4000000-0000-4000-8000-000000000001")!,
            endpointID: addressBID,
            detectedAt: Date(timeIntervalSince1970: 1_787_616_000)
        )
        let encoded = try JSONEncoder().encode(edge)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "connectionProfileID")
        legacyObject.removeValue(forKey: "endpointID")
        legacyObject.removeValue(forKey: "detectedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decodedLegacy = try JSONDecoder().decode(TopologyGraphEdge.self, from: legacyData)
        XCTAssertNil(decodedLegacy.connectionProfileID)
        XCTAssertNil(decodedLegacy.endpointID)
        XCTAssertNil(decodedLegacy.detectedAt)

        let decodedCurrent = try JSONDecoder().decode(TopologyGraphEdge.self, from: encoded)
        XCTAssertEqual(decodedCurrent.connectionProfileID, edge.connectionProfileID)
        XCTAssertEqual(decodedCurrent.endpointID, edge.endpointID)
        XCTAssertEqual(decodedCurrent.detectedAt, edge.detectedAt)
    }

    private func makeEnvelope() -> HostV6.MetadataEnvelope {
        let now = Date(timeIntervalSince1970: 1_787_616_000)
        let hostA = HostV6.Host(
            id: hostAID,
            name: "Database",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: addressAID,
            createdAt: now,
            stamp: stamp(1)
        )
        let hostB = HostV6.Host(
            id: hostBID,
            name: "Web",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: addressBID,
            createdAt: now,
            stamp: stamp(2)
        )
        let addressA = HostV6.AccessAddress(
            id: addressAID,
            hostID: hostAID,
            normalizedHost: "db.example.com",
            sshPort: 22,
            originalLabel: "db.example.com",
            source: .manual,
            sortOrder: 0,
            stamp: stamp(3)
        )
        let addressB = HostV6.AccessAddress(
            id: addressBID,
            hostID: hostBID,
            normalizedHost: "web.example.com",
            sshPort: 22,
            originalLabel: "web.example.com",
            source: .manual,
            sortOrder: 0,
            stamp: stamp(4)
        )
        let identityA = HostV6.SSHIdentity(
            id: identityAID,
            hostID: hostAID,
            username: "deploy",
            alias: "database-deploy",
            preferredAddressID: addressAID,
            createdAt: now,
            stamp: stamp(5)
        )
        let identityB = HostV6.SSHIdentity(
            id: identityBID,
            hostID: hostBID,
            username: "web",
            alias: "web-admin",
            preferredAddressID: addressBID,
            createdAt: now,
            stamp: stamp(6)
        )
        let deviceCurrent = HostV6.Device(
            id: currentDeviceID,
            name: "Current Mac",
            registeredAt: now,
            lastActiveAt: now,
            tailscaleIdentity: nil,
            stamp: stamp(7)
        )
        let deviceOther = HostV6.Device(
            id: otherDeviceID,
            name: "Other Mac",
            registeredAt: now,
            lastActiveAt: now,
            tailscaleIdentity: nil,
            stamp: stamp(8)
        )
        let keyCurrent = HostV6.SSHKeyRecord(
            id: "key-current",
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA current-public-key",
            fingerprint: "SHA256:current",
            origin: .generated,
            stamp: stamp(9)
        )
        let keyOther = HostV6.SSHKeyRecord(
            id: "key-other",
            deviceID: otherDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA other-public-key",
            fingerprint: "SHA256:other",
            origin: .generated,
            stamp: stamp(10)
        )
        let pinA = HostV6.HostKeyPin(
            id: pinAID,
            hostID: hostAID,
            addressID: addressAID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:host-a",
            state: .confirmed,
            firstConfirmedAt: now,
            lastSeenAt: now,
            stamp: stamp(11)
        )
        let pinB = HostV6.HostKeyPin(
            id: pinBID,
            hostID: hostBID,
            addressID: addressBID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:host-b",
            state: .confirmed,
            firstConfirmedAt: now,
            lastSeenAt: now,
            stamp: stamp(12)
        )
        let lineA = HostV6.KnownHostsLine(
            id: lineAID,
            pinID: pinAID,
            rawLine: "db.example.com ssh-ed25519 AAAA host-a",
            source: .operation(UUID(uuidString: "90000000-0000-4000-8000-000000000001")!),
            duplicateOrdinal: 0,
            stamp: stamp(13)
        )
        let lineB = HostV6.KnownHostsLine(
            id: lineBID,
            pinID: pinBID,
            rawLine: "web.example.com ssh-ed25519 AAAA host-b",
            source: .operation(UUID(uuidString: "90000000-0000-4000-8000-000000000002")!),
            duplicateOrdinal: 0,
            stamp: stamp(14)
        )
        let service = HostV6.SavedService(
            id: serviceAID,
            hostID: hostAID,
            name: "Admin",
            serviceProtocol: .https,
            endpoint: HostV6.RemoteServiceEndpoint(bind: .loopbackV4, port: 8443, path: "/admin"),
            isFavorite: true,
            fixedAddressID: addressAID,
            stamp: stamp(15)
        )
        let authorizationA = HostV6.Authorization(
            sshIdentityID: identityAID,
            keyID: keyCurrent.id,
            fingerprint: keyCurrent.fingerprint,
            remoteComment: "keyport:fixture:current",
            remoteState: .authorized,
            relationState: .active,
            authorizedAt: now,
            lastVerifiedAt: now,
            stamp: stamp(16)
        )
        let authorizationB = HostV6.Authorization(
            sshIdentityID: identityBID,
            keyID: keyOther.id,
            fingerprint: keyOther.fingerprint,
            remoteComment: "keyport:fixture:other",
            remoteState: .authorized,
            relationState: .active,
            authorizedAt: now,
            lastVerifiedAt: now,
            stamp: stamp(17)
        )
        let association = HostV6.NodeAssociation(
            id: "web.example.com",
            sshIdentityID: identityBID,
            target: ActualNodeReference(tailnetKey: "tailnet.example", nodeID: "node-web"),
            state: .linked,
            method: .manual,
            autoLinkEnabled: true,
            stamp: stamp(18)
        )
        let graph = HostV6.SyncedGraph(
            hosts: [hostA, hostB],
            addresses: [addressA, addressB],
            identities: [identityA, identityB],
            devices: [deviceCurrent, deviceOther],
            sshKeys: [keyCurrent, keyOther],
            hostKeyPins: [pinA, pinB],
            knownHostsLines: [lineA, lineB],
            services: [service],
            authorizations: [authorizationA, authorizationB],
            nodeAssociations: [association]
        )
        let local = HostV6.LocalState(
            identityStates: [HostV6.LocalSSHIdentityState(
                sshIdentityID: identityAID,
                status: .authorized,
                statusDetail: nil,
                lastCheckedAt: now,
                passwordCheck: nil,
                keyCheck: AuthenticationCheck(state: .succeeded, detail: "fixture", checkedAt: now),
                machineConfigurationRefreshAttemptedAt: nil
            )],
            deviceStates: [HostV6.LocalDeviceState(deviceID: currentDeviceID, isCurrent: true)],
            keyStates: [HostV6.LocalSSHKeyState(
                keyID: keyCurrent.id,
                privateKeyPath: "/Users/private-key",
                isInAgent: true,
                isLocallyAvailable: true
            )],
            reachabilityEvidence: [
                HostV6.ReachabilityEvidence(
                    addressID: addressAID,
                    networkEpoch: 1,
                    observedAt: now,
                    wasReachable: true
                ),
                HostV6.ReachabilityEvidence(
                    addressID: addressBID,
                    networkEpoch: 1,
                    observedAt: now,
                    wasReachable: false
                ),
            ]
        )
        return HostV6.MetadataEnvelope(
            synced: graph,
            local: local,
            migrationProvenance: HostV6.MigrationProvenance(
                legacySources: [],
                authorityManifest: HostV6.AuthorityManifest(
                    mode: .v6Canary,
                    v1Hash: "v1",
                    v6Hash: "v6",
                    compatibilityHash: "compat",
                    checkpointHash: "checkpoint",
                    acknowledgedDeviceIDs: [currentDeviceID],
                    cloudChangeTag: nil,
                    firstV6MutationID: nil,
                    codeVersion: "fixture",
                    notRepresentable: []
                )
            )
        )
    }

    private func stamp(_ value: Int) -> HostV6.SyncStamp {
        HostV6.SyncStamp(
            vector: ["fixture": UInt64(value)],
            mutationID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!,
            updatedAt: Date(timeIntervalSince1970: 1_787_616_000)
        )
    }
}
