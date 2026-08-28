import Foundation
import Darwin

public enum KeyPortFeatureFlags {
    public static let serviceAccessEnabled = false
}

public enum ServiceProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case http
    case https
    case tcp

    public var urlScheme: String? {
        switch self {
        case .http: "http"
        case .https: "https"
        case .tcp: nil
        }
    }
}

public enum IPAddress: Hashable, Codable, Sendable {
    case v4(String)
    case v6(String)

    public init?(_ value: String) {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketed: String
        if candidate.hasPrefix("[") && candidate.hasSuffix("]") {
            unbracketed = String(candidate.dropFirst().dropLast())
        } else {
            unbracketed = candidate
        }

        guard !unbracketed.isEmpty else { return nil }
        var address = in_addr()
        if inet_pton(AF_INET, unbracketed, &address) == 1 {
            self = .v4(unbracketed)
            return
        }
        var address6 = in6_addr()
        if inet_pton(AF_INET6, unbracketed, &address6) == 1 {
            self = .v6(unbracketed)
            return
        }
        return nil
    }

    public var value: String {
        switch self {
        case .v4(let value), .v6(let value): value
        }
    }

    public var isIPv6: Bool {
        if case .v6 = self { return true }
        return false
    }

    public var isLoopback: Bool {
        switch self {
        case .v4(let value):
            var address = in_addr()
            guard inet_pton(AF_INET, value, &address) == 1 else { return false }
            return withUnsafeBytes(of: address) { bytes in
                bytes.first == 127
            }
        case .v6(let value):
            var address = in6_addr()
            guard inet_pton(AF_INET6, value, &address) == 1 else { return false }
            return withUnsafeBytes(of: address) { bytes in
                bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            }
        }
    }
}

public enum ListenerBind: Codable, Hashable, Sendable {
    case loopbackV4
    case loopbackV6
    case wildcardV4
    case wildcardV6
    case specific(IPAddress)

    public var isLoopback: Bool {
        switch self {
        case .loopbackV4, .loopbackV6: true
        case .wildcardV4, .wildcardV6: false
        case .specific(let address): address.isLoopback
        }
    }

    public var forwardingHost: String {
        switch self {
        case .loopbackV4, .wildcardV4: "127.0.0.1"
        case .loopbackV6, .wildcardV6: "::1"
        case .specific(let address): address.value
        }
    }
}

public struct RemoteServiceEndpoint: Codable, Hashable, Sendable {
    public let bind: ListenerBind
    public let port: UInt16
    public let path: String?

    public init(bind: ListenerBind, port: UInt16, path: String? = nil) {
        self.bind = bind
        self.port = port
        self.path = path
    }
}

public enum ServiceEndpointFormattingError: Error, Equatable, Sendable {
    case invalidHost
    case invalidPort
    case invalidPath
    case unsupportedScheme
}

public enum ServiceAccessEndpointFormatter {
    public static func url(
        scheme: ServiceProtocol,
        host: String,
        port: UInt16,
        path: String?
    ) throws -> String {
        guard let urlScheme = scheme.urlScheme else {
            throw ServiceEndpointFormattingError.unsupportedScheme
        }
        guard port > 0 else { throw ServiceEndpointFormattingError.invalidPort }

        var components = URLComponents()
        components.scheme = urlScheme
        components.host = try urlHost(host)
        components.port = Int(port)
        if let path = try normalizedPath(path) {
            components.percentEncodedPath = path
        }
        guard let string = components.string else {
            throw ServiceEndpointFormattingError.invalidHost
        }
        return string
    }

    public static func tcpHostPort(host: String, port: UInt16) throws -> String {
        guard port > 0 else { throw ServiceEndpointFormattingError.invalidPort }
        let formattedHost = try urlHost(host)
        return "\(formattedHost):\(port)"
    }

    public static func tunnelURL(
        scheme: ServiceProtocol,
        localPort: UInt16,
        path: String?
    ) throws -> String {
        try url(scheme: scheme, host: "127.0.0.1", port: localPort, path: path)
    }

    public static func tunnelTCPHostPort(localPort: UInt16) throws -> String {
        try tcpHostPort(host: "127.0.0.1", port: localPort)
    }

