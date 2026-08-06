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
        case .authorized: "Authorized"
        case .needsAuthorization: "Needs authorization"
        case .missingLocalKey: "Missing local key"
        case .hostKeyPending: "Host key pending"
        case .hostKeyMismatch: "Host key changed"
        case .unreachable: "Unreachable"
        case .passwordAuthenticationFailed: "Password failed"
        case .keyAuthenticationFailed: "Key failed"
        case .authorizationConflict: "Authorization conflict"
        case .syncPending: "Sync pending"
        case .checking: "Checking"
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
        case .checking: "Checking"
        case .succeeded: "Passed"
        case .failed: "Failed"
        case .blocked: "Blocked"
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
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, alias: String, group: String = "", notes: String = "", confirmedHostKeys: [HostKeyRecord] = [], status: AuthorizationStatus = .hostKeyPending, statusDetail: String? = nil, lastCheckedAt: Date? = nil, passwordCheck: AuthenticationCheck? = nil, keyCheck: AuthenticationCheck? = nil, createdAt: Date = .now, updatedAt: Date = .now, isDeleted: Bool = false, version: Int = 1) {
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }

    public var endpoint: String { "\(host):\(port)" }
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
    public var id: String { "\(serverID.uuidString):\(keyID)" }
    public var serverID: UUID
    public var keyID: String
    public var fingerprint: String
    public var remoteComment: String
    public var status: AuthorizationStatus
    public var authorizedAt: Date?
    public var lastVerifiedAt: Date?

    public init(serverID: UUID, keyID: String, fingerprint: String, remoteComment: String, status: AuthorizationStatus, authorizedAt: Date? = nil, lastVerifiedAt: Date? = nil) {
        self.serverID = serverID
        self.keyID = keyID
        self.fingerprint = fingerprint
        self.remoteComment = remoteComment
        self.status = status
        self.authorizedAt = authorizedAt
        self.lastVerifiedAt = lastVerifiedAt
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
