import XCTest
@testable import KeyPortCore

final class UnifiedTopologyTests: XCTestCase {
    func testLegacySSHAccountsShareOneNodeAndProjectIntoGraphWithoutHostV6Envelope() {
        let currentDeviceID = "device-current"
        let host = "server.example.com"
        var legacy = AppSnapshot()
        legacy.devices = [
            Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)
        ]
        legacy.servers = [
            ServerConnection(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                name: "生产服务器",
                host: host,
                username: "root",
                alias: "prod-root"
            ),
            ServerConnection(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                name: "生产服务器",
                host: host,
                username: "deploy",
                alias: "prod-deploy"
            )
        ]

        let topology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let remoteNodes = topology.nodes.filter { $0.roles.contains(.sshHost) }

        XCTAssertEqual(remoteNodes.count, 1)
        XCTAssertEqual(topology.endpoints.filter { $0.nodeID == remoteNodes[0].id }.count, 1)
        XCTAssertEqual(topology.sshAccounts.filter { $0.nodeID == remoteNodes[0].id }.count, 2)

        let graph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery()
        )

        XCTAssertTrue(graph.nodes.contains { $0.kind == .node && $0.title == "生产服务器" })
        XCTAssertTrue(graph.nodes.contains { $0.isWorkspaceDevice && $0.title == "我的 Mac" })
        XCTAssertTrue(graph.edges.contains { $0.kind == .candidateAccess })
    }

    func testMultiplePortsStayOnOneNodeAndAuthorizedKeyCreatesNodeAccessEdge() {
        let currentDeviceID = "device-current"
        let key = SSHKeyRecord(
            id: "key-current",
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA current",
            fingerprint: "SHA256:current",
            privateKeyPath: "/tmp/current",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )
        let accountID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.keys = [key]
        legacy.servers = [
            ServerConnection(
                id: accountID,
                name: "生产服务器",
                host: "server.example.com",
                port: 22,
                username: "root",
                alias: "prod-root",
                status: .authorized
            ),
            ServerConnection(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
                name: "生产服务器",
                host: "server.example.com",
                port: 2222,
                username: "deploy",
                alias: "prod-deploy"
            )
        ]
        legacy.authorizations = [Authorization(
            serverID: accountID,
            keyID: key.id,
            fingerprint: key.fingerprint,
            remoteComment: "current",
            status: .authorized
        )]

        let topology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let remoteNode = try! XCTUnwrap(topology.nodes.first(where: { $0.isSSHHost }))
        XCTAssertEqual(topology.endpoints.filter { $0.nodeID == remoteNode.id }.count, 2)

        let graph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery()
        )
        XCTAssertTrue(graph.edges.contains {
            $0.kind == .nodeAccess
                && $0.from == .node(TopologyStableID.node(forDeviceID: currentDeviceID))
                && $0.to == .node(remoteNode.id)
        })
        XCTAssertEqual(
            graph.nodes.first(where: { $0.id == .node(remoteNode.id) })?.endpointSummaries.count,
            2
        )
    }

    func testCurrentDeviceQueryHidesOtherWorkspaceProfilesButKeepsRemoteNodes() {
        let currentDeviceID = "device-current"
        var legacy = AppSnapshot()
        legacy.devices = [
            Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true),
            Device(id: "device-other", name: "另一台 Mac", isCurrent: false)
        ]
        legacy.servers = [ServerConnection(
            name: "生产服务器",
            host: "server.example.com",
            username: "root",
            alias: "prod-root"
        )]

        let topology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let graph = TopologyGraphProjector().project(
            topology: topology,
            currentDeviceID: currentDeviceID,
            query: TopologyGraphQuery(viewMode: .currentDevice)
        )

        XCTAssertEqual(graph.nodes.filter(\.isWorkspaceDevice).count, 1)
        XCTAssertTrue(graph.nodes.contains(where: {
            $0.kind == .node && !$0.isWorkspaceDevice && $0.title == "生产服务器"
        }))
    }

    func testLegacyRefreshPreservesTopologyOnlyServiceAndEndpointFacts() {
        let currentDeviceID = "device-current"
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            name: "数据库服务器",
            host: "db.example.com",
            username: "admin",
            alias: "db-admin"
        )]

        let base = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let remoteNode = try! XCTUnwrap(base.nodes.first(where: { $0.isSSHHost }))
        let serviceID = TopologyStableID.service(
            nodeID: remoteNode.id,
            name: "PostgreSQL",
            protocol: .postgresql
        )
        let serviceEndpointID = TopologyStableID.endpoint(
            nodeID: remoteNode.id,
            address: "db.example.com",
            port: 5432,
            protocol: .postgresql
        )
        var existing = base
        existing.nodes[existing.nodes.firstIndex { $0.id == remoteNode.id }!].roles.append(.serviceHost)
        existing.endpoints.append(Endpoint(
            id: serviceEndpointID,
            nodeID: remoteNode.id,
            serviceID: serviceID,
            address: "db.example.com",
            port: 5432,
            protocol: .postgresql,
            networkScope: .publicNetwork,
            source: .manual
        ))
        existing.services.append(Service(
            id: serviceID,
            nodeID: remoteNode.id,
            name: "PostgreSQL",
            protocol: .postgresql,
            endpointIDs: [serviceEndpointID]
        ))

        let refreshed = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )

        XCTAssertEqual(refreshed.services.map(\.id), [serviceID])
        XCTAssertEqual(refreshed.endpoint(id: serviceEndpointID)?.networkScope, .publicNetwork)
        XCTAssertTrue(refreshed.node(id: remoteNode.id)?.roles.contains(.serviceHost) == true)
    }

    func testLegacyRefreshPreservesAccountWithoutConnectionProfile() throws {
        let currentDeviceID = "device-current"
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            name: "构建服务器",
            host: "builder.example.com",
            username: "root",
            alias: "builder-root"
        )]

        var existing = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let nodeID = try XCTUnwrap(existing.activeAccounts.first?.nodeID)
        let standaloneAccountID = TopologyStableID.sshAccount(
            nodeID: nodeID,
            username: "deploy"
        )
        existing.sshAccounts.append(SSHAccount(
            id: standaloneAccountID,
            nodeID: nodeID,
            username: "deploy",
            label: "部署用户"
        ))

        let refreshed = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )

        XCTAssertEqual(refreshed.accounts(for: nodeID).map(\.username).sorted(), ["deploy", "root"])
        XCTAssertEqual(refreshed.connectionProfiles(forNodeID: nodeID).count, 1)
        XCTAssertEqual(refreshed.sshAccounts.first(where: { $0.id == standaloneAccountID })?.label, "部署用户")
    }

    func testLegacyProjectionKeepsEndpointAddressSeparateFromDisplayLabel() throws {
        let currentDeviceID = "device-current"
        let nodeID = UUID(uuidString: "20000000-0000-4000-8000-000000000021")!
        let endpointID = TopologyStableID.nodeEndpoint(
            nodeID: nodeID,
            address: "203.0.113.21",
            port: 22,
            protocol: .ssh
        )
        let accountID = UUID(uuidString: "20000000-0000-4000-8000-000000000022")!
        let topology = TopologySnapshot(
            nodes: [Node(id: nodeID, name: "公网节点", roles: [.sshHost])],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: nodeID,
                address: "203.0.113.21",
                label: "办公出口",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .manual
            )],
            sshAccounts: [SSHAccount(
                id: accountID,
                nodeID: nodeID,
                username: "root"
            )],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000023")!,
                accountID: accountID,
                sshAlias: "public-root",
                routePolicy: .fixed(endpointID: endpointID)
            )]
        )

        let projected = TopologySnapshotMigration.legacyProjection(
            from: topology,
            currentDeviceID: currentDeviceID
        )

        XCTAssertEqual(projected.servers.first?.host, "203.0.113.21")
        XCTAssertEqual(projected.servers.first?.name, "公网节点")
    }

    func testLegacyRefreshReattachesExactTailscaleAddressAndPreservesMultipleAccounts() throws {
        let currentDeviceID = "device-current"
        let targetNodeID = TopologyStableID.node(forTailscale: "acme.example", nodeID: "ts-node-1")
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.servers = [
            ServerConnection(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000011")!,
                name: "生产服务器",
                host: "server.acme.ts.net",
                username: "root",
                alias: "prod-root"
            ),
            ServerConnection(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000012")!,
                name: "生产服务器",
                host: "server.acme.ts.net",
                username: "deploy",
                alias: "prod-deploy"
            )
        ]

        let migrated = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let identity = try XCTUnwrap(TailscaleNodeIdentity(
            keyPortNodeID: targetNodeID,
            tailnetKey: "acme.example",
            tailscaleNodeID: "ts-node-1",
            displayName: "生产服务器",
            magicDNS: "server.acme.ts.net",
            addresses: ["100.100.0.10"]
        ))
        let existing = TopologySnapshot(
            nodes: migrated.nodes.filter { !$0.isSSHHost } + [
                Node(id: targetNodeID, name: "生产服务器", roles: [])
            ],
            profiles: migrated.profiles,
            endpoints: [Endpoint(
                id: TopologyStableID.nodeEndpoint(
                    nodeID: targetNodeID,
                    address: "server.acme.ts.net",
                    port: 22,
                    protocol: .ssh
                ),
                nodeID: targetNodeID,
                address: "server.acme.ts.net",
                port: 22,
                protocol: .ssh,
                networkScope: .tailnet,
                source: .tailscale
            )],
            tailscaleNodes: [identity]
        )

        let refreshed = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )

        let sourceNodeID = try XCTUnwrap(migrated.nodes.first(where: \.isSSHHost)?.id)
        XCTAssertEqual(refreshed.activeAccounts.count, 2)
        XCTAssertTrue(refreshed.activeAccounts.allSatisfy { $0.nodeID == targetNodeID })
        XCTAssertEqual(refreshed.activeEndpoints.filter { $0.nodeID == targetNodeID }.count, 1)
        XCTAssertTrue(refreshed.nodes.first(where: { $0.id == sourceNodeID })?.isDeleted == true)
        XCTAssertTrue(refreshed.node(id: targetNodeID)?.roles.contains(.sshHost) == true)
    }

    func testLegacyRefreshDoesNotAttachPublicAddressToTailscaleNode() throws {
        let currentDeviceID = "device-current"
        let targetNodeID = TopologyStableID.node(forTailscale: "acme.example", nodeID: "ts-node-2")
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000013")!,
            name: "公网服务器",
            host: "203.0.113.10",
            username: "root",
            alias: "public-root"
        )]

        let migrated = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )
        let identity = try XCTUnwrap(TailscaleNodeIdentity(
            keyPortNodeID: targetNodeID,
            tailnetKey: "acme.example",
            tailscaleNodeID: "ts-node-2",
            displayName: "Tailnet 服务器",
            magicDNS: "server.acme.ts.net",
            addresses: ["100.100.0.11"]
        ))
        let existing = TopologySnapshot(
            nodes: migrated.nodes.filter { !$0.isSSHHost } + [
                Node(id: targetNodeID, name: "Tailnet 服务器", roles: [.sshHost])
            ],
            profiles: migrated.profiles,
            tailscaleNodes: [identity]
        )

        let refreshed = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )

        let publicNodeID = try XCTUnwrap(migrated.nodes.first(where: \.isSSHHost)?.id)
        XCTAssertEqual(refreshed.activeNodes.filter(\.isSSHHost).count, 2)
        XCTAssertEqual(refreshed.activeAccounts.first?.nodeID, publicNodeID)
        XCTAssertEqual(refreshed.activeEndpoints.first?.networkScope, .publicNetwork)
    }

    func testExplicitNodeBindingKeepsPublicAccountsGroupedAcrossRefreshes() throws {
        let currentDeviceID = "device-current"
        let targetNodeID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let endpointID = TopologyStableID.nodeEndpoint(
            nodeID: targetNodeID,
            address: "203.0.113.20",
            port: 22,
            protocol: .ssh
        )
        let existingProfileID = UUID(uuidString: "20000000-0000-4000-8000-000000000011")!
        let newProfileID = UUID(uuidString: "20000000-0000-4000-8000-000000000012")!
        let existingAccountID = TopologyStableID.sshAccount(nodeID: targetNodeID, username: "root")
        let newAccountID = TopologyStableID.sshAccount(nodeID: targetNodeID, username: "deploy")
        let publicHost = "203.0.113.20"

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "我的 Mac", isCurrent: true)]
        legacy.servers = [
            ServerConnection(
                id: existingProfileID,
                name: "公网节点",
                host: publicHost,
                username: "root",
                alias: "public-root"
            ),
            ServerConnection(
                id: newProfileID,
                name: "公网节点",
                host: publicHost,
                username: "deploy",
                alias: "public-deploy"
            ),
        ]

        let currentNodeID = TopologyStableID.node(forDeviceID: currentDeviceID)
        let existing = TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "我的 Mac", roles: [.clientDevice]),
                Node(id: targetNodeID, name: "公网节点", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "我的 Mac",
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: targetNodeID,
                address: publicHost,
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .manual
            )],
            sshAccounts: [SSHAccount(
                id: existingAccountID,
                nodeID: targetNodeID,
                username: "root"
            )],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: existingProfileID,
                accountID: existingAccountID,
                sshAlias: "public-root",
                routePolicy: .fixed(endpointID: endpointID)
            )]
        )

        let firstRefresh = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: existing,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac",
            profileBindings: [SSHConnectionProfileNodeBinding(
                profileID: newProfileID,
                nodeID: targetNodeID,
                endpointID: endpointID
            )]
        )

        XCTAssertEqual(firstRefresh.accounts(for: targetNodeID).count, 2)
        XCTAssertTrue(firstRefresh.accounts(for: targetNodeID).contains { $0.id == existingAccountID })
        XCTAssertTrue(firstRefresh.accounts(for: targetNodeID).contains { $0.id == newAccountID })
        XCTAssertEqual(firstRefresh.endpoints(for: targetNodeID).map(\.id), [endpointID])
        let sourceNodeID = TopologyStableID.node(forHost: publicHost)
        XCTAssertTrue(firstRefresh.nodes.first(where: { $0.id == sourceNodeID })?.isDeleted == true)

        let secondRefresh = TopologySnapshotMigration.refreshed(
            from: legacy,
            preserving: firstRefresh,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "我的 Mac"
        )

        XCTAssertEqual(secondRefresh.accounts(for: targetNodeID).count, 2)
        XCTAssertTrue(secondRefresh.connectionProfiles(forNodeID: targetNodeID).allSatisfy {
            $0.routePolicy.fixedEndpointID == endpointID
        })
        XCTAssertEqual(secondRefresh.endpoints(for: targetNodeID).count, 1)
        XCTAssertTrue(secondRefresh.nodes.first(where: { $0.id == sourceNodeID })?.isDeleted == true)
    }
}