    private static func urlHost(_ host: String) throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == host,
              !containsControlOrWhitespace(trimmed),
              !trimmed.contains("@"),
              !trimmed.contains("/"),
              !trimmed.contains("?"),
              !trimmed.contains("#") else {
            throw ServiceEndpointFormattingError.invalidHost
        }

        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
                throw ServiceEndpointFormattingError.invalidHost
            }
        }
        let unbracketed = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        if unbracketed.contains(":") {
            guard let address = IPAddress(unbracketed), address.isIPv6 else {
                throw ServiceEndpointFormattingError.invalidHost
            }
            return "[\(address.value)]"
        }
        guard !unbracketed.contains("[") && !unbracketed.contains("]") else {
            throw ServiceEndpointFormattingError.invalidHost
        }
        return unbracketed
    }

    private static func normalizedPath(_ path: String?) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard path.hasPrefix("/"),
              !path.contains("?"),
              !path.contains("#"),
              !containsControlOrWhitespace(path),
              path.removingPercentEncoding != nil else {
            throw ServiceEndpointFormattingError.invalidPath
        }
        return path
    }

    private static func containsControlOrWhitespace(_ value: String, includeWhitespace: Bool = true) -> Bool {
        value.unicodeScalars.contains { scalar in
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
            return isControl || (includeWhitespace && CharacterSet.whitespacesAndNewlines.contains(scalar))
        }
    }
}

public enum TargetProbeResult: Equatable, Sendable {
    case notAttempted
    case reachable
    case refused
    case timedOut
    case indeterminate
}

public enum ServiceAccessDecision: Equatable, Sendable {
    case direct
    case tunnel
    case failed(OperationFailureCode)
}

public enum ServiceAccessDecider {
    public static func decide(
        listener: ListenerBind,
        probe: TargetProbeResult,
        originSensitive: Bool
    ) -> ServiceAccessDecision {
        let mode: ServiceAccessDecision
        if listener.isLoopback {
            mode = .tunnel
        } else {
            switch probe {
            case .reachable:
                mode = .direct
            case .notAttempted, .refused, .timedOut:
                mode = .tunnel
            case .indeterminate:
                return .failed(.targetProbeIndeterminate)
            }
        }

        if originSensitive, mode == .tunnel {
            return .failed(.originSensitiveTunnelUnsupported)
        }
        return mode
    }
}

public struct LocalEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum TunnelCloseReason: String, Codable, Hashable, Sendable {
    case userRequested
    case authoritativeDeletion
    case applicationTermination
    case sleep
    case networkChanged
    case brokerExited
    case targetFailure
    case reservationCancelled
}

public enum CleanupStatus: String, Codable, Hashable, Sendable {
    case notNeeded
    case completed
    case pending
}

public enum TunnelState: Equatable, Sendable {
    case allocatingPort(attempt: Int)
    case starting
    case forwardEstablished
    case verifyingTarget
    case targetVerified(TargetVerificationEvidence)
    case active(local: LocalEndpoint, reused: Bool)
    case stopping(TunnelCloseReason)
    case closed(TunnelCloseReason)
    case failed(OperationFailureCode, cleanup: CleanupStatus)
}

public struct TunnelHandle: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let serviceID: UUID?
    public let hostID: UUID
    public let local: LocalEndpoint
    public let reused: Bool
    public let subject: TunnelSubject
    public let verificationEvidence: TargetVerificationEvidence?

    public init(
        id: UUID,
        serviceID: UUID?,
        hostID: UUID,
        local: LocalEndpoint,
        reused: Bool = false,
        subject: TunnelSubject? = nil,
        verificationEvidence: TargetVerificationEvidence? = nil
    ) {
        self.id = id
        self.serviceID = serviceID
        self.hostID = hostID
        self.local = local
        self.reused = reused
        self.subject = subject ?? TunnelSubject(
            operationID: id,
            sessionID: id,
            candidateID: serviceID ?? hostID,
            sshIdentityID: hostID,
            sshAddressID: hostID,
            remoteDigest: "legacy-handle",
            networkEpoch: 0
        )
        self.verificationEvidence = verificationEvidence
    }

    public var evidence: TargetVerificationEvidence? { verificationEvidence }
}

public struct TunnelRequest: Hashable, Sendable {
    public let operationID: UUID
    public let sessionID: UUID
    public let candidateID: UUID
    public let serviceID: UUID?
    public let hostID: UUID
    public let sshIdentityID: UUID
    public let sshAddressID: UUID
    public let serviceProtocol: ServiceProtocol
    public let sshHost: String
    public let sshPort: UInt16
    public let username: String
    public let identityPath: String
    public let knownHostsPath: String
    public let remote: RemoteServiceEndpoint
    public let networkEpoch: UInt64
    public let originSensitive: Bool

