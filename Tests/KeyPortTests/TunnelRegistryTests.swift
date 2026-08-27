import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

final class TunnelRegistryTests: XCTestCase {
    func testOpenVerifiesTargetAndMovesThroughEstablishedStates() async throws {
        let allocator = TestPortAllocator(ports: [41001])
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let request = makeRequest()

        let handle = try await registry.open(request)

        XCTAssertEqual(handle.local, LocalEndpoint(port: 41001))
        XCTAssertFalse(handle.reused)
        let states = await registry.states(for: handle.id)
        XCTAssertEqual(states.count, 6)
        XCTAssertEqual(states[0], .allocatingPort(attempt: 1))
        XCTAssertEqual(states[1], .starting)
        XCTAssertEqual(states[2], .forwardEstablished)
        XCTAssertEqual(states[3], .verifyingTarget)
        guard case .targetVerified(let evidence) = states[4] else {
            XCTFail("Target verification evidence was not recorded")
            return
        }
        XCTAssertEqual(evidence.subject, request.subject)
        XCTAssertEqual(
            states[5],
            .active(local: LocalEndpoint(port: 41001), reused: false)
        )
        let launchCount = await broker.launchCount
        let verificationCount = await broker.verificationCount
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(verificationCount, 1)
    }

    func testOpenPublishesSubjectAndTargetVerificationEvidence() async throws {
        let request = makeRequest()
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41025]),
            brokerLauncher: TestBroker(outcomes: [.success]),
            leaseStore: TestLeaseStore()
        )

        let handle = try await registry.open(request)

        XCTAssertEqual(handle.subject, request.subject)
        let evidence = try XCTUnwrap(handle.verificationEvidence)
        XCTAssertEqual(evidence.subject, request.subject)
        XCTAssertTrue(evidence.isValid(at: evidence.verifiedAt.addingTimeInterval(1), networkEpoch: request.networkEpoch))
    }

    func testAdoptRekeysAnActiveCandidateAndReusesItAfterSavingTheService() async throws {
        let request = makeRequest(serviceID: nil)
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41026]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )

        let candidate = try await registry.open(request)
        let evidence = try XCTUnwrap(candidate.verificationEvidence)
        let serviceID = UUID()
        let adopted = try await registry.adopt(
            tunnelID: candidate.id,
            serviceID: serviceID,
            evidence: evidence,
            at: evidence.verifiedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(adopted.id, candidate.id)
        XCTAssertEqual(adopted.serviceID, serviceID)
        XCTAssertEqual(adopted.local, candidate.local)
        XCTAssertTrue(adopted.reused)
        XCTAssertNil(candidate.serviceID)
        XCTAssertNil(candidate.subject.serviceID)
        XCTAssertEqual(adopted.subject.serviceID, serviceID)
        XCTAssertEqual(adopted.verificationEvidence?.subject, adopted.subject)

        let savedRequest = TunnelRequest(
            operationID: UUID(),
            serviceID: serviceID,
            hostID: request.hostID,
            sshIdentityID: request.sshIdentityID,
            sshAddressID: request.sshAddressID,
            serviceProtocol: request.serviceProtocol,
            sshHost: request.sshHost,
            sshPort: request.sshPort,
            username: request.username,
            identityPath: request.identityPath,
            knownHostsPath: request.knownHostsPath,
            remote: request.remote,
            networkEpoch: request.networkEpoch,
            originSensitive: request.originSensitive,
            sessionID: UUID(),
            candidateID: UUID()
        )
        let reopened = try await registry.open(savedRequest)

        XCTAssertEqual(reopened.id, candidate.id)
        XCTAssertEqual(reopened.local, candidate.local)
        XCTAssertTrue(reopened.reused)
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 1)
    }

    func testAdoptRejectsEvidenceForAnotherCandidateBeforeReservingAPort() async throws {
        let request = makeRequest()
        let mismatchedSubject = TunnelSubject(
            operationID: request.operationID,
            sessionID: request.sessionID,
            candidateID: UUID(),
            sshIdentityID: request.sshIdentityID,
            sshAddressID: request.sshAddressID,
            remote: request.remote,
            networkEpoch: request.networkEpoch
        )
        let evidence = TargetVerificationEvidence(
            subject: mismatchedSubject,
            verifiedAt: Date(timeIntervalSince1970: 100)
        )
        let allocator = TestPortAllocator(ports: [41027])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: TestBroker(outcomes: [.success]),
            leaseStore: TestLeaseStore()
        )

        let candidate = try await registry.open(request)

        do {
            _ = try await registry.adopt(
                tunnelID: candidate.id,
                serviceID: UUID(),
                evidence: evidence,
                at: evidence.verifiedAt.addingTimeInterval(1)
            )
            XCTFail("Evidence for another candidate unexpectedly opened a tunnel")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .targetProbeIndeterminate)
        }
        let reserveCount = await allocator.reserveCount
        XCTAssertEqual(reserveCount, 1)
        _ = await registry.close(id: candidate.id, reason: .userRequested)
    }

    func testDuplicateActiveOpenReusesTheSameLocalEndpointWithoutAnotherBroker() async throws {
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41002]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let request = makeRequest()

        let first = try await registry.open(request)
        let second = try await registry.open(request)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.local, second.local)
        XCTAssertTrue(second.reused)
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 1)
    }

    func testPortCollisionRetriesThreeReservationsAndReleasesFailedAttempts() async throws {
        let allocator = TestPortAllocator(ports: [41003, 41004, 41005])
        let broker = TestBroker(outcomes: [.portUnavailable, .portUnavailable, .success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )

        let handle = try await registry.open(makeRequest())

        XCTAssertEqual(handle.local, LocalEndpoint(port: 41005))
        let launchCount = await broker.launchCount
        let releasedPorts = await allocator.releasedPorts
        XCTAssertEqual(launchCount, 3)
        XCTAssertEqual(releasedPorts, [41003, 41004, 41005])
    }

    func testPortReservationIsReleasedBeforeBrokerLaunchAndNotReleasedAgainAfterHandoff() async throws {
        let reservation = TestPortReservation(port: 41009, releaseDelayNanoseconds: 0)
        let allocator = TestSinglePortAllocator(reservation: reservation)
        let broker = TestBroker(
            outcomes: [.success],
            onLaunch: { XCTAssertEqual(reservation.releaseCount, 1) }
        )
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )

        let handle = try await registry.open(makeRequest())
        XCTAssertEqual(reservation.releaseCount, 1)

        _ = await registry.close(id: handle.id, reason: .userRequested)
        XCTAssertEqual(reservation.releaseCount, 1)
    }

    func testCancellingOneSharedStarterDoesNotCancelTheRemainingWaiter() async throws {
        let gate = TestGate()
        let broker = TestBroker(outcomes: [.success], verificationGate: gate)
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41008]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let request = makeRequest()
        let first = Task { try await registry.open(request) }

        for _ in 0..<100 {
            if await broker.verificationCount == 1 { break }
            await Task.yield()
        }
        let second = Task { try await registry.open(request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        first.cancel()
        await gate.open()

        do {
            _ = try await first.value
            XCTFail("The cancelled starter unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation belongs to the first waiter.
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .reservationCancelled)
        }

        let handle = try await second.value
        XCTAssertEqual(handle.local, LocalEndpoint(port: 41008))
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 1)
    }

    func testCancellingEverySharedStarterDoesNotLeaveAStaleStartingEntry() async throws {
        let gate = TestGate()
        let broker = TestBroker(outcomes: [.success, .success], verificationGate: gate)
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41021, 41022]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let request = makeRequest()
        let first = Task { try await registry.open(request) }

        for _ in 0..<100 {
            if await broker.verificationCount == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let verificationCount = await broker.verificationCount
        XCTAssertEqual(verificationCount, 1)
        let second = Task { try await registry.open(request) }
        try await Task.sleep(nanoseconds: 10_000_000)
        first.cancel()
        second.cancel()
        await gate.open()

        do {
            _ = try await first.value
            XCTFail("The first cancelled starter unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError || error is TunnelOpenFailure)
        }
        do {
            _ = try await second.value
            XCTFail("The second cancelled starter unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError || error is TunnelOpenFailure)
        }

        let reopened = try await registry.open(request)
        XCTAssertFalse(reopened.reused)
        XCTAssertEqual(reopened.local, LocalEndpoint(port: 41022))
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 2)
    }

    func testActiveLeaseRecordsTheActualBrokerProcessIdentifier() async throws {
        let leaseStore = TestLeaseStore()
        let broker = TestBroker(outcomes: [.success], processIdentifier: 4242)
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41017]),
            brokerLauncher: broker,
            leaseStore: leaseStore
        )

        _ = try await registry.open(makeRequest())

        let leases = await leaseStore.savedLeases
        XCTAssertEqual(leases.last?.brokerPID, 4242)
    }

    func testGeneratedControlPathFitsTheMacOSUnixSocketLimit() async throws {
        let runtimeDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("KeyPort-long-runtime-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41024]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore(),
            runtimeDirectory: runtimeDirectory
        )

        _ = try await registry.open(makeRequest())

        let configuration = await broker.lastConfiguration
        XCTAssertNotNil(configuration)
        let controlNameLength = configuration.map {
            URL(fileURLWithPath: $0.controlPath).lastPathComponent.utf8.count
        } ?? Int.max
        XCTAssertLessThanOrEqual(controlNameLength, 35)
        XCTAssertLessThanOrEqual(configuration?.controlPath.utf8.count ?? .max, 103)
    }

    func testUnexpectedBrokerExitRemovesActiveTunnelAndLease() async throws {
        let terminationGate = TestGate()
        let leaseStore = TestLeaseStore()
        let broker = TestBroker(outcomes: [.success], terminationGate: terminationGate)
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41019]),
            brokerLauncher: broker,
            leaseStore: leaseStore
        )

        let handle = try await registry.open(makeRequest())
        await terminationGate.open()

        for _ in 0..<100 {
            if await registry.state(for: handle.id) == .failed(.brokerExited, cleanup: .completed) {
                break
            }
            await Task.yield()
        }

        let finalState = await registry.state(for: handle.id)
        let removedLeaseCount = await leaseStore.removedLeases.count
        XCTAssertEqual(finalState, .failed(.brokerExited, cleanup: .completed))
        XCTAssertEqual(removedLeaseCount, 1)
    }

    func testTargetRefusalKeepsPrimaryFailureSeparateFromCleanupStatus() async throws {
        let broker = TestBroker(outcomes: [.failure(.targetRefused)])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41006]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )

        do {
            _ = try await registry.open(makeRequest())
            XCTFail("Target refusal unexpectedly opened a tunnel")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .targetRefused)
            XCTAssertEqual(failure.cleanup, .completed)
        }
    }

    func testReleaseTimeoutReturnsCleanupPendingWithoutChangingPrimaryFailure() async throws {
        let allocator = TestPortAllocator(ports: [41007])
        let leaseStore = TestLeaseStore()
        let broker = TestBroker(
            outcomes: [.failure(.targetTimeout)],
            closeDelayNanoseconds: 100_000_000
        )
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: leaseStore,
            cleanupTimeoutNanoseconds: 1_000_000
        )

        do {
            _ = try await registry.open(makeRequest())
            XCTFail("Timed out target unexpectedly opened a tunnel")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .targetTimeout)
            XCTAssertEqual(failure.cleanup, .pending)
        }
        let removedLeases = await leaseStore.removedLeases
        XCTAssertTrue(removedLeases.isEmpty)
    }

    func testReservationHandoffTimeoutFailsBeforeBrokerLaunch() async throws {
        let allocator = TestPortAllocator(ports: [41018], releaseDelayNanoseconds: 100_000_000)
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: TestLeaseStore(),
            cleanupTimeoutNanoseconds: 1_000_000
        )

        do {
            _ = try await registry.open(makeRequest())
            XCTFail("A timed out reservation handoff unexpectedly opened")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .localPortUnavailable)
            XCTAssertEqual(failure.cleanup, .pending)
        }
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testHostCapacityStopsFifthOpenWithoutEvictingExistingTunnels() async throws {
        let allocator = TestPortAllocator(ports: Array(41010...41014))
        let broker = TestBroker(outcomes: Array(repeating: .success, count: 5))
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: allocator,
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let hostID = UUID()

        for _ in 0..<4 {
            _ = try await registry.open(makeRequest(hostID: hostID, serviceID: UUID()))
        }

        do {
            _ = try await registry.open(makeRequest(hostID: hostID, serviceID: UUID()))
            XCTFail("The fifth tunnel for one host unexpectedly opened")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .tunnelCapacityReached)
            XCTAssertEqual(failure.cleanup, .notNeeded)
        }
        let launchCount = await broker.launchCount
        XCTAssertEqual(launchCount, 4)
    }

    func testNetworkEpochClosesExistingTunnelAndDoesNotRebuildIt() async throws {
        let broker = TestBroker(outcomes: [.success])
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestPortAllocator(ports: [41015]),
            brokerLauncher: broker,
            leaseStore: TestLeaseStore()
        )
        let handle = try await registry.open(makeRequest(networkEpoch: 0))

        let result = await registry.networkEpochChanged()

        XCTAssertEqual(result.closedCount, 1)
        XCTAssertEqual(result.cleanup, .completed)
        let closeCount = await broker.closeCount
        let state = await registry.state(for: handle.id)
        let networkEpoch = await registry.currentNetworkEpoch()
        let launchCount = await broker.launchCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(state, .closed(.networkChanged))
        XCTAssertEqual(networkEpoch, 1)
        XCTAssertEqual(launchCount, 1)
    }

    func testDisabledFeatureFailsBeforeReservingAPort() async throws {
        let allocator = TestPortAllocator(ports: [41016])
        let registry = TunnelRegistry(
            portReserver: allocator,
            brokerLauncher: TestBroker(outcomes: [.success]),
            leaseStore: TestLeaseStore()
        )

        do {
            _ = try await registry.open(makeRequest())
            XCTFail("Disabled service access unexpectedly opened a tunnel")
        } catch let failure as TunnelOpenFailure {
            XCTAssertEqual(failure.code, .serviceAccessDisabled)
        }
        let reserveCount = await allocator.reserveCount
        XCTAssertEqual(reserveCount, 0)
    }

    private func makeRequest(
        hostID: UUID = UUID(),
        serviceID: UUID? = UUID(),
        networkEpoch: UInt64 = 0
    ) -> TunnelRequest {
        TunnelRequest(
            operationID: UUID(),
            serviceID: serviceID,
            hostID: hostID,
            sshIdentityID: UUID(),
            sshAddressID: UUID(),
            serviceProtocol: .tcp,
            sshHost: "ssh.example.test",
            sshPort: 22,
            username: "admin",
            identityPath: "/Users/test/.ssh/keyport/identities/id",
            knownHostsPath: "/Users/test/.ssh/keyport/known_hosts",
            remote: RemoteServiceEndpoint(bind: .loopbackV4, port: 8080),
            networkEpoch: networkEpoch
        )
    }
}

