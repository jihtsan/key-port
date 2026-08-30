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
            sshAlias: "studio-lan"
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

    func testConnectionProfileSaveRejectsAliasAddedToSSHConfigAfterLoad() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-connection-alias-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-connection-alias-conflict"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "31500000-0000-4000-8000-000000000001")!,
            name: "测试服务器",
            host: "server.example.com",
            username: "deploy",
            alias: "existing-profile"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        let account = try XCTUnwrap(model.topology.activeAccounts.first)
        let endpointID = try XCTUnwrap(
            model.topology.connectionProfile(id: legacy.servers[0].id)?.routePolicy.fixedEndpointID
        )
        let profileCount = model.topology.activeConnectionProfiles.count

        try paths.prepareDirectories()
        try "Host late-conflict\n    HostName other.example.com\n"
            .write(to: paths.userConfig, atomically: true, encoding: .utf8)

        do {
            _ = try await model.saveSSHConnectionProfile(SSHAccessSetupDraft(
                nodeID: account.nodeID,
                profileID: nil,
                accountID: account.id,
                endpointID: endpointID,
                sshAlias: "late-conflict"
            ))
            XCTFail("An alias added to SSH Config after load was accepted")
        } catch SSHConfigError.aliasConflict(let alias) {
            XCTAssertEqual(alias, "late-conflict")
        }

        XCTAssertEqual(model.topology.activeConnectionProfiles.count, profileCount)
        XCTAssertFalse(model.topology.activeConnectionProfiles.contains {
            $0.sshAlias == "late-conflict"
        })
    }

    func testAccountCanBeAddedWithoutEndpointOrConnectionProfile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-account-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-account-only"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let nodeID = UUID(uuidString: "32000000-0000-4000-8000-000000000001")!
        let currentNodeID = TopologyStableID.node(forDeviceID: currentDeviceID)
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)
        try await TopologyStore(paths: paths).save(TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "测试 Mac", roles: [.clientDevice]),
                Node(id: nodeID, name: "无地址节点", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "测试 Mac",
                isCurrent: true
            )]
        ))

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        XCTAssertTrue(model.topology.endpoints(for: nodeID).isEmpty)

        let accountID = try await model.saveSSHAccount(SSHAccountEditorSubmission(
            draft: SSHAccountDraft(
                nodeID: nodeID,
                label: "部署用户",
                username: "deploy"
            ),
            password: "",
            synchronizable: false
        ))

        XCTAssertEqual(model.topology.accounts(for: nodeID).map(\.id), [accountID])
        XCTAssertTrue(model.topology.connectionProfiles(for: accountID).isEmpty)
        XCTAssertTrue(model.activeServers.isEmpty)

        let reloaded = AppModel(paths: paths, defaults: defaults)
        await reloaded.load()
        XCTAssertEqual(reloaded.topology.accounts(for: nodeID).first?.username, "deploy")
        XCTAssertEqual(reloaded.topology.accounts(for: nodeID).first?.label, "部署用户")
    }

    func testEditingAccountUsernamePreservesConnectionProfileAndEndpoint() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-account-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-account-edit"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let profileID = UUID(uuidString: "33000000-0000-4000-8000-000000000001")!
        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: profileID,
            name: "构建服务器",
            host: "builder.example.com",
            username: "root",
            alias: "builder-root"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        let previousAccount = try XCTUnwrap(model.topology.activeAccounts.first)
        let endpointID = try XCTUnwrap(
            model.topology.connectionProfile(id: profileID)?.routePolicy.fixedEndpointID
        )

        let updatedAccountID = try await model.saveSSHAccount(SSHAccountEditorSubmission(
            draft: SSHAccountDraft(
                nodeID: previousAccount.nodeID,
                accountID: previousAccount.id,
                label: "部署用户",
                username: "deploy"
            ),
            password: "",
            synchronizable: false
        ))

        XCTAssertNotEqual(updatedAccountID, previousAccount.id)
        XCTAssertEqual(model.topology.connectionProfile(id: profileID)?.accountID, updatedAccountID)
        XCTAssertEqual(
            model.topology.connectionProfile(id: profileID)?.routePolicy.fixedEndpointID,
            endpointID
        )
        XCTAssertEqual(model.activeServers.first?.username, "deploy")
        XCTAssertEqual(model.activeServers.first?.alias, "builder-root")
        XCTAssertEqual(
            model.topology.sshAccounts.first(where: { $0.id == previousAccount.id })?.isDeleted,
            true
        )

        let reloaded = AppModel(paths: paths, defaults: defaults)
        await reloaded.load()
        XCTAssertEqual(reloaded.topology.connectionProfile(id: profileID)?.accountID, updatedAccountID)
        XCTAssertEqual(reloaded.activeServers.first?.username, "deploy")
        XCTAssertEqual(reloaded.activeServers.first?.alias, "builder-root")
    }
}
