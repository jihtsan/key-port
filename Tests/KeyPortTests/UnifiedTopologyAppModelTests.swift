import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class UnifiedTopologyAppModelTests: XCTestCase {
    func testDefaultRuntimeMigratesLegacyServerIntoGraph() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-unified-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-unified-runtime"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            name: "测试服务器",
            host: "server.example.com",
            username: "root",
            alias: "test-server"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()

        XCTAssertTrue(model.graphWorkspace.isAvailable)
        XCTAssertTrue(model.graphWorkspace.usesUnifiedTopology)
        XCTAssertTrue(model.graphWorkspace.snapshot.nodes.contains(where: {
            $0.kind == .node && $0.title == "测试服务器"
        }))
        XCTAssertTrue(model.graphWorkspace.snapshot.edges.contains(where: {
            $0.kind == .candidateAccess
        }))
        let stored = try await TopologyStore(paths: paths).load()
        XCTAssertNotNil(stored)
    }

    func testConnectionProfileReusesAccountAndPersistsSelectedNetworkPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-connection-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-connection-profile"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "31000000-0000-4000-8000-000000000001")!,
            name: "Mac Studio",
            host: "100.117.174.75",
            username: "sw-jooder",
            alias: "studio-tailnet"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)
        var seededTopology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "测试 Mac"
        )
        let seededAccount = try XCTUnwrap(seededTopology.activeAccounts.first)
        let lanEndpoint = Endpoint(
            id: UUID(uuidString: "31000000-0000-4000-8000-000000000002")!,
            nodeID: seededAccount.nodeID,
            address: "192.168.1.20",
            label: "工作室局域网",
            port: 22,
            protocol: .ssh,
            networkScope: .lan,
            source: .manual
        )
        seededTopology.endpoints.append(lanEndpoint)
        try await TopologyStore(paths: paths).save(seededTopology)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        let account = try XCTUnwrap(model.topology.activeAccounts.first)

        let profileID = try await model.saveSSHConnectionProfile(SSHAccessSetupDraft(
            nodeID: account.nodeID,
            profileID: nil,
            accountID: account.id,
            endpointID: lanEndpoint.id,
            sshAlias: "studio-lan",
            sshInput: "ssh sw-jooder@192.168.1.20"
        ))

        XCTAssertEqual(model.topology.activeAccounts.count, 1)
        XCTAssertEqual(model.topology.activeConnectionProfiles.count, 2)
        XCTAssertEqual(model.topology.connectionProfile(id: profileID)?.accountID, account.id)
        XCTAssertEqual(
            model.topology.connectionProfile(id: profileID)?.routePolicy.fixedEndpointID,
            lanEndpoint.id
        )
        XCTAssertEqual(Set(model.activeServers.map(\.alias)), ["studio-tailnet", "studio-lan"])

        let loaded = try await TopologyStore(paths: paths).load()
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.activeConnectionProfiles.count, 2)
        XCTAssertEqual(stored.connectionProfile(id: profileID)?.accountID, account.id)
    }
}
