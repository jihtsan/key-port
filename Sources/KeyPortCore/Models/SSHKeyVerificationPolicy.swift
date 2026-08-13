import Foundation

public struct SSHKeyVerificationContext: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let keyFingerprint: String

    public init(host: String, port: Int, username: String, keyFingerprint: String) {
        self.host = Self.normalizeHost(host)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyFingerprint = keyFingerprint
    }

    public static func normalizeHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

public enum SSHKeyVerificationPolicy {
    public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    public static func shouldRunAutomaticCheck(lastAttemptAt: Date?, now: Date = .now) -> Bool {
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= automaticCheckInterval
    }

    public static func context(
        for server: ServerConnection,
        keyFingerprint: String
    ) -> SSHKeyVerificationContext {
        SSHKeyVerificationContext(
            host: server.host,
            port: server.port,
            username: server.username,
            keyFingerprint: keyFingerprint
        )
    }

    public static func contextChanged(
        verified: SSHKeyVerificationContext?,
        current: SSHKeyVerificationContext
    ) -> Bool {
        guard let verified else { return false }
        return verified != current
    }

    public static func result(
        for outcome: SSHKeyCheckOutcome,
        previousSuccessAt: Date?,
        checkedAt: Date
    ) -> SSHKeyCheckResult {
        switch outcome {
        case .succeeded:
            SSHKeyCheckResult(status: .authorized, lastSuccessAt: checkedAt)
        case .rejected:
            SSHKeyCheckResult(status: .keyAuthenticationFailed, lastSuccessAt: nil)
        case .transportFailure:
            SSHKeyCheckResult(status: .unreachable, lastSuccessAt: previousSuccessAt)
        case .missingLocalKey:
            SSHKeyCheckResult(status: .missingLocalKey, lastSuccessAt: nil)
        case .hostKeyPending:
            SSHKeyCheckResult(status: .hostKeyPending, lastSuccessAt: previousSuccessAt)
        case .hostKeyMismatch:
            SSHKeyCheckResult(status: .hostKeyMismatch, lastSuccessAt: previousSuccessAt)
        }
    }
}

public enum SSHKeyCheckOutcome: Sendable {
    case succeeded
    case rejected
    case transportFailure
    case missingLocalKey
    case hostKeyPending
    case hostKeyMismatch
}

public struct SSHKeyCheckResult: Equatable, Sendable {
    public let status: AuthorizationStatus
    public let lastSuccessAt: Date?

    public init(status: AuthorizationStatus, lastSuccessAt: Date?) {
        self.status = status
        self.lastSuccessAt = lastSuccessAt
    }
}

public enum SSHCopyValue: Sendable {
    case alias
    case command

    public func content(alias: String) -> String {
        switch self {
        case .alias: alias
        case .command: "ssh \(alias)"
        }
    }
}
