import Foundation
import KeyPortCore

protocol LoopbackPortReservation: Sendable {
    var host: String { get }
    var port: UInt16 { get }
    func release() async
}

protocol LoopbackPortReserving: Sendable {
    func reserve() async throws -> any LoopbackPortReservation
}

protocol TunnelBrokerSession: Sendable {
    var processIdentifier: Int32? { get }
    func verifyTarget() async throws
    func verifyTarget(
        tunnelID: UUID,
        operationID: UUID,
        subject: TunnelSubject
    ) async throws -> TargetVerificationEvidence
    func close() async -> CleanupStatus
}

extension TunnelBrokerSession {
    var processIdentifier: Int32? { nil }

    func verifyTarget(
        tunnelID: UUID,
        operationID: UUID,
        subject: TunnelSubject
    ) async throws -> TargetVerificationEvidence {
        try await verifyTarget()
        return TargetVerificationEvidence(
            tunnelID: tunnelID,
            operationID: operationID,
            subject: subject,
            verifiedAt: Date()
        )
    }
}

protocol TunnelBrokerTerminationObserving: TunnelBrokerSession {
    func waitForTermination() async
}

protocol TunnelBrokerLaunching: Sendable {
    func launch(_ configuration: TunnelBrokerConfiguration) async throws -> any TunnelBrokerSession
}

struct TunnelLeaseOwnership: Codable, Hashable, Sendable {
    let hostID: UUID
    let sshIdentityID: UUID
    let sshAddressID: UUID
    let serviceID: UUID?

    init(
        hostID: UUID,
        sshIdentityID: UUID,
        sshAddressID: UUID,
        serviceID: UUID?
    ) {
        self.hostID = hostID
        self.sshIdentityID = sshIdentityID
        self.sshAddressID = sshAddressID
        self.serviceID = serviceID
    }

    init(request: TunnelRequest) {
        self.init(
            hostID: request.hostID,
            sshIdentityID: request.sshIdentityID,
            sshAddressID: request.sshAddressID,
            serviceID: request.serviceID
        )
    }
}

enum TunnelCleanupScope: Hashable, Sendable {
    case host(UUID)
    case identity(UUID)
    case address(UUID)
    case service(UUID)

    func matches(_ ownership: TunnelLeaseOwnership) -> Bool {
        switch self {
        case .host(let hostID): ownership.hostID == hostID
        case .identity(let identityID): ownership.sshIdentityID == identityID
        case .address(let addressID): ownership.sshAddressID == addressID
        case .service(let serviceID): ownership.serviceID == serviceID
        }
    }
}

struct TunnelLease: Codable, Hashable, Sendable {
    let tunnelID: UUID
    let controlPath: String
    let brokerPID: Int32?
    let createdAt: Date
    let ownership: TunnelLeaseOwnership?

    init(
        tunnelID: UUID,
        controlPath: String,
        brokerPID: Int32?,
        createdAt: Date,
        ownership: TunnelLeaseOwnership? = nil
    ) {
        self.tunnelID = tunnelID
        self.controlPath = controlPath
        self.brokerPID = brokerPID
        self.createdAt = createdAt
        self.ownership = ownership
    }
}

