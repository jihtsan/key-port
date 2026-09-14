import Foundation
import KeyPortCore

/// One-time readers only. Source documents remain untouched and are backed up before publication.
@MainActor enum WorkspaceMigration {
    static func load(paths: KeyPortPaths, deviceID: String?) throws -> WorkspaceStore.Document {
        let fm = FileManager.default
        var sources: [URL] = []
        func read<T: Decodable>(_ type: T.Type, _ url: URL, pilot: Bool = false) throws -> T? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            let value = try (pilot ? JSONDecoder() : WorkspaceStore.decoder()).decode(type, from: data)
            sources.append(url); return value
        }
        var topology = try read(TopologySnapshot.self, paths.topologySnapshot)
            ?? read(TopologySnapshot.self, paths.topologySnapshotBackup)
        var legacy = try read(AppSnapshot.self, paths.snapshot) ?? read(AppSnapshot.self, paths.snapshotBackup)
        var authoritativeV6 = false
        if let envelope = try read(HostV6.MetadataEnvelope.self, paths.stateV6),
           let mode = envelope.migrationProvenance.authorityManifest?.mode,
           mode == .v6Authoritative || mode == .compatibilityRollback {
            legacy = try HostV6.AuthorityController.compatibilityProjection(from: envelope, requiresCompleteRoutes: true).snapshot
            authoritativeV6 = true
        }
        // An interrupted old transaction must be recovered by the previous version before migration.
        for url in [paths.authorityActivationJournal, paths.v6CommitJournal, paths.v6MutationJournal] where fm.fileExists(atPath: url.path) {
            throw WorkspaceMigrationError.pendingTransaction
        }
        let pilotPaths = KeyPortPaths(home: paths.applicationSupport.appendingPathComponent("AccessPilot"))
        let pilot = try read(WorkspaceStore.State.self, pilotPaths.applicationSupport.appendingPathComponent("access-pilot-v1.json"), pilot: true)
        if let pilot, pilot.version != 1 { throw WorkspaceError.storage }
        let current = deviceID ?? topology?.profiles.first(where: \.isCurrent)?.id ?? legacy?.devices.first(where: \.isCurrent)?.id ?? pilot?.deviceID ?? UUID().uuidString
        if let legacy, topology == nil || authoritativeV6 {
            topology = TopologySnapshotMigration.refreshed(from: legacy, preserving: topology, currentDeviceID: current, currentDeviceName: Host.current().localizedName ?? "此 Mac")
        }
        var result = WorkspaceStore.Document(deviceID: current, topology: topology ?? TopologySnapshot())
        if let pilot { try importPilot(pilot, into: &result) }
        for i in result.topology.profiles.indices { result.topology.profiles[i].isCurrent = result.topology.profiles[i].id == current }
        if !result.topology.profiles.contains(where: { $0.id == current }) {
            let id = UUID()
            result.topology.nodes.append(.init(id: id, name: Host.current().localizedName ?? "此 Mac", roles: [.clientDevice]))
            result.topology.profiles.append(.init(id: current, nodeID: id, name: Host.current().localizedName ?? "此 Mac", isCurrent: true))
        }
        for connection in WorkspaceStore.project(result).connections where result.defaultPaths[connection.serverID] == nil {
            result.defaultPaths[connection.serverID] = connection.id
        }
        if !sources.isEmpty {
            let directory = paths.applicationSupport.appendingPathComponent("migration-backup-\(UUID().uuidString)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (i, url) in sources.enumerated() {
                let destination = directory.appendingPathComponent("\(i)-\(url.lastPathComponent)")
                try fm.copyItem(at: url, to: destination)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        return result
    }
    static func importPilot(_ pilot: WorkspaceStore.State, into result: inout WorkspaceStore.Document) throws {
        for key in pilot.keys {
            if let existing = result.topology.sshKeys.first(where: { $0.id == key.id }), existing.fingerprint != key.fingerprint { throw WorkspaceMigrationError.conflictingIdentity }
            if !result.topology.sshKeys.contains(where: { $0.id == key.id }) {
                result.topology.sshKeys.append(.init(id: key.id, deviceID: key.deviceID == pilot.deviceID ? result.deviceID : key.deviceID, kind: key.kind, publicKey: key.publicKey, fingerprint: key.fingerprint, privateKeyPath: key.privateKeyPath, isInAgent: key.isInAgent, origin: key.origin, isLocallyAvailable: key.isLocallyAvailable))
            }
        }
        for trust in pilot.trusts {
            let endpoint = try WorkspaceStore.ensureEndpoint(trust, in: &result.topology)
            if !result.topology.hostKeyTrusts.contains(where: { $0.endpointID == endpoint && $0.fingerprint == trust.key.fingerprint }) {
                result.topology.hostKeyTrusts.append(.init(id: UUID(), endpointID: endpoint, algorithm: trust.key.algorithm, fingerprint: trust.key.fingerprint, knownHostsLine: trust.key.knownHostsLine, firstConfirmedAt: trust.key.firstConfirmedAt))
            }
        }
        for c in pilot.connections {
            guard let node = UUID(uuidString: c.serverID), let id = UUID(uuidString: c.id), let port = UInt16(exactly: c.port), port > 0 else { throw WorkspaceError.storage }
            if let i = result.topology.nodes.firstIndex(where: { $0.id == node }) { result.topology.nodes[i].name = c.description }
            else { result.topology.nodes.append(.init(id: node, name: c.description, roles: [.sshHost])) }
            let endpoint = result.topology.activeEndpoints.first { $0.nodeID == node && $0.address == c.address && $0.port == port && $0.protocol == .ssh }
                ?? Endpoint(id: UUID(), nodeID: node, address: c.address, port: port, protocol: .ssh)
            if !result.topology.endpoints.contains(where: { $0.id == endpoint.id }) { result.topology.endpoints.append(endpoint) }
            let account = result.topology.activeAccounts.first { $0.nodeID == node && $0.username == c.account }
                ?? SSHAccount(id: UUID(), nodeID: node, username: c.account)
            if !result.topology.sshAccounts.contains(where: { $0.id == account.id }) { result.topology.sshAccounts.append(account) }
            guard !result.topology.sshConnectionProfiles.contains(where: { $0.id == id }) else { throw WorkspaceMigrationError.conflictingIdentity }
            result.topology.sshConnectionProfiles.append(.init(id: id, accountID: account.id, sshAlias: c.alias, routePolicy: .fixed(endpointID: endpoint.id)))
            result.pathKeys[id.uuidString] = c.keyID
            if pilot.defaultPaths?[c.serverID] == c.id || (pilot.defaultPaths == nil && result.defaultPaths[node.uuidString] == nil) { result.defaultPaths[node.uuidString] = id.uuidString }
            if let key = result.topology.sshKeys.first(where: { $0.id == c.keyID }) {
                let status = pilot.authorizations["\(c.serverID)|\(c.account)|\(c.keyID)"]
                let auth = SSHAuthorization(accountID: account.id, keyID: key.id, fingerprint: key.fingerprint, remoteComment: "", remoteState: status == "installed" ? .authorized : status == "absent" ? .revoked : .unknown)
                result.topology.authorizations.removeAll { $0.id == auth.id }; result.topology.authorizations.append(auth)
            }
            // Keep prior evidence as dated local evidence; never invent a fresh successful check.
            if let date = c.checkedAt {
                result.topology.accessVerifications.append(.init(accountID: account.id, deviceID: result.deviceID, profileID: id, endpointID: endpoint.id, status: c.verification == "verified" ? .authorized : .keyAuthenticationFailed, lastCheckedAt: date))
            }
        }
    }
}

enum WorkspaceMigrationError: LocalizedError {
    case pendingTransaction, conflictingIdentity
    var errorDescription: String? {
        switch self {
        case .pendingTransaction: "旧工作区存在未完成事务，请先用原版本恢复。原数据尚未修改。"
        case .conflictingIdentity: "两个工作区的身份记录冲突，未覆盖任何记录。"
        }
    }
}