private actor TestPortAllocator: LoopbackPortReserving {
    private let allReservations: [TestPortReservation]
    private var reservations: [TestPortReservation]
    private(set) var reserveCount = 0

    init(ports: [UInt16], releaseDelayNanoseconds: UInt64 = 0) {
        let reservations = ports.map { TestPortReservation(port: $0, releaseDelayNanoseconds: releaseDelayNanoseconds) }
        self.allReservations = reservations
        self.reservations = reservations
    }

    var releasedPorts: [UInt16] {
        allReservations.filter { $0.releaseCount > 0 }.map(\.port)
    }

    func reserve() async throws -> any LoopbackPortReservation {
        reserveCount += 1
        guard !reservations.isEmpty else { throw TunnelOpenFailure(code: .localPortUnavailable) }
        return reservations.removeFirst()
    }
}

private actor TestSinglePortAllocator: LoopbackPortReserving {
    private let reservation: TestPortReservation

    init(reservation: TestPortReservation) {
        self.reservation = reservation
    }

    func reserve() async throws -> any LoopbackPortReservation {
        reservation
    }
}

private final class TestPortReservation: LoopbackPortReservation, @unchecked Sendable {
    let host = "127.0.0.1"
    let port: UInt16
    private let lock = NSLock()
    private var storedReleaseCount = 0
    private let releaseDelayNanoseconds: UInt64

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReleaseCount
    }

    init(port: UInt16, releaseDelayNanoseconds: UInt64) {
        self.port = port
        self.releaseDelayNanoseconds = releaseDelayNanoseconds
    }

    func release() async {
        if releaseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: releaseDelayNanoseconds)
        }
        incrementReleaseCount()
    }

    private func incrementReleaseCount() {
        lock.lock()
        storedReleaseCount += 1
        lock.unlock()
    }
}

