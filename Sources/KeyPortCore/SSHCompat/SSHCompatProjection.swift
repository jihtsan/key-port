import Foundation

/// v6 <-> legacy SSH 路由的只读兼容投影（切片 C）。
///
/// 两个方向都是纯函数，不写 Keychain、SSH 派生文件、Cloud 或任何持久状态：
/// - `LegacySSHCompatAssembly` 把当前 v5 `ServerConnection` 数组确定性地组装为
///   承载 SSH 路由所需的最小 v6 图（Host/Address/Identity/Pin/KnownHostsLine），
///   供 pre-authority 期间 v6 适配器在内存中使用；它不是切片 B 的持久化影子迁移，
///   不产出 ledger/digest/staging。
/// - `HostV6SSHCompatProjection` 把 v6 图投影回 legacy `ServerConnection` 兼容视图，
///   保持 identity ID（= 原 `ServerConnection.id`）、Keychain account 定位、alias、
///   Host Key 来源行与授权引用不变。
public enum SSHCompatProjection {}

// MARK: - v5 -> v6 内存组装（只读、确定性）

public enum LegacySSHCompatAssembly {
    private static let compatNamespace = HostV6.StableID.uuidV5(
        namespace: UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!,
        name: "app.keyport/ssh-compat"
    )

    private static func mutationID(entity: String, id: String) -> UUID {
        HostV6.StableID.uuidV5(namespace: compatNamespace, name: "mutation|\(entity)|\(id)")
    }

    private static func stamp(for server: ServerConnection) -> HostV6.SyncStamp {
        let dimension = "legacy-v1/server/\(server.id.uuidString.lowercased())"
        return HostV6.SyncStamp(
            vector: [dimension: UInt64(max(1, server.version))],
            mutationID: mutationID(entity: "sshIdentity", id: server.id.uuidString.lowercased()),
            updatedAt: server.updatedAt
        )
    }

    private static func joinedStamp(
        contributors: [ServerConnection],
        entity: String,
        id: String
    ) -> HostV6.SyncStamp {
        var vector: [String: UInt64] = [:]
        for server in contributors {
            let dimension = "legacy-v1/server/\(server.id.uuidString.lowercased())"
            vector[dimension] = max(vector[dimension, default: 0], UInt64(max(1, server.version)))
        }
        return HostV6.SyncStamp(
            vector: vector,
            mutationID: mutationID(entity: entity, id: id),
            updatedAt: contributors.map(\.updatedAt).max() ?? .distantPast
        )
    }

    /// 代表 contributor：同 endpoint 共享字段（Host 名称/分组、地址原字面值等）
    /// 取 createdAt 最早者，平局取稳定 ID 较小者；与现有 UI 分组的代表规则一致。
    private static func representative(of contributors: [ServerConnection]) -> ServerConnection {
        contributors.min {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }!
    }

    public struct Assembly: Hashable, Sendable {
        public var graph: HostV6.SyncedGraph
        public var local: HostV6.LocalState
    }

