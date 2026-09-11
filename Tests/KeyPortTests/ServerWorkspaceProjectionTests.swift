import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class ServerWorkspaceProjectionTests: XCTestCase {
    func testListAndGraphShareNodeFactsForMultipleAddressesAndAccounts() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-server-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-server-workspace"
        let defaultsSuite = "KeyPort.ServerWorkspaceProjectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let firstProfileID = UUID(uuidString: "72000000-0000-4000-8000-000000000001")!
        let secondProfileID = UUID(uuidString: "72000000-0000-4000-8000-000000000002")!
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [
            ServerConnection(
                id: firstProfileID,
                name: "构建服务器",
                host: "builder.example.com",
                username: "deploy",
                alias: "builder-deploy",
                status: .hostKeyPending
            ),
            ServerConnection(
                id: secondProfileID,
                name: "构建服务器",
                host: "builder.example.com",
                username: "root",
                alias: "builder-root",
                status: .hostKeyPending
            ),
        ]

        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)

        var topology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "测试 Mac"
        )
        let serverNodeID = try XCTUnwrap(topology.activeAccounts.first?.nodeID)
        let alternateEndpointID = TopologyStableID.nodeEndpoint(
            nodeID: serverNodeID,
            address: "192.168.50.20",
            port: 2222,
            protocol: .ssh
        )
        topology.endpoints.append(Endpoint(
            id: alternateEndpointID,
            nodeID: serverNodeID,
            address: "192.168.50.20",
            label: "构建机局域网",
            port: 2222,
            protocol: .ssh,
            networkScope: .lan,
            source: .manual,
            priority: 1
        ))

        let setupNodeID = UUID(uuidString: "72000000-0000-4000-8000-000000000010")!
        topology.nodes.append(Node(
            id: setupNodeID,
            name: "待配置服务器",
            roles: [.sshHost]
        ))
        try await TopologyStore(paths: paths).save(topology)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        model.graphWorkspace.viewMode = .allDevices
        model.graphWorkspace.searchText = ""
        model.graphWorkspace.onlyIssues = false

        let graphServerNode = try XCTUnwrap(
            model.graphWorkspace.snapshot.nodes.first { $0.id == .node(serverNodeID) }
        )
        let serverItems = NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        )
        let serverItem = try XCTUnwrap(serverItems.first { $0.id == .node(serverNodeID) })

        XCTAssertEqual(serverItem.node, graphServerNode)
        XCTAssertEqual(serverItem.topologyNodeID, serverNodeID)
        XCTAssertTrue(serverItem.isServerNode)
        XCTAssertFalse(serverItem.node.isWorkspaceDevice)
        XCTAssertEqual(Set(serverItem.accounts.map(\.id)), [firstProfileID, secondProfileID])
        XCTAssertEqual(serverItem.accountCount, 2)
        XCTAssertEqual(serverItem.connectionProfileCount, 2)
        XCTAssertEqual(
            Set(serverItem.endpoints.map(\.id)),
            Set(model.topology.endpoints(for: serverNodeID, endpointProtocol: .ssh).map(\.id))
        )
        XCTAssertEqual(serverItem.endpointCount, 2)
        XCTAssertTrue(serverItem.endpoints.contains { $0.id == alternateEndpointID })

        let setupItem = try XCTUnwrap(serverItems.first { $0.id == .node(setupNodeID) })
        XCTAssertTrue(setupItem.accounts.isEmpty)
        XCTAssertEqual(setupItem.endpointCount, 0)

        model.graphWorkspace.searchText = "deploy"
        let accountSearchItems = NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        )
        XCTAssertEqual(accountSearchItems.map(\.id), [.node(serverNodeID)])

        model.graphWorkspace.searchText = "192.168.50.20"
        let endpointSearchItems = NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        )
        XCTAssertEqual(endpointSearchItems.map(\.id), [.node(serverNodeID)])

        model.graphWorkspace.searchText = ""
        model.graphWorkspace.onlyIssues = true
        let issueItems = NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        )
        let graphIssueNodeIDs = Set(
            model.graphWorkspace.snapshot.nodes
                .filter { $0.kind == .node && !$0.isWorkspaceDevice }
                .map(\.id)
        )
        XCTAssertEqual(Set(issueItems.map(\.id)), graphIssueNodeIDs)
        XCTAssertTrue(issueItems.contains { $0.id == .node(serverNodeID) })
    }
}
