import Foundation
import KeyPortCore

extension WorkspaceStore {
    static func invalidatesAccess(_ old: Document, _ next: Document) -> Bool {
        let a = old.topology, b = next.topology
        if old.pathKeys.contains(where: { next.pathKeys[$0.key] != $0.value }) { return true }
        for key in a.sshKeys where key.deviceID == old.deviceID && key.privateKeyPath != nil {
            guard b.sshKeys.contains(where: { $0.id == key.id && $0.fingerprint == key.fingerprint && $0.privateKeyPath == key.privateKeyPath && $0.isLocallyAvailable == key.isLocallyAvailable }) else { return true }
        }
        for endpoint in a.activeEndpoints where endpoint.protocol == .ssh {
            guard b.activeEndpoints.contains(where: { $0.id == endpoint.id && $0.nodeID == endpoint.nodeID && $0.address == endpoint.address && $0.port == endpoint.port && $0.protocol == endpoint.protocol }) else { return true }
        }
        for account in a.activeAccounts {
            guard b.activeAccounts.contains(where: { $0.id == account.id && $0.nodeID == account.nodeID && $0.username == account.username }), b.activeNodes.contains(where: { $0.id == account.nodeID }) else { return true }
        }
        for trust in a.hostKeyTrusts where !trust.isDeleted && trust.state == .confirmed {
            guard b.hostKeyTrusts.contains(where: { !$0.isDeleted && $0.state == .confirmed && $0.endpointID == trust.endpointID && $0.algorithm == trust.algorithm && $0.fingerprint == trust.fingerprint }) else { return true }
        }
        for auth in a.authorizations where !auth.isDeleted && auth.remoteState == .authorized && auth.relationState == .active {
            guard b.authorizations.contains(where: { !$0.isDeleted && $0.accountID == auth.accountID && $0.fingerprint == auth.fingerprint && $0.remoteState == .authorized && $0.relationState == .active }) else { return true }
        }
        for evidence in a.accessVerifications where evidence.deviceID == old.deviceID && evidence.status == .authorized {
            guard b.accessVerifications.contains(where: { $0.id == evidence.id && $0.status == .authorized && $0.policyEvidenceBinding == evidence.policyEvidenceBinding }) else { return true }
        }
        for profile in a.activeConnectionProfiles {
            guard let p = b.activeConnectionProfiles.first(where: { $0.id == profile.id }), p.policyConflict != true else { return true }
            let before = profile.routePolicy.fixedEndpointID.map { [$0] } ?? profile.candidateEndpointIDs
            let after = p.routePolicy.fixedEndpointID.map { [$0] } ?? p.candidateEndpointIDs
            if !Set(before).isSubset(of: Set(after)) || p.transportPreference != profile.transportPreference { return true }
        }
        return false
    }
    func repairPolicyInstallation() throws {
        try installation.install(entries: [], knownHosts: paths.knownHosts)
        try policyInstallation.quarantineDependencies()
        try synchronizeAliases()
    }
    func testConnectionPolicy(_ connection: Connection) async throws {
        guard !serverOperationInProgress else { throw WorkspaceError.configuration }
        _ = try command(for: connection)
        setServerOperationInProgress(true); defer { setServerOperationInProgress(false) }
        let result = try await ProcessExecutor().execute(.init(executable: "/usr/bin/ssh", arguments: ["-F", installation.userConfig.path, "-o", "BatchMode=yes", "-T", connection.alias, "true"], limits: .init(timeout: 30, maximumStdoutBytes: 512 * 1024, maximumStderrBytes: 512 * 1024, maximumCombinedOutputBytes: 512 * 1024)))
        refreshSelectionEvents()
        guard result.succeeded else { throw SSHServiceError.operationFailed("连接策略测试未通过；请检查地址、主机身份或账户授权。不会因身份或登录失败而换地址。") }
    }
    func policyEndpoints(_ id: UUID) -> [UUID] {
        guard let profile = topology.activeConnectionProfiles.first(where: { $0.id == id }) else { return [] }
        var seen = Set<UUID>()
        var ids = SSHPolicyUpgrade.group(for: profile, in: topology).flatMap { $0.candidateEndpointIDs.isEmpty ? [$0.routePolicy.fixedEndpointID].compactMap { $0 } : $0.candidateEndpointIDs }.filter { seen.insert($0).inserted }
        if profile.policyVersion == nil {
            let account = topology.activeAccounts.first { $0.id == profile.accountID }
            let defaultID = account.flatMap { document.defaultPaths[$0.nodeID.uuidString] }
            let current = state.connections.first { $0.id == defaultID && $0.account == account?.username && $0.alias == profile.sshAlias }
            if let fixed = current?.endpointID ?? profile.routePolicy.fixedEndpointID { ids = [fixed] + ids.filter { $0 != fixed } }
        }
        return ids
    }