    /// 把 v5 servers（含墓碑）组装为 SSH 路由口径的 v6 图与 local overlay。
    /// 相同输入必然产生字节等价的输出（确定性 ID 与排序）。
    public static func assemble(servers: [ServerConnection]) -> Assembly {
        var graph = HostV6.SyncedGraph()
        var local = HostV6.LocalState()

        let grouped = Dictionary(grouping: servers) {
            HostV6.StableID.legacyEndpointKey(host: $0.host, port: UInt16(clamping: $0.port))
        }

        for endpointKey in grouped.keys.sorted() {
            let contributors = grouped[endpointKey]!.sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
            let representative = representative(of: contributors)
            let activeContributors = contributors.filter { !$0.isDeleted }
            let hostID = HostV6.StableID.host(legacyEndpointKey: endpointKey)
            let addressID = HostV6.StableID.address(hostID: hostID, endpointKey: endpointKey)
            let hostStamp = joinedStamp(contributors: contributors, entity: "host", id: hostID.uuidString.lowercased())
            let allDeleted = activeContributors.isEmpty
            let tombstoneAt = allDeleted ? contributors.map(\.updatedAt).max() : nil

            graph.hosts.append(HostV6.Host(
                id: hostID,
                name: representative.name,
                group: representative.group,
                machineConfiguration: representative.machineConfiguration,
                fixedAddressID: nil,
                createdAt: contributors.map(\.createdAt).min() ?? representative.createdAt,
                stamp: hostStamp,
                deletedAt: tombstoneAt
            ))

            let normalizedHost = representative.host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            graph.addresses.append(HostV6.AccessAddress(
                id: addressID,
                hostID: hostID,
                normalizedHost: normalizedHost,
                sshPort: UInt16(clamping: representative.port),
                originalLabel: representative.host,
                source: .legacy,
                sortOrder: 0,
                stamp: joinedStamp(contributors: contributors, entity: "address", id: addressID.uuidString.lowercased()),
                deletedAt: tombstoneAt
            ))

            // Pin/KnownHostsLine：按 (algorithm, fingerprint) 聚合 Pin，来源行逐字保留，
            // 同 identity 内字节相同 rawLine 分配从 0 开始的 duplicateOrdinal（架构 5.1/6.3.6）。
            var pinsByKey: [String: HostV6.HostKeyPin] = [:]
            var pinContributors: [UUID: [ServerConnection]] = [:]
            var lineOrdinals: [String: UInt32] = [:]
            for server in contributors {
                for record in server.confirmedHostKeys {
                    let pinID = HostV6.StableID.hostKeyPin(
                        addressID: addressID,
                        algorithm: record.algorithm,
                        fingerprint: record.fingerprint
                    )
                    pinContributors[pinID, default: []].append(server)
                    if pinsByKey[pinID.uuidString.lowercased()] == nil {
                        pinsByKey[pinID.uuidString.lowercased()] = HostV6.HostKeyPin(
                            id: pinID,
                            hostID: hostID,
                            addressID: addressID,
                            algorithm: record.algorithm,
                            fingerprint: record.fingerprint,
                            state: .confirmed,
                            firstConfirmedAt: record.firstConfirmedAt,
                            lastSeenAt: record.lastSeenAt,
                            replacedAt: nil,
                            stamp: HostV6.SyncStamp(vector: [:], mutationID: mutationID(entity: "hostKeyPin", id: pinID.uuidString.lowercased()), updatedAt: record.lastSeenAt),
                            deletedAt: nil
                        )
                    } else {
                        let key = pinID.uuidString.lowercased()
                        var existing = pinsByKey[key]!
                        existing.lastSeenAt = max(existing.lastSeenAt, record.lastSeenAt)
                        pinsByKey[key] = existing
                    }

                    let ordinalKey = "\(pinID.uuidString.lowercased())|\(server.id.uuidString.lowercased())|\(record.knownHostsLine)"
                    let ordinal = lineOrdinals[ordinalKey, default: 0]
                    lineOrdinals[ordinalKey] = ordinal + 1
                    let lineID = HostV6.StableID.knownHostsLine(
                        pinID: pinID,
                        sourceID: server.id,
                        rawLine: record.knownHostsLine,
                        duplicateOrdinal: ordinal
                    )
                    graph.knownHostsLines.append(HostV6.KnownHostsLine(
                        id: lineID,
                        pinID: pinID,
                        rawLine: record.knownHostsLine,
                        source: .legacyIdentity(server.id),
                        duplicateOrdinal: ordinal,
                        stamp: stamp(for: server),
                        deletedAt: server.isDeleted ? server.updatedAt : nil
                    ))
                }
            }
            for pinID in pinContributors.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let pinContributorsForPin = pinContributors[pinID]!
                let pinKey = pinID.uuidString.lowercased()
                var pin = pinsByKey[pinKey]!
                let uniqueContributors = Dictionary(grouping: pinContributorsForPin, by: \.id).map(\.value[0])
                pin.stamp = joinedStamp(contributors: uniqueContributors, entity: "hostKeyPin", id: pinKey)
                // Pin 在至少一条来源 line active 时保持 active（架构 6.3.7）。
                let pinLines = graph.knownHostsLines.filter { $0.pinID == pin.id }
                pin.deletedAt = pinLines.allSatisfy { $0.deletedAt != nil }
                    ? pinLines.map(\.stamp.updatedAt).max()
                    : nil
                graph.hostKeyPins.append(pin)
            }

            for server in contributors {
                graph.identities.append(HostV6.SSHIdentity(
                    id: server.id,
                    hostID: hostID,
                    username: server.username,
                    alias: server.alias,
                    preferredAddressID: nil,
                    createdAt: server.createdAt,
                    stamp: stamp(for: server),
                    deletedAt: server.isDeleted ? server.updatedAt : nil
                ))
                local.identityStates.append(HostV6.LocalSSHIdentityState(
                    sshIdentityID: server.id,
                    status: server.status,
                    statusDetail: server.statusDetail,
                    lastCheckedAt: server.lastCheckedAt,
                    passwordCheck: server.passwordCheck,
                    keyCheck: server.keyCheck,
                    machineConfigurationRefreshAttemptedAt: server.machineConfigurationRefreshAttemptedAt
                ))
                if !server.notes.isEmpty {
                    local.hostAnnotations.append(HostV6.LocalHostAnnotation(
                        hostID: hostID,
                        legacyIdentityID: server.id,
                        notes: server.notes
                    ))
                }
            }
        }

