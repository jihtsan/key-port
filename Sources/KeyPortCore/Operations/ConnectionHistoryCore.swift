import Foundation

/// Pure transitions of the connection history envelope. All functions are
/// deterministic: time comes from the injected clock, and every mutation is
/// staged so the caller can persist it in a single atomic replace.
public enum ConnectionHistoryCore {
    /// Records older than this age at `finish` time are deleted.
    public static let maximumRecordAge: TimeInterval = 30 * 24 * 60 * 60
    /// Each host keeps at most this many terminal records, newest by `endedAt`.
    public static let maximumRecordsPerHost = 200

    /// Idempotent: repeating `begin` with the identical context is a no-op, as
    /// is replaying `begin` after the operation already reached a terminal
    /// record. A contradicting context for the same operation is a conflict.
    public static func begin(
        _ envelope: inout ConnectionHistoryEnvelope,
        context: OperationContext
    ) throws {
        if let existing = envelope.inflight.first(where: { $0.operationID == context.operationID }) {
            guard existing == context else { throw ConnectionHistoryError.terminalConflict }
            return
        }
        if envelope.records.contains(where: { $0.id == context.operationID }) {
            return
        }
        envelope.inflight.append(context)
    }

    /// Closes one operation into exactly one terminal record: removes the
    /// inflight context, upserts the record by operationID and applies
    /// retention, all staged for one atomic replace. Replaying the same
    /// outcome is an idempotent success; a different outcome for an existing
    /// terminal record is `historyTerminalConflict`.
    @discardableResult
    public static func finish(
        _ envelope: inout ConnectionHistoryEnvelope,
        operationID: UUID,
        outcome: SanitizedOutcome,
        endedAt: Date,
        ssid: String?
    ) throws -> ConnectionRecord {
        if let terminal = envelope.records.first(where: { $0.id == operationID }) {
            guard terminal.result == outcome.result,
                  terminal.failureCode == outcome.failureCode,
                  terminal.accessMode == outcome.accessMode
            else { throw ConnectionHistoryError.terminalConflict }
            envelope.inflight.removeAll { $0.operationID == operationID }
            prune(&envelope, now: endedAt)
            return terminal
        }
        guard let context = envelope.inflight.first(where: { $0.operationID == operationID }) else {
            throw ConnectionHistoryError.terminalConflict
        }
        let record = ConnectionRecord(
            id: context.operationID,
            hostID: context.hostID,
            addressID: context.addressID,
            sshIdentityID: context.sshIdentityID,
            serviceID: context.serviceID,
            action: context.action,
            accessMode: outcome.accessMode,
            result: outcome.result,
            failureCode: outcome.failureCode,
            startedAt: context.startedAt,
            endedAt: endedAt,
            ssid: ssid
        )
        envelope.inflight.removeAll { $0.operationID == operationID }
        envelope.records.append(record)
        prune(&envelope, now: endedAt)
        return record
    }

    /// Startup recovery: every leftover inflight operation is closed into
    /// exactly one terminal `interruptedByPreviousTermination` record, so a
    /// crash or an abandoned waiting-for-user state never produces zero or
    /// multiple history entries for one user action.
    @discardableResult
    public static func recoverInterrupted(
        _ envelope: inout ConnectionHistoryEnvelope,
        endedAt: Date
    ) -> [ConnectionRecord] {
        let pending = envelope.inflight
        guard !pending.isEmpty else { return [] }
        envelope.inflight.removeAll()
        var recovered: [ConnectionRecord] = []
        for context in pending {
            if let existing = envelope.records.first(where: { $0.id == context.operationID }) {
                recovered.append(existing)
                continue
            }
            let record = ConnectionRecord(
                id: context.operationID,
                hostID: context.hostID,
                addressID: context.addressID,
                sshIdentityID: context.sshIdentityID,
                serviceID: context.serviceID,
                action: context.action,
                result: .interruptedByPreviousTermination,
                startedAt: context.startedAt,
                endedAt: endedAt
            )
            envelope.records.append(record)
            recovered.append(record)
        }
        prune(&envelope, now: endedAt)
        return recovered
    }

    /// Clears terminal records for one host, or for every host when `hostID`
    /// is nil. Inflight contexts are kept so an action that was already
    /// running can still close into exactly one new terminal record. Only the
    /// history envelope is touched: Host, Address, Identity, Service,
    /// AuditEvent and SSH configuration are outside this store.
    public static func clear(
        _ envelope: inout ConnectionHistoryEnvelope,
        hostID: UUID?
    ) {
        if let hostID {
            envelope.records.removeAll { $0.hostID == hostID }
        } else {
            envelope.records.removeAll()
        }
    }

    /// First-in-first-deleted retention: drops records older than 30 days,
    /// then keeps only the 200 most recent records per host by `endedAt`.
    public static func prune(
        _ envelope: inout ConnectionHistoryEnvelope,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-maximumRecordAge)
        envelope.records.removeAll { $0.endedAt < cutoff }
        var countsByHost: [UUID: Int] = [:]
        let ordered = envelope.records.sorted { lhs, rhs in
            if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        var kept: [ConnectionRecord] = []
        kept.reserveCapacity(ordered.count)
        for record in ordered {
            let count = countsByHost[record.hostID, default: 0]
            guard count < maximumRecordsPerHost else { continue }
            countsByHost[record.hostID] = count + 1
            kept.append(record)
        }
        envelope.records = kept
    }
}
