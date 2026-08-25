import Foundation

/// System clock used by production wiring; tests inject a fixed clock.
public struct SystemHostV6Clock: HostV6Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Local connection history store backed by `history-v1.json`.
///
/// Every mutation stages the next envelope value and persists it with one
/// atomic replace; when persistence fails the in-memory state is left
/// untouched and `historyWriteFailed` is thrown, so the already completed
/// remote or network action is never rolled back. The store is an actor and
/// performs no work on the main actor.
public actor ConnectionHistoryStore: ConnectionHistoryWriting, ConnectionHistoryReading {
    public typealias SSIDLookup = @Sendable (OperationContext) async -> String?

    private let bytesStore: any ConnectionHistoryBytesStoring
    private let clock: any HostV6Clock
    private let ssidLookup: SSIDLookup?
    private var envelope: ConnectionHistoryEnvelope?
    private var loadReportedCorruption = false

    /// - Parameter ssidLookup: optional network hint resolver. When nil (the
    ///   default until the C2 signed-build matrix is accepted) every record is
    ///   written with `ssid = nil`.
    public init(
        bytesStore: any ConnectionHistoryBytesStoring,
        clock: any HostV6Clock,
        ssidLookup: SSIDLookup? = nil
    ) {
        self.bytesStore = bytesStore
        self.clock = clock
        self.ssidLookup = ssidLookup
    }

    /// True when the previous history file failed to decode and the store
    /// recovered by starting empty; the corrupt bytes are replaced by the next
    /// successful atomic save. History is local diagnostic data, so resetting
    /// it is the sanctioned recovery path.
    public var didRecoverFromCorruptFile: Bool { loadReportedCorruption }

    public func begin(_ context: OperationContext) async throws {
        var next = try loadEnvelope()
        try ConnectionHistoryCore.begin(&next, context: context)
        try persist(next)
    }

    /// Closes the operation into one terminal record. Replays of the same
    /// outcome are idempotent; use `records(hostID:)` to read the result.
    public func finish(operationID: UUID, outcome: SanitizedOutcome) async throws {
        _ = try await finishRecording(operationID: operationID, outcome: outcome)
    }

    /// Same as `finish(operationID:outcome:)` but returns the stored terminal
    /// record for callers that need it immediately.
    @discardableResult
    public func finishRecording(operationID: UUID, outcome: SanitizedOutcome) async throws -> ConnectionRecord {
        // The SSID lookup is the only suspension point: stage the mutation
        // from a fresh envelope snapshot taken after it completes.
        let context = try loadEnvelope().inflight.first { $0.operationID == operationID }
        let ssid: String?
        if let context, let ssidLookup {
            ssid = await ssidLookup(context)
        } else {
            ssid = nil
        }
        var next = try loadEnvelope()
        let record = try ConnectionHistoryCore.finish(
            &next,
            operationID: operationID,
            outcome: outcome,
            endedAt: clock.now(),
            ssid: ssid
        )
        try persist(next)
        return record
    }

    public func clear(hostID: UUID?) async throws {
        var next = try loadEnvelope()
        ConnectionHistoryCore.clear(&next, hostID: hostID)
        try persist(next)
    }

    /// Startup recovery: closes every leftover inflight operation into one
    /// terminal `interruptedByPreviousTermination` record. Must run once
    /// before new operations are begun.
    @discardableResult
    public func recoverInterruptedInflight() async throws -> [ConnectionRecord] {
        var next = try loadEnvelope()
        let recovered = ConnectionHistoryCore.recoverInterrupted(&next, endedAt: clock.now())
        if !recovered.isEmpty {
            try persist(next)
        }
        return recovered
    }

    public func records(hostID: UUID?) async -> [ConnectionRecord] {
        let current = (try? loadEnvelope()) ?? ConnectionHistoryEnvelope()
        let filtered = hostID.map { id in current.records.filter { $0.hostID == id } } ?? current.records
        return filtered.sorted { lhs, rhs in
            if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    public func inflightContexts() async -> [OperationContext] {
        ((try? loadEnvelope()) ?? ConnectionHistoryEnvelope()).inflight
    }

    private func loadEnvelope() throws -> ConnectionHistoryEnvelope {
        if let envelope { return envelope }
        let data: Data?
        do {
            data = try bytesStore.load()
        } catch {
            throw ConnectionHistoryError.writeFailed
        }
        guard let data else {
            let loaded = ConnectionHistoryEnvelope()
            envelope = loaded
            return loaded
        }
        let loaded: ConnectionHistoryEnvelope
        do {
            loaded = try Self.decoder.decode(ConnectionHistoryEnvelope.self, from: data)
        } catch {
            loadReportedCorruption = true
            loaded = ConnectionHistoryEnvelope()
        }
        envelope = loaded
        return loaded
    }

    private func persist(_ next: ConnectionHistoryEnvelope) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(next)
        } catch {
            throw ConnectionHistoryError.writeFailed
        }
        do {
            try bytesStore.atomicReplace(with: data)
        } catch {
            throw ConnectionHistoryError.writeFailed
        }
        envelope = next
    }

    /// `sortedKeys` keeps the file byte-stable for identical content. Numeric
    /// Unix timestamps preserve Date precision across process restarts.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
