import XCTest
@testable import KeyPortCore

final class TailscaleTopologyTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testLocalStatusBindsTailscaleIdentitiesToExistingNodesAndKeepsMissingNodes() throws {
        let currentDeviceID = "device-current"
        let currentNodeID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let serverNodeID = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
        let endpointID = UUID(uuidString: "40000000-0000-4000-8000-000000000003")!
        let topology = TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "我的 Mac", roles: [.clientDevice], createdAt: observedAt, updatedAt: observedAt),
                Node(id: serverNodeID, name: "生产服务器", roles: [.sshHost], createdAt: observedAt, updatedAt: observedAt),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "我的 Mac",
                registeredAt: observedAt,
                lastActiveAt: observedAt,
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: serverNodeID,
                address: "server.example.ts.net",
                port: 22,
                protocol: .ssh,
                networkScope: .tailnet
            )]
        )
        let status = TailscaleStatus(
            backendState: "Running",
            tailnetName: "example.com",
            magicDNSSuffix: "ts.net",
            nodes: [
                makeNode(
                    id: "node-current",
                    name: "my-mac",
                    dnsName: "my-mac.example.ts.net",
                    addresses: ["100.64.0.1"],
                    isCurrent: true
                ),
                makeNode(
                    id: "node-server",
                    name: "server",
                    dnsName: "server.example.ts.net",
                    addresses: ["100.64.0.2"]
                ),
            ],
            observedAt: observedAt
        )

        let first = TailscaleTopologySynchronizer.apply(
            status: status,
            to: topology,
            observerDeviceID: currentDeviceID
        )
        let serverIdentity = try XCTUnwrap(first.tailscaleNodes.first { $0.tailscaleNodeID == "node-server" })
        XCTAssertEqual(serverIdentity.keyPortNodeID, serverNodeID)
        XCTAssertEqual(first.tailscaleNodes.count, 2)
        XCTAssertEqual(first.tailscaleObservations.count, 2)
        XCTAssertEqual(
            first.tailscaleObservations.first { $0.identityID == serverIdentity.id }?.isOnline,
            true
        )

        let secondStatus = TailscaleStatus(
            backendState: "Running",
            tailnetName: "example.com",
            magicDNSSuffix: "ts.net",
            nodes: [status.nodes[0]],
            observedAt: observedAt.addingTimeInterval(30)
        )
        let second = TailscaleTopologySynchronizer.apply(
            status: secondStatus,
            to: first,
            observerDeviceID: currentDeviceID
        )
        XCTAssertEqual(second.tailscaleNodes.count, 2)
        XCTAssertEqual(
            second.tailscaleNodes.first { $0.id == serverIdentity.id }?.updatedAt,
            observedAt
        )
        XCTAssertEqual(
            second.tailscaleObservations.first { $0.identityID == serverIdentity.id }?.observedAt,
            observedAt
        )
    }

    func testTailscaleRefreshPromotesMigratedMagicDNSEndpointToTailnet() throws {
        let nodeID = UUID(uuidString: "40400000-0000-4000-8000-000000000001")!
        let endpointID = UUID(uuidString: "40400000-0000-4000-8000-000000000002")!
        let topology = TopologySnapshot(
            nodes: [Node(
                id: nodeID,
                name: "生产服务器",
                roles: [.sshHost],
                createdAt: observedAt,
                updatedAt: observedAt
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: nodeID,
                address: "server.example.ts.net",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .migrated
            )]
        )
        let result = TailscaleTopologySynchronizer.apply(
            status: TailscaleStatus(
                backendState: "Running",
                tailnetName: "example.com",
                magicDNSSuffix: "ts.net",
                nodes: [makeNode(
                    id: "node-server",
                    name: "server",
                    dnsName: "server.example.ts.net",
                    addresses: ["100.64.0.2"]
                )],
                observedAt: observedAt
            ),
            to: topology,
            observerDeviceID: "device-current"
        )

        XCTAssertEqual(result.tailscaleNodes.first?.keyPortNodeID, nodeID)
        XCTAssertEqual(result.endpoint(id: endpointID)?.networkScope, .tailnet)
        XCTAssertEqual(result.endpoint(id: endpointID)?.source, .tailscale)
    }

    func testTailscaleRefreshMaterializesTailnetEndpointsIdempotently() throws {
        let nodeID = UUID(uuidString: "40500000-0000-4000-8000-000000000001")!
        let serviceID = UUID(uuidString: "40500000-0000-4000-8000-000000000002")!
        let serviceEndpointID = UUID(uuidString: "40500000-0000-4000-8000-000000000003")!
        let topology = TopologySnapshot(
            nodes: [Node(
                id: nodeID,
                name: "服务节点",
                roles: [.serviceHost],
                createdAt: observedAt,
                updatedAt: observedAt
            )],
            endpoints: [Endpoint(
                id: serviceEndpointID,
                nodeID: nodeID,
                serviceID: serviceID,
                address: "service.example.ts.net",
                port: 22,
                protocol: .ssh,
                networkScope: .tailnet,
                source: .manual
            )],
            services: [Service(
                id: serviceID,
                nodeID: nodeID,
                name: "SSH 代理服务",
                protocol: .ssh,
                endpointIDs: [serviceEndpointID]
            )]
        )
        let status = TailscaleStatus(
            backendState: "Running",
            tailnetName: "example.com",
            magicDNSSuffix: "ts.net",
            nodes: [makeNode(
                id: "node-service",
                name: "service",
                dnsName: "service.example.ts.net",
                addresses: ["100.64.0.9", "fd7a:115c:a1e0::9"]
            )],
            observedAt: observedAt
        )

        let first = TailscaleTopologySynchronizer.apply(
            status: status,
            to: topology,
            observerDeviceID: "device-current"
        )
        let identity = try XCTUnwrap(first.tailscaleNodes.first)
        let nodeEndpoints = first.endpoints.filter {
            $0.nodeID == identity.keyPortNodeID && $0.serviceID == nil
        }
        XCTAssertEqual(
            Set(nodeEndpoints.map(\.address)),
            ["service.example.ts.net", "100.64.0.9", "fd7a:115c:a1e0::9"]
        )
        XCTAssertTrue(nodeEndpoints.allSatisfy {
            $0.networkScope == .tailnet && $0.source == .tailscale && $0.port == 22
        })
        XCTAssertEqual(first.endpoints.first { $0.id == serviceEndpointID }?.serviceID, serviceID)

        let second = TailscaleTopologySynchronizer.apply(
            status: status,
            to: first,
            observerDeviceID: "device-current",
            observedAt: observedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(
            second.endpoints.filter { $0.nodeID == identity.keyPortNodeID && $0.serviceID == nil }.count,
            3
        )
        XCTAssertEqual(second.endpoints.count, first.endpoints.count)
    }

    func testTailscaleMatchingIgnoresServiceOnlyEndpoints() throws {
        let legacyNodeID = UUID(uuidString: "40600000-0000-4000-8000-000000000001")!
        let serviceID = UUID(uuidString: "40600000-0000-4000-8000-000000000002")!
        let topology = TopologySnapshot(
            nodes: [Node(
                id: legacyNodeID,
                name: "仅服务节点",
                roles: [.serviceHost],
                createdAt: observedAt,
                updatedAt: observedAt
            )],
            endpoints: [Endpoint(
                id: UUID(uuidString: "40600000-0000-4000-8000-000000000003")!,
                nodeID: legacyNodeID,
                serviceID: serviceID,
                address: "service.example.ts.net",
                port: 22,
                protocol: .ssh,
                networkScope: .tailnet
            )]
        )
        let result = TailscaleTopologySynchronizer.apply(
            status: TailscaleStatus(
                backendState: "Running",
                tailnetName: "example.com",
                magicDNSSuffix: "ts.net",
                nodes: [makeNode(
                    id: "node-new",
                    name: "new",
                    dnsName: "service.example.ts.net",
                    addresses: ["100.64.0.10"]
                )],
                observedAt: observedAt
            ),
            to: topology,
            observerDeviceID: "device-current"
        )

        XCTAssertEqual(result.tailscaleNodes.first?.keyPortNodeID, TopologyStableID.node(
            forTailscale: "example.com",
            nodeID: "node-new"
        ))
        XCTAssertNotEqual(result.tailscaleNodes.first?.keyPortNodeID, legacyNodeID)
    }

    func testGraphProjectsTailscalePeerAndSearchesStableNodeID() throws {
        let currentDeviceID = "device-current"
        let currentNodeID = UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
        let serverNodeID = UUID(uuidString: "41000000-0000-4000-8000-000000000002")!
        let topology = TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "我的 Mac", roles: [.clientDevice], createdAt: observedAt, updatedAt: observedAt),
                Node(id: serverNodeID, name: "生产服务器", roles: [], createdAt: observedAt, updatedAt: observedAt),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "我的 Mac",
                registeredAt: observedAt,
                lastActiveAt: observedAt,
                isCurrent: true
            )],
            tailscaleNodes: [try XCTUnwrap(TailscaleNodeIdentity(
                keyPortNodeID: serverNodeID,
                tailnetKey: "example.com",
                tailscaleNodeID: "node-server",
                displayName: "server",
                magicDNS: "server.example.ts.net",
                addresses: ["100.64.0.2"],
                updatedAt: observedAt
            ))],
            tailscaleObservations: [try XCTUnwrap(TailscaleNodeObservation(
                tailnetKey: "example.com",
                tailscaleNodeID: "node-server",
                observerDeviceID: currentDeviceID,
                backendState: "Running",
                observedAt: observedAt,
                isOnline: true
            ))]
        )

        let graph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            now: observedAt,
            query: TopologyGraphQuery(viewMode: .allDevices)
        )
        let server = try XCTUnwrap(graph.nodes.first { $0.id == .node(serverNodeID) })
        XCTAssertEqual(server.tailscaleIdentities.first?.observationState, .online)
        XCTAssertTrue(graph.edges.contains {
            $0.kind == .tailscalePeer
                && $0.from == .node(currentNodeID)
                && $0.to == .node(serverNodeID)
        })

        let defaultGraph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            now: observedAt
        )
        XCTAssertTrue(defaultGraph.nodes.contains { $0.id == .node(serverNodeID) })
        XCTAssertTrue(defaultGraph.edges.contains { $0.kind == .tailscalePeer })

        let filtered = graph.applying(TopologyGraphQuery(
            viewMode: .allDevices,
            searchText: "node-server"
        ))
        XCTAssertTrue(filtered.nodes.contains { $0.id == .node(serverNodeID) })
    }

    func testLiveStatusDoesNotReuseMissingOrUnavailablePersistedObservations() throws {
        let currentDeviceID = "device-current"
        let currentNodeID = UUID(uuidString: "41500000-0000-4000-8000-000000000001")!
        let serverNodeID = UUID(uuidString: "41500000-0000-4000-8000-000000000002")!
        let identity = try XCTUnwrap(TailscaleNodeIdentity(
            keyPortNodeID: serverNodeID,
            tailnetKey: "example.com",
            tailscaleNodeID: "node-server",
            displayName: "server",
            updatedAt: observedAt
        ))
        let persistedObservation = try XCTUnwrap(TailscaleNodeObservation(
            tailnetKey: "example.com",
            tailscaleNodeID: "node-server",
            observerDeviceID: currentDeviceID,
            backendState: "Running",
            observedAt: observedAt,
            isOnline: true
        ))
        let topology = TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "我的 Mac", roles: [.clientDevice], createdAt: observedAt, updatedAt: observedAt),
                Node(id: serverNodeID, name: "server", roles: [], createdAt: observedAt, updatedAt: observedAt),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "我的 Mac",
                registeredAt: observedAt,
                lastActiveAt: observedAt,
                isCurrent: true
            )],
            tailscaleNodes: [identity],
            tailscaleObservations: [persistedObservation]
        )
        let liveStatus = TailscaleStatus(
            backendState: "Running",
            tailnetName: "example.com",
            magicDNSSuffix: "ts.net",
            nodes: [],
            observedAt: observedAt.addingTimeInterval(30)
        )
        let liveGraph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            tailscaleStatus: liveStatus,
            query: TopologyGraphQuery(viewMode: .allDevices)
        )
        XCTAssertEqual(
            liveGraph.nodes.first { $0.id == .node(serverNodeID) }?.tailscaleIdentities.first?.observationState,
            .notObserved
        )
        XCTAssertFalse(liveGraph.edges.contains { $0.kind == .tailscalePeer })

        let unavailableGraph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            tailscaleStatus: TailscaleStatus(
                backendState: "Stopped",
                tailnetName: nil,
                magicDNSSuffix: nil,
                nodes: [],
                observedAt: observedAt.addingTimeInterval(60)
            ),
            query: TopologyGraphQuery(viewMode: .allDevices)
        )
        XCTAssertEqual(
            unavailableGraph.nodes.first { $0.id == .node(serverNodeID) }?.tailscaleIdentities.first?.observationState,
            .unavailable
        )

        let staleGraph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            now: observedAt.addingTimeInterval(TailscaleNodeObservation.defaultFreshnessInterval + 1),
            query: TopologyGraphQuery(viewMode: .allDevices)
        )
        XCTAssertEqual(
            staleGraph.nodes.first { $0.id == .node(serverNodeID) }?.tailscaleIdentities.first?.observationState,
            .stale
        )
    }

    func testCloudPolicyRemovesLocalObservationsAndCredentialsThenRestoresThem() throws {
        let currentDeviceID = "device-current"
        let nodeID = UUID(uuidString: "42000000-0000-4000-8000-000000000001")!
        let identity = try XCTUnwrap(TailscaleNodeIdentity(
            keyPortNodeID: nodeID,
            tailnetKey: "example.com",
            tailscaleNodeID: "node-server",
            displayName: "server",
            updatedAt: observedAt
        ))
        let observation = try XCTUnwrap(TailscaleNodeObservation(
            tailnetKey: "example.com",
            tailscaleNodeID: "node-server",
            observerDeviceID: currentDeviceID,
            backendState: "Running",
            observedAt: observedAt,
            isOnline: true
        ))
        let key = SSHKey(
            id: "key-current",
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA",
            fingerprint: "SHA256:test",
            privateKeyPath: "/private/key",
            isInAgent: true,
            origin: .generated,
            isLocallyAvailable: true
        )
        let local = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "server", roles: [], createdAt: observedAt, updatedAt: observedAt)],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: nodeID,
                name: "我的 Mac",
                registeredAt: observedAt,
                lastActiveAt: observedAt,
                isCurrent: true
            )],
            tailscaleNodes: [identity],
            tailscaleObservations: [observation],
            sshKeys: [key],
            reachabilityObservations: [ReachabilityObservation(
                endpointID: UUID(),
                observerDeviceID: currentDeviceID,
                networkEpoch: 1,
                observedAt: observedAt,
                wasReachable: true
            )],
            auditEvents: [.init(category: "test", action: "local", result: "local")]
        )

        let sanitized = TopologyCloudMetadataSnapshotPolicy.sanitized(local)
        XCTAssertEqual(sanitized.tailscaleNodes, [identity])
        XCTAssertTrue(sanitized.tailscaleObservations.isEmpty)
        XCTAssertTrue(sanitized.reachabilityObservations.isEmpty)
        XCTAssertEqual(sanitized.sshKeys.first?.privateKeyPath, nil)
        XCTAssertEqual(sanitized.sshKeys.first?.isInAgent, false)
        XCTAssertEqual(sanitized.sshKeys.first?.isLocallyAvailable, false)
        XCTAssertEqual(sanitized.profiles.first?.isCurrent, false)
        XCTAssertEqual(sanitized.auditEvents, [])

        let restored = TopologyCloudMetadataSnapshotPolicy.restoringLocalState(
            in: sanitized,
            from: local
        )
        XCTAssertEqual(restored.tailscaleObservations, [observation])
        XCTAssertEqual(restored.reachabilityObservations.count, 1)
        XCTAssertEqual(restored.sshKeys.first?.privateKeyPath, "/private/key")
        XCTAssertEqual(restored.profiles.first?.isCurrent, true)
        XCTAssertEqual(restored.auditEvents.count, 1)
    }

    func testCloudMergeKeepsStableArrayOrdering() throws {
        let firstNode = Node(
            id: UUID(uuidString: "43000000-0000-4000-8000-000000000001")!,
            name: "first",
            roles: [],
            createdAt: observedAt,
            updatedAt: observedAt
        )
        let secondNode = Node(
            id: UUID(uuidString: "43000000-0000-4000-8000-000000000002")!,
            name: "second",
            roles: [],
            createdAt: observedAt,
            updatedAt: observedAt
        )
        let local = TopologySnapshot(nodes: [secondNode, firstNode])
        let remote = TopologySnapshot(nodes: [firstNode, secondNode])

        let merged = TopologyCloudMetadataSnapshotPolicy.merge(local: local, remote: remote)
        XCTAssertEqual(merged.nodes.map(\.id), [firstNode.id, secondNode.id])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(merged),
            try encoder.encode(TopologyCloudMetadataSnapshotPolicy.merge(local: remote, remote: local))
        )
    }

    func testTopologySnapshotDecodesLegacyPayloadWithoutTailscaleFields() throws {
        let data = #"{"schemaVersion":1,"nodes":[],"profiles":[],"endpoints":[],"services":[],"sshAccounts":[],"sshKeys":[],"hostKeyTrusts":[],"authorizations":[],"reachabilityObservations":[],"accessVerifications":[],"nodeAssociations":[],"auditEvents":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TopologySnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.tailscaleNodes.isEmpty)
        XCTAssertTrue(decoded.tailscaleObservations.isEmpty)
    }

    private func makeNode(
        id: String,
        name: String,
        dnsName: String,
        addresses: [String],
        isCurrent: Bool = false
    ) -> TailscaleNode {
        TailscaleNode(
            id: id,
            name: name,
            hostName: name,
            dnsName: dnsName,
            operatingSystem: "linux",
            addresses: addresses,
            isOnline: true,
            isCurrent: isCurrent,
            lastSeen: observedAt,
            relay: nil,
            isExitNode: false,
            isExitNodeOption: false,
            stableNodeID: id
        )
    }
}