    public init(
        operationID: UUID,
        serviceID: UUID? = nil,
        hostID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        serviceProtocol: ServiceProtocol,
        sshHost: String,
        sshPort: UInt16,
        username: String,
        identityPath: String,
        knownHostsPath: String,
        remote: RemoteServiceEndpoint,
        networkEpoch: UInt64,
        originSensitive: Bool = false,
        sessionID: UUID? = nil,
        candidateID: UUID? = nil
    ) {
        self.operationID = operationID
        self.sessionID = sessionID ?? operationID
        self.candidateID = candidateID ?? sshAddressID
        self.serviceID = serviceID
        self.hostID = hostID
        self.sshIdentityID = sshIdentityID
        self.sshAddressID = sshAddressID
        self.serviceProtocol = serviceProtocol
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.identityPath = identityPath
        self.knownHostsPath = knownHostsPath
        self.remote = remote
        self.networkEpoch = networkEpoch
        self.originSensitive = originSensitive
    }

    public var subject: TunnelSubject {
        if let serviceID {
            return TunnelSubject(
                serviceID: serviceID,
                sshIdentityID: sshIdentityID,
                sshAddressID: sshAddressID,
                remote: remote,
                networkEpoch: networkEpoch
            )
        }
        return TunnelSubject(
            operationID: operationID,
            sessionID: sessionID,
            candidateID: candidateID,
            sshIdentityID: sshIdentityID,
            sshAddressID: sshAddressID,
            remote: remote,
            networkEpoch: networkEpoch
        )
    }

    public func withServiceID(_ serviceID: UUID) -> TunnelRequest {
        TunnelRequest(
            operationID: operationID,
            serviceID: serviceID,
            hostID: hostID,
            sshIdentityID: sshIdentityID,
            sshAddressID: sshAddressID,
            serviceProtocol: serviceProtocol,
            sshHost: sshHost,
            sshPort: sshPort,
            username: username,
            identityPath: identityPath,
            knownHostsPath: knownHostsPath,
            remote: remote,
            networkEpoch: networkEpoch,
            originSensitive: originSensitive,
            sessionID: sessionID,
            candidateID: candidateID
        )
    }
}

public struct TunnelOpenFailure: Error, Equatable, Sendable {
    public let code: OperationFailureCode
    public let cleanup: CleanupStatus

    public init(code: OperationFailureCode, cleanup: CleanupStatus = .notNeeded) {
        self.code = code
        self.cleanup = cleanup
    }
}

public struct TunnelBrokerConfiguration: Hashable, Sendable {
    public let localPort: UInt16
    public let remoteHost: String
    public let remotePort: UInt16
    public let sshHost: String
    public let sshPort: UInt16
    public let username: String
    public let identityPath: String
    public let knownHostsPath: String
    public let controlPath: String
    public let leasePath: String
    public let subject: TunnelSubject?

    public init(
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        sshHost: String,
        sshPort: UInt16,
        username: String,
        identityPath: String,
        knownHostsPath: String,
        controlPath: String,
        leasePath: String,
        subject: TunnelSubject? = nil
    ) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.identityPath = identityPath
        self.knownHostsPath = knownHostsPath
        self.controlPath = controlPath
        self.leasePath = leasePath
        self.subject = subject
    }
}

public struct TunnelBrokerCommand: Equatable, Sendable {
    public let brokerArguments: [String]
    public let sshArguments: [String]

    public init(brokerArguments: [String], sshArguments: [String]) {
        self.brokerArguments = brokerArguments
        self.sshArguments = sshArguments
    }
}

