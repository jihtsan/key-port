import Foundation
import KeyPortCore

extension WorkspaceStore {
    /// Target identity is account plus fingerprint; the authenticating key may belong to this Mac.
    func refreshAuthorization(_ authorization: SSHAuthorization, revoke: Bool, executor: any ProcessExecuting = ProcessExecutor()) async throws {
        guard let account = topology.activeAccounts.first(where: { $0.id == authorization.accountID }),
              let path = state.connections.first(where: { $0.serverID == account.nodeID.uuidString && $0.account == account.username && !$0.keyID.isEmpty }),
              let identity = state.keys.first(where: { $0.id == path.keyID && $0.deviceID == state.deviceID }), identity.privateKeyPath != nil,
              let target = state.keys.first(where: { $0.id == authorization.keyID && $0.fingerprint == authorization.fingerprint }),
              let parsed = PublicKeyParser.parse(target.publicKey), parsed.fingerprint == authorization.fingerprint else { throw WorkspaceError.missingKey }
        if revoke { try await LocalAuthenticationService().authorize(reason: "撤销指定账户的 SSH 公钥授权") }
        let adapter = OpenSSHFirstAccessAdapter(store: self, expectedServerID: path.serverID, executor: executor)
        defer { adapter.cancel() }
        let observed = try await adapter.inspectHost(address: path.address, port: String(path.port))
        guard !observed.needsConfirmation else { throw SSHServiceError.hostKeyNotConfirmed }
        let route = ServerConnection(name: path.description, host: path.address, port: path.port, username: path.account, alias: path.alias,
            confirmedHostKeys: state.trusts.filter { $0.serverID == path.serverID && $0.address == path.address && $0.port == path.port }.map(\.key))
        let session = try await TrustedSSHSession.establish(route: route, observedHostKeys: route.confirmedHostKeys, identity: identity, executor: executor, paths: paths)
        if revoke {
            try record(.unknown, serverID: path.serverID, account: path.account, keyID: target.id)
            let result = try await session.executeRaw(.revokeAuthorizedKey(keyBlob: parsed.blob))
            guard result.ending == .exited(0) else { throw SSHServiceError.operationFailed("撤销未完成，请重新核对远端授权。") }
            try record(.absent, serverID: path.serverID, account: path.account, keyID: target.id)
        } else {
            let result = try await session.executeRaw(.readAuthorizedKeys)
            guard result.ending == .exited(0) else { throw SSHServiceError.operationFailed("无法读取远端授权，已有记录未改为成功。") }
            let keys = AuthorizedKeysParser.parse(String(decoding: result.stdout, as: UTF8.self))
            let present = keys.contains { $0.key?.fingerprint == parsed.fingerprint }
            try record(present ? .installed : .absent, serverID: path.serverID, account: path.account, keyID: target.id)
        }
    }
}