private enum TestBrokerOutcome: Sendable {
    case success
    case portUnavailable
    case failure(OperationFailureCode)
}

private actor TestBroker: TunnelBrokerLaunching {
    private var outcomes: [TestBrokerOutcome]
    private let onLaunch: (@Sendable () async -> Void)?
    private let verificationGate: TestGate?
    private let processIdentifier: Int32?
    private let closeDelayNanoseconds: UInt64
    private let terminationGate: TestGate?
    private(set) var launchCount = 0
    private(set) var lastConfiguration: TunnelBrokerConfiguration?
    private(set) var verificationCount = 0
    private(set) var closeCount = 0

    init(
        outcomes: [TestBrokerOutcome],
        onLaunch: (@Sendable () async -> Void)? = nil,
        verificationGate: TestGate? = nil,
        processIdentifier: Int32? = nil,
        closeDelayNanoseconds: UInt64 = 0,
        terminationGate: TestGate? = nil
    ) {
        self.outcomes = outcomes
        self.onLaunch = onLaunch
        self.verificationGate = verificationGate
        self.processIdentifier = processIdentifier
        self.closeDelayNanoseconds = closeDelayNanoseconds
        self.terminationGate = terminationGate
    }

    func launch(_ configuration: TunnelBrokerConfiguration) async throws -> any TunnelBrokerSession {
        launchCount += 1
        lastConfiguration = configuration
        await onLaunch?()
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            return TestBrokerSession(
                verificationGate: verificationGate,
                processIdentifier: processIdentifier,
                closeDelayNanoseconds: closeDelayNanoseconds,
                terminationGate: terminationGate,
                onVerify: { [weak self] in await self?.recordVerification() },
                onClose: { [weak self] in await self?.recordClose() }
            )
        case .portUnavailable:
            throw TunnelBrokerLaunchError.portUnavailable
        case .failure(let code):
            return TestBrokerSession(
                verificationFailure: code,
                verificationGate: verificationGate,
                processIdentifier: processIdentifier,
                closeDelayNanoseconds: closeDelayNanoseconds,
                terminationGate: terminationGate,
                onVerify: { [weak self] in await self?.recordVerification() },
                onClose: { [weak self] in await self?.recordClose() }
            )
        }
    }

    private func recordVerification() {
        verificationCount += 1
    }

    private func recordClose() {
        closeCount += 1
    }
}

