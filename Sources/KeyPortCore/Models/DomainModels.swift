import Foundation

public enum AuthorizationStatus: String, Codable, CaseIterable, Sendable {
    case authorized
    case needsAuthorization
    case missingLocalKey
    case hostKeyPending
    case hostKeyMismatch
    case unreachable
    case passwordAuthenticationFailed
    case keyAuthenticationFailed
    case authorizationConflict
    case syncPending
    case checking

    public var title: String {
        switch self {
        case .authorized: "免密已验证"
        case .needsAuthorization: "待启用免密"
        case .missingLocalKey: "缺少本机密钥"
        case .hostKeyPending: "主机密钥待确认"
        case .hostKeyMismatch: "主机密钥已变更"
        case .unreachable: "无法连接"
        case .passwordAuthenticationFailed: "密码验证失败"
        case .keyAuthenticationFailed: "免密验证失败"
        case .authorizationConflict: "授权冲突"
        case .syncPending: "免密待验证"
        case .checking: "检测中"
        }
    }
}

public enum AuthenticationCheckState: String, Codable, Hashable, Sendable {
    case checking
    case succeeded
    case failed
    case blocked

    public var title: String {
        switch self {
        case .checking: "检查中"
        case .succeeded: "已通过"
        case .failed: "失败"
        case .blocked: "已阻止"
        }
    }
}

public struct AuthenticationCheck: Codable, Hashable, Sendable {
    public var state: AuthenticationCheckState
    public var detail: String
    public var checkedAt: Date?

    public init(state: AuthenticationCheckState, detail: String, checkedAt: Date? = nil) {
        self.state = state
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public struct RemoteMachineConfiguration: Codable, Hashable, Sendable {
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    public var hostname: String
    public var operatingSystem: String
    public var kernel: String
    public var architecture: String
    public var processorCount: Int?
    public var memoryBytes: UInt64?
    public var synchronizedAt: Date

    public init(
        hostname: String,
        operatingSystem: String,
        kernel: String,
        architecture: String,
        processorCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        synchronizedAt: Date = .now
    ) {
        self.hostname = hostname
        self.operatingSystem = operatingSystem
        self.kernel = kernel
        self.architecture = architecture
        self.processorCount = processorCount
        self.memoryBytes = memoryBytes
        self.synchronizedAt = synchronizedAt
    }

    public var capacitySummary: String? {
        var components: [String] = []
        if let processorCount, processorCount > 0 {
            components.append("\(processorCount)C")
        }
        if let memoryBytes, memoryBytes > 0 {
            let gibibytes = Double(memoryBytes) / 1_073_741_824
            if gibibytes >= 1 {
                components.append("\(Int(gibibytes.rounded()))G")
            } else {
                let mebibytes = max(1, Int((Double(memoryBytes) / 1_048_576).rounded()))
                components.append("\(mebibytes)M")
            }
        }
        return components.isEmpty ? nil : components.joined()
    }
}

public struct HostKeyRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(algorithm):\(fingerprint)" }
    public let algorithm: String
    public let fingerprint: String
    public let knownHostsLine: String
    public let firstConfirmedAt: Date?
    public var lastSeenAt: Date

    public init(algorithm: String, fingerprint: String, knownHostsLine: String, firstConfirmedAt: Date? = nil, lastSeenAt: Date = .now) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.knownHostsLine = knownHostsLine
        self.firstConfirmedAt = firstConfirmedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct ServerConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var alias: String
    public var group: String
    public var notes: String
    public var confirmedHostKeys: [HostKeyRecord]
    public var status: AuthorizationStatus
    public var statusDetail: String?
    public var lastCheckedAt: Date?
    public var passwordCheck: AuthenticationCheck?
    public var keyCheck: AuthenticationCheck?
    public var machineConfiguration: RemoteMachineConfiguration?
    public var machineConfigurationRefreshAttemptedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, alias: String, group: String = "", notes: String = "", confirmedHostKeys: [HostKeyRecord] = [], status: AuthorizationStatus = .hostKeyPending, statusDetail: String? = nil, lastCheckedAt: Date? = nil, passwordCheck: AuthenticationCheck? = nil, keyCheck: AuthenticationCheck? = nil, machineConfiguration: RemoteMachineConfiguration? = nil, machineConfigurationRefreshAttemptedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date = .now, isDeleted: Bool = false, version: Int = 1) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.alias = alias
        self.group = group
        self.notes = notes
        self.confirmedHostKeys = confirmedHostKeys
        self.status = status
        self.statusDetail = statusDetail
        self.lastCheckedAt = lastCheckedAt
        self.passwordCheck = passwordCheck
        self.keyCheck = keyCheck
        self.machineConfiguration = machineConfiguration
        self.machineConfigurationRefreshAttemptedAt = machineConfigurationRefreshAttemptedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }

    public var endpoint: String { "\(host):\(port)" }

    public func shouldRefreshMachineConfiguration(at date: Date = .now) -> Bool {
        let lastRefresh = [
            machineConfiguration?.synchronizedAt,
            machineConfigurationRefreshAttemptedAt
        ]
        .compactMap { $0 }
        .max()

        guard let lastRefresh else { return true }
        return date.timeIntervalSince(lastRefresh) >= RemoteMachineConfiguration.refreshInterval
    }
}

