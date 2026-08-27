import Foundation
import XCTest
@testable import KeyPortCore

/// M6: address coordinator state machine, ranking, concurrency, timeout,
/// cancellation, network epoch and the explicit WaitingForUser continuation.
final class AddressSelectionCoordinatorTests: XCTestCase {
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let fixedID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let altA = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let altB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    // MARK: - Fixed address flow

    func testFixedSuccessSelectsFixedWithoutProbingAlternatives() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.success, host: "fixed.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal"), candidate(altA, host: "alt.internal")]
        )

        let outcome = await coordinator.select(request)
        guard case .selected(let decision) = outcome else {
            return XCTFail("expected selected, got \(outcome)")
        }
        XCTAssertEqual(decision.addressID, fixedID)
        XCTAssertTrue(decision.usedFixedAddress)
        XCTAssertEqual(probe.probedTargets, [NetworkTarget(host: "fixed.internal", port: 22)])
    }

    func testFixedDelayedSuccessAfterEpochChangeIsCancelledWithoutAcceptingEvidence() async {
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.delayedSuccess(.milliseconds(80)), host: "fixed.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider, probeTimeout: .seconds(1))
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal")]
        )

        let task = Task { await coordinator.select(request) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(probe.probedTargets.map(\.host), ["fixed.internal"])
        provider.setEpoch(8)

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled(.networkChanged))
        let terminal = await coordinator.terminalOutcome(for: request.operationID)
        XCTAssertEqual(terminal, outcome)
    }

    func testFixedFailureRequiresExplicitUserChoiceAndNeverFallsBackSilently() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.failure(.tcpRefused), host: "fixed.internal")
        probe.setBehavior(.success, host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal"), candidate(altA, host: "alt.internal")]
        )

        let outcome = await coordinator.select(request)
        guard case .requiresUserChoice(let continuation, let failedFixed, let verified) = outcome else {
            return XCTFail("fixed failure must never auto-select an alternative, got \(outcome)")
        }
        XCTAssertEqual(failedFixed.addressID, fixedID)
        XCTAssertEqual(failedFixed.failureCode, .tcpRefused)
        XCTAssertEqual(verified.map(\.addressID), [altA])
        XCTAssertEqual(continuation.verifiedAddressIDs, [altA])
        XCTAssertEqual(continuation.operationID, request.operationID)
        let awaiting = await coordinator.isAwaitingChoice(operationID: request.operationID)
        XCTAssertTrue(awaiting)
    }

    func testFixedFailureWithoutVerifiedAlternativesIsUnavailable() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.failure(.tcpRefused), host: "fixed.internal")
        probe.setBehavior(.failure(.tcpTimeout), host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal"), candidate(altA, host: "alt.internal")]
        )

        let outcome = await coordinator.select(request)
        guard case .unavailable(let evidence) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(evidence.count, 2)
        XCTAssertTrue(evidence.allSatisfy { !$0.wasReachable })
    }

    func testFixedAddressMissingFromCandidatesIsInvalidAddressWithoutFallback() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: UUID(),
            candidates: [candidate(altA, host: "alt.internal")]
        )

        let outcome = await coordinator.select(request)
        XCTAssertEqual(outcome, .cancelled(.invalidAddress))
        XCTAssertTrue(probe.probedTargets.isEmpty)
    }

    // MARK: - WaitingForUser continuation (resume / cancel)

    func testResumeWithValidTokenSelectsVerifiedAlternativeUnderSameOperation() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        guard case .selected(let decision) = outcome else {
            return XCTFail("expected selected, got \(outcome)")
        }
        XCTAssertEqual(decision.addressID, altA)
        XCTAssertFalse(decision.usedFixedAddress)
        XCTAssertTrue(decision.evidence.wasReachable)
        let stillAwaiting = await coordinator.isAwaitingChoice(operationID: request.operationID)
        XCTAssertFalse(stillAwaiting)
    }

    func testResumeRejectsForgedToken() async throws {
        let (coordinator, _, request) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: UUID(),
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(outcome, .cancelled(.invalidAddressChoice))
    }

    func testResumeRejectsForgedAddressOutsideVerifiedSet() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: UUID(),
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(outcome, .cancelled(.invalidAddressChoice))
    }

    func testResumeRejectsMismatchedOperationID() async throws {
        let (coordinator, continuation, _) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: UUID(),
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: 1,
            networkEpoch: 7
        )
        XCTAssertEqual(outcome, .cancelled(.invalidAddressChoice))
    }

    func testResumeAfterTokenExpiryIsAddressChoiceStale() async throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let (coordinator, continuation, request) = try await reachWaitingForUser(now: clock.now)

        clock.advance(31)
        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(outcome, .cancelled(.addressChoiceStale))
    }

    func testResumeWithinTokenLifetimeSucceeds() async throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let (coordinator, continuation, request) = try await reachWaitingForUser(now: clock.now)

        clock.advance(29)
        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        guard case .selected = outcome else {
            return XCTFail("token inside its 30 s lifetime must resume, got \(outcome)")
        }
    }

    func testResumeAfterNetworkEpochChangeIsNetworkChanged() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch + 1
        )
        XCTAssertEqual(outcome, .cancelled(.networkChanged))
    }

    func testResumeRejectsTokenWhenEpochProviderAdvancesAfterTokenIssued() async throws {
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.failure(.tcpRefused), host: "fixed.internal")
        probe.setBehavior(.success, host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal"), candidate(altA, host: "alt.internal")]
        )
        let outcome = await coordinator.select(request)
        guard case .requiresUserChoice(let continuation, _, _) = outcome else {
            return XCTFail("expected requiresUserChoice, got \(outcome)")
        }

        provider.setEpoch(8)
        let resumed = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(resumed, .cancelled(.networkChanged))
    }

    func testResumeAfterHostMutationIsStaleRevision() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let outcome = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision + 1,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(outcome, .cancelled(.staleRevision))
    }

    func testDuplicateResumeReturnsCachedTerminalOutcome() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let first = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        // A replayed resume must not re-run anything; the terminal outcome is cached.
        let second = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: UUID(),
            selectedAddressID: UUID(),
            hostRevision: 999,
            networkEpoch: 999
        )
        XCTAssertEqual(first, second)
    }

    func testCancelChoiceTerminatesAndDuplicateCancelIsCached() async throws {
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        let first = await coordinator.cancelChoice(operationID: request.operationID, token: continuation.token)
        XCTAssertEqual(first, .cancelled(.probeCancelled))
        let second = await coordinator.cancelChoice(operationID: request.operationID, token: UUID())
        XCTAssertEqual(second, first)
        // resume after cancel hits the same cached terminal outcome.
        let resumed = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(resumed, first)
    }

    func testCancelWithUnknownTokenIsInvalidAddressChoice() async throws {
        let (coordinator, _, request) = try await reachWaitingForUser()
        let outcome = await coordinator.cancelChoice(operationID: request.operationID, token: UUID())
        XCTAssertEqual(outcome, .cancelled(.invalidAddressChoice))
    }

    func testWaitingForUserCrashConsolidationRejectsTokenOnFreshCoordinator() async throws {
        let (_, continuation, request) = try await reachWaitingForUser()

        // The process crashed while WaitingForUser: continuations live only in
        // memory, so a fresh coordinator closes the operation deterministically.
        let restarted = AddressSelectionCoordinator(
            probe: FakeProbe(epochProvider: FakeEpochProvider(epoch: 7)),
            epochProvider: FakeEpochProvider(epoch: 7)
        )
        let resumed = await restarted.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch
        )
        XCTAssertEqual(resumed, .cancelled(.invalidAddressChoice))
        let cancelled = await restarted.cancelChoice(operationID: request.operationID, token: continuation.token)
        XCTAssertEqual(cancelled, .cancelled(.invalidAddressChoice))
    }

    // MARK: - Ranking, concurrency, timeout, budget

    func testRankingOrdersSSIDRecentThenLocalRecentThenSortOrderThenStableID() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let coordinator = makeCoordinator(probe: probe, epoch: 7, maxConcurrentProbes: 1)
        let t100 = Date(timeIntervalSince1970: 100)
        let t50 = Date(timeIntervalSince1970: 50)
        let lowerStableID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let higherStableID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let highestStableID = UUID(uuidString: "00000000-0000-4000-8000-0000000000FF")!
        let candidates = [
            candidate(higherStableID, host: "e.internal", sortOrder: 1),
            candidate(highestStableID, host: "d.internal", sortOrder: 1),
            candidate(UUID(), host: "c.internal", sortOrder: 5, localSuccess: t100),
            candidate(UUID(), host: "b.internal", sortOrder: 0, ssidSuccess: t50),
            candidate(UUID(), host: "a.internal", sortOrder: 9, ssidSuccess: t100),
            candidate(lowerStableID, host: "f.internal", sortOrder: 1),
        ]
        // d.internal has no history and sortOrder 1; its UUID sorts after the two fixed ones.
        let request = makeRequest(epoch: 7, candidates: candidates)

        _ = await coordinator.select(request)
        XCTAssertEqual(
            probe.probedTargets.map(\.host),
            ["a.internal", "b.internal", "c.internal", "f.internal", "e.internal", "d.internal"]
        )
    }

    func testConcurrencyNeverExceedsThreeProbes() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        for index in 0 ..< 6 {
            probe.setBehavior(.delayedSuccess(.milliseconds(80)), host: "h\(index).internal")
        }
        let request = makeRequest(
            epoch: 7,
            candidates: (0 ..< 6).map { candidate(UUID(), host: "h\($0).internal") }
        )

        _ = await coordinator.select(request)
        XCTAssertEqual(probe.maxInFlight, 3)
    }

    func testPerProbeTimeoutYieldsTCPTimeoutAndSelectionContinues() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.hang, host: "hang.internal")
        probe.setBehavior(.failure(.tcpRefused), host: "dead1.internal")
        probe.setBehavior(.failure(.dnsUnresolved), host: "dead2.internal")
        probe.setBehavior(.success, host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7, probeTimeout: .milliseconds(100))
        let request = makeRequest(
            epoch: 7,
            candidates: [
                candidate(UUID(), host: "hang.internal", sortOrder: 0),
                candidate(UUID(), host: "dead1.internal", sortOrder: 1),
                candidate(UUID(), host: "dead2.internal", sortOrder: 2),
                candidate(altA, host: "alt.internal", sortOrder: 3),
            ]
        )

        let outcome = await coordinator.select(request)
        guard case .selected(let decision) = outcome else {
            return XCTFail("expected selected from the second batch, got \(outcome)")
        }
        XCTAssertEqual(decision.addressID, altA)
        XCTAssertEqual(probe.probedTargets.count, 4)
    }

    func testUnavailableCollectsTimeoutEvidence() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.hang, host: "hang.internal")
        probe.setBehavior(.failure(.tcpRefused), host: "dead.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7, probeTimeout: .milliseconds(100))
        let request = makeRequest(
            epoch: 7,
            candidates: [candidate(UUID(), host: "hang.internal"), candidate(UUID(), host: "dead.internal")]
        )

        let outcome = await coordinator.select(request)
        guard case .unavailable(let evidence) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(evidence.first { $0.target.host == "hang.internal" }?.failureCode, .tcpTimeout)
        XCTAssertEqual(evidence.first { $0.target.host == "dead.internal" }?.failureCode, .tcpRefused)
    }

    func testAtMostTwelveCandidatesAreProbed() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(
            epoch: 7,
            candidates: (0 ..< 15).map { candidate(UUID(), host: "h\($0).internal", sortOrder: $0) }
        )

        _ = await coordinator.select(request)
        XCTAssertEqual(probe.probedTargets.count, 12)
    }

    func testOverallBudgetStopsLaunchingNewBatches() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let clock = StepClock(start: Date(timeIntervalSince1970: 1_700_000_000), step: 2)
        let coordinator = AddressSelectionCoordinator(
            probe: probe,
            epochProvider: FakeEpochProvider(epoch: 7),
            configuration: AddressSelectionConfiguration(
                probeTimeout: .seconds(2),
                maxConcurrentProbes: 3,
                maxCandidates: 12,
                overallBudget: .seconds(13)
            ),
            now: clock.now
        )
        let request = makeRequest(
            epoch: 7,
            candidates: (0 ..< 12).map { candidate(UUID(), host: "h\($0).internal") }
        )

        let outcome = await coordinator.select(request)
        // Clock calls: deadline(1), then per batch check(1) + 3 probe timestamps(3).
        // Batches start at t=2 and t=10; the t=18 check exceeds the 13 s budget.
        XCTAssertEqual(probe.probedTargets.count, 6)
        guard case .unavailable(let evidence) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(evidence.count, 6)
    }

    func testCancellationPropagatesIntoInFlightProbes() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.hang, host: "hang.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7, probeTimeout: .seconds(30))
        let request = makeRequest(epoch: 7, candidates: [candidate(UUID(), host: "hang.internal")])

        let task = Task { await coordinator.select(request) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled(.probeCancelled))
        XCTAssertGreaterThanOrEqual(probe.cancelledProbeCount, 1)
    }

    func testDuplicateSelectReturnsCachedTerminalOutcome() async {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        let coordinator = makeCoordinator(probe: probe, epoch: 7)
        let request = makeRequest(epoch: 7, candidates: [candidate(altA, host: "alt.internal")])

        let first = await coordinator.select(request)
        let second = await coordinator.select(request)
        XCTAssertEqual(first, second)
        XCTAssertEqual(probe.probedTargets.count, 1)
    }

    func testConcurrentSelectForSameOperationProbesOnceAndSharesTerminalOutcome() async {
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.delayedSuccess(.milliseconds(80)), host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider)
        let request = makeRequest(epoch: 7, candidates: [candidate(altA, host: "alt.internal")])

        async let first = coordinator.select(request)
        async let second = coordinator.select(request)
        let (firstOutcome, secondOutcome) = await (first, second)

        XCTAssertEqual(firstOutcome, secondOutcome)
        XCTAssertEqual(probe.probedTargets.count, 1)
        let terminal = await coordinator.terminalOutcome(for: request.operationID)
        XCTAssertEqual(terminal, firstOutcome)
    }

    // MARK: - Network epoch invalidation

    func testRequestWithStaleEpochFailsFastWithoutProbing() async {
        let provider = FakeEpochProvider(epoch: 9)
        let probe = FakeProbe(epochProvider: provider)
        let coordinator = makeCoordinator(probe: probe, provider: provider)
        let request = makeRequest(epoch: 7, candidates: [candidate(altA, host: "alt.internal")])

        let outcome = await coordinator.select(request)
        XCTAssertEqual(outcome, .cancelled(.networkChanged))
        XCTAssertTrue(probe.probedTargets.isEmpty)
    }

    func testEpochChangeMidFlightStalesTheOperation() async {
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.hang, host: "hang.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider, probeTimeout: .milliseconds(100))
        let request = makeRequest(epoch: 7, candidates: [candidate(UUID(), host: "hang.internal")])

        let task = Task { await coordinator.select(request) }
        try? await Task.sleep(for: .milliseconds(30))
        provider.setEpoch(8)
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled(.networkChanged))
    }

    func testInvalidateCancelsAffectedFixedProbeImmediately() async {
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.hang, host: "fixed.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider, probeTimeout: .seconds(5))
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal")]
        )

        let task = Task { await coordinator.select(request) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(probe.probedTargets.map(\.host), ["fixed.internal"])
        let invalidatedAt = Date()
        await coordinator.invalidate(before: 8)

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled(.networkChanged))
        XCTAssertGreaterThanOrEqual(probe.cancelledProbeCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(invalidatedAt), 1)
        let terminal = await coordinator.terminalOutcome(for: request.operationID)
        XCTAssertEqual(terminal, outcome)
    }

    func testSleepWakeCycleIncrementsEpochAndStaleEvidenceStaysStale() async {
        // willSleep/didWake funnel into the same epoch mechanism (architecture 7.2).
        let provider = FakeEpochProvider(epoch: 7)
        let probe = FakeProbe(epochProvider: provider)
        probe.setBehavior(.success, host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, provider: provider)
        let request = makeRequest(epoch: 7, candidates: [candidate(altA, host: "alt.internal")])

        let outcome = await coordinator.select(request)
        guard case .selected(let decision) = outcome else {
            return XCTFail("expected selected, got \(outcome)")
        }
        XCTAssertEqual(decision.evidence.state(atEpoch: 7), .reachable)

        provider.setEpoch(8) // didWake
        XCTAssertEqual(decision.evidence.state(atEpoch: 8), .stale)

        let replay = makeRequest(epoch: 7, candidates: [candidate(altA, host: "alt.internal")])
        let replayOutcome = await coordinator.select(replay)
        XCTAssertEqual(replayOutcome, .cancelled(.networkChanged))
    }

    func testVPNOrTailscaleChangeClosesPendingChoiceAsNetworkChanged() async throws {
        // VPN/Tailscale transitions use the same invalidate funnel (architecture 7.2).
        let (coordinator, continuation, request) = try await reachWaitingForUser()

        await coordinator.invalidate(before: request.networkEpoch + 1)
        let awaitingAfterInvalidate = await coordinator.isAwaitingChoice(operationID: request.operationID)
        XCTAssertFalse(awaitingAfterInvalidate)

        let resumed = await coordinator.resumeChoice(
            operationID: request.operationID,
            token: continuation.token,
            selectedAddressID: altA,
            hostRevision: request.hostRevision,
            networkEpoch: request.networkEpoch + 1
        )
        XCTAssertEqual(resumed, .cancelled(.networkChanged))
        let repeated = await coordinator.cancelChoice(operationID: request.operationID, token: continuation.token)
        XCTAssertEqual(repeated, .cancelled(.networkChanged))
    }

    // MARK: - Helpers

    private func makeCoordinator(
        probe: FakeProbe,
        epoch: UInt64,
        maxConcurrentProbes: Int = 3,
        probeTimeout: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AddressSelectionCoordinator {
        makeCoordinator(
            probe: probe,
            provider: FakeEpochProvider(epoch: epoch),
            maxConcurrentProbes: maxConcurrentProbes,
            probeTimeout: probeTimeout,
            now: now
        )
    }

    private func makeCoordinator(
        probe: FakeProbe,
        provider: FakeEpochProvider,
        maxConcurrentProbes: Int = 3,
        probeTimeout: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AddressSelectionCoordinator {
        AddressSelectionCoordinator(
            probe: probe,
            epochProvider: provider,
            configuration: AddressSelectionConfiguration(
                probeTimeout: probeTimeout,
                maxConcurrentProbes: maxConcurrentProbes
            ),
            now: now
        )
    }

    private func makeRequest(
        epoch: UInt64,
        fixedAddressID: UUID? = nil,
        candidates: [AddressCandidate]
    ) -> AddressSelectionRequest {
        AddressSelectionRequest(
            operationID: UUID(),
            hostID: hostID,
            hostRevision: 1,
            target: .ssh,
            fixedAddressID: fixedAddressID,
            candidates: candidates,
            networkEpoch: epoch
        )
    }

    private func candidate(
        _ id: UUID,
        host: String,
        sortOrder: Int = 0,
        ssidSuccess: Date? = nil,
        localSuccess: Date? = nil
    ) -> AddressCandidate {
        AddressCandidate(
            addressID: id,
            host: host,
            sshPort: 22,
            sortOrder: sortOrder,
            lastSuccessOnCurrentSSIDAt: ssidSuccess,
            lastLocalSuccessAt: localSuccess
        )
    }

    /// Drives a coordinator to WaitingForUser: fixed address refuses, one
    /// alternative verifies. Returns the coordinator, continuation and request.
    private func reachWaitingForUser(
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (AddressSelectionCoordinator, AddressChoiceContinuation, AddressSelectionRequest) {
        let probe = FakeProbe(epochProvider: FakeEpochProvider(epoch: 7))
        probe.setBehavior(.failure(.tcpRefused), host: "fixed.internal")
        probe.setBehavior(.success, host: "alt.internal")
        let coordinator = makeCoordinator(probe: probe, epoch: 7, now: now)
        let request = makeRequest(
            epoch: 7,
            fixedAddressID: fixedID,
            candidates: [candidate(fixedID, host: "fixed.internal"), candidate(altA, host: "alt.internal")]
        )
        let outcome = await coordinator.select(request)
        guard case .requiresUserChoice(let continuation, _, let verified) = outcome else {
            XCTFail("expected requiresUserChoice, got \(outcome)")
            throw TestError.setupFailed
        }
        XCTAssertEqual(verified.map(\.addressID), [altA])
        return (coordinator, continuation, request)
    }

    private enum TestError: Error {
        case setupFailed
    }
}

// MARK: - Test doubles

/// Lock box keeping NSLock usage inside synchronous methods so test doubles
/// stay warning-free when called from async contexts.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class FakeEpochProvider: NetworkEpochProviding, @unchecked Sendable {
    private let epoch: Locked<UInt64>

    init(epoch: UInt64) {
        self.epoch = Locked(epoch)
    }

    func currentEpoch() async -> UInt64 {
        epoch.read()
    }

    func setEpoch(_ newValue: UInt64) {
        epoch.update { $0 = newValue }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let current: Locked<Date>

    init(start: Date) {
        current = Locked(start)
    }

    func now() -> Date {
        current.read()
    }

    func advance(_ seconds: TimeInterval) {
        current.update { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Deterministic clock advancing by `step` on every read; used to exercise the
/// overall probing budget without real sleeps.
private final class StepClock: @unchecked Sendable {
    private struct State {
        var current: Date
        let step: TimeInterval
    }

    private let state: Locked<State>

    init(start: Date, step: TimeInterval) {
        state = Locked(State(current: start, step: step))
    }

    func now() -> Date {
        state.update { state in
            let value = state.current
            state.current = state.current.addingTimeInterval(state.step)
            return value
        }
    }
}

private final class FakeProbe: ReachabilityProbing, @unchecked Sendable {
    enum Behavior {
        case success
        case failure(OperationFailureCode)
        case delayedSuccess(Duration)
        case hang
    }

    private struct State {
        var behaviors: [String: Behavior] = [:]
        var targets: [NetworkTarget] = []
        var inFlight = 0
        var peakInFlight = 0
        var cancelled = 0
    }

    private let epochProvider: FakeEpochProvider
    private let state = Locked(State())

    init(epochProvider: FakeEpochProvider) {
        self.epochProvider = epochProvider
    }

    func setBehavior(_ behavior: Behavior, host: String) {
        state.update { $0.behaviors[host] = behavior }
    }

    var probedTargets: [NetworkTarget] {
        state.read().targets
    }

    var maxInFlight: Int {
        state.read().peakInFlight
    }

    var cancelledProbeCount: Int {
        state.read().cancelled
    }

    func probe(_ target: NetworkTarget, timeout: Duration, operationID: UUID) async -> ProbeEvidence {
        let behavior = state.update { state -> Behavior in
            state.targets.append(target)
            state.inFlight += 1
            state.peakInFlight = max(state.peakInFlight, state.inFlight)
            return state.behaviors[target.host] ?? .failure(.tcpRefused)
        }
        defer { state.update { $0.inFlight -= 1 } }

        switch behavior {
        case .success:
            break
        case .failure:
            break
        case .delayedSuccess(let delay):
            try? await Task.sleep(for: delay)
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        if Task.isCancelled {
            state.update { $0.cancelled += 1 }
            return await evidence(target, reachable: false, code: .probeCancelled)
        }
        switch behavior {
        case .success, .delayedSuccess:
            return await evidence(target, reachable: true, code: nil)
        case .failure(let code):
            return await evidence(target, reachable: false, code: code)
        case .hang:
            return await evidence(target, reachable: false, code: .probeCancelled)
        }
    }

    private func evidence(_ target: NetworkTarget, reachable: Bool, code: OperationFailureCode?) async -> ProbeEvidence {
        ProbeEvidence(
            addressID: UUID(),
            target: target,
            networkEpoch: await epochProvider.currentEpoch(),
            observedAt: Date(),
            wasReachable: reachable,
            failureCode: code
        )
    }
}

// MARK: - Outcome assertions

extension AddressSelectionOutcome: Equatable {
    public static func == (lhs: AddressSelectionOutcome, rhs: AddressSelectionOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.selected(let a), .selected(let b)):
            return a == b
        case (.unavailable(let a), .unavailable(let b)):
            return a == b
        case (.cancelled(let a), .cancelled(let b)):
            return a == b
        case (
            .requiresUserChoice(let ac, let af, let av),
            .requiresUserChoice(let bc, let bf, let bv)
        ):
            return ac == bc && af == bf && av == bv
        default:
            return false
        }
    }
}
