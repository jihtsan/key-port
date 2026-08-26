import Foundation

/// Tunables of the address-selection algorithm (architecture 7.2 / 13).
/// Defaults are the shipping values; tests inject smaller durations.
public struct AddressSelectionConfiguration: Sendable {
    public var probeTimeout: Duration
    public var maxConcurrentProbes: Int
    public var maxCandidates: Int
    public var overallBudget: Duration
    public var choiceTokenLifetime: TimeInterval

    public init(
        probeTimeout: Duration = .seconds(5),
        maxConcurrentProbes: Int = 3,
        maxCandidates: Int = 12,
        overallBudget: Duration = .seconds(20),
        choiceTokenLifetime: TimeInterval = 30
    ) {
        self.probeTimeout = probeTimeout
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        self.maxCandidates = max(1, maxCandidates)
        self.overallBudget = overallBudget
        self.choiceTokenLifetime = choiceTokenLifetime
    }
}

/// Pure address-verification coordinator (architecture 7.2 state machine).
///
/// States per operation: Preparing -> ProbingFixed | ProbingRanked ->
/// Selected | Unavailable, ProbingFixed -> WaitingForUser -> Selected |
/// Cancelled, any probing state -> Stale (network epoch change, surfaced as
/// `.cancelled(.networkChanged)`). Terminal outcomes are cached per
/// `operationID`; WaitingForUser continuations live only in memory, so an app
/// crash closes them deterministically (a fresh coordinator rejects the token
/// with `invalidAddressChoice`).
public actor AddressSelectionCoordinator: AddressSelecting {
    private struct PendingChoice {
        var token: UUID
        var operationID: UUID
        var hostID: UUID
        var hostRevision: UInt64
        var networkEpoch: UInt64
        var expiresAt: Date
        var alternatives: [UUID: ProbeEvidence]
    }

    private let probe: any ReachabilityProbing
    private let epochProvider: any NetworkEpochProviding
    private let configuration: AddressSelectionConfiguration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void

    private var pendingChoices: [UUID: PendingChoice] = [:]
    private var pendingTokenByOperation: [UUID: UUID] = [:]
    private var terminalOutcomes: [UUID: AddressSelectionOutcome] = [:]
    private var inFlightOperations: [UUID: Task<AddressSelectionOutcome, Never>] = [:]
    private var invalidatedBeforeEpoch: UInt64 = 0

    public init(
        probe: any ReachabilityProbing,
        epochProvider: any NetworkEpochProviding,
        configuration: AddressSelectionConfiguration = AddressSelectionConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.probe = probe
        self.epochProvider = epochProvider
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
    }

    // MARK: - AddressSelecting

    public func select(_ request: AddressSelectionRequest) async -> AddressSelectionOutcome {
        if let cached = terminalOutcomes[request.operationID] {
            return cached
        }

        let operation = inFlightOperations[request.operationID] ?? {
            let task = Task { await self.performSelect(request) }
            inFlightOperations[request.operationID] = task
            return task
        }()
        let outcome = await withTaskCancellationHandler(operation: {
            await operation.value
        }, onCancel: {
            operation.cancel()
        })
        if case .requiresUserChoice = outcome {
            // Keep the shared continuation available until resume/cancel/invalidate.
        } else {
            inFlightOperations.removeValue(forKey: request.operationID)
        }
        return outcome
    }

    private func performSelect(_ request: AddressSelectionRequest) async -> AddressSelectionOutcome {
        // Preparing: a request carrying an already-stale epoch fails fast.
        guard await isEpochCurrent(request.networkEpoch) else {
            return finish(request.operationID, .cancelled(.networkChanged))
        }

        var fixedCandidate: AddressCandidate?
        if let fixedAddressID = request.fixedAddressID {
            guard let resolved = request.candidates.first(where: { $0.addressID == fixedAddressID }) else {
                // Pinned reference is cross-Host, deleted or unresolved: report
                // invalidAddress, never degrade to a lower-precedence value.
                return finish(request.operationID, .cancelled(.invalidAddress))
            }
            fixedCandidate = resolved
        }

        let ranked = Self.rank(request.candidates)
            .prefix(configuration.maxCandidates)
            .filter { $0.addressID != fixedCandidate?.addressID }
        let deadline = now().addingTimeInterval(Self.timeInterval(configuration.overallBudget))

        if let fixedCandidate {
            return await selectWithFixed(request, fixed: fixedCandidate, ranked: ranked, deadline: deadline)
        }
        return await selectRanked(request, ranked: ranked, deadline: deadline, prefixEvidence: [])
    }

    public func resumeChoice(
        operationID: UUID,
        token: UUID,
        selectedAddressID: UUID,
        hostRevision: UInt64,
        networkEpoch: UInt64
    ) async -> AddressSelectionOutcome {
        if let cached = terminalOutcomes[operationID] {
            return cached
        }
        guard let pending = pendingChoices[token], pending.operationID == operationID else {
            // Unknown or forged token, including tokens issued before a crash.
            return finish(operationID, .cancelled(.invalidAddressChoice))
        }
        guard await epochProvider.currentEpoch() == pending.networkEpoch else {
            return closeChoice(pending, outcome: .cancelled(.networkChanged))
        }
        guard now() < pending.expiresAt else {
            return closeChoice(pending, outcome: .cancelled(.addressChoiceStale))
        }
        guard networkEpoch == pending.networkEpoch, networkEpoch >= invalidatedBeforeEpoch else {
            return closeChoice(pending, outcome: .cancelled(.networkChanged))
        }
        guard hostRevision == pending.hostRevision else {
            return closeChoice(pending, outcome: .cancelled(.staleRevision))
        }
        guard let evidence = pending.alternatives[selectedAddressID] else {
            // The user can only pick a verified alternative; anything else is forged.
            return closeChoice(pending, outcome: .cancelled(.invalidAddressChoice))
        }
        let decision = AddressDecision(
            addressID: selectedAddressID,
            target: evidence.target,
            evidence: evidence,
            usedFixedAddress: false
        )
        return closeChoice(pending, outcome: .selected(decision))
    }

    public func cancelChoice(operationID: UUID, token: UUID) async -> AddressSelectionOutcome {
        if let cached = terminalOutcomes[operationID] {
            return cached
        }
        guard let pending = pendingChoices[token], pending.operationID == operationID else {
            return finish(operationID, .cancelled(.invalidAddressChoice))
        }
        return closeChoice(pending, outcome: .cancelled(.probeCancelled))
    }

    /// NWPathMonitor / sleep-wake / Tailscale funnel: every operation and
    /// continuation older than `networkEpoch` is closed as `networkChanged`.
    /// In-flight batches notice at their next checkpoint; their in-progress
    /// probes are never reused because evidence carries the old epoch.
    public func invalidate(before networkEpoch: UInt64) async {
        invalidatedBeforeEpoch = max(invalidatedBeforeEpoch, networkEpoch)
        for (token, pending) in pendingChoices where pending.networkEpoch < networkEpoch {
            pendingChoices.removeValue(forKey: token)
            pendingTokenByOperation.removeValue(forKey: pending.operationID)
            inFlightOperations.removeValue(forKey: pending.operationID)
            terminalOutcomes[pending.operationID] = .cancelled(.networkChanged)
        }
    }

    // MARK: - Introspection for UI / tests

    public func isAwaitingChoice(operationID: UUID) -> Bool {
        pendingTokenByOperation[operationID] != nil
    }

    public func terminalOutcome(for operationID: UUID) -> AddressSelectionOutcome? {
        terminalOutcomes[operationID]
    }

    // MARK: - State machine internals

    private func selectWithFixed(
        _ request: AddressSelectionRequest,
        fixed: AddressCandidate,
        ranked: [AddressCandidate],
        deadline: Date
    ) async -> AddressSelectionOutcome {
        // ProbingFixed
        if let failure = await cancellationOrEpochFailure(for: request) {
            return finish(request.operationID, failure)
        }
        let fixedEvidence = await probeBatch([fixed], request: request)[0]
        if fixedEvidence.wasReachable {
            let decision = AddressDecision(
                addressID: fixed.addressID,
                target: fixedEvidence.target,
                evidence: fixedEvidence,
                usedFixedAddress: true
            )
            return finish(request.operationID, .selected(decision))
        }
        if let failure = await cancellationOrEpochFailure(for: request) {
            return finish(request.operationID, failure)
        }

        // Fixed failed: alternatives may be verified but are never adopted
        // automatically (architecture 7.2 fixed contract).
        let (verified, allEvidence, control) = await probeRanked(request, ranked: ranked, deadline: deadline)
        if let control {
            return finish(request.operationID, control)
        }
        let evidence = [fixedEvidence] + allEvidence
        guard !verified.isEmpty else {
            return finish(request.operationID, .unavailable(evidence))
        }

        // WaitingForUser
        let token = UUID()
        let pending = PendingChoice(
            token: token,
            operationID: request.operationID,
            hostID: request.hostID,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch,
            expiresAt: now().addingTimeInterval(configuration.choiceTokenLifetime),
            alternatives: Dictionary(uniqueKeysWithValues: verified.map { ($0.addressID, $0) })
        )
        pendingChoices[token] = pending
        pendingTokenByOperation[request.operationID] = token
        return .requiresUserChoice(
            continuation: AddressChoiceContinuation(
                token: token,
                operationID: request.operationID,
                expiresAt: pending.expiresAt,
                verifiedAddressIDs: verified.map(\.addressID)
            ),
            failedFixed: fixedEvidence,
            verifiedAlternatives: verified
        )
    }

    private func selectRanked(
        _ request: AddressSelectionRequest,
        ranked: [AddressCandidate],
        deadline: Date,
        prefixEvidence: [ProbeEvidence]
    ) async -> AddressSelectionOutcome {
        // ProbingRanked
        let (verified, allEvidence, control) = await probeRanked(request, ranked: ranked, deadline: deadline)
        if let control {
            return finish(request.operationID, control)
        }
        if let best = verified.first {
            let decision = AddressDecision(
                addressID: best.addressID,
                target: best.target,
                evidence: best,
                usedFixedAddress: false
            )
            return finish(request.operationID, .selected(decision))
        }
        return finish(request.operationID, .unavailable(prefixEvidence + allEvidence))
    }

    /// Probes `ranked` in priority batches of `maxConcurrentProbes`, waiting for
    /// each batch to terminate before deciding (architecture 7.2). Returns the
    /// verified evidence in priority order, all observed evidence, and a
    /// control outcome when the operation was cancelled or went stale.
    private func probeRanked(
        _ request: AddressSelectionRequest,
        ranked: [AddressCandidate],
        deadline: Date
    ) async -> (verified: [ProbeEvidence], evidence: [ProbeEvidence], control: AddressSelectionOutcome?) {
        var verified: [ProbeEvidence] = []
        var evidence: [ProbeEvidence] = []
        var index = 0
        while index < ranked.count {
            if let failure = await cancellationOrEpochFailure(for: request) {
                return (verified, evidence, failure)
            }
            if now() >= deadline {
                break
            }
            let batch = Array(ranked[index ..< min(index + configuration.maxConcurrentProbes, ranked.count)])
            index += batch.count
            let batchEvidence = await probeBatch(batch, request: request)
            evidence.append(contentsOf: batchEvidence)
            if let failure = await cancellationOrEpochFailure(for: request) {
                return (verified, evidence, failure)
            }
            let batchVerified = batchEvidence.filter(\.wasReachable)
            verified.append(contentsOf: batchVerified)
            if !batchVerified.isEmpty {
                // Highest-priority success of this batch wins; lower-priority
                // candidates are not probed further.
                break
            }
        }
        return (verified, evidence, nil)
    }

    /// Probes one batch concurrently. Each probe is raced against the per-probe
    /// timeout; cancelling the surrounding task propagates into the probes and
    /// rewrites in-flight results as `probeCancelled`. `observedAt` is captured
    /// once per probe before any suspension so injected clocks stay
    /// deterministic for timeout evidence.
    private func probeBatch(_ batch: [AddressCandidate], request: AddressSelectionRequest) async -> [ProbeEvidence] {
        await withTaskGroup(of: (Int, ProbeEvidence).self) { group in
            for (offset, candidate) in batch.enumerated() {
                group.addTask { [probe, sleep, now, configuration] in
                    let target = candidate.target(for: request.target)
                    let timeout = configuration.probeTimeout
                    let observedAt = now()
                    func syntheticEvidence(_ code: OperationFailureCode) -> ProbeEvidence {
                        ProbeEvidence(
                            addressID: candidate.addressID,
                            target: target,
                            networkEpoch: request.networkEpoch,
                            observedAt: observedAt,
                            wasReachable: false,
                            failureCode: code
                        )
                    }
                    var evidence = await withTaskGroup(of: ProbeEvidence.self) { inner -> ProbeEvidence in
                        inner.addTask {
                            await probe.probe(target, timeout: timeout, operationID: request.operationID)
                        }
                        inner.addTask {
                            await sleep(timeout)
                            return syntheticEvidence(Task.isCancelled ? .probeCancelled : .tcpTimeout)
                        }
                        let first = await inner.next() ?? syntheticEvidence(.probeCancelled)
                        inner.cancelAll()
                        return first
                    }
                    // The coordinator owns the candidate binding: stamp the
                    // probed candidate's stable ID onto whatever the probe saw.
                    evidence.addressID = candidate.addressID
                    if Task.isCancelled {
                        evidence = syntheticEvidence(.probeCancelled)
                    }
                    return (offset, evidence)
                }
            }
            var results: [(Int, ProbeEvidence)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func cancellationOrEpochFailure(for request: AddressSelectionRequest) async -> AddressSelectionOutcome? {
        if Task.isCancelled {
            return .cancelled(.probeCancelled)
        }
        guard await isEpochCurrent(request.networkEpoch) else {
            return .cancelled(.networkChanged)
        }
        return nil
    }

    private func isEpochCurrent(_ epoch: UInt64) async -> Bool {
        guard epoch >= invalidatedBeforeEpoch else { return false }
        return await epochProvider.currentEpoch() == epoch
    }

    private func finish(_ operationID: UUID, _ outcome: AddressSelectionOutcome) -> AddressSelectionOutcome {
        terminalOutcomes[operationID] = outcome
        return outcome
    }

    private func closeChoice(_ pending: PendingChoice, outcome: AddressSelectionOutcome) -> AddressSelectionOutcome {
        pendingChoices.removeValue(forKey: pending.token)
        pendingTokenByOperation.removeValue(forKey: pending.operationID)
        inFlightOperations.removeValue(forKey: pending.operationID)
        terminalOutcomes[pending.operationID] = outcome
        return outcome
    }

    /// Ranking (architecture 7.2): most recent success under the current SSID,
    /// then most recent local success, then the user's synced `sortOrder`,
    /// then the stable ID. History only orders; it never creates trust.
    static func rank(_ candidates: [AddressCandidate]) -> [AddressCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.lastSuccessOnCurrentSSIDAt != rhs.lastSuccessOnCurrentSSIDAt {
                return (lhs.lastSuccessOnCurrentSSIDAt ?? .distantPast) > (rhs.lastSuccessOnCurrentSSIDAt ?? .distantPast)
            }
            if lhs.lastLocalSuccessAt != rhs.lastLocalSuccessAt {
                return (lhs.lastLocalSuccessAt ?? .distantPast) > (rhs.lastLocalSuccessAt ?? .distantPast)
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.addressID.uuidString < rhs.addressID.uuidString
        }
    }

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
