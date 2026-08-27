import Foundation

/// Target of a single TCP reachability probe, resolved from an `AddressCandidate`.
/// Mirrors architecture section 7.1 `ProbeTarget`.
public enum ProbeTarget: Hashable, Sendable {
    /// Probe the candidate's configured SSH port.
    case ssh
    /// Probe a service port on the candidate's host.
    case service(UInt16)
}

/// A concrete `host:port` pair handed to the platform probe (NWConnection seam).
public struct NetworkTarget: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// One address of a Host that may be probed. History only influences ordering;
/// it never creates trust (architecture 7.2).
public struct AddressCandidate: Hashable, Sendable, Identifiable {
    public var addressID: UUID
    public var host: String
    public var sshPort: UInt16
    public var sortOrder: Int
    /// Most recent success under the current SSID. Callers pass `nil` for every
    /// candidate when the SSID hint is unavailable or denied.
    public var lastSuccessOnCurrentSSIDAt: Date?
    /// Most recent success observed on this machine, any network.
    public var lastLocalSuccessAt: Date?

    public var id: UUID { addressID }

    public init(
        addressID: UUID,
        host: String,
        sshPort: UInt16,
        sortOrder: Int,
        lastSuccessOnCurrentSSIDAt: Date? = nil,
        lastLocalSuccessAt: Date? = nil
    ) {
        self.addressID = addressID
        self.host = host
        self.sshPort = sshPort
        self.sortOrder = sortOrder
        self.lastSuccessOnCurrentSSIDAt = lastSuccessOnCurrentSSIDAt
        self.lastLocalSuccessAt = lastLocalSuccessAt
    }

    public func target(for probeTarget: ProbeTarget) -> NetworkTarget {
        switch probeTarget {
        case .ssh:
            return NetworkTarget(host: host, port: sshPort)
        case .service(let port):
            return NetworkTarget(host: host, port: port)
        }
    }
}

/// Presentation state of an evidence record. Staleness is derived from the
/// network epoch, never stored: evidence from an older epoch is stale the
/// moment the epoch moves (architecture 7.2).
public enum ReachabilityState: String, Hashable, Sendable {
    case unknown
    case reachable
    case unreachable
    case stale
}

/// Terminal result of probing one candidate. Carries no address strings beyond
/// the stable ID plus the probed target, so records/audit can persist it.
public struct ProbeEvidence: Hashable, Sendable {
    public var addressID: UUID
    public var target: NetworkTarget
    public var networkEpoch: UInt64
    public var observedAt: Date
    public var wasReachable: Bool
    /// Populated for negative or indeterminate results; `nil` when reachable.
    public var failureCode: OperationFailureCode?

    public init(
        addressID: UUID,
        target: NetworkTarget,
        networkEpoch: UInt64,
        observedAt: Date,
        wasReachable: Bool,
        failureCode: OperationFailureCode?
    ) {
        self.addressID = addressID
        self.target = target
        self.networkEpoch = networkEpoch
        self.observedAt = observedAt
        self.wasReachable = wasReachable
        self.failureCode = failureCode
    }

    public func state(atEpoch currentEpoch: UInt64) -> ReachabilityState {
        guard networkEpoch == currentEpoch else { return .stale }
        return wasReachable ? .reachable : .unreachable
    }
}

/// A verified address choice. `usedFixedAddress` distinguishes the caller-pinned
/// address from an explicitly resumed user choice.
public struct AddressDecision: Hashable, Sendable {
    public var addressID: UUID
    public var target: NetworkTarget
    public var evidence: ProbeEvidence
    public var usedFixedAddress: Bool

    public init(addressID: UUID, target: NetworkTarget, evidence: ProbeEvidence, usedFixedAddress: Bool) {
        self.addressID = addressID
        self.target = target
        self.evidence = evidence
        self.usedFixedAddress = usedFixedAddress
    }
}

