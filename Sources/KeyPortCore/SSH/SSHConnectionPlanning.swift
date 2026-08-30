import Foundation

public enum SSHConnectionTransportPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case direct
    case tailscaleCLI
}

public enum SSHConnectionTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case tailscaleCLI
}

public enum SSHConnectionTransportResolver {
    public static func resolve(
        preference: SSHConnectionTransportPreference,
        networkScope: NetworkScope?
    ) -> SSHConnectionTransport {
        switch preference {
        case .automatic:
            networkScope == .tailnet ? .tailscaleCLI : .direct
        case .direct:
            .direct
        case .tailscaleCLI:
            .tailscaleCLI
        }
    }
}

/// A durable path preference. Automatic policies select a currently suitable
/// endpoint inside the requested network scope; fixed policies never fall back
/// to another endpoint without a new user decision.
public enum SSHRoutePolicy: Codable, Hashable, Sendable {
    case automatic(networkScope: NetworkScope?)
    case fixed(endpointID: UUID)

    public var fixedEndpointID: UUID? {
        guard case .fixed(let endpointID) = self else { return nil }
        return endpointID
    }

    public var networkScope: NetworkScope? {
        guard case .automatic(let networkScope) = self else { return nil }
        return networkScope
    }
}

/// A user-facing, durable SSH entry. It is a shortcut to an account and route
/// policy, not an authorization identity.
public struct SSHConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var sshAlias: String
    public var routePolicy: SSHRoutePolicy
    public var transportPreference: SSHConnectionTransportPreference
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(
        id: UUID,
        accountID: UUID,
        sshAlias: String,
        routePolicy: SSHRoutePolicy,
        transportPreference: SSHConnectionTransportPreference = .automatic,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isDeleted: Bool = false,
        version: Int = 1
    ) {
        self.id = id
        self.accountID = accountID
        self.sshAlias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routePolicy = routePolicy
        self.transportPreference = transportPreference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }
}

/// Parsed user intent. Every field is a hint until the planner resolves stable
/// topology IDs and a concrete endpoint.
public struct SSHConnectionIntent: Hashable, Sendable {
    public var nodeID: UUID?
    public var accountID: UUID?
    public var profileID: UUID?
    public var username: String?
    public var target: String?
    public var port: UInt16?
    public var networkScope: NetworkScope?

    public init(
        nodeID: UUID? = nil,
        accountID: UUID? = nil,
        profileID: UUID? = nil,
        username: String? = nil,
        target: String? = nil,
        port: UInt16? = nil,
        networkScope: NetworkScope? = nil
    ) {
        self.nodeID = nodeID
        self.accountID = accountID
        self.profileID = profileID
        self.username = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.networkScope = networkScope
    }
}

public enum SSHConnectionPlanReason: String, Codable, Hashable, Sendable {
    case explicitProfile
    case explicitEndpoint
    case exactAddress
    case currentNetworkSuccess
    case profileNetworkScope
    case endpointPriority
}

/// The one resolved input shared by host-key scanning, authentication,
/// authorization and post-install verification.
public struct SSHConnectionPlan: Hashable, Sendable, Identifiable {
    public var profileID: UUID?
    public var nodeID: UUID
    public var accountID: UUID
    public var endpointID: UUID
    public var sshAlias: String?
    public var username: String
    public var host: String
    public var port: UInt16
    public var networkScope: NetworkScope
    public var transport: SSHConnectionTransport
    public var networkEpoch: UInt64
    public var reason: SSHConnectionPlanReason

    public var id: String {
        "\(accountID.uuidString.lowercased()):\(endpointID.uuidString.lowercased()):\(transport.rawValue):\(networkEpoch)"
    }
}

public enum SSHConnectionIntentError: LocalizedError, Equatable, Sendable {
    case empty
    case unsafeSyntax
    case unsupportedOption(String)
    case missingOptionValue(String)
    case invalidPort(String)
    case missingTarget
    case multipleTargets
    case invalidTarget

    public var errorDescription: String? {
        switch self {
        case .empty: "请输入 SSH 目标或命令。"
        case .unsafeSyntax: "SSH 输入包含 shell 控制字符，KeyPort 不会执行该内容。"
        case .unsupportedOption(let option): "暂不支持 SSH 选项 \(option)。"
        case .missingOptionValue(let option): "SSH 选项 \(option) 缺少参数。"
        case .invalidPort(let value): "SSH 端口 \(value) 无效。"
        case .missingTarget: "SSH 命令缺少目标。"
        case .multipleTargets: "一次只能解析一个 SSH 目标。"
        case .invalidTarget: "SSH 目标格式无效。"
        }
    }
}

/// Parses a deliberately small, non-executable subset:
/// `ssh [-p port] [-l user] [user@]target`, `[user@]target`.
public enum SSHConnectionIntentParser {
    public static func parse(_ input: String) throws -> SSHConnectionIntent {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SSHConnectionIntentError.empty }
        let unsafe = CharacterSet(charactersIn: ";&|<>`$\\\n\r")
        guard value.rangeOfCharacter(from: unsafe) == nil else {
            throw SSHConnectionIntentError.unsafeSyntax
        }

