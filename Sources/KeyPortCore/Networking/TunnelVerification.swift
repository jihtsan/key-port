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
    public let operationID: UUID?
    public let sessionID: UUID?
    public let candidateID: UUID?
    public let serviceID: UUID?
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
        self.serviceID = nil
        self.sshIdentityID = sshIdentityID
        self.sshAddressID = sshAddressID
        self.remoteDigest = remoteDigest
        self.networkEpoch = networkEpoch
    }

    public init(
        serviceID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        remote: RemoteServiceEndpoint,
        networkEpoch: UInt64
    ) {
        self.init(
            serviceID: serviceID,
            sshIdentityID: sshIdentityID,
            sshAddressID: sshAddressID,
            remoteDigest: remote.remoteDigest,
            networkEpoch: networkEpoch
        )
    }

    public init(
        serviceID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        remoteDigest: String,
        networkEpoch: UInt64
    ) {
        self.operationID = nil
        self.sessionID = nil
        self.candidateID = nil
        self.serviceID = serviceID
        self.sshIdentityID = sshIdentityID
        self.sshAddressID = sshAddressID
        self.remoteDigest = remoteDigest
        self.networkEpoch = networkEpoch
    }

    public var isCandidate: Bool {
        serviceID == nil && operationID != nil && sessionID != nil && candidateID != nil
    }

    public var isSaved: Bool {
        serviceID != nil && operationID == nil && sessionID == nil && candidateID == nil
    }
}

public enum TargetVerificationEvidenceError: Error, Equatable, Sendable {
    case subjectMismatch
    case expired
    case networkEpochMismatch
}

public struct TargetVerificationEvidence: Codable, Hashable, Sendable {
    public static let validityDuration: TimeInterval = 30

    public let tunnelID: UUID
    public let operationID: UUID
    public let subject: TunnelSubject
    public let sshIdentityID: UUID
    public let sshAddressID: UUID
    public let remoteDigest: String
    public let networkEpoch: UInt64
    public let verifiedAt: Date
    public let expiresAt: Date

    public var sessionID: UUID? { subject.sessionID }
    public var candidateID: UUID? { subject.candidateID }
    public var serviceID: UUID? { subject.serviceID }

    public init(
        tunnelID: UUID,
        operationID: UUID,
        subject: TunnelSubject,
        verifiedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.tunnelID = tunnelID
        self.operationID = operationID
        self.subject = subject
        self.sshIdentityID = subject.sshIdentityID
        self.sshAddressID = subject.sshAddressID
        self.remoteDigest = subject.remoteDigest
        self.networkEpoch = subject.networkEpoch
        self.verifiedAt = verifiedAt
        self.expiresAt = min(
            expiresAt ?? verifiedAt.addingTimeInterval(Self.validityDuration),
            verifiedAt.addingTimeInterval(Self.validityDuration)
        )
    }

    public func isValid(at date: Date, networkEpoch: UInt64) -> Bool {
        self.networkEpoch == networkEpoch
            && date >= verifiedAt
            && date < expiresAt
    }

    public func adopt(candidate: TunnelSubject, at date: Date) throws -> TunnelSubject {
        guard subject == candidate,
              candidate.operationID == operationID,
              candidate.sshIdentityID == sshIdentityID,
              candidate.sshAddressID == sshAddressID,
              candidate.remoteDigest == remoteDigest else {
            throw TargetVerificationEvidenceError.subjectMismatch
        }
        guard networkEpoch == candidate.networkEpoch else {
            throw TargetVerificationEvidenceError.networkEpochMismatch
        }
        guard date >= verifiedAt, date < expiresAt else {
            throw TargetVerificationEvidenceError.expired
        }
        return candidate
    }

    public func adopting(
        savedSubject: TunnelSubject,
        at date: Date
    ) throws -> TargetVerificationEvidence {
        guard subject.isCandidate,
              subject.operationID == operationID,
              savedSubject.isSaved,
              sshIdentityID == savedSubject.sshIdentityID,
              sshAddressID == savedSubject.sshAddressID,
              remoteDigest == savedSubject.remoteDigest else {
            throw TargetVerificationEvidenceError.subjectMismatch
        }
        guard networkEpoch == savedSubject.networkEpoch else {
            throw TargetVerificationEvidenceError.networkEpochMismatch
        }
        guard date >= verifiedAt, date < expiresAt else {
            throw TargetVerificationEvidenceError.expired
        }
        return TargetVerificationEvidence(
            tunnelID: tunnelID,
            operationID: operationID,
            subject: savedSubject,
            verifiedAt: verifiedAt,
            expiresAt: expiresAt
        )
    }

    public func validate(for candidate: TunnelSubject, at date: Date) throws {
        _ = try adopt(candidate: candidate, at: date)
    }
}

public struct OpenSSHVersion: Codable, Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: String

    public init(major: Int, minor: Int, patch: Int = 1, build: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    public static func < (lhs: OpenSSHVersion, rhs: OpenSSHVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        return lhs.build < rhs.build
    }
}

public enum OpenSSHVersionPolicy {
    public static let supportedVersions: Set<OpenSSHVersion> = [
        OpenSSHVersion(major: 9, minor: 7, patch: 1, build: "LibreSSL 3.3.6"),
        OpenSSHVersion(major: 10, minor: 2, patch: 1, build: "LibreSSL 3.3.6")
    ]

    public static func parse(_ output: String) -> OpenSSHVersion? {
        guard output.utf8.count <= 4 * 1024 else { return nil }
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return nil
        }
        let token = String(components[0]).trimmingCharacters(in: .whitespaces)
        let build = String(components[1]).trimmingCharacters(in: .whitespaces)
        let pattern = #"^OpenSSH_\d+\.\d+p\d+$"#
        guard !build.isEmpty,
              token.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        let versionText = token.dropFirst("OpenSSH_".count)
        let versionComponents = versionText.split { character in
            character == "." || character == "p"
        }
        guard versionComponents.count == 3,
              let major = Int(versionComponents[0]),
              let minor = Int(versionComponents[1]),
              let patch = Int(versionComponents[2]) else {
            return nil
        }
        return OpenSSHVersion(major: major, minor: minor, patch: patch, build: build)
    }

    public static func isSupported(_ output: String) -> Bool {
        guard let version = parse(output) else { return false }
        return supportedVersions.contains(version)
    }
}