enum TunnelRuntimeNaming {
    static func token(for tunnelID: UUID) -> String {
        var uuid = tunnelID.uuid
        return withUnsafeBytes(of: &uuid) { bytes in
            Data(bytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    static func legacyToken(for tunnelID: UUID) -> String {
        tunnelID.uuidString.lowercased()
    }

    static func controlName(for tunnelID: UUID) -> String {
        "control-\(token(for: tunnelID)).sock"
    }

    static func legacyControlName(for tunnelID: UUID) -> String {
        "control-\(legacyToken(for: tunnelID)).sock"
    }

    static func leaseName(for tunnelID: UUID) -> String {
        "lease-\(token(for: tunnelID)).json"
    }

    static func legacyLeaseName(for tunnelID: UUID) -> String {
        "lease-\(legacyToken(for: tunnelID)).json"
    }
}

protocol TunnelLeaseStore: Sendable {
    func save(_ lease: TunnelLease) async throws
    func remove(_ lease: TunnelLease) async throws
    func reap() async -> CleanupStatus
    func reap(matching scope: TunnelCleanupScope) async -> CleanupStatus
}

enum TunnelBrokerLaunchError: Error, Equatable, Sendable {
    case portUnavailable
    case forwardRejected
    case targetRefused
    case targetTimeout
    case targetProbeIndeterminate
    case unknownOutput
    case exited

    var failureCode: OperationFailureCode {
        switch self {
        case .portUnavailable: .localPortUnavailable
        case .forwardRejected: .forwardRejected
        case .targetRefused: .targetRefused
        case .targetTimeout: .targetTimeout
        case .targetProbeIndeterminate: .targetProbeIndeterminate
        case .unknownOutput: .unknownBrokerOutput
        case .exited: .brokerExited
        }
    }
}

struct TunnelCloseResult: Equatable, Sendable {
    let closedCount: Int
    let cleanup: CleanupStatus
}

actor TunnelRegistry {
    static let maximumGlobalTunnels = 8
    static let maximumTunnelsPerHost = 4
    static let maximumPortAllocationAttempts = 3

    private struct RegistryKey: Hashable, Sendable {
        let subject: TunnelSubject
        let sshIdentityID: UUID
        let sshAddressID: UUID
        let remote: RemoteServiceEndpoint
    }

    private struct ActiveTunnel: Sendable {
        var request: TunnelRequest
        var handle: TunnelHandle
        var verificationEvidence: TargetVerificationEvidence
        let broker: any TunnelBrokerSession
        var lease: TunnelLease
        let leaseSaved: Bool
        var terminationMonitor: Task<Void, Never>?
    }

    private struct StartingTunnel: Sendable {
        let key: RegistryKey
        let tunnelID: UUID
        let hostID: UUID
        let ownership: TunnelLeaseOwnership
        var waiters: Set<UUID>
        let task: Task<TunnelHandle, Error>
    }

    private struct CleanupOperation: Sendable {
        let token: UUID
        let task: Task<CleanupStatus, Never>
    }

    private enum CleanupFinalization: Sendable {
        case closed(TunnelCloseReason)
        case brokerExited
    }

    private enum RegistryEntry: Sendable {
        case starting(StartingTunnel)
        case active(ActiveTunnel)
        case closing(ActiveTunnel)
    }

    private let serviceAccessEnabled: Bool
    private let portReserver: any LoopbackPortReserving
    private let brokerLauncher: any TunnelBrokerLaunching
    private let leaseStore: any TunnelLeaseStore
    private let runtimeDirectory: URL
    private let cleanupTimeoutNanoseconds: UInt64
    private var entries: [RegistryKey: RegistryEntry] = [:]
    private var stateHistory: [UUID: [TunnelState]] = [:]
    // A caller timeout does not release ownership of cleanup that is still running.
    private var cleanupInProgress: [UUID: CleanupOperation] = [:]
    private var networkEpoch: UInt64 = 0

    static func production(paths: KeyPortPaths = KeyPortPaths()) -> TunnelRegistry {
        let leaseStore = FileTunnelLeaseStore(
            directory: paths.tunnelRuntimeDirectory,
            controlMasterExit: OpenSSHControlMasterExiter()
        )
        return TunnelRegistry(
            portReserver: NetworkLoopbackPortReserver(),
            brokerLauncher: OpenSSHTunnelBrokerLauncher(),
            leaseStore: leaseStore,
            runtimeDirectory: paths.tunnelRuntimeDirectory
        )
    }

    init(
        serviceAccessEnabled: Bool = KeyPortFeatureFlags.serviceAccessEnabled,
        portReserver: any LoopbackPortReserving,
        brokerLauncher: any TunnelBrokerLaunching,
        leaseStore: any TunnelLeaseStore,
        runtimeDirectory: URL = KeyPortPaths().tunnelRuntimeDirectory,
        cleanupTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.serviceAccessEnabled = serviceAccessEnabled
        self.portReserver = portReserver
        self.brokerLauncher = brokerLauncher
        self.leaseStore = leaseStore
        self.runtimeDirectory = runtimeDirectory
        self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
    }

    func open(_ request: TunnelRequest) async throws -> TunnelHandle {
        try await openTunnel(request)
    }

    func adopt(
        tunnelID: UUID,
        serviceID: UUID,
        evidence: TargetVerificationEvidence,
        at date: Date = Date()
    ) async throws -> TunnelHandle {
        guard let match = entries.first(where: { _, entry in
            guard case .active(let active) = entry else { return false }
            return active.handle.id == tunnelID
        }), case .active(let active) = match.value else {
            throw TunnelOpenFailure(code: .targetProbeIndeterminate)
        }

        guard active.request.serviceID == nil,
              active.handle.subject.isCandidate,
              evidence == active.verificationEvidence else {
            throw TunnelOpenFailure(code: .targetProbeIndeterminate)
        }

        let savedRequest = active.request.withServiceID(serviceID)
        let savedEvidence: TargetVerificationEvidence
        do {
            savedEvidence = try evidence.adopting(
                savedSubject: savedRequest.subject,
                at: date
            )
        } catch {
            throw TunnelOpenFailure(code: .targetProbeIndeterminate)
        }

        let savedKey = registryKey(for: savedRequest)
        guard entries[savedKey] == nil else {
            throw TunnelOpenFailure(code: .localPortUnavailable)
        }

        let savedLease = TunnelLease(
            tunnelID: active.lease.tunnelID,
            controlPath: active.lease.controlPath,
            brokerPID: active.lease.brokerPID,
            createdAt: active.lease.createdAt,
            ownership: TunnelLeaseOwnership(request: savedRequest)
        )
        do {
            try await leaseStore.save(savedLease)
        } catch {
            throw TunnelOpenFailure(code: .targetProbeIndeterminate, cleanup: .pending)
        }

        active.terminationMonitor?.cancel()
        var adopted = active
        adopted.request = savedRequest
        adopted.lease = savedLease
        adopted.handle = TunnelHandle(
            id: active.handle.id,
            serviceID: serviceID,
            hostID: active.handle.hostID,
            local: active.handle.local,
            reused: true,
            subject: savedRequest.subject,
            verificationEvidence: savedEvidence
        )
        adopted.verificationEvidence = savedEvidence
        adopted.terminationMonitor = nil
        entries.removeValue(forKey: match.key)
        entries[savedKey] = .active(adopted)
        startTerminationMonitor(for: adopted, key: savedKey)
        return adopted.handle
    }

    func adopt(
        _ tunnelID: UUID,
        _ serviceID: UUID,
        _ evidence: TargetVerificationEvidence,
        at date: Date = Date()
    ) async throws -> TunnelHandle {
        try await adopt(
            tunnelID: tunnelID,
            serviceID: serviceID,
            evidence: evidence,
            at: date
        )
    }

    private func openTunnel(_ request: TunnelRequest) async throws -> TunnelHandle {
        guard serviceAccessEnabled else {
            throw TunnelOpenFailure(code: .serviceAccessDisabled)
        }
        guard request.remote.port > 0,
              request.sshPort > 0,
              !request.sshHost.isEmpty,
              !request.username.isEmpty,
              !request.originSensitive else {
            if request.originSensitive {
                throw TunnelOpenFailure(code: .originSensitiveTunnelUnsupported)
            }
            throw TunnelOpenFailure(code: .invalidTunnelRequest)
        }
        guard request.networkEpoch == networkEpoch else {
            throw TunnelOpenFailure(code: .closedForNetworkChange)
        }

        let key = registryKey(for: request)
        if let entry = entries[key] {
            switch entry {
            case .active(let active):
                return TunnelHandle(
                    id: active.handle.id,
                    serviceID: active.handle.serviceID,
                    hostID: active.handle.hostID,
                    local: active.handle.local,
                    reused: true,
                    subject: active.handle.subject,
                    verificationEvidence: active.verificationEvidence
                )
            case .starting(var starting):
                let waiterID = UUID()
                starting.waiters.insert(waiterID)
                entries[key] = .starting(starting)
                return try await waitForStartingTunnel(
                    key: key,
                    tunnelID: starting.tunnelID,
                    waiterID: waiterID,
                    task: starting.task,
                    reused: true
                )
            case .closing:
                throw TunnelOpenFailure(code: .localPortUnavailable)
            }
        }

        let occupiedEntries = entries.values.filter { entry in
            switch entry {
            case .starting, .active, .closing: true
            }
        }
        let occupiedForHost = occupiedEntries.filter { entry in
            switch entry {
            case .starting(let starting):
                return starting.hostID == request.hostID
            case .active(let active): return active.request.hostID == request.hostID
            case .closing(let active): return active.request.hostID == request.hostID
            }
        }
        guard occupiedEntries.count < Self.maximumGlobalTunnels,
              occupiedForHost.count < Self.maximumTunnelsPerHost else {
            throw TunnelOpenFailure(code: .tunnelCapacityReached)
        }

        let tunnelID = UUID()
        let task = Task { [weak self] in
            guard let self else { throw TunnelOpenFailure(code: .brokerExited) }
            return try await self.establish(request: request, key: key, tunnelID: tunnelID)
        }
        let waiterID = UUID()
        entries[key] = .starting(
            StartingTunnel(
                key: key,
                tunnelID: tunnelID,
                hostID: request.hostID,
                ownership: TunnelLeaseOwnership(request: request),
                waiters: [waiterID],
                task: task
            )
        )
        return try await waitForStartingTunnel(
            key: key,
            tunnelID: tunnelID,
            waiterID: waiterID,
            task: task,
            reused: false
        )
    }

    private func waitForStartingTunnel(
        key: RegistryKey,
        tunnelID: UUID,
        waiterID: UUID,
        task: Task<TunnelHandle, Error>,
        reused: Bool
    ) async throws -> TunnelHandle {
        do {
            let handle = try await withTaskCancellationHandler {
                let handle = try await task.value
                try Task.checkCancellation()
                return handle
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelStartingWaiter(
                        key: key,
                        tunnelID: tunnelID,
                        waiterID: waiterID
                    )
                }
            }
            finishStartingWaiter(key: key, tunnelID: tunnelID, waiterID: waiterID)
            return TunnelHandle(
                id: handle.id,
                serviceID: handle.serviceID,
                hostID: handle.hostID,
                local: handle.local,
                reused: reused,
                subject: handle.subject,
                verificationEvidence: handle.verificationEvidence
            )
        } catch {
            finishStartingWaiter(key: key, tunnelID: tunnelID, waiterID: waiterID)
            throw error
        }
    }

    private func cancelStartingWaiter(
        key: RegistryKey,
        tunnelID: UUID,
        waiterID: UUID
    ) {
        guard case .starting(var starting) = entries[key],
              starting.tunnelID == tunnelID,
              starting.waiters.remove(waiterID) != nil else {
            return
        }
        if starting.waiters.isEmpty {
            starting.task.cancel()
            entries.removeValue(forKey: key)
            return
        }
        entries[key] = .starting(starting)
    }

    private func finishStartingWaiter(
        key: RegistryKey,
        tunnelID: UUID,
        waiterID: UUID
    ) {
        guard case .starting(var starting) = entries[key],
              starting.tunnelID == tunnelID,
              starting.waiters.remove(waiterID) != nil else {
            return
        }
        if starting.waiters.isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = .starting(starting)
        }
    }

    func close(id: UUID, reason: TunnelCloseReason) async -> TunnelCloseResult {
        guard let match = entries.first(where: { key, entry in
            switch entry {
            case .active(let active): return active.handle.id == id
            case .closing(let active): return active.handle.id == id
            case .starting: return false
            }
        }) else {
            return TunnelCloseResult(closedCount: 0, cleanup: .notNeeded)
        }
        let active: ActiveTunnel
        switch match.value {
        case .active(let value):
            active = value
            stateHistory[id, default: []].append(.stopping(reason))
            entries[match.key] = .closing(value)
        case .closing(let value):
            guard cleanupInProgress[id] == nil else {
                return TunnelCloseResult(closedCount: 0, cleanup: .pending)
            }
            active = value
        case .starting:
            return TunnelCloseResult(closedCount: 0, cleanup: .notNeeded)
        }

        let operation = beginCleanup(
            active,
            key: match.key,
            finalization: .closed(reason)
        )
        switch await waitForCleanup(operation.task) {
        case .timedOut:
            return TunnelCloseResult(closedCount: 0, cleanup: .pending)
        case .finished(let cleanup):
            finishCleanup(
                key: match.key,
                tunnelID: id,
                token: operation.token,
                finalization: .closed(reason),
                cleanup: cleanup
            )
            if cleanup == .pending {
                return TunnelCloseResult(closedCount: 0, cleanup: .pending)
            }
            return TunnelCloseResult(closedCount: 1, cleanup: cleanup)
        }
    }

    func closeHostTunnels(_ hostID: UUID) async -> TunnelCloseResult {
        await closeTunnels(matching: .host(hostID), reason: .authoritativeDeletion)
    }

    func closeIdentityTunnels(_ identityID: UUID) async -> TunnelCloseResult {
        await closeTunnels(matching: .identity(identityID), reason: .authoritativeDeletion)
    }

    func closeAddressTunnels(_ addressID: UUID) async -> TunnelCloseResult {
        await closeTunnels(matching: .address(addressID), reason: .authoritativeDeletion)
    }

    func closeServiceTunnel(_ serviceID: UUID) async -> TunnelCloseResult {
        await closeTunnels(matching: .service(serviceID), reason: .authoritativeDeletion)
    }

    private func closeTunnels(
        matching scope: TunnelCleanupScope,
        reason: TunnelCloseReason
    ) async -> TunnelCloseResult {
        let startingTunnels = entries.values.compactMap { entry -> StartingTunnel? in
            guard case .starting(let starting) = entry,
                  scope.matches(starting.ownership) else {
                return nil
            }
            return starting
        }
        var cleanup: CleanupStatus = .notNeeded
        for starting in startingTunnels {
            starting.task.cancel()
            do {
                _ = try await starting.task.value
            } catch let failure as TunnelOpenFailure {
                cleanup = merge(cleanup, failure.cleanup)
            } catch {
                cleanup = merge(cleanup, .completed)
            }
            if case .starting = entries[starting.key] {
                entries.removeValue(forKey: starting.key)
            }
        }

        let matchingIDs = Set(entries.values.compactMap { entry -> UUID? in
            switch entry {
            case .active(let active), .closing(let active):
                return scope.matches(TunnelLeaseOwnership(request: active.request))
                    ? active.handle.id
                    : nil
            case .starting:
                return nil
            }
        })
        var closedCount = 0
        for id in matchingIDs {
            let result = await close(id: id, reason: reason)
            closedCount += result.closedCount
            cleanup = merge(cleanup, result.cleanup)
        }

        if cleanup != .pending {
            cleanup = merge(cleanup, await leaseStore.reap(matching: scope))
        }
        return TunnelCloseResult(closedCount: closedCount, cleanup: cleanup)
    }

    func closeAll(reason: TunnelCloseReason) async -> TunnelCloseResult {
        let startingTasks = entries.compactMap { key, entry -> StartingTunnel? in
            guard case .starting(let starting) = entry else { return nil }
            return starting
        }
        var cleanup: CleanupStatus = .notNeeded
        for starting in startingTasks {
            starting.task.cancel()
            do {
                _ = try await starting.task.value
            } catch let failure as TunnelOpenFailure {
                cleanup = merge(cleanup, failure.cleanup)
            } catch {
                cleanup = merge(cleanup, .completed)
            }
            if case .starting = entries[starting.key] {
                entries.removeValue(forKey: starting.key)
            }
        }

        let activeIDs = entries.values.compactMap { entry -> UUID? in
            switch entry {
            case .active(let active), .closing(let active): active.handle.id
            case .starting: nil
            }
        }
        var closedCount = 0
        for id in activeIDs {
            let result = await close(id: id, reason: reason)
            closedCount += result.closedCount
            cleanup = merge(cleanup, result.cleanup)
        }
        return TunnelCloseResult(closedCount: closedCount, cleanup: cleanup)
    }

    func networkEpochChanged() async -> TunnelCloseResult {
        networkEpoch &+= 1
        return await closeAll(reason: .networkChanged)
    }

    func currentNetworkEpoch() -> UInt64 {
        networkEpoch
    }

    func state(for tunnelID: UUID) -> TunnelState? {
        stateHistory[tunnelID]?.last
    }

    func states(for tunnelID: UUID) -> [TunnelState] {
        stateHistory[tunnelID] ?? []
    }

    func reapLeases() async -> CleanupStatus {
        await leaseStore.reap()
    }

    private func brokerExited(key: RegistryKey, tunnelID: UUID) async {
        guard let entry = entries[key], case .active(let active) = entry,
              active.handle.id == tunnelID else {
            return
        }

        entries[key] = .closing(active)
        let operation = beginCleanup(active, key: key, finalization: .brokerExited)
        guard case .finished(let cleanup) = await waitForCleanup(operation.task) else {
            return
        }
        finishCleanup(
            key: key,
            tunnelID: tunnelID,
            token: operation.token,
            finalization: .brokerExited,
            cleanup: cleanup
        )
    }

    private func establish(
        request: TunnelRequest,
        key: RegistryKey,
        tunnelID: UUID
    ) async throws -> TunnelHandle {
        defer { removeStartingEntryIfMatches(key: key, tunnelID: tunnelID) }

        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: runtimeDirectory.path
            )
        } catch {
            throw TunnelOpenFailure(code: .invalidTunnelRequest, cleanup: .pending)
        }

