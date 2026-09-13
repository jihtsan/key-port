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

    func testConnectionProfileSavePersistsAutomaticCandidateOrder() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-automatic-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-automatic-route"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "31200000-0000-4000-8000-000000000001")!,
            name: "Mac Studio",
            host: "100.117.174.75",
            username: "root",
            alias: "studio-tailnet"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)
        try paths.prepareDirectories()
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.sshRelayHelper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.sshRelayHelper.path
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.sshRelayHelper)
        }
        var seededTopology = TopologySnapshotMigration.fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: "测试 Mac"
        )
        let seededAccount = try XCTUnwrap(seededTopology.activeAccounts.first)
        seededTopology.endpoints.append(Endpoint(
            id: UUID(uuidString: "31200000-0000-4000-8000-000000000002")!,
            nodeID: seededAccount.nodeID,
            address: "192.168.1.20",
            label: "工作室局域网",
            port: 22,
            protocol: .ssh,
            networkScope: .lan,
            source: .manual,
            priority: 1
        ))
        try await TopologyStore(paths: paths).save(seededTopology)
        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()

        let account = try XCTUnwrap(model.topology.activeAccounts.first)
        let endpoints = model.topology.endpoints(for: account.nodeID, endpointProtocol: .ssh)
        let orderedEndpointIDs = endpoints.sorted {
            if $0.networkScope != $1.networkScope {
                return $0.networkScope == .lan
            }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
        let previewEndpointID = try XCTUnwrap(orderedEndpointIDs.first)
        let profileID = try await model.saveSSHConnectionProfile(SSHAccessSetupDraft(
            nodeID: account.nodeID,
            accountID: account.id,
            endpointID: previewEndpointID,
            sshAlias: "studio-ordered",
            routeMode: .automatic,
            candidateEndpointIDs: orderedEndpointIDs
        ))

        let profile = try XCTUnwrap(model.topology.connectionProfile(id: profileID))
        XCTAssertEqual(profile.routePolicy.networkScope, nil)
        XCTAssertEqual(profile.candidateEndpointIDs, orderedEndpointIDs)

        let loaded = try await TopologyStore(paths: paths).load()
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(
            stored.connectionProfile(id: profileID)?.candidateEndpointIDs,
            orderedEndpointIDs
        )
    }

    func testNewConnectionDraftRecordsPersistedProfileBeforeFurtherValidation() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-connection-draft-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-connection-draft-persistence"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            name: "Mac Studio",
            host: "100.117.174.75",
            username: "sw-jooder",
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
        var draft = SSHAccessSetupDraft(
            nodeID: account.nodeID,
            profileID: nil,
            accountID: account.id,
            endpointID: endpointID,
            sshAlias: "new-tailnet-profile"
        )

        let profileID = try await model.saveSSHConnectionProfile(draft)
        draft.recordPersistedProfile(profileID)

        XCTAssertEqual(draft.profileID, profileID)
        XCTAssertNil(model.sshAliasValidationMessage(
            draft.sshAlias,
            excludingProfileID: draft.profileID
        ))
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

    func testEditingEndpointPreservesPathIdentityAndInvalidatesEvidence() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-endpoint-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-endpoint-edit"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let currentNodeID = TopologyStableID.node(forDeviceID: currentDeviceID)
        let targetNodeID = UUID(uuidString: "34000000-0000-4000-8000-000000000001")!
        let endpointID = UUID(uuidString: "34000000-0000-4000-8000-000000000002")!
        let accountID = TopologyStableID.sshAccount(nodeID: targetNodeID, username: "deploy")
        let profileID = UUID(uuidString: "34000000-0000-4000-8000-000000000003")!
        let now = Date(timeIntervalSince1970: 1_787_616_000)
        let paths = KeyPortPaths(home: home)

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        try await SnapshotStore(paths: paths).save(legacy)
        try await TopologyStore(paths: paths).save(TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "测试 Mac", roles: [.clientDevice]),
                Node(id: targetNodeID, name: "构建服务器", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "测试 Mac",
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: targetNodeID,
                address: "builder.example.com",
                label: "原地址",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .manual
            )],
            sshAccounts: [SSHAccount(
                id: accountID,
                nodeID: targetNodeID,
                username: "deploy"
            )],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: profileID,
                accountID: accountID,
                sshAlias: "builder-deploy",
                routePolicy: .fixed(endpointID: endpointID)
            )],
            hostKeyTrusts: [SSHHostKeyTrust(
                id: UUID(uuidString: "34000000-0000-4000-8000-000000000004")!,
                endpointID: endpointID,
                algorithm: "ssh-ed25519",
                fingerprint: "SHA256:builder",
                knownHostsLine: "builder.example.com ssh-ed25519 builder",
                state: .confirmed,
                firstConfirmedAt: now,
                lastSeenAt: now
            )],
            reachabilityObservations: [ReachabilityObservation(
                endpointID: endpointID,
                observerDeviceID: currentDeviceID,
                networkEpoch: 1,
                observedAt: now,
                wasReachable: true
            )],
            accessVerifications: [AccessVerification(
                accountID: accountID,
                deviceID: currentDeviceID,
                profileID: profileID,
                endpointID: endpointID,
                transport: .direct,
                networkEpoch: 1,
                status: .authorized,
                statusDetail: "已验证",
                lastCheckedAt: now,
                passwordCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "密码可用",
                    checkedAt: now
                ),
                keyCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "密钥可用",
                    checkedAt: now
                )
            )]
        ))

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()

        try await model.saveNodeEndpoint(NodeEndpointDraft(
            endpointID: endpointID,
            address: "builder.internal.example.com",
            label: "内网地址",
            port: 2222,
            networkScope: .lan
        ), forNodeID: targetNodeID)

        let activeEndpoints = model.topology.endpoints(for: targetNodeID, endpointProtocol: .ssh)
        XCTAssertEqual(activeEndpoints.count, 1)
        XCTAssertEqual(activeEndpoints.first?.id, endpointID)
        XCTAssertEqual(activeEndpoints.first?.address, "builder.internal.example.com")
        XCTAssertEqual(activeEndpoints.first?.port, 2222)
        XCTAssertEqual(
            model.topology.connectionProfile(id: profileID)?.routePolicy.fixedEndpointID,
            endpointID
        )
        XCTAssertTrue(model.topology.reachabilityObservations.isEmpty)

        let verification = try XCTUnwrap(model.topology.accessVerifications.first)
        XCTAssertEqual(verification.status, .needsAuthorization)
        XCTAssertNil(verification.lastCheckedAt)
        XCTAssertNil(verification.passwordCheck)
        XCTAssertNil(verification.keyCheck)
        XCTAssertTrue(model.topology.hostKeyTrusts.contains {
            $0.endpointID == endpointID && $0.state == .replaced && $0.isDeleted
        })

        let stored = try await TopologyStore(paths: paths).load()
        let storedTopology = try XCTUnwrap(stored)
        XCTAssertEqual(
            storedTopology.endpoints
                .filter { !$0.isDeleted && $0.nodeID == targetNodeID }
                .map(\.id),
            [endpointID]
        )
        XCTAssertEqual(storedTopology.connectionProfile(id: profileID)?.routePolicy.fixedEndpointID, endpointID)
    }

    func testDeletingUnreferencedEndpointTombstonesPathButKeepsRemoteAuthorization() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-endpoint-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-endpoint-delete"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let currentNodeID = TopologyStableID.node(forDeviceID: currentDeviceID)
        let targetNodeID = UUID(uuidString: "35000000-0000-4000-8000-000000000001")!
        let endpointID = UUID(uuidString: "35000000-0000-4000-8000-000000000002")!
        let accountID = TopologyStableID.sshAccount(nodeID: targetNodeID, username: "ops")
        let keyID = "key-endpoint-delete"
        let now = Date(timeIntervalSince1970: 1_787_616_000)
        let paths = KeyPortPaths(home: home)

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        try await SnapshotStore(paths: paths).save(legacy)
        try await TopologyStore(paths: paths).save(TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "测试 Mac", roles: [.clientDevice]),
                Node(id: targetNodeID, name: "运维服务器", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "测试 Mac",
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: targetNodeID,
                address: "ops.example.com",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .manual
            )],
            sshAccounts: [SSHAccount(
                id: accountID,
                nodeID: targetNodeID,
                username: "ops"
            )],
            sshKeys: [SSHKey(
                id: keyID,
                deviceID: currentDeviceID,
                kind: .ed25519,
                publicKey: "ssh-ed25519 AAAA endpoint-delete",
                fingerprint: "SHA256:endpoint-delete",
                origin: .generated,
                isLocallyAvailable: true
            )],
            hostKeyTrusts: [SSHHostKeyTrust(
                id: UUID(uuidString: "35000000-0000-4000-8000-000000000003")!,
                endpointID: endpointID,
                algorithm: "ssh-ed25519",
                fingerprint: "SHA256:ops",
                knownHostsLine: "ops.example.com ssh-ed25519 ops",
                state: .confirmed,
                firstConfirmedAt: now,
                lastSeenAt: now
            )],
            authorizations: [SSHAuthorization(
                accountID: accountID,
                keyID: keyID,
                fingerprint: "SHA256:endpoint-delete",
                remoteComment: "device",
                remoteState: .authorized,
                authorizedAt: now,
                lastVerifiedAt: now,
                updatedAt: now
            )],
            reachabilityObservations: [ReachabilityObservation(
                endpointID: endpointID,
                observerDeviceID: currentDeviceID,
                networkEpoch: 1,
                observedAt: now,
                wasReachable: true
            )],
            accessVerifications: [AccessVerification(
                accountID: accountID,
                deviceID: currentDeviceID,
                endpointID: endpointID,
                transport: .direct,
                status: .authorized,
                lastCheckedAt: now
            )]
        ))

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        try await model.deleteNodeEndpoint(endpointID, forNodeID: targetNodeID)

        XCTAssertTrue(model.topology.endpoints.contains { $0.id == endpointID && $0.isDeleted })
        XCTAssertTrue(model.topology.endpoints(for: targetNodeID, endpointProtocol: .ssh).isEmpty)
        XCTAssertTrue(model.topology.hostKeyTrusts.contains {
            $0.endpointID == endpointID && $0.state == .replaced && $0.isDeleted
        })
        XCTAssertTrue(model.topology.reachabilityObservations.isEmpty)
        XCTAssertEqual(model.topology.authorizations.first?.remoteState, .authorized)
        XCTAssertEqual(model.topology.accessVerifications.first?.status, .needsAuthorization)
        XCTAssertTrue(model.topology.auditEvents.contains {
            $0.category == "endpoint" && $0.action == "delete" && $0.targetID == endpointID.uuidString
        })
    }

    func testDeletingConnectionProfileLeavesAccountAuthorization() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-profile-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-profile-delete"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        let currentNodeID = TopologyStableID.node(forDeviceID: currentDeviceID)
        let targetNodeID = UUID(uuidString: "36000000-0000-4000-8000-000000000001")!
        let endpointID = UUID(uuidString: "36000000-0000-4000-8000-000000000002")!
        let profileID = UUID(uuidString: "36000000-0000-4000-8000-000000000003")!
        let accountID = TopologyStableID.sshAccount(nodeID: targetNodeID, username: "deploy")
        let keyID = "key-profile-delete"
        let now = Date(timeIntervalSince1970: 1_787_616_000)
        let paths = KeyPortPaths(home: home)

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        try await SnapshotStore(paths: paths).save(legacy)
        try await TopologyStore(paths: paths).save(TopologySnapshot(
            nodes: [
                Node(id: currentNodeID, name: "测试 Mac", roles: [.clientDevice]),
                Node(id: targetNodeID, name: "应用服务器", roles: [.sshHost]),
            ],
            profiles: [WorkspaceDeviceProfile(
                id: currentDeviceID,
                nodeID: currentNodeID,
                name: "测试 Mac",
                isCurrent: true
            )],
            endpoints: [Endpoint(
                id: endpointID,
                nodeID: targetNodeID,
                address: "app.example.com",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork,
                source: .manual
            )],
            sshAccounts: [SSHAccount(
                id: accountID,
                nodeID: targetNodeID,
                username: "deploy"
            )],
            sshConnectionProfiles: [SSHConnectionProfile(
                id: profileID,
                accountID: accountID,
                sshAlias: "app-deploy",
                routePolicy: .fixed(endpointID: endpointID)
            )],
            sshKeys: [SSHKey(
                id: keyID,
                deviceID: currentDeviceID,
                kind: .ed25519,
                publicKey: "ssh-ed25519 AAAA profile-delete",
                fingerprint: "SHA256:profile-delete",
                origin: .generated,
                isLocallyAvailable: true
            )],
            authorizations: [SSHAuthorization(
                accountID: accountID,
                keyID: keyID,
                fingerprint: "SHA256:profile-delete",
                remoteComment: "device",
                remoteState: .authorized,
                authorizedAt: now,
                lastVerifiedAt: now,
                updatedAt: now
            )]
        ))

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()
        XCTAssertEqual(model.activeServers.map(\.id), [profileID])
        XCTAssertTrue(model.topology.sshConnectionProfiles.contains {
            $0.id == profileID && !$0.isDeleted
        })

        await model.deleteServer(profileID)

        XCTAssertTrue(model.topology.sshConnectionProfiles.contains {
            $0.id == profileID && $0.isDeleted
        })
        XCTAssertTrue(model.topology.activeAccounts.contains { $0.id == accountID })
        XCTAssertEqual(model.topology.activeAuthorizations(for: accountID).first?.remoteState, .authorized)
        XCTAssertTrue(model.activeServers.isEmpty)

        let reloaded = AppModel(paths: paths, defaults: defaults)
        await reloaded.load()
        XCTAssertTrue(reloaded.topology.activeAccounts.contains { $0.id == accountID })
        XCTAssertEqual(reloaded.topology.activeAuthorizations(for: accountID).first?.remoteState, .authorized)
        XCTAssertTrue(reloaded.activeServers.isEmpty)
    }
}
