import Foundation
import KeyPortCore

/// SSH 路由提供者：AppModel 的既有 SSH 一期操作通过它获得用于
/// SSH 操作的 `ServerConnection` 路由视图。两种实现：
/// - `LegacySSHRouteProvider`：现状行为，直接使用 v5 对象（默认）。
/// - `V6CompatSSHRouteProvider`：从等价 v6 图做只读兼容投影；
///   blocking 冲突或无可用地址时 fail closed，不静默回退 legacy。
protocol SSHRouteProviding: Sendable {
    /// 返回可用于 SSH 操作的路由视图；fail closed 时返回 `nil`。
    func sshRoute(for identityID: UUID) -> ServerConnection?
    /// 路由被关闭时给出稳定失败（stage + objectID + code + recoveryAction），否则为 `nil`。
    func blockingFailure(for identityID: UUID) -> StableOperationFailure?
}

struct LegacySSHRouteProvider: SSHRouteProviding {
    let servers: [ServerConnection]

    func sshRoute(for identityID: UUID) -> ServerConnection? {
        servers.first { $0.id == identityID && !$0.isDeleted }
    }

    func blockingFailure(for identityID: UUID) -> StableOperationFailure? { nil }
}

struct V6CompatSSHRouteProvider: SSHRouteProviding {
    let projection: SSHCompatProjection.Result

    init(projection: SSHCompatProjection.Result) {
        self.projection = projection
    }

    /// pre-authority 运行期入口：把当前 v5 快照在内存中确定性组装为 v6 图再投影。
    /// 该组装是只读的，与切片 B 的持久化影子迁移互不依赖。
    init(servers: [ServerConnection]) {
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        self.init(projection: HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local))
    }

    func sshRoute(for identityID: UUID) -> ServerConnection? {
        projection.servers.first { $0.id == identityID }
    }

    func blockingFailure(for identityID: UUID) -> StableOperationFailure? {
        let objectID = identityID.uuidString.lowercased()
        if projection.blockedIdentityIDs.contains(identityID) {
            return StableOperationFailure(
                stage: .migration, objectID: objectID,
                code: .concurrentConflict, recoveryAction: .resolveConflict
            )
        }
        if projection.unavailableIdentityIDs.contains(identityID) {
            return StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .identityUnavailable, recoveryAction: .edit
            )
        }
        return nil
    }
}

/// v6 SSH 兼容适配层开关。默认关闭：旧 UI、旧写入路径与 legacy route 不变；
/// 回滚即删除该键（或置 false），AppModel 立即回到 legacy adapter。
enum SSHCompatFeatureFlags {
    static let v6SSHAdapterKey = "KeyPort.sshCompatAdapterV6"

    static func isV6SSHAdapterEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: v6SSHAdapterKey)
    }

    static func routeProvider(
        servers: [ServerConnection],
        defaults: UserDefaults = .standard
    ) -> any SSHRouteProviding {
        if isV6SSHAdapterEnabled(defaults: defaults) {
            return V6CompatSSHRouteProvider(servers: servers)
        }
        return LegacySSHRouteProvider(servers: servers)
    }
}
