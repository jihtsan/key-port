import Foundation

/// A single address that may be tried before OpenSSH owns the connection.
/// This value intentionally contains no credentials, private-key material or
/// host-key state.
public struct SSHPreconnectRelayCandidate: Identifiable, Codable, Hashable, Sendable {
    public let endpointID: UUID
    public let host: String
    public let port: UInt16

    public var id: UUID { endpointID }

    public init(endpointID: UUID, host: String, port: UInt16) {
        self.endpointID = endpointID
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }
}

/// The address OpenSSH believes it is connecting to. The relay only uses this
/// to reject a command accidentally pointed at a different target.
public struct SSHPreconnectRelayTarget: Codable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }
}

public enum SSHPreconnectRelayConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case missingCandidates
    case tooManyCandidates
    case duplicateCandidate
    case invalidHost
    case invalidPort
    case invalidConnectTimeout
    case invalidOverallBudget

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "连接前回退配置版本不受支持。"
        case .missingCandidates: "连接前回退配置没有候选地址。"
        case .tooManyCandidates: "连接前回退配置的候选地址过多。"
        case .duplicateCandidate: "连接前回退配置包含重复候选地址。"
        case .invalidHost: "连接前回退配置包含无效主机地址。"
        case .invalidPort: "连接前回退配置包含无效端口。"
        case .invalidConnectTimeout: "连接前回退配置的单候选超时无效。"
        case .invalidOverallBudget: "连接前回退配置的总预算无效。"
        }
    }
}

/// Versioned, owner-only local data consumed by `KeyPortSSHRelay`.
///
/// The target is deliberately stored alongside the candidate list. The
/// helper receives OpenSSH's `%h`/`%p` expansion and must verify that it
/// matches this target before opening any socket.
public struct SSHPreconnectRelayConfiguration: Identifiable, Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumCandidateCount = 16
    public static let minimumConnectTimeoutMilliseconds = 100
    public static let maximumConnectTimeoutMilliseconds = 30_000
    public static let minimumOverallBudgetMilliseconds = 100
    public static let maximumOverallBudgetMilliseconds = 120_000

    public let eventsDirectory: String?
    public let schemaVersion: Int
    public let operationID: UUID
    public let profileID: UUID
    public let target: SSHPreconnectRelayTarget
    public let candidates: [SSHPreconnectRelayCandidate]
    public let connectTimeoutMilliseconds: Int
    public let overallBudgetMilliseconds: Int

    public var id: UUID { profileID }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        eventsDirectory: String? = nil,
        operationID: UUID,
        profileID: UUID,
        target: SSHPreconnectRelayTarget,
        candidates: [SSHPreconnectRelayCandidate],
        connectTimeoutMilliseconds: Int = 5_000,
        overallBudgetMilliseconds: Int = 20_000
    ) {
        self.eventsDirectory = eventsDirectory
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.profileID = profileID
        self.target = target
        self.candidates = candidates
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
        self.overallBudgetMilliseconds = overallBudgetMilliseconds
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SSHPreconnectRelayConfigurationError.unsupportedSchema
        }
        guard !candidates.isEmpty else {
            throw SSHPreconnectRelayConfigurationError.missingCandidates
        }
        guard candidates.count <= Self.maximumCandidateCount else {
            throw SSHPreconnectRelayConfigurationError.tooManyCandidates
        }
        guard validHost(target.host), target.port > 0 else {
            throw SSHPreconnectRelayConfigurationError.invalidHost
        }
        guard (Self.minimumConnectTimeoutMilliseconds...Self.maximumConnectTimeoutMilliseconds)
            .contains(connectTimeoutMilliseconds) else {
            throw SSHPreconnectRelayConfigurationError.invalidConnectTimeout
        }
        guard (Self.minimumOverallBudgetMilliseconds...Self.maximumOverallBudgetMilliseconds)
            .contains(overallBudgetMilliseconds) else {
            throw SSHPreconnectRelayConfigurationError.invalidOverallBudget
        }

        var endpointIDs = Set<UUID>()
        for candidate in candidates {
            guard endpointIDs.insert(candidate.endpointID).inserted else {
                throw SSHPreconnectRelayConfigurationError.duplicateCandidate
            }
            guard validHost(candidate.host), candidate.port > 0 else {
                throw SSHPreconnectRelayConfigurationError.invalidHost
            }
        }
    }

    public func matchesForwardingTarget(host: String, port: UInt16) -> Bool {
        Self.normalizedHost(host) == Self.normalizedHost(target.host) && port == target.port
    }

    public static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func validHost(_ host: String) -> Bool {
        let value = Self.normalizedHost(host)
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45       // -
                || byte == 46       // .
                || byte == 58       // :
                || byte == 37       // % (IPv6 zone identifiers)
                || byte == 95       // _ (legacy DNS names)
        }
    }
}