        return Assembly(graph: graph, local: local)
    }
}

// MARK: - v6 -> legacy 只读兼容投影

public extension SSHCompatProjection {
    struct Result: Hashable, Sendable {
        /// 已组装路由的活跃 identity 兼容视图（含被信任门禁降级的身份），按 (alias, id) 排序。
        public var servers: [ServerConnection]
        /// 存在未解决 blocking MergeReview 的 identity：fail closed，不产生任何 SSH 路由。
        public var blockedIdentityIDs: [UUID]
        /// 没有可用活跃地址的 identity（架构 5.3.4）：不产生 SSH 路由。
        public var unavailableIdentityIDs: [UUID]
        /// known_hosts 派生文件内容：所有活跃来源行的 sorted(unique(rawLine))。
        public var derivedKnownHostsLines: [String]

        public init(
            servers: [ServerConnection],
            blockedIdentityIDs: [UUID],
            unavailableIdentityIDs: [UUID],
            derivedKnownHostsLines: [String]
        ) {
            self.servers = servers
            self.blockedIdentityIDs = blockedIdentityIDs
            self.unavailableIdentityIDs = unavailableIdentityIDs
            self.derivedKnownHostsLines = derivedKnownHostsLines
        }
    }
}

public enum HostV6SSHCompatProjection {
    /// 把 v6 图投影为 legacy `ServerConnection` 兼容视图。只读：
    /// 输入输出都是值类型，post-authority 也只允许这种只读 compat view。
    public static func project(graph: HostV6.SyncedGraph, local: HostV6.LocalState) -> SSHCompatProjection.Result {
        let activeHosts = Dictionary(
            graph.hosts.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeAddresses = Dictionary(
            graph.addresses.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let identityStates = Dictionary(
            local.identityStates.map { ($0.sshIdentityID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let annotations = Dictionary(
            local.hostAnnotations.map { ($0.id, $0.notes) },
            uniquingKeysWith: { first, _ in first }
        )
        let blockingReviews = graph.mergeReviews.filter { $0.isBlocking && !$0.isResolved }

        func hasBlockingReview(_ type: HostV6.EntityType, id: String) -> Bool {
            blockingReviews.contains { $0.entityType == type && $0.entityID == id }
        }

        var servers: [ServerConnection] = []
        var blocked: [UUID] = []
        var unavailable: [UUID] = []

        let activeIdentities = graph.identities
            .filter { $0.deletedAt == nil }
            .sorted { ($0.alias, $0.id.uuidString) < ($1.alias, $1.id.uuidString) }

        for identity in activeIdentities {
            guard let host = activeHosts[identity.hostID] else {
                unavailable.append(identity.id)
                continue
            }

            // 地址解析：身份级首选 > Host 级固定 > 活跃地址稳定 ID 升序（架构 6.5）。
            // 固定引用跨 Host、已删除或悬空时不降级到低优先级值，直接判不可用。
            let hostAddresses = graph.addresses
                .filter { $0.hostID == host.id && $0.deletedAt == nil && $0.sshPort > 0 }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            var selected: HostV6.AccessAddress?
            var invalidFixedReference = false
            if let preferredID = identity.preferredAddressID {
                if let address = activeAddresses[preferredID], address.hostID == host.id, address.sshPort > 0 {
                    selected = address
                } else {
                    invalidFixedReference = true
                }
            } else if let fixedID = host.fixedAddressID {
                if let address = activeAddresses[fixedID], address.hostID == host.id, address.sshPort > 0 {
                    selected = address
                } else {
                    invalidFixedReference = true
                }
            } else {
                selected = hostAddresses.first
            }
            guard !invalidFixedReference, let address = selected else {
                unavailable.append(identity.id)
                continue
            }

            let pins = graph.hostKeyPins.filter { $0.hostID == host.id && $0.deletedAt == nil }
            let addressPins = pins.filter { $0.addressID == address.id }

            // 未解决 blocking MergeReview 命中身份/Host/地址/Pin/来源行时 fail closed。
            let reviewedLines = graph.knownHostsLines.filter { line in
                addressPins.contains { $0.id == line.pinID }
            }
            let isBlocked =
                hasBlockingReview(.sshIdentity, id: identity.id.uuidString.lowercased()) ||
                hasBlockingReview(.host, id: host.id.uuidString.lowercased()) ||
                hasBlockingReview(.address, id: address.id.uuidString.lowercased()) ||
                addressPins.contains { hasBlockingReview(.hostKeyPin, id: $0.id.uuidString.lowercased()) } ||
                reviewedLines.contains { hasBlockingReview(.knownHostsLine, id: $0.id.uuidString.lowercased()) }
            if isBlocked {
                blocked.append(identity.id)
                continue
            }

            // 信任判断只看 Pin（ADR-5）；confirmed Pin 的活跃来源行映射回 HostKeyRecord。
            let confirmedPins = addressPins.filter { $0.state == .confirmed }
            let confirmedHostKeys: [HostKeyRecord] = confirmedPins.flatMap { pin in
                graph.knownHostsLines
                    .filter { $0.pinID == pin.id && $0.deletedAt == nil }
                    .map { line in
                        HostKeyRecord(
                            algorithm: pin.algorithm,
                            fingerprint: pin.fingerprint,
                            knownHostsLine: line.rawLine,
                            firstConfirmedAt: pin.firstConfirmedAt,
                            lastSeenAt: pin.lastSeenAt
                        )
                    }
            }
            .sorted { ($0.algorithm, $0.knownHostsLine, $0.fingerprint) < ($1.algorithm, $1.knownHostsLine, $1.fingerprint) }

            let stored = identityStates[identity.id]
            var status = stored?.status ?? .hostKeyPending
            var statusDetail = stored?.statusDetail
            // Host 级 fail closed：任一 pendingReview Pin 阻止该 Host 所有 SSH 动作（架构 5.3.5）；
            // 可达性、SSID、Tailscale 均不参与该判断，无法绕过。
            if pins.contains(where: { $0.state == .pendingReview }) {
                status = .hostKeyMismatch
                statusDetail = "主机密钥存在待确认冲突，SSH 操作已被阻止。"
            } else if confirmedHostKeys.isEmpty {
                status = .hostKeyPending
                statusDetail = statusDetail ?? "身份验证前，请核对主机密钥指纹。"
            }

            let annotationKey = "\(host.id.uuidString.lowercased()):\(identity.id.uuidString.lowercased())"
            servers.append(ServerConnection(
                id: identity.id,
                name: host.name,
                host: address.originalLabel.isEmpty ? address.normalizedHost : address.originalLabel,
                port: Int(address.sshPort),
                username: identity.username,
                alias: identity.alias,
                group: host.group,
                notes: annotations[annotationKey] ?? "",
                confirmedHostKeys: confirmedHostKeys,
                status: status,
                statusDetail: statusDetail,
                lastCheckedAt: stored?.lastCheckedAt,
                passwordCheck: stored?.passwordCheck,
                keyCheck: stored?.keyCheck,
                machineConfiguration: host.machineConfiguration,
                machineConfigurationRefreshAttemptedAt: stored?.machineConfigurationRefreshAttemptedAt,
                createdAt: identity.createdAt,
                updatedAt: identity.stamp.updatedAt,
                isDeleted: false,
                version: 1
            ))
        }

        return SSHCompatProjection.Result(
            servers: servers,
            blockedIdentityIDs: blocked,
            unavailableIdentityIDs: unavailable,
            derivedKnownHostsLines: HostV6.KnownHostsLine.derivedFileLines(from: graph.knownHostsLines)
        )
    }

    /// Keychain 定位规则：account = identity ID 的小写 UUID 字符串，
    /// 与 legacy `serverID.uuidString.lowercased()` 完全一致。
    public static func keychainAccount(for identityID: UUID) -> String {
        identityID.uuidString.lowercased()
    }
}