/// Input of one address-selection operation. The caller resolves
/// `fixedAddressID` beforehand with Service > SSHIdentity > Host precedence and
/// must not fall back to a lower-precedence value when a reference is invalid
/// (architecture 7.2, invariant 5.3.3).
public struct AddressSelectionRequest: Sendable {
    public var operationID: UUID
    public var hostID: UUID
    /// Host mutation counter at request time; a resume is rejected with
    /// `staleRevision` when the Host changed while WaitingForUser.
    public var hostRevision: UInt64
    public var target: ProbeTarget
    public var fixedAddressID: UUID?
    public var candidates: [AddressCandidate]
    public var networkEpoch: UInt64

    public init(
        operationID: UUID,
        hostID: UUID,
        hostRevision: UInt64,
        target: ProbeTarget,
        fixedAddressID: UUID?,
        candidates: [AddressCandidate],
        networkEpoch: UInt64
    ) {
        self.operationID = operationID
        self.hostID = hostID
        self.hostRevision = hostRevision
        self.target = target
        self.fixedAddressID = fixedAddressID
        self.candidates = candidates
        self.networkEpoch = networkEpoch
    }
}

/// Opaque one-shot handle for the WaitingForUser state. Bound to the
/// operation, the Host revision, the network epoch and the exact set of
/// verified alternatives; expires after `choiceTokenLifetime` (30 s default).
public struct AddressChoiceContinuation: Hashable, Sendable {
    public var token: UUID
    public var operationID: UUID
    public var expiresAt: Date
    public var verifiedAddressIDs: [UUID]

    public init(token: UUID, operationID: UUID, expiresAt: Date, verifiedAddressIDs: [UUID]) {
        self.token = token
        self.operationID = operationID
        self.expiresAt = expiresAt
        self.verifiedAddressIDs = verifiedAddressIDs
    }
}

/// Outcome of `select`/`resumeChoice`/`cancelChoice`. Every operation reaches
/// exactly one terminal outcome; duplicates return the cached terminal value.
public enum AddressSelectionOutcome: Sendable {
    case selected(AddressDecision)
    case requiresUserChoice(
        continuation: AddressChoiceContinuation,
        failedFixed: ProbeEvidence,
        verifiedAlternatives: [ProbeEvidence]
    )
    case unavailable([ProbeEvidence])
    case cancelled(OperationFailureCode)
}

/// NWConnection seam. Implementations perform a TCP handshake only: no ping,
/// no "DNS resolved means reachable" shortcut. A probe must honour task
/// cancellation promptly and report `.probeCancelled`; it must never throw —
/// every failure maps to an `OperationFailureCode` inside the evidence.
public protocol ReachabilityProbing: Sendable {
    func probe(_ target: NetworkTarget, timeout: Duration, operationID: UUID) async -> ProbeEvidence
}

/// NWPathMonitor seam. Path signature changes, Tailscale state changes and
/// willSleep/didWake all increment the epoch; pure logic never touches the
/// platform singletons directly.
public protocol NetworkEpochProviding: Sendable {
    func currentEpoch() async -> UInt64
}

/// Architecture 7.1 public surface, extended with the explicit WaitingForUser
/// continuation (`resumeChoice`/`cancelChoice`).
public protocol AddressSelecting: Sendable {
    func select(_ request: AddressSelectionRequest) async -> AddressSelectionOutcome
    func resumeChoice(
        operationID: UUID,
        token: UUID,
        selectedAddressID: UUID,
        hostRevision: UInt64,
        networkEpoch: UInt64
    ) async -> AddressSelectionOutcome
    func cancelChoice(operationID: UUID, token: UUID) async -> AddressSelectionOutcome
    func invalidate(before networkEpoch: UInt64) async
}

/// Rollout gate for slice D. The coordinator ships dark: nothing constructs or
/// calls it while the flag is off. Rollback = keep the flag off / stop calling
/// the coordinator; legacy reachability results must not be reused across the
/// switch (see JODER-15).
public enum AddressSelectionV2Gate {
    public static let defaultEnabled = false
}