public struct Device: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isCurrent: Bool
    public var registeredAt: Date
    public var lastActiveAt: Date
    public var isRevoked: Bool
    public var tailscaleIdentity: TailscaleDeviceIdentity?

    public init(id: String, name: String, isCurrent: Bool, registeredAt: Date = .now, lastActiveAt: Date = .now, isRevoked: Bool = false, tailscaleIdentity: TailscaleDeviceIdentity? = nil) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.registeredAt = registeredAt
        self.lastActiveAt = lastActiveAt
        self.isRevoked = isRevoked
        self.tailscaleIdentity = tailscaleIdentity
    }
}

public enum SSHKeyKind: String, Codable, Sendable { case ed25519, rsa, other }
public enum SSHKeyOrigin: String, Codable, Sendable { case generated, scanned, imported, agent }

public struct SSHKeyRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var deviceID: String
    public var kind: SSHKeyKind
    public var publicKey: String
    public var fingerprint: String
    public var privateKeyPath: String?
    public var isInAgent: Bool
    public var origin: SSHKeyOrigin
    public var isLocallyAvailable: Bool

    public init(id: String, deviceID: String, kind: SSHKeyKind, publicKey: String, fingerprint: String, privateKeyPath: String?, isInAgent: Bool, origin: SSHKeyOrigin, isLocallyAvailable: Bool) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.privateKeyPath = privateKeyPath
        self.isInAgent = isInAgent
        self.origin = origin
        self.isLocallyAvailable = isLocallyAvailable
    }

    public var publicKeyComment: String? { PublicKeyParser.parse(publicKey)?.comment }
}

public struct Authorization: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(serverID.uuidString):\(fingerprint)" }
    public var serverID: UUID
    public var keyID: String
    public var fingerprint: String
    public var remoteComment: String
    public var status: AuthorizationStatus
    public var authorizedAt: Date?
    public var lastVerifiedAt: Date?
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(
        serverID: UUID,
        keyID: String,
        fingerprint: String,
        remoteComment: String,
        status: AuthorizationStatus,
        authorizedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        updatedAt: Date = .now,
        isDeleted: Bool = false,
        version: Int = 1
    ) {
        self.serverID = serverID
        self.keyID = keyID
        self.fingerprint = fingerprint
        self.remoteComment = remoteComment
        self.status = status
        self.authorizedAt = authorizedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case serverID
        case keyID
        case fingerprint
        case remoteComment
        case status
        case authorizedAt
        case lastVerifiedAt
        case updatedAt
        case isDeleted
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decode(UUID.self, forKey: .serverID)
        keyID = try container.decode(String.self, forKey: .keyID)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        remoteComment = try container.decode(String.self, forKey: .remoteComment)
        status = try container.decode(AuthorizationStatus.self, forKey: .status)
        authorizedAt = try container.decodeIfPresent(Date.self, forKey: .authorizedAt)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? lastVerifiedAt
            ?? authorizedAt
            ?? .distantPast
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        version = max(1, try container.decodeIfPresent(Int.self, forKey: .version) ?? 1)
    }
}

public struct AuditEvent: Identifiable, Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public var id: UUID
    public var timestamp: Date
    public var category: String
    public var action: String
    public var targetID: String?
    public var result: String
    public var level: Level

    public init(id: UUID = UUID(), timestamp: Date = .now, category: String, action: String, targetID: String? = nil, result: String, level: Level = .info) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.action = action
        self.targetID = targetID
        self.result = result
        self.level = level
    }
}

public struct AppSnapshot: Codable, Sendable {
    public var schemaVersion = 4
    public var servers: [ServerConnection] = []
    public var devices: [Device] = []
    public var keys: [SSHKeyRecord] = []
    public var authorizations: [Authorization] = []
    public var auditEvents: [AuditEvent] = []

    public init() {}
}
