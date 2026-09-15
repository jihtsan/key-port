import Foundation
import KeyPortCore

extension WorkspaceStore {
    func serverAuthorizations(_ serverID: String) -> [SSHAuthorization] {
        let accounts = Set(topology.sshAccounts.filter { $0.nodeID.uuidString == serverID }.map(\.id))
        return topology.authorizations.filter { accounts.contains($0.accountID) && !$0.isDeleted }
            .sorted { $0.id < $1.id }
    }

    /// The injected operation represents one remote account batch, including write-back verification.
    func revokeServer(_ serverID: String, disconnect: Bool,
                      revoke: (([SSHAuthorization]) async throws -> Void)? = nil) async throws {
        guard !serverOperationInProgress, syncState != .syncing else {
            throw SSHServiceError.operationFailed("正在处理其他操作，请稍后重试。")
        }
        guard let node = topology.activeNodes.first(where: { $0.id.uuidString == serverID }) else { throw WorkspaceError.storage }
        if disconnect && topology.profiles.contains(where: { $0.nodeID == node.id && !$0.isRevoked }) {
            throw SSHServiceError.operationFailed("该机器也是工作区设备，不能通过服务器解除操作删除设备档案。")
        }
        setServerOperationInProgress(true)
        defer { setServerOperationInProgress(false) }
        let pending = serverAuthorizations(serverID).filter { $0.remoteState != .revoked }
        if !pending.isEmpty && revoke == nil {
            try await LocalAuthenticationService().authorize(reason: disconnect ? "撤销服务器授权并解除服务器" : "撤销服务器的 SSH 公钥授权")
        }
        for accountID in Set(pending.map(\.accountID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            let batch = pending.filter { $0.accountID == accountID }
            do {
                try Task.checkCancellation()
                if let revoke { try await revoke(batch) }
                else { try await revokeAccountBatch(batch, serverID: serverID) }
                // Persist each completed account so a later failure can be retried safely.
                var next = document
                for i in next.topology.authorizations.indices where batch.contains(where: { $0.id == next.topology.authorizations[i].id }) {
                    next.topology.authorizations[i].remoteState = .revoked
                    next.topology.authorizations[i].updatedAt = Date()
                }
                next.topology.accessVerifications.removeAll { $0.accountID == accountID }
                try commit(next)
            } catch {
                let username = topology.sshAccounts.first { $0.id == accountID }?.username ?? "账户"
                throw SSHServiceError.operationFailed("\(username) 撤销未完成：\(error.localizedDescription) 服务器记录已保留；已成功撤销的账户不会恢复授权。")
            }
        }
        guard serverAuthorizations(serverID).allSatisfy({ $0.remoteState == .revoked }) else {
            throw SSHServiceError.operationFailed("授权范围已变化，请重新确认后重试。服务器记录已保留。")
        }
        if disconnect { try removeRevokedServer(node.id) }
        else { try synchronizeAliases() }
    }

    private func revokeAccountBatch(_ batch: [SSHAuthorization], serverID: String) async throws {
        guard let accountID = batch.first?.accountID,
              let account = topology.sshAccounts.first(where: { $0.id == accountID }),
              let path = state.connections.first(where: { $0.serverID == serverID && $0.account == account.username && !$0.keyID.isEmpty }),
              let identity = state.keys.first(where: { $0.id == path.keyID && $0.deviceID == state.deviceID }), identity.privateKeyPath != nil else {
            throw SSHServiceError.operationFailed("缺少可用 SSH 路径或本机密钥，请先为该账户恢复连接路径。")
        }
        let blobs = try batch.map { authorization -> String in
            guard let key = state.keys.first(where: { $0.id == authorization.keyID && $0.fingerprint == authorization.fingerprint }),
                  let parsed = PublicKeyParser.parse(key.publicKey), parsed.fingerprint == authorization.fingerprint else { throw WorkspaceError.missingKey }
            return parsed.blob
        }
        let adapter = OpenSSHFirstAccessAdapter(store: self, expectedServerID: serverID)
        defer { adapter.cancel() }
        let observed = try await adapter.inspectHost(address: path.address, port: String(path.port))
        guard !observed.needsConfirmation else { throw SSHServiceError.hostKeyNotConfirmed }
        let route = ServerConnection(name: path.description, host: path.address, port: path.port, username: path.account, alias: path.alias,
            confirmedHostKeys: state.trusts.filter { $0.serverID == serverID && $0.address == path.address && $0.port == path.port }.map(\.key))
        let session = try await TrustedSSHSession.establish(route: route, observedHostKeys: route.confirmedHostKeys, identity: identity, executor: ProcessExecutor(), paths: paths)
        var next = document
        for i in next.topology.authorizations.indices where batch.contains(where: { $0.id == next.topology.authorizations[i].id }) {
            next.topology.authorizations[i].remoteState = .unknown
            next.topology.authorizations[i].updatedAt = Date()
        }
        next.topology.accessVerifications.removeAll { $0.accountID == accountID }
        try commit(next)
        // All keys are removed in one SSH invocation, even when one is the login key.
        _ = try await session.execute(.revokeAuthorizedKeys(keyBlobs: blobs))
    }

    private func removeRevokedServer(_ nodeID: UUID) throws {
        var next = document
        let accounts = Set(next.topology.sshAccounts.filter { $0.nodeID == nodeID }.map(\.id))
        let endpoints = Set(next.topology.endpoints.filter { $0.nodeID == nodeID }.map(\.id))
        let profiles = Set(next.topology.sshConnectionProfiles.filter { accounts.contains($0.accountID) }.map { $0.id.uuidString })
        for i in next.topology.nodes.indices where next.topology.nodes[i].id == nodeID {
            next.topology.nodes[i].isDeleted = true; next.topology.nodes[i].updatedAt = Date()
        }
        for i in next.topology.sshAccounts.indices where accounts.contains(next.topology.sshAccounts[i].id) {
            next.topology.sshAccounts[i].isDeleted = true; next.topology.sshAccounts[i].updatedAt = Date(); next.topology.sshAccounts[i].version += 1
        }
        for i in next.topology.sshConnectionProfiles.indices where profiles.contains(next.topology.sshConnectionProfiles[i].id.uuidString) {
            next.topology.sshConnectionProfiles[i].isDeleted = true; next.topology.sshConnectionProfiles[i].updatedAt = Date(); next.topology.sshConnectionProfiles[i].version += 1
        }
        for i in next.topology.endpoints.indices where endpoints.contains(next.topology.endpoints[i].id) { next.topology.endpoints[i].isDeleted = true }
        for i in next.topology.services.indices where next.topology.services[i].nodeID == nodeID { next.topology.services[i].isDeleted = true }
        for i in next.topology.hostKeyTrusts.indices where endpoints.contains(next.topology.hostKeyTrusts[i].endpointID) {
            next.topology.hostKeyTrusts[i].isDeleted = true; next.topology.hostKeyTrusts[i].lastSeenAt = Date()
        }
        for i in next.topology.authorizations.indices where accounts.contains(next.topology.authorizations[i].accountID) {
            next.topology.authorizations[i].isDeleted = true; next.topology.authorizations[i].updatedAt = Date()
        }
        let tailscaleIDs = Set(next.topology.tailscaleNodes.filter { $0.keyPortNodeID == nodeID }.map(\.id))
        for i in next.topology.tailscaleNodes.indices where next.topology.tailscaleNodes[i].keyPortNodeID == nodeID {
            next.topology.tailscaleNodes[i].isDeleted = true; next.topology.tailscaleNodes[i].updatedAt = Date()
        }
        next.topology.nodeAssociations.removeAll { $0.serverID == nodeID }
        next.topology.tailscaleObservations.removeAll { tailscaleIDs.contains($0.identityID) }
        next.topology.accessVerifications.removeAll { accounts.contains($0.accountID) }
        next.topology.reachabilityObservations.removeAll { endpoints.contains($0.endpointID) }
        next.defaultPaths.removeValue(forKey: nodeID.uuidString)
        next.pathKeys = next.pathKeys.filter { !profiles.contains($0.key) }
        try commit(next)
        try synchronizeAliases()
    }
}
