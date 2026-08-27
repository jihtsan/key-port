import Foundation

public enum OperationFailureCode: String, Codable, CaseIterable, Error, Hashable, Sendable {
    case invalidAddress
    case dnsUnresolved
    case tcpTimeout
    case tcpRefused
    case networkChanged
    case probeCancelled
    case fixedAddressUnavailable
    case addressChoiceStale
    case invalidAddressChoice
    case hostKeyPending
    case hostKeyChanged
    case identityUnavailable
    case keyAuthenticationFailed
    case strictHostKeyRejected
    case unsupportedOS
    case toolUnavailable
    case outputLimit
    case parseFailed
    case remoteExecutionFailed
    case protocolUnconfirmed
    case directUnavailable
    case targetVerificationRequired
    case originSensitiveTunnelUnsupported
    case tlsHandledExternally
    case localPortUnavailable
    case localPortReleaseTimeout
    case forwardRejected
    case targetConnectionRefused
    case targetConnectionTimeout
    case targetProbeIndeterminate
    case brokerExited
    case capacityReached
    case tunnelCapacityReached
    case closedForSleep
    case closedForNetworkChange
    case cleanupPending
    case reservationCancelled
    case targetRefused
    case targetTimeout
    case unknownBrokerOutput
    case serviceAccessDisabled
    case invalidTunnelRequest
    case staleRevision
    case addressStillReferenced
    case lastAddressForActiveIdentity
    case keyStillAuthorized
    case decodeFailed
    case invariantFailed
    case artifactMismatch
    case legacyVersionReuse
    case legacyImmutableKeyConflict
    case concurrentConflict
    case payloadTooLarge
    case mixedVersionPending
    case authorityGateFailed
    case rollbackProjectionInvalid
    case binaryDowngradeUnsafe
    case unexpectedCloudField
    case historyWriteFailed
    case historyTerminalConflict
    case hintDenied
    case hintUnavailable
}

public enum DiscoveryWarningCode: String, Codable, CaseIterable, Hashable, Sendable {
    case permissionLimited
    case partialParse
    case truncated
    case containerMappingNotObservable
}

public enum CommittedWarningCode: String, Codable, CaseIterable, Hashable, Sendable {
    case derivedConfigOutOfDate
    case credentialCleanupPending
    case keyMaterialCleanupPending
    case remoteAuthorizationMayRemain
    case cleanupPending
}

public enum OperationStage: String, Codable, CaseIterable, Hashable, Sendable {
    case address
    case sshTrust
    case discovery
    case service
    case tunnel
    case model
    case migration
    case history
    case networkHint
}

public enum RecoveryAction: String, Codable, CaseIterable, Hashable, Sendable {
    case edit
    case retry
    case chooseVerifiedAlternative
    case verifyFingerprint
    case prepareLocalKey
    case reauthorize
    case installSystemTool
    case acceptLimitedCandidates
    case closeOtherTunnels
    case completeCleanup
    case reload
    case provideReplacement
    case revokeRemoteAuthorization
    case resolveConflict
    case completeRolloutGate
    case openSystemSettings
}

public struct StableOperationFailure: Codable, Hashable, Sendable {
    public var stage: OperationStage
    public var objectID: String
    public var code: OperationFailureCode
    public var recoveryAction: RecoveryAction

    public init(
        stage: OperationStage,
        objectID: String,
        code: OperationFailureCode,
        recoveryAction: RecoveryAction
    ) {
        self.stage = stage
        self.objectID = objectID
        self.code = code
        self.recoveryAction = recoveryAction
    }
}