        for attempt in 1...Self.maximumPortAllocationAttempts {
            if Task.isCancelled {
                let failure = TunnelOpenFailure(code: .reservationCancelled)
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            }
            record(tunnelID, .allocatingPort(attempt: attempt))
            let reservation: any LoopbackPortReservation
            do {
                reservation = try await portReserver.reserve()
            } catch is CancellationError {
                record(tunnelID, .failed(.reservationCancelled, cleanup: .notNeeded))
                throw TunnelOpenFailure(code: .reservationCancelled)
            } catch let failure as TunnelOpenFailure {
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            } catch {
                record(tunnelID, .failed(.localPortUnavailable, cleanup: .notNeeded))
                throw TunnelOpenFailure(code: .localPortUnavailable)
            }

            guard reservation.host == "127.0.0.1", reservation.port > 0 else {
                let cleanup = await release(reservation)
                let failure = TunnelOpenFailure(code: .invalidTunnelRequest, cleanup: cleanup)
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            }

            let handoffCleanup = await release(reservation)
            guard handoffCleanup == .completed else {
                let code: OperationFailureCode = Task.isCancelled
                    ? .reservationCancelled
                    : .localPortUnavailable
                let failure = TunnelOpenFailure(code: code, cleanup: handoffCleanup)
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            }
            if Task.isCancelled {
                let failure = TunnelOpenFailure(code: .reservationCancelled, cleanup: .completed)
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            }

            record(tunnelID, .starting)
            let controlPath = runtimeDirectory
                .appendingPathComponent(TunnelRuntimeNaming.controlName(for: tunnelID))
                .path
            let leasePath = runtimeDirectory
                .appendingPathComponent(TunnelRuntimeNaming.leaseName(for: tunnelID))
                .path
            var lease = TunnelLease(
                tunnelID: tunnelID,
                controlPath: controlPath,
                brokerPID: nil,
                createdAt: Date(),
                ownership: TunnelLeaseOwnership(request: request)
            )
            var broker: (any TunnelBrokerSession)?
            var leaseSaved = false
            do {
                try await leaseStore.save(lease)
                leaseSaved = true
                let configuration = TunnelBrokerConfiguration(
                    localPort: reservation.port,
                    remoteHost: request.remote.bind.forwardingHost,
                    remotePort: request.remote.port,
                    sshHost: request.sshHost,
                    sshPort: request.sshPort,
                    username: request.username,
                    identityPath: request.identityPath,
                    knownHostsPath: request.knownHostsPath,
                    controlPath: controlPath,
                    leasePath: leasePath,
                    subject: request.subject
                )
                broker = try await brokerLauncher.launch(configuration)
                lease = TunnelLease(
                    tunnelID: tunnelID,
                    controlPath: controlPath,
                    brokerPID: broker?.processIdentifier,
                    createdAt: lease.createdAt,
                    ownership: lease.ownership
                )
                try await leaseStore.save(lease)
                record(tunnelID, .forwardEstablished)
                record(tunnelID, .verifyingTarget)
                let verificationEvidence = try await requireBroker(broker)
                    .verifyTarget(
                        tunnelID: tunnelID,
                        operationID: request.operationID,
                        subject: request.subject
                    )
                guard verificationEvidence.tunnelID == tunnelID,
                      verificationEvidence.operationID == request.operationID,
                      verificationEvidence.subject == request.subject,
                      verificationEvidence.sshIdentityID == request.sshIdentityID,
                      verificationEvidence.sshAddressID == request.sshAddressID,
                      verificationEvidence.remoteDigest == request.remote.remoteDigest,
                      verificationEvidence.isValid(
                          at: verificationEvidence.verifiedAt,
                          networkEpoch: request.networkEpoch
                      ) else {
                    throw TunnelOpenFailure(code: .targetProbeIndeterminate)
                }
                try Task.checkCancellation()

                let handle = TunnelHandle(
                    id: tunnelID,
                    serviceID: request.serviceID,
                    hostID: request.hostID,
                    local: LocalEndpoint(port: reservation.port),
                    subject: request.subject,
                    verificationEvidence: verificationEvidence
                )
                record(tunnelID, .targetVerified(verificationEvidence))
                record(tunnelID, .active(local: handle.local, reused: false))
                let active = ActiveTunnel(
                    request: request,
                    handle: handle,
                    verificationEvidence: verificationEvidence,
                    broker: try requireBroker(broker),
                    lease: lease,
                    leaseSaved: leaseSaved,
                    terminationMonitor: nil
                )
                entries[key] = .active(active)
                startTerminationMonitor(for: active, key: key)
                return handle
            } catch {
                let primaryCode = failureCode(for: error)
                let cleanup = await cleanup(
                    broker: broker,
                    reservation: nil,
                    lease: lease,
                    leaseSaved: leaseSaved
                )
                if primaryCode == .localPortUnavailable,
                   attempt < Self.maximumPortAllocationAttempts,
                   cleanup != .pending {
                    continue
                }
                let failure = TunnelOpenFailure(code: primaryCode, cleanup: cleanup)
                record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
                throw failure
            }
        }

