import Foundation
import KeyPortCore

enum DiscoveryFeatureFlags {
    static let discoveryEnabledKey = "KeyPort.discoveryEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: discoveryEnabledKey)
    }
}

enum ListenerDiscoveryTriggerError: Error, Equatable, Sendable {
    case featureDisabled
    case hostNotFound
    case hostNotAuthorized
}

protocol ListenerDiscoveryAdapter: Sendable {
    var platform: DiscoveryPlatform { get }
    func capabilities(using session: TrustedSSHSession) async throws -> DiscoveryCapabilities
    func discover(
        using session: TrustedSSHSession,
        limits: DiscoveryLimits
    ) async throws -> DiscoveryResult
}

struct SSHListenerDiscoveryAdapter: ListenerDiscoveryAdapter {
    // The remote platform is learned from the fixed capability probe.
    let platform: DiscoveryPlatform = .unsupported

    func capabilities(using session: TrustedSSHSession) async throws -> DiscoveryCapabilities {
        let result: TrustedSSHCommandResult
        do {
            result = try await session.executeRaw(.listenerCapabilities, limits: processLimits(for: .default))
        } catch {
            throw mapExecutionError(error, session: session)
        }

        switch result.ending {
        case .exited(0):
            return DiscoveryCapabilities.parse(result.stdout)
        case .exited(125):
            throw failure(for: session, code: .unsupportedOS, recoveryAction: .retry)
        case .exited:
            throw failure(for: session, code: .remoteExecutionFailed, recoveryAction: .retry)
        case .timedOut:
            throw failure(for: session, code: .tcpTimeout, recoveryAction: .retry)
        case .outputLimitExceeded:
            throw failure(for: session, code: .outputLimit, recoveryAction: .retry)
        case .cancelled:
            throw failure(for: session, code: .probeCancelled, recoveryAction: .retry)
        }
    }

    func discover(
        using session: TrustedSSHSession,
        limits: DiscoveryLimits = .default
    ) async throws -> DiscoveryResult {
        let capabilities = try await capabilities(using: session)
        guard capabilities.isSupported else {
            throw failure(for: session, code: .unsupportedOS, recoveryAction: .retry)
        }
        guard let tool = capabilities.preferredTool else {
            throw failure(for: session, code: .toolUnavailable, recoveryAction: .installSystemTool)
        }

        let result: TrustedSSHCommandResult
        do {
            result = try await session.executeRaw(
                .listenerSnapshot,
                limits: processLimits(for: limits)
            )
        } catch {
            throw mapExecutionError(error, session: session)
        }

        switch result.ending {
        case .exited(let status):
            if status == 127 {
                throw failure(for: session, code: .toolUnavailable, recoveryAction: .installSystemTool)
            }
            if status != 0 && !hasPermissionDiagnostic(result.stderr) {
                throw failure(for: session, code: .remoteExecutionFailed, recoveryAction: .retry)
            }
        case .timedOut:
            throw failure(for: session, code: .tcpTimeout, recoveryAction: .retry)
        case .outputLimitExceeded:
            throw failure(for: session, code: .outputLimit, recoveryAction: .retry)
        case .cancelled:
            throw failure(for: session, code: .probeCancelled, recoveryAction: .retry)
        }

        let parsed: DiscoveryResult
        do {
            parsed = try ListenerDiscoveryParser.parse(
                result.stdout,
                platform: capabilities.platform,
                tool: tool,
                limits: limits
            )
        } catch let error as ListenerDiscoveryParseError {
            switch error {
            case .outputLimitExceeded:
                throw failure(for: session, code: .outputLimit, recoveryAction: .retry)
            case .unsupportedPlatform:
                throw failure(for: session, code: .unsupportedOS, recoveryAction: .retry)
            case .noValidRecords:
                throw failure(for: session, code: .parseFailed, recoveryAction: .retry)
            }
        } catch {
            throw failure(for: session, code: .parseFailed, recoveryAction: .retry)
        }

        guard hasPermissionDiagnostic(result.stderr) else { return parsed }
        return DiscoveryResult(
            candidates: parsed.candidates,
            warnings: parsed.warnings + [.permissionLimited],
            partialParseCount: parsed.partialParseCount,
            truncated: parsed.truncated
        )
    }

    private func processLimits(for limits: DiscoveryLimits) -> ProcessExecutionLimits {
        ProcessExecutionLimits(
            timeout: durationInSeconds(limits.timeout),
            maximumStdoutBytes: limits.maximumOutputBytes,
            maximumStderrBytes: limits.maximumOutputBytes,
            maximumCombinedOutputBytes: limits.maximumOutputBytes
        )
    }

    private func durationInSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private func mapExecutionError(_ error: Error, session: TrustedSSHSession) -> StableOperationFailure {
        if let failure = error as? StableOperationFailure { return failure }
        if error is CancellationError {
            return failure(for: session, code: .probeCancelled, recoveryAction: .retry)
        }
        return failure(for: session, code: .remoteExecutionFailed, recoveryAction: .retry)
    }

    private func failure(
        for session: TrustedSSHSession,
        code: OperationFailureCode,
        recoveryAction: RecoveryAction
    ) -> StableOperationFailure {
        StableOperationFailure(
            stage: .discovery,
            objectID: session.route.id.uuidString.lowercased(),
            code: code,
            recoveryAction: recoveryAction
        )
    }

    private func hasPermissionDiagnostic(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).localizedLowercase
        return text.contains("permission denied")
            || text.contains("operation not permitted")
            || text.contains("not permitted")
    }
}