public struct SSHPreconnectRelayManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let configurations: [SSHPreconnectRelayConfiguration]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        configurations: [SSHPreconnectRelayConfiguration]
    ) {
        self.schemaVersion = schemaVersion
        self.configurations = configurations
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SSHPreconnectRelayConfigurationError.unsupportedSchema
        }
        var profileIDs = Set<UUID>()
        for configuration in configurations {
            guard profileIDs.insert(configuration.profileID).inserted else {
                throw SSHPreconnectRelayConfigurationError.duplicateCandidate
            }
            try configuration.validate()
        }
    }

    public func configuration(for profileID: UUID) -> SSHPreconnectRelayConfiguration? {
        configurations.first { $0.profileID == profileID }
    }
}

/// Builds the local helper data from the same topology route resolver used by
/// the connection editor. A fixed route and an automatic route without an
/// explicit allow-list deliberately return `nil`: both retain their existing
/// direct/Tailscale OpenSSH behavior.
public enum SSHPreconnectRelayConfigurationBuilder {
    public static func make(
        profile: SSHConnectionProfile,
        nodeID: UUID,
        server: ServerConnection,
        topology: TopologySnapshot,
        operationID: UUID = UUID(),
        connectTimeoutMilliseconds: Int = 5_000,
        overallBudgetMilliseconds: Int = 20_000
    ) throws -> SSHPreconnectRelayConfiguration? {
        guard case .automatic = profile.routePolicy,
              !profile.candidateEndpointIDs.isEmpty else { return nil }

        let endpoints = try SSHRoutePolicyResolver.endpoints(
            for: profile,
            nodeID: nodeID,
            in: topology
        )
        guard let targetPort = UInt16(exactly: server.port), targetPort > 0 else {
            throw SSHPreconnectRelayConfigurationError.invalidPort
        }
        let candidates = endpoints.map {
            SSHPreconnectRelayCandidate(
                endpointID: $0.id,
                host: $0.address,
                port: $0.port
            )
        }
        let configuration = SSHPreconnectRelayConfiguration(
            operationID: operationID,
            profileID: profile.id,
            target: SSHPreconnectRelayTarget(host: server.host, port: targetPort),
            candidates: candidates,
            connectTimeoutMilliseconds: connectTimeoutMilliseconds,
            overallBudgetMilliseconds: overallBudgetMilliseconds
        )
        try configuration.validate()
        return configuration
    }

    public static func makeManifest(
        profiles: [SSHConnectionProfile],
        servers: [ServerConnection],
        topology: TopologySnapshot,
        operationID: UUID = UUID(),
        connectTimeoutMilliseconds: Int = 5_000,
        overallBudgetMilliseconds: Int = 20_000
    ) throws -> SSHPreconnectRelayManifest {
        let serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let accountsByID = Dictionary(uniqueKeysWithValues: topology.activeAccounts.map { ($0.id, $0) })
        let configurations: [SSHPreconnectRelayConfiguration] = try profiles.compactMap { profile in
            guard let server = serversByID[profile.id],
                  let account = accountsByID[profile.accountID] else { return nil }
            return try make(
                profile: profile,
                nodeID: account.nodeID,
                server: server,
                topology: topology,
                operationID: operationID,
                connectTimeoutMilliseconds: connectTimeoutMilliseconds,
                overallBudgetMilliseconds: overallBudgetMilliseconds
            )
        }
        let manifest = SSHPreconnectRelayManifest(configurations: configurations)
        try manifest.validate()
        return manifest
    }
}

/// Stable helper identity shared by the app's dependency checker and the
/// standalone executable. The helper's output intentionally uses stable
/// codes instead of endpoint/error text.
public enum SSHPreconnectRelayRuntime {
    public static let executableName = "KeyPortSSHRelay"
    public static let version = 1
    public static let versionString = "KeyPortSSHRelay/1"
    public static let maximumManifestBytes = 1_024 * 1_024
}

public struct SSHRelaySelectionEvent: Codable, Sendable {
    public let attemptID: UUID
    public let profileID: UUID
    public let endpointID: UUID
    public let selectedAt: Date
    public init(attemptID: UUID, profileID: UUID, endpointID: UUID, selectedAt: Date) {
        self.attemptID = attemptID; self.profileID = profileID; self.endpointID = endpointID; self.selectedAt = selectedAt
    }
}