private actor TestBrokerSession: TunnelBrokerTerminationObserving {
    private let verificationFailure: OperationFailureCode?
    private let verificationGate: TestGate?
    let processIdentifier: Int32?
    private let closeDelayNanoseconds: UInt64
    private let terminationGate: TestGate?
    private let onVerify: @Sendable () async -> Void
    private let onClose: @Sendable () async -> Void

    init(
        verificationFailure: OperationFailureCode? = nil,
        verificationGate: TestGate? = nil,
        processIdentifier: Int32? = nil,
        closeDelayNanoseconds: UInt64 = 0,
        terminationGate: TestGate? = nil,
        onVerify: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.verificationFailure = verificationFailure
        self.verificationGate = verificationGate
        self.processIdentifier = processIdentifier
        self.closeDelayNanoseconds = closeDelayNanoseconds
        self.terminationGate = terminationGate
        self.onVerify = onVerify
        self.onClose = onClose
    }

    func verifyTarget() async throws {
        await onVerify()
        await verificationGate?.wait()
        if let verificationFailure {
            throw TunnelOpenFailure(code: verificationFailure)
        }
    }

    func close() async -> CleanupStatus {
        if closeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: closeDelayNanoseconds)
        }
        await onClose()
        return .completed
    }

    func waitForTermination() async {
        if let terminationGate {
            await terminationGate.wait()
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor TestLeaseStore: TunnelLeaseStore {
    private(set) var savedLeases: [TunnelLease] = []
    private(set) var removedLeases: [TunnelLease] = []

    func save(_ lease: TunnelLease) async throws {
        savedLeases.append(lease)
    }
    func remove(_ lease: TunnelLease) async throws {
        removedLeases.append(lease)
    }
    func reap() async -> CleanupStatus { .completed }
}
