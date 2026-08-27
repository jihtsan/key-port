import Foundation
import XCTest
@testable import KeyPortCore

final class ConnectionHistoryCoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherHostID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private func makeEnvelope() -> ConnectionHistoryEnvelope { ConnectionHistoryEnvelope() }

    // MARK: begin idempotency

    func testBeginReplayWithIdenticalContextKeepsSingleInflight() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        XCTAssertEqual(envelope.inflight, [context])
        XCTAssertTrue(envelope.records.isEmpty)
    }

    func testBeginWithContradictingContextIsTerminalConflict() throws {
        var envelope = makeEnvelope()
        let operationID = UUID()
        try ConnectionHistoryCore.begin(
            &envelope,
            context: historyContext(operationID: operationID, hostID: hostID, startedAt: t0)
        )
        XCTAssertThrowsError(
            try ConnectionHistoryCore.begin(
                &envelope,
                context: historyContext(operationID: operationID, hostID: otherHostID, startedAt: t0)
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionHistoryError, .terminalConflict)
            XCTAssertEqual((error as? ConnectionHistoryError)?.failureCode, .historyTerminalConflict)
        }
        XCTAssertEqual(envelope.inflight.count, 1)
    }

    func testBeginReplayAfterFinishIsANoOp() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        try ConnectionHistoryCore.finish(
            &envelope,
            operationID: context.operationID,
            outcome: SanitizedOutcome(result: .succeeded),
            endedAt: t0.addingTimeInterval(1),
            ssid: nil
        )
        try ConnectionHistoryCore.begin(&envelope, context: context)
        XCTAssertTrue(envelope.inflight.isEmpty)
        XCTAssertEqual(envelope.records.count, 1)
    }

    // MARK: finish terminal semantics

    func testFinishClosesInflightIntoExactlyOneTerminalRecord() throws {
        var envelope = makeEnvelope()
        let addressID = UUID()
        let context = historyContext(hostID: hostID, addressID: addressID, action: .serviceOpen, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        let record = try ConnectionHistoryCore.finish(
            &envelope,
            operationID: context.operationID,
            outcome: SanitizedOutcome(result: .succeeded, accessMode: .tunnel),
            endedAt: t0.addingTimeInterval(5),
            ssid: "FixtureNet"
        )
        XCTAssertTrue(envelope.inflight.isEmpty)
        XCTAssertEqual(envelope.records, [record])
        XCTAssertEqual(record.id, context.operationID)
        XCTAssertEqual(record.hostID, hostID)
        XCTAssertEqual(record.addressID, addressID)
        XCTAssertEqual(record.action, .serviceOpen)
        XCTAssertEqual(record.accessMode, .tunnel)
        XCTAssertEqual(record.result, .succeeded)
        XCTAssertNil(record.failureCode)
        XCTAssertEqual(record.startedAt, t0)
        XCTAssertEqual(record.endedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(record.ssid, "FixtureNet")
    }

    func testFinishReplayWithSameOutcomeIsIdempotentSuccess() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        let outcome = SanitizedOutcome(result: .failed, failureCode: .tcpTimeout)
        let first = try ConnectionHistoryCore.finish(
            &envelope, operationID: context.operationID, outcome: outcome,
            endedAt: t0.addingTimeInterval(1), ssid: nil
        )
        let replayed = try ConnectionHistoryCore.finish(
            &envelope, operationID: context.operationID, outcome: outcome,
            endedAt: t0.addingTimeInterval(30), ssid: "ChangedNetwork"
        )
        XCTAssertEqual(replayed, first)
        XCTAssertEqual(envelope.records.count, 1)
        XCTAssertNil(envelope.records.first?.ssid)
        XCTAssertEqual(envelope.records.first?.endedAt, t0.addingTimeInterval(1))
    }

    func testFinishReplayWithDifferentOutcomeIsTerminalConflictAndKeepsRecord() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        let stored = try ConnectionHistoryCore.finish(
            &envelope, operationID: context.operationID,
            outcome: SanitizedOutcome(result: .succeeded),
            endedAt: t0.addingTimeInterval(1), ssid: nil
        )
        XCTAssertThrowsError(
            try ConnectionHistoryCore.finish(
                &envelope, operationID: context.operationID,
                outcome: SanitizedOutcome(result: .failed, failureCode: .keyAuthenticationFailed),
                endedAt: t0.addingTimeInterval(2), ssid: nil
            )
        ) { error in
            XCTAssertEqual((error as? ConnectionHistoryError)?.failureCode, .historyTerminalConflict)
        }
        XCTAssertEqual(envelope.records, [stored])
        XCTAssertTrue(envelope.inflight.isEmpty)
    }

    func testFinishWithoutInflightOrTerminalIsRejected() {
        var envelope = makeEnvelope()
        XCTAssertThrowsError(
            try ConnectionHistoryCore.finish(
                &envelope, operationID: UUID(),
                outcome: SanitizedOutcome(result: .succeeded),
                endedAt: t0, ssid: nil
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionHistoryError, .terminalConflict)
        }
        XCTAssertTrue(envelope.records.isEmpty)
    }

    // MARK: crash / waiting-for-user recovery

    func testRecoveryClosesEveryInflightIntoOneInterruptedRecord() throws {
        var envelope = makeEnvelope()
        let first = historyContext(hostID: hostID, action: .addressValidation, startedAt: t0)
        let second = historyContext(hostID: hostID, action: .serviceDiscovery, startedAt: t0.addingTimeInterval(2))
        try ConnectionHistoryCore.begin(&envelope, context: first)
        try ConnectionHistoryCore.begin(&envelope, context: second)
        let recovered = ConnectionHistoryCore.recoverInterrupted(&envelope, endedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(recovered.count, 2)
        XCTAssertTrue(envelope.inflight.isEmpty)
        XCTAssertEqual(envelope.records.count, 2)
        for record in envelope.records {
            XCTAssertEqual(record.result, .interruptedByPreviousTermination)
            XCTAssertNil(record.failureCode)
            XCTAssertNil(record.ssid)
            XCTAssertEqual(record.endedAt, t0.addingTimeInterval(60))
        }
    }

    func testRecoveryIsIdempotentAndPreservesExistingTerminal() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        let firstRecovery = ConnectionHistoryCore.recoverInterrupted(&envelope, endedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(firstRecovery.count, 1)
        // A begin replay after the crash is a no-op because the terminal
        // record already exists, so a second recovery converts nothing.
        try ConnectionHistoryCore.begin(&envelope, context: context)
        let secondRecovery = ConnectionHistoryCore.recoverInterrupted(&envelope, endedAt: t0.addingTimeInterval(120))
        XCTAssertTrue(secondRecovery.isEmpty)
        XCTAssertEqual(envelope.records.count, 1)
        XCTAssertTrue(envelope.inflight.isEmpty)
    }

    // MARK: retention

    func testPruneDropsRecordsOlderThanThirtyDays() throws {
        var envelope = makeEnvelope()
        let old = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: old)
        try ConnectionHistoryCore.finish(
            &envelope, operationID: old.operationID,
            outcome: SanitizedOutcome(result: .succeeded),
            endedAt: t0, ssid: nil
        )
        let now = t0.addingTimeInterval(ConnectionHistoryCore.maximumRecordAge + 1)
        let fresh = historyContext(hostID: hostID, startedAt: now)
        try ConnectionHistoryCore.begin(&envelope, context: fresh)
        try ConnectionHistoryCore.finish(
            &envelope, operationID: fresh.operationID,
            outcome: SanitizedOutcome(result: .succeeded),
            endedAt: now, ssid: nil
        )
        XCTAssertEqual(envelope.records.map(\.id), [fresh.operationID])
    }

    func testPruneKeepsTwoHundredNewestRecordsPerHostFirstInFirstDeleted() throws {
        var envelope = makeEnvelope()
        for index in 0..<201 {
            let stamp = t0.addingTimeInterval(TimeInterval(index))
            let context = historyContext(hostID: hostID, startedAt: stamp)
            try ConnectionHistoryCore.begin(&envelope, context: context)
            try ConnectionHistoryCore.finish(
                &envelope, operationID: context.operationID,
                outcome: SanitizedOutcome(result: .succeeded),
                endedAt: stamp, ssid: nil
            )
        }
        XCTAssertEqual(envelope.records.count, ConnectionHistoryCore.maximumRecordsPerHost)
        let endedAts = envelope.records.map(\.endedAt)
        XCTAssertFalse(endedAts.contains(t0), "oldest record must be evicted first")
        XCTAssertTrue(endedAts.contains(t0.addingTimeInterval(200)))
        // A second host is not affected by the first host's eviction.
        let other = historyContext(hostID: otherHostID, startedAt: t0.addingTimeInterval(300))
        try ConnectionHistoryCore.begin(&envelope, context: other)
        try ConnectionHistoryCore.finish(
            &envelope, operationID: other.operationID,
            outcome: SanitizedOutcome(result: .cancelled),
            endedAt: t0.addingTimeInterval(300), ssid: nil
        )
        XCTAssertEqual(envelope.records.filter { $0.hostID == otherHostID }.count, 1)
        XCTAssertEqual(envelope.records.filter { $0.hostID == hostID }.count, ConnectionHistoryCore.maximumRecordsPerHost)
    }

    // MARK: clear

    func testClearByHostKeepsOtherHostsAndInflight() throws {
        var envelope = makeEnvelope()
        for host in [hostID, otherHostID] {
            let context = historyContext(hostID: host, startedAt: t0)
            try ConnectionHistoryCore.begin(&envelope, context: context)
            try ConnectionHistoryCore.finish(
                &envelope, operationID: context.operationID,
                outcome: SanitizedOutcome(result: .succeeded),
                endedAt: t0.addingTimeInterval(1), ssid: "FixtureNet"
            )
        }
        let pending = historyContext(hostID: hostID, startedAt: t0.addingTimeInterval(2))
        try ConnectionHistoryCore.begin(&envelope, context: pending)

        ConnectionHistoryCore.clear(&envelope, hostID: hostID)
        XCTAssertTrue(envelope.records.allSatisfy { $0.hostID == otherHostID })
        XCTAssertEqual(envelope.records.count, 1)
        XCTAssertEqual(envelope.inflight, [pending])

        // The still-running action can close into exactly one new record.
        try ConnectionHistoryCore.finish(
            &envelope, operationID: pending.operationID,
            outcome: SanitizedOutcome(result: .succeeded),
            endedAt: t0.addingTimeInterval(3), ssid: nil
        )
        XCTAssertEqual(envelope.records.count, 2)

        ConnectionHistoryCore.clear(&envelope, hostID: nil)
        XCTAssertTrue(envelope.records.isEmpty)
        XCTAssertTrue(envelope.inflight.isEmpty)
    }

    func testEnvelopeRoundTripsThroughCodable() throws {
        var envelope = makeEnvelope()
        let context = historyContext(hostID: hostID, startedAt: t0)
        try ConnectionHistoryCore.begin(&envelope, context: context)
        try ConnectionHistoryCore.finish(
            &envelope, operationID: context.operationID,
            outcome: SanitizedOutcome(result: .failed, failureCode: .hostKeyChanged, accessMode: .unavailable),
            endedAt: t0.addingTimeInterval(1), ssid: "FixtureNet"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConnectionHistoryEnvelope.self, from: encoder.encode(envelope))
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeRejectsUnsupportedSchemaVersion() {
        let json = #"{"schemaVersion": 2, "inflight": [], "records": []}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConnectionHistoryEnvelope.self, from: Data(json.utf8))
        )
    }
}
