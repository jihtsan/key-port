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
}
