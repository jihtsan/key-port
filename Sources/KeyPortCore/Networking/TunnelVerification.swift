import CryptoKit
import Foundation

public extension RemoteServiceEndpoint {
    /// A stable, non-reversible identifier for the endpoint used by evidence.
    var remoteDigest: String {
        let bind: String
        switch self.bind {
        case .loopbackV4: bind = "loopback-v4"
        case .loopbackV6: bind = "loopback-v6"
        case .wildcardV4: bind = "wildcard-v4"
        case .wildcardV6: bind = "wildcard-v6"
        case .specific(.v4(let address)): bind = "specific-v4:\(address)"
        case .specific(.v6(let address)): bind = "specific-v6:\(address)"
        }
        let path = self.path ?? ""
        let canonical = "bind=\(bind)|port=\(port)|path=\(path)"
        return Data(SHA256.hash(data: Data(canonical.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct TunnelSubject: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let sessionID: UUID
    public let candidateID: UUID
    public let sshIdentityID: UUID
    public let sshAddressID: UUID
    public let remoteDigest: String
    public let networkEpoch: UInt64

    public init(
        operationID: UUID,
        sessionID: UUID,
        candidateID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        remote: RemoteServiceEndpoint,
        networkEpoch: UInt64
    ) {
        self.init(
            operationID: operationID,
            sessionID: sessionID,
            candidateID: candidateID,
            sshIdentityID: sshIdentityID,
            sshAddressID: sshAddressID,
            remoteDigest: remote.remoteDigest,
            networkEpoch: networkEpoch
        )
    }

    public init(
        operationID: UUID,
        sessionID: UUID,
        candidateID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        remoteDigest: String,
        networkEpoch: UInt64
    ) {
        self.operationID = operationID
        self.sessionID = sessionID
        self.candidateID = candidateID
        self.sshIdentityID = sshIdentityID
        self.sshAddressID = sshAddressID
        self.remoteDigest = remoteDigest
        self.networkEpoch = networkEpoch
    }
}

public enum TargetVerificationEvidenceError: Error, Equatable, Sendable {
    case subjectMismatch
    case expired
    case networkEpochMismatch
}

public struct TargetVerificationEvidence: Codable, Hashable, Sendable {
    public static let validityDuration: TimeInterval = 30

    public let subject: TunnelSubject
    public let verifiedAt: Date
    public let expiresAt: Date

    public var operationID: UUID { subject.operationID }
    public var sessionID: UUID { subject.sessionID }
    public var candidateID: UUID { subject.candidateID }
    public var sshIdentityID: UUID { subject.sshIdentityID }
    public var sshAddressID: UUID { subject.sshAddressID }
    public var remoteDigest: String { subject.remoteDigest }
    public var networkEpoch: UInt64 { subject.networkEpoch }

    public init(
        subject: TunnelSubject,
        verifiedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.subject = subject
        self.verifiedAt = verifiedAt
        self.expiresAt = min(
            expiresAt ?? verifiedAt.addingTimeInterval(Self.validityDuration),
            verifiedAt.addingTimeInterval(Self.validityDuration)
        )
    }

    public func isValid(at date: Date, networkEpoch: UInt64) -> Bool {
        subject.networkEpoch == networkEpoch
            && date >= verifiedAt
            && date < expiresAt
    }

    public func adopt(candidate: TunnelSubject, at date: Date) throws -> TunnelSubject {
        guard subject.operationID == candidate.operationID,
              subject.sessionID == candidate.sessionID,
              subject.candidateID == candidate.candidateID,
              subject.sshIdentityID == candidate.sshIdentityID,
              subject.sshAddressID == candidate.sshAddressID,
              subject.remoteDigest == candidate.remoteDigest else {
            throw TargetVerificationEvidenceError.subjectMismatch
        }
        guard subject.networkEpoch == candidate.networkEpoch else {
            throw TargetVerificationEvidenceError.networkEpochMismatch
        }
        guard date >= verifiedAt, date < expiresAt else {
            throw TargetVerificationEvidenceError.expired
        }
        return candidate
    }

    public func validate(for candidate: TunnelSubject, at date: Date) throws {
        _ = try adopt(candidate: candidate, at: date)
    }
}

public struct OpenSSHVersion: Codable, Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: OpenSSHVersion, rhs: OpenSSHVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public enum OpenSSHVersionPolicy {
    public static let supportedVersions: Set<OpenSSHVersion> = [
        OpenSSHVersion(major: 9, minor: 7),
        OpenSSHVersion(major: 10, minor: 2)
    ]

    public static func parse(_ output: String) -> OpenSSHVersion? {
        guard output.utf8.count <= 4 * 1024 else { return nil }
        let pattern = #"OpenSSH_(\d+)\.(\d+)"#
        guard let match = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let versionText = String(output[match])
            .dropFirst("OpenSSH_".count)
        let components = versionText.split(separator: ".")
        guard components.count == 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else {
            return nil
        }
        return OpenSSHVersion(major: major, minor: minor)
    }

    public static func isSupported(_ output: String) -> Bool {
        guard let version = parse(output) else { return false }
        return supportedVersions.contains(version)
    }
}