        let failure = TunnelOpenFailure(code: .localPortUnavailable, cleanup: .completed)
        record(tunnelID, .failed(failure.code, cleanup: failure.cleanup))
        throw failure
    }

    private func registryKey(for request: TunnelRequest) -> RegistryKey {
        RegistryKey(
            subject: request.subject,
            sshIdentityID: request.sshIdentityID,
            sshAddressID: request.sshAddressID,
            remote: request.remote
        )
    }

    private func requireBroker(_ broker: (any TunnelBrokerSession)?) throws -> any TunnelBrokerSession {
        guard let broker else {
            throw TunnelBrokerLaunchError.exited
        }
        return broker
    }

    private func startTerminationMonitor(for active: ActiveTunnel, key: RegistryKey) {
        guard let observer = active.broker as? any TunnelBrokerTerminationObserving else {
            return
        }
        let tunnelID = active.handle.id
        let monitor = Task { [weak self, observer] in
            await observer.waitForTermination()
            guard !Task.isCancelled else { return }
            await self?.brokerExited(key: key, tunnelID: tunnelID)
        }
        guard case .active(var current) = entries[key], current.handle.id == tunnelID else {
            monitor.cancel()
            return
        }
        current.terminationMonitor = monitor
        entries[key] = .active(current)
    }

    private func beginCleanup(
        _ active: ActiveTunnel,
        key: RegistryKey,
        finalization: CleanupFinalization
    ) -> CleanupOperation {
        active.terminationMonitor?.cancel()
        let tunnelID = active.handle.id
        let broker = active.broker
        let lease = active.lease
        let leaseSaved = active.leaseSaved
        let leaseStore = self.leaseStore
        let task = Task.detached(priority: .utility) {
            let brokerCleanup = await broker.close()
            guard brokerCleanup != .pending else { return CleanupStatus.pending }
            guard leaseSaved else {
                return brokerCleanup == .notNeeded ? .completed : brokerCleanup
            }
            do {
                try await leaseStore.remove(lease)
                return .completed
            } catch {
                return .pending
            }
        }
        let operation = CleanupOperation(token: UUID(), task: task)
        cleanupInProgress[tunnelID] = operation
        Task { [weak self] in
            let cleanup = await task.value
            await self?.finishCleanup(
                key: key,
                tunnelID: tunnelID,
                token: operation.token,
                finalization: finalization,
                cleanup: cleanup
            )
        }
        return operation
    }

    private func finishCleanup(
        key: RegistryKey,
        tunnelID: UUID,
        token: UUID,
        finalization: CleanupFinalization,
        cleanup: CleanupStatus
    ) {
        guard cleanupInProgress[tunnelID]?.token == token else { return }
        cleanupInProgress.removeValue(forKey: tunnelID)
        guard let current = entries[key], self.tunnelID(in: current) == tunnelID else {
            return
        }

        switch finalization {
        case .closed(let reason):
            guard cleanup != .pending else { return }
            record(tunnelID, .closed(reason))
            entries.removeValue(forKey: key)
        case .brokerExited:
            record(tunnelID, .failed(.brokerExited, cleanup: cleanup))
            entries.removeValue(forKey: key)
        }
    }

    private func waitForCleanup(
        _ operation: Task<CleanupStatus, Never>
    ) async -> CleanupOperationWaitResult {
        await runOperationWithTimeout {
            await operation.value
        }
    }

    private func tunnelID(in entry: RegistryEntry) -> UUID {
        switch entry {
        case .starting(let starting): starting.tunnelID
        case .active(let active), .closing(let active): active.handle.id
        }
    }

    private func cleanup(
        broker: (any TunnelBrokerSession)?,
        reservation: (any LoopbackPortReservation)?,
        lease: TunnelLease,
        leaseSaved: Bool
    ) async -> CleanupStatus {
        var status: CleanupStatus = .notNeeded
        var brokerCleanup: CleanupStatus = .notNeeded
        if let broker {
            brokerCleanup = await runCleanupWithTimeout { await broker.close() }
            status = merge(status, brokerCleanup)
        }
        if let reservation {
            status = merge(status, await release(reservation))
        }
        if leaseSaved, brokerCleanup != .pending {
            let leaseRemoval = await runCleanupWithTimeout { [leaseStore] in
                do {
                    try await leaseStore.remove(lease)
                    return .completed
                } catch {
                    return .pending
                }
            }
            status = merge(status, leaseRemoval)
        }
        return status == .notNeeded ? .completed : status
    }

    private func release(_ reservation: any LoopbackPortReservation) async -> CleanupStatus {
        await runCleanupWithTimeout {
            await reservation.release()
            return .completed
        }
    }

    private func runCleanupWithTimeout(
        _ operation: @escaping @Sendable () async -> CleanupStatus
    ) async -> CleanupStatus {
        switch await runOperationWithTimeout(operation) {
        case .finished(let cleanup): cleanup
        case .timedOut: .pending
        }
    }

    private func runOperationWithTimeout(
        _ operation: @escaping @Sendable () async -> CleanupStatus
    ) async -> CleanupOperationWaitResult {
        let race = CleanupTimeoutRace()
        let timeoutNanoseconds = cleanupTimeoutNanoseconds
        return await withCheckedContinuation { continuation in
            race.setContinuation(continuation)
            let operationTask = Task.detached(priority: .utility) {
                let result = await operation()
                race.resolve(.finished(result))
            }
            race.setOperationTask(operationTask)
            let timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                race.resolve(.timedOut)
            }
            race.setTimeoutTask(timeoutTask)
        }
    }

    private func failureCode(for error: Error) -> OperationFailureCode {
        if error is CancellationError { return .reservationCancelled }
        if let failure = error as? TunnelOpenFailure { return failure.code }
        if let error = error as? TunnelBrokerLaunchError { return error.failureCode }
        return .brokerExited
    }

    private func merge(_ lhs: CleanupStatus, _ rhs: CleanupStatus) -> CleanupStatus {
        if lhs == .pending || rhs == .pending { return .pending }
        if lhs == .completed || rhs == .completed { return .completed }
        return .notNeeded
    }

    private func record(_ tunnelID: UUID, _ state: TunnelState) {
        stateHistory[tunnelID, default: []].append(state)
    }

    private func removeStartingEntryIfMatches(key: RegistryKey, tunnelID: UUID) {
        guard case .starting(let starting) = entries[key], starting.tunnelID == tunnelID else {
            return
        }
        entries.removeValue(forKey: key)
    }
}

private enum CleanupOperationWaitResult: Sendable {
    case finished(CleanupStatus)
    case timedOut
}

private final class CleanupTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CleanupOperationWaitResult?
    private var continuation: CheckedContinuation<CleanupOperationWaitResult, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setContinuation(
        _ continuation: CheckedContinuation<CleanupOperationWaitResult, Never>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            operationTask = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resolve(_ result: CleanupOperationWaitResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let losingOperationTask = operationTask
        let losingTimeoutTask = timeoutTask
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        switch result {
        case .finished:
            losingTimeoutTask?.cancel()
        case .timedOut:
            losingOperationTask?.cancel()
        }
        continuation?.resume(returning: result)
    }
}