public enum TunnelBrokerCommandBuilder {
    public static func make(configuration: TunnelBrokerConfiguration) throws -> TunnelBrokerCommand {
        guard configuration.localPort > 0,
              configuration.remotePort > 0,
              configuration.sshPort > 0,
              validArgument(configuration.remoteHost),
              validArgument(configuration.sshHost),
              validUsername(configuration.username),
              !configuration.identityPath.isEmpty,
              !configuration.knownHostsPath.isEmpty,
              !configuration.controlPath.isEmpty,
              configuration.controlPath.utf8.count <= 103,
              !configuration.leasePath.isEmpty else {
            throw TunnelOpenFailure(code: .invalidTunnelRequest)
        }

        do {
            _ = try ServiceAccessEndpointFormatter.tcpHostPort(
                host: configuration.sshHost,
                port: configuration.sshPort
            )
            _ = try ServiceAccessEndpointFormatter.tcpHostPort(
                host: configuration.remoteHost,
                port: configuration.remotePort
            )
        } catch {
            throw TunnelOpenFailure(code: .invalidTunnelRequest)
        }
        let target = configuration.sshHost.contains(":")
            ? "\(configuration.username)@[\(configuration.sshHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]"
            : "\(configuration.username)@\(configuration.sshHost)"
        let localForward = "127.0.0.1:\(configuration.localPort):\(configuration.remoteHost.contains(":") ? "[\(configuration.remoteHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : configuration.remoteHost):\(configuration.remotePort)"

        let brokerArguments = [
            "start",
            "--local-port", String(configuration.localPort),
            "--remote-host", configuration.remoteHost,
            "--remote-port", String(configuration.remotePort),
            "--ssh-host", configuration.sshHost,
            "--ssh-port", String(configuration.sshPort),
            "--username", configuration.username,
            "--identity-path", configuration.identityPath,
            "--known-hosts-path", configuration.knownHostsPath,
            "--control-path", configuration.controlPath,
            "--lease-path", configuration.leasePath
        ]
        let sshArguments = [
            "-T", "-N", "-M", "-S", configuration.controlPath,
            "-vv",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(configuration.knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
            "-i", configuration.identityPath,
            "-L", localForward,
            "-p", String(configuration.sshPort),
            target
        ]
        return TunnelBrokerCommand(brokerArguments: brokerArguments, sshArguments: sshArguments)
    }

    private static func validArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func validUsername(_ value: String) -> Bool {
        validArgument(value) && !value.contains("@")
    }
}

public enum TunnelBrokerOutputEvent: Equatable, Sendable {
    case forwardEstablished
    case forwardRejected
    case targetRefused
    case targetTimedOut
    case targetProbeIndeterminate
    case unknownOutput
}

public struct TunnelBrokerOutputRecognizer: Sendable {
    public static let maximumBytes = 64 * 1024

    private var buffered = Data()
    private var hasFailedClosed = false
    private var totalBytes = 0

    public init() {}

    public mutating func consume(_ data: Data) -> [TunnelBrokerOutputEvent] {
        guard !hasFailedClosed else { return [] }
        guard totalBytes <= Self.maximumBytes,
              data.count <= Self.maximumBytes - totalBytes else {
            hasFailedClosed = true
            return [.unknownOutput]
        }
        totalBytes += data.count
        buffered.append(data)
        var events: [TunnelBrokerOutputEvent] = []
        while let newline = buffered.firstIndex(of: 0x0A) {
            let lineData = buffered.prefix(upTo: newline)
            buffered.removeSubrange(...newline)
            events.append(contentsOf: parseLine(lineData))
        }
        return events
    }

    public mutating func finish() -> [TunnelBrokerOutputEvent] {
        guard !hasFailedClosed, !buffered.isEmpty else { return [] }
        let lineData = buffered
        buffered.removeAll(keepingCapacity: false)
        return parseLine(lineData)
    }

    private mutating func parseLine(_ lineData: Data) -> [TunnelBrokerOutputEvent] {
        let line = String(decoding: lineData, as: UTF8.self)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lower = trimmed.lowercased()
        if trimmed == "FORWARD_ESTABLISHED" || lower.range(
            of: #"channel [0-9]+: open confirm"#,
            options: .regularExpression
        ) != nil {
            return [.forwardEstablished]
        }
        if trimmed.hasPrefix("FORWARD_FAILED") || lower.range(
            of: #"channel [0-9]+: open failed"#,
            options: .regularExpression
        ) != nil {
            if lower == "forward_failed forward_rejected" {
                return [.forwardRejected]
            }
            if lower.contains("refused") {
                return [.targetRefused]
            }
            if lower.contains("timed out") || lower.contains("timeout") || lower.contains("timed_out") {
                return [.targetTimedOut]
            }
            if lower.contains("target_probe_indeterminate") {
                return [.targetProbeIndeterminate]
            }
        }

        hasFailedClosed = true
        return [.unknownOutput]
    }
}