        var tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first?.lowercased() == "ssh" {
            tokens.removeFirst()
        }

        var username: String?
        var port: UInt16?
        var target: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--":
                index += 1
                guard index < tokens.count else { throw SSHConnectionIntentError.missingTarget }
                guard target == nil, index == tokens.count - 1 else {
                    throw SSHConnectionIntentError.multipleTargets
                }
                target = tokens[index]
            case "-p", "-l":
                guard index + 1 < tokens.count else {
                    throw SSHConnectionIntentError.missingOptionValue(token)
                }
                let optionValue = tokens[index + 1]
                if token == "-p" {
                    guard let number = UInt16(optionValue), number > 0 else {
                        throw SSHConnectionIntentError.invalidPort(optionValue)
                    }
                    port = number
                } else {
                    guard !optionValue.isEmpty else { throw SSHConnectionIntentError.invalidTarget }
                    username = optionValue
                }
                index += 1
            default:
                if token.hasPrefix("-") {
                    throw SSHConnectionIntentError.unsupportedOption(token)
                }
                guard target == nil else { throw SSHConnectionIntentError.multipleTargets }
                target = token
            }
            index += 1
        }

        guard var parsedTarget = target, !parsedTarget.isEmpty else {
            throw SSHConnectionIntentError.missingTarget
        }
        if let at = parsedTarget.firstIndex(of: "@") {
            let userPart = String(parsedTarget[..<at])
            let hostPart = String(parsedTarget[parsedTarget.index(after: at)...])
            guard !userPart.isEmpty, !hostPart.isEmpty else {
                throw SSHConnectionIntentError.invalidTarget
            }
            username = userPart
            parsedTarget = hostPart
        }
        if parsedTarget.hasPrefix("[") && parsedTarget.hasSuffix("]") {
            parsedTarget.removeFirst()
            parsedTarget.removeLast()
        }
        guard !parsedTarget.isEmpty else { throw SSHConnectionIntentError.invalidTarget }
        return SSHConnectionIntent(username: username, target: parsedTarget, port: port)
    }
}

public enum SSHConnectionPlanningError: LocalizedError, Equatable, Sendable {
    case nodeNotFound
    case accountNotFound
    case accountAmbiguous
    case endpointNotFound
    case profileNotFound
    case profileOutsideNode

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound: "无法把 SSH 目标匹配到节点。"
        case .accountNotFound: "节点上没有匹配的 SSH 账户。"
        case .accountAmbiguous: "存在多个可能的 SSH 账户，请明确选择用户。"
        case .endpointNotFound: "节点上没有符合访问要求的 SSH 路径。"
        case .profileNotFound: "找不到指定的 SSH 连接配置。"
        case .profileOutsideNode: "SSH 连接配置不属于所选节点。"
        }
    }
}

/// Pure planning module. Live TCP probing remains behind the existing
/// `AddressSelecting` seam; this module ranks saved evidence and produces the
/// concrete inputs that every SSH operation must share.
public struct SSHConnectionPlanner: Sendable {
    public init() {}

    public func plans(
        for intent: SSHConnectionIntent,
        in topology: TopologySnapshot,
        currentDeviceID: String,
        networkEpoch: UInt64
    ) throws -> [SSHConnectionPlan] {
        let profiles = topology.activeConnectionProfiles
        let explicitProfile = try resolveProfile(intent: intent, profiles: profiles)
        let nodeID = try resolveNodeID(intent: intent, profile: explicitProfile, topology: topology)
        if let explicitNodeID = intent.nodeID,
           let explicitProfile,
           topology.activeAccounts.first(where: { $0.id == explicitProfile.accountID })?.nodeID != explicitNodeID {
            throw SSHConnectionPlanningError.profileOutsideNode
        }
        let account = try resolveAccount(
            intent: intent,
            profile: explicitProfile,
            nodeID: nodeID,
            topology: topology
        )
        let candidates = try resolveEndpoints(
            intent: intent,
            profile: explicitProfile,
            nodeID: nodeID,
            topology: topology,
            currentDeviceID: currentDeviceID,
            networkEpoch: networkEpoch
        )
        return candidates.map { endpoint, reason in
            SSHConnectionPlan(
                profileID: explicitProfile?.id,
                nodeID: nodeID,
                accountID: account.id,
                endpointID: endpoint.id,
                sshAlias: explicitProfile?.sshAlias,
                username: account.username,
                host: endpoint.address,
                port: endpoint.port,
                networkScope: endpoint.networkScope,
                transport: SSHConnectionTransportResolver.resolve(
                    preference: explicitProfile?.transportPreference ?? .automatic,
                    networkScope: endpoint.networkScope
                ),
                networkEpoch: networkEpoch,
                reason: reason
            )
        }
    }