    @discardableResult func updatePolicy(profileID: UUID, endpoints: [UUID], automatic: Bool, ports: [UUID: UInt16] = [:]) throws -> [UUID] {
        var next = document
        guard let profile = next.topology.activeConnectionProfiles.first(where: { $0.id == profileID }) else { throw WorkspaceError.configuration }
        let group = SSHPolicyUpgrade.group(for: profile, in: topology)
        let keys = Set(group.compactMap { next.pathKeys[$0.id.uuidString] })
        guard keys.count <= 1 else { throw WorkspaceError.configuration }
        var requested = endpoints
        for (index, id) in endpoints.enumerated() {
            guard let port = ports[id], let old = next.topology.activeEndpoints.first(where: { $0.id == id }), port != old.port else { continue }
            guard port > 0 else { throw WorkspaceError.configuration }
            let replacement = next.topology.activeEndpoints.first { $0.nodeID == old.nodeID && $0.address == old.address && $0.port == port && $0.protocol == .ssh && $0.serviceID == nil }
                ?? Endpoint(id: UUID(), nodeID: old.nodeID, address: old.address, port: port, protocol: .ssh, networkScope: old.networkScope, source: old.source)
            if !next.topology.endpoints.contains(where: { $0.id == replacement.id }) { next.topology.endpoints.append(replacement) }
            requested[index] = replacement.id
        }
        let canonical = try SSHPolicyUpgrade.apply(profileID: profileID, endpointIDs: requested, automatic: automatic, to: &next.topology)
        next.pathKeys[canonical.uuidString] = keys.first
        // Bind existing local success only when its endpoint trust and selected account key still exist.
        for i in next.topology.accessVerifications.indices {
            let v = next.topology.accessVerifications[i]
            guard v.profileID == canonical, v.deviceID == state.deviceID, v.status == .authorized, v.policyEvidenceBinding == nil,
                  let source = group.first(where: { $0.policyVersion == nil && $0.routePolicy.fixedEndpointID == v.endpointID }),
                  let key = next.topology.sshKeys.first(where: { $0.id == document.pathKeys[source.id.uuidString] && $0.deviceID == state.deviceID }),
                  let endpoint = next.topology.activeEndpoints.first(where: { $0.id == v.endpointID }),
                  let trust = next.topology.hostKeyTrusts.first(where: { !$0.isDeleted && $0.state == .confirmed && $0.endpointID == endpoint.id && $0.algorithm == "ssh-ed25519" }) else { continue }
            next.topology.accessVerifications[i].policyEvidenceBinding = SSHPolicyCompiler.evidence(endpoint: endpoint, fingerprint: trust.fingerprint, keyFingerprint: key.fingerprint, username: next.topology.activeAccounts.first { $0.id == profile.accountID }!.username)
        }
        if let account = next.topology.activeAccounts.first(where: { $0.id == profile.accountID }), let first = requested.first {
            next.defaultPaths[account.nodeID.uuidString] = SSHPolicyUpgrade.pathID(profileID: canonical, endpointID: first)
        }
        if next.preferredProfilesByAccountID == nil { next.preferredProfilesByAccountID = [:] }
        next.preferredProfilesByAccountID?[profile.accountID.uuidString] = canonical
        next.version = 2
        try commit(next)
        if let first = requested.first { workspace.select(.path(SSHPolicyUpgrade.pathID(profileID: canonical, endpointID: first))) }
        return requested
    }
    func authorizationConnection(accountID: UUID) throws -> Connection {
        let profiles = topology.activeConnectionProfiles.filter { $0.accountID == accountID }
        let selected = workspace.selectedPath.flatMap { path in state.connections.first { $0.id == path.id } }?.profileID
        let profile = profiles.first { $0.id == selected }
            ?? profiles.first { $0.id == document.preferredProfilesByAccountID?[accountID.uuidString] }
            ?? (profiles.count == 1 ? profiles.first : nil)
        guard let profile else { throw WorkspaceError.configuration }
        if profile.policyVersion == 1 {
            let plan = try SSHPolicyCompiler.compile(profile: profile, topology: topology, deviceID: state.deviceID, keyID: document.pathKeys[profile.id.uuidString])
            guard let endpoint = plan.endpoints.first, let c = state.connections.first(where: { $0.profileID == profile.id && $0.endpointID == endpoint.id }) else { throw WorkspaceError.configuration }
            return c
        }
        guard let c = state.connections.first(where: { $0.profileID == profile.id && $0.verification == "verified" }) else { throw WorkspaceError.configuration }
        return c
    }
    func legacyDiagnosticConnections() -> [Connection] {
        var result: [Connection] = []
        let rows = state.connections
        for profile in topology.activeConnectionProfiles where profile.policyConflict != true {
            var bindings = profile.legacyEndpointIDs
            for id in profile.supersededProfileIDs where bindings[id.uuidString] == nil {
                bindings[id.uuidString] = topology.sshConnectionProfiles.first { $0.id == id }?.routePolicy.fixedEndpointID
            }
            for (oldID, endpoint) in bindings {
                guard var row = rows.first(where: { $0.profileID == profile.id && $0.endpointID == endpoint && $0.verification == "verified" }) else { continue }
                row.id = oldID
                result.append(row)
            }
        }
        return result
    }
    func invalidateOldPolicyFiles(except generation: URL) throws {
        let root = policyInstallation.root.appendingPathComponent("generations")
        if FileManager.default.fileExists(atPath: root.path) {
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.standardizedFileURL.path != generation.standardizedFileURL.path {
                // Only hash-named generations are owned by this installer.
                guard url.lastPathComponent.count == 64, url.lastPathComponent.allSatisfy({ $0.isHexDigit }) else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
        for url in try FileManager.default.contentsOfDirectory(at: paths.keyPortDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("path-") && ["conf", "known_hosts"].contains(url.pathExtension) {
            guard UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(5))) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