    public func plan(
        for intent: SSHConnectionIntent,
        in topology: TopologySnapshot,
        currentDeviceID: String,
        networkEpoch: UInt64
    ) throws -> SSHConnectionPlan {
        guard let first = try plans(
            for: intent,
            in: topology,
            currentDeviceID: currentDeviceID,
            networkEpoch: networkEpoch
        ).first else {
            throw SSHConnectionPlanningError.endpointNotFound
        }
        return first
    }

    private func resolveProfile(
        intent: SSHConnectionIntent,
        profiles: [SSHConnectionProfile]
    ) throws -> SSHConnectionProfile? {
        if let profileID = intent.profileID {
            guard let profile = profiles.first(where: { $0.id == profileID }) else {
                throw SSHConnectionPlanningError.profileNotFound
            }
            return profile
        }
        guard let target = intent.target else { return nil }
        return profiles.first { $0.sshAlias.caseInsensitiveCompare(target) == .orderedSame }
    }

    private func resolveNodeID(
        intent: SSHConnectionIntent,
        profile: SSHConnectionProfile?,
        topology: TopologySnapshot
    ) throws -> UUID {
        if let nodeID = intent.nodeID, topology.node(id: nodeID) != nil { return nodeID }
        if let profile,
           let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }) {
            return account.nodeID
        }
        if let accountID = intent.accountID,
           let account = topology.activeAccounts.first(where: { $0.id == accountID }) {
            return account.nodeID
        }
        if let target = intent.target {
            let requestedPort = intent.port ?? 22
            let matches = topology.activeEndpoints.filter {
                $0.protocol == .ssh
                    && TopologyStableID.normalize($0.address) == TopologyStableID.normalize(target)
                    && $0.port == requestedPort
            }
            let nodeIDs = Set(matches.map(\.nodeID))
            if nodeIDs.count == 1, let nodeID = nodeIDs.first { return nodeID }
        }
        throw SSHConnectionPlanningError.nodeNotFound
    }

    private func resolveAccount(
        intent: SSHConnectionIntent,
        profile: SSHConnectionProfile?,
        nodeID: UUID,
        topology: TopologySnapshot
    ) throws -> SSHAccount {
        let accounts = topology.accounts(for: nodeID)
        if let accountID = profile?.accountID ?? intent.accountID {
            guard let account = accounts.first(where: { $0.id == accountID }) else {
                throw SSHConnectionPlanningError.accountNotFound
            }
            return account
        }
        if let username = intent.username, !username.isEmpty {
            let matches = accounts.filter { $0.username == username }
            guard matches.count <= 1 else { throw SSHConnectionPlanningError.accountAmbiguous }
            guard let match = matches.first else { throw SSHConnectionPlanningError.accountNotFound }
            return match
        }
        guard accounts.count <= 1 else { throw SSHConnectionPlanningError.accountAmbiguous }
        guard let account = accounts.first else { throw SSHConnectionPlanningError.accountNotFound }
        return account
    }

    private func resolveEndpoints(
        intent: SSHConnectionIntent,
        profile: SSHConnectionProfile?,
        nodeID: UUID,
        topology: TopologySnapshot,
        currentDeviceID: String,
        networkEpoch: UInt64
    ) throws -> [(Endpoint, SSHConnectionPlanReason)] {
        var endpoints = topology.endpoints(for: nodeID, endpointProtocol: .ssh)
        if let target = intent.target,
           profile == nil {
            let requestedPort = intent.port ?? 22
            let exact = endpoints.filter {
                TopologyStableID.normalize($0.address) == TopologyStableID.normalize(target)
                    && $0.port == requestedPort
            }
            if !exact.isEmpty { return exact.map { ($0, .exactAddress) } }
        }
        if let profile {
            switch profile.routePolicy {
            case .fixed(let endpointID):
                guard let endpoint = endpoints.first(where: { $0.id == endpointID }) else {
                    throw SSHConnectionPlanningError.endpointNotFound
                }
                return [(endpoint, .explicitEndpoint)]
            case .automatic(let scope):
                if let scope { endpoints = endpoints.filter { $0.networkScope == scope } }
            }
        } else if let scope = intent.networkScope {
            endpoints = endpoints.filter { $0.networkScope == scope }
        }
        guard !endpoints.isEmpty else { throw SSHConnectionPlanningError.endpointNotFound }

        let evidenceByEndpoint = Dictionary(
            topology.reachabilityObservations
                .filter {
                    $0.observerDeviceID == currentDeviceID
                        && $0.networkEpoch == networkEpoch
                        && $0.wasReachable
                }
                .map { ($0.endpointID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        endpoints.sort { lhs, rhs in
            let lhsReachable = evidenceByEndpoint[lhs.id] != nil
            let rhsReachable = evidenceByEndpoint[rhs.id] != nil
            if lhsReachable != rhsReachable { return lhsReachable }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return endpoints.map { endpoint in
            let reason: SSHConnectionPlanReason
            if evidenceByEndpoint[endpoint.id] != nil {
                reason = .currentNetworkSuccess
            } else if profile?.routePolicy.networkScope != nil || intent.networkScope != nil {
                reason = .profileNetworkScope
            } else {
                reason = .endpointPriority
            }
            return (endpoint, reason)
        }
    }

}
