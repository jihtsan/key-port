import Foundation
import XCTest
@testable import KeyPortCore

final class ConnectionHistoryStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func makeStore(
        bytes: InMemoryHistoryBytesStore = InMemoryHistoryBytesStore(),
        clock: HistoryFixedClock? = nil,
        ssidLookup: ConnectionHistoryStore.SSIDLookup? = nil
    ) -> ConnectionHistoryStore {
        ConnectionHistoryStore(
            bytesStore: bytes,
            clock: clock ?? HistoryFixedClock(t0),
            ssidLookup: ssidLookup
        )
    }

    func testBeginFinishPersistsOneTerminalRecordInOneAtomicReplaceEach() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let store = makeStore(bytes: bytes)
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        let inflight = await store.inflightContexts()
        XCTAssertEqual(inflight, [context])
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        let records = await store.records(hostID: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.result, .succeeded)
        XCTAssertNil(records.first?.ssid)
        XCTAssertEqual(bytes.replaceCount, 2, "begin and finish must each persist in a single atomic replace")
        let remainingInflight = await store.inflightContexts()
        XCTAssertTrue(remainingInflight.isEmpty)
    }

    func testFinishWriteFailureThrowsStableCodeAndLeavesStateUntouched() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let store = makeStore(bytes: bytes)
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        bytes.injectedWriteFailure = true
        do {
            try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
            XCTFail("finish must surface the write failure")
        } catch let error as ConnectionHistoryError {
            XCTAssertEqual(error, .writeFailed)
            XCTAssertEqual(error.failureCode, .historyWriteFailed)
        }
        // The failed write did not mutate the persisted state: the inflight
        // context is still there and a retry succeeds once writes recover.
        bytes.injectedWriteFailure = false
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        let records = await store.records(hostID: nil)
        XCTAssertEqual(records.count, 1)
    }

    func testBeginWriteFailureThrowsStableCode() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let store = makeStore(bytes: bytes)
        bytes.injectedWriteFailure = true
        do {
            try await store.begin(historyContext(hostID: hostID, startedAt: t0))
            XCTFail("begin must surface the write failure")
        } catch let error as ConnectionHistoryError {
            XCTAssertEqual(error.failureCode, .historyWriteFailed)
        }
        bytes.injectedWriteFailure = false
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        let inflight = await store.inflightContexts()
        XCTAssertEqual(inflight, [context])
    }

    func testClearFaultInjectionLeavesRecordsUntouched() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let store = makeStore(bytes: bytes)
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        bytes.injectedWriteFailure = true
        do {
            try await store.clear(hostID: hostID)
            XCTFail("clear must surface the write failure")
        } catch let error as ConnectionHistoryError {
            XCTAssertEqual(error, .writeFailed)
        }
        let surviving = await store.records(hostID: nil)
        XCTAssertEqual(surviving.count, 1)
        bytes.injectedWriteFailure = false
        try await store.clear(hostID: hostID)
        let afterClear = await store.records(hostID: nil)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testClearAllRemovesEveryRecordAtomically() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let store = makeStore(bytes: bytes)
        for index in 0..<3 {
            let context = historyContext(hostID: UUID(), startedAt: t0.addingTimeInterval(TimeInterval(index)))
            try await store.begin(context)
            try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        }
        let beforeClear = await store.records(hostID: nil)
        XCTAssertEqual(beforeClear.count, 3)
        let writesBeforeClear = bytes.replaceCount
        try await store.clear(hostID: nil)
        let cleared = await store.records(hostID: nil)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(bytes.replaceCount, writesBeforeClear + 1, "clear must be one atomic replace")
    }

    func testCrashRecoveryClosesInflightAsInterruptedAcrossStoreInstances() async throws {
        let bytes = InMemoryHistoryBytesStore()
        let firstProcess = makeStore(bytes: bytes)
        let waiting = historyContext(hostID: hostID, action: .addressValidation, startedAt: t0)
        try await firstProcess.begin(waiting)

        // Simulated restart: a new store over the same bytes recovers the
        // leftover inflight (crash or abandoned waiting-for-user state).
        let restartClock = HistoryFixedClock(t0.addingTimeInterval(3600))
        let secondProcess = makeStore(bytes: bytes, clock: restartClock)
        let recovered = try await secondProcess.recoverInterruptedInflight()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.id, waiting.operationID)
        XCTAssertEqual(recovered.first?.result, .interruptedByPreviousTermination)

        // A late finish with a real outcome now conflicts with the terminal.
        do {
            try await secondProcess.finish(
                operationID: waiting.operationID,
                outcome: SanitizedOutcome(result: .succeeded)
            )
            XCTFail("finish after recovery must conflict with the interrupted terminal")
        } catch let error as ConnectionHistoryError {
            XCTAssertEqual(error.failureCode, .historyTerminalConflict)
        }
        let secondRecords = await secondProcess.records(hostID: nil)
        XCTAssertEqual(secondRecords.count, 1)
        // Repeating recovery after a second crash adds nothing.
        let thirdProcess = makeStore(bytes: bytes, clock: restartClock)
        let secondRecovery = try await thirdProcess.recoverInterruptedInflight()
        XCTAssertTrue(secondRecovery.isEmpty)
        let thirdRecords = await thirdProcess.records(hostID: nil)
        XCTAssertEqual(thirdRecords.count, 1)
    }

    func testCorruptFileIsResetAndReplacedByNextSave() async throws {
        let bytes = InMemoryHistoryBytesStore(precoded: Data("not json".utf8))
        let store = makeStore(bytes: bytes)
        let initialRecords = await store.records(hostID: nil)
        XCTAssertTrue(initialRecords.isEmpty)
        let recoveredFlag = await store.didRecoverFromCorruptFile
        XCTAssertTrue(recoveredFlag)
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(ConnectionHistoryEnvelope.self, from: bytes.currentData()!)
        XCTAssertEqual(persisted.records.count, 1)
    }

    func testConcurrentOperationsEachCloseIntoExactlyOneRecord() async throws {
        let store = makeStore()
        let contexts = (0..<20).map { historyContext(hostID: hostID, startedAt: t0.addingTimeInterval(TimeInterval($0))) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for context in contexts {
                group.addTask {
                    try await store.begin(context)
                    try await store.finish(
                        operationID: context.operationID,
                        outcome: SanitizedOutcome(result: .succeeded)
                    )
                }
            }
            try await group.waitForAll()
        }
        let records = await store.records(hostID: nil)
        XCTAssertEqual(records.count, contexts.count)
        XCTAssertEqual(Set(records.map(\.id)).count, contexts.count)
        let finalInflight = await store.inflightContexts()
        XCTAssertTrue(finalInflight.isEmpty)
    }

    func testSSIDLookupFeedsFinishAndIsSkippedForReplays() async throws {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let store = makeStore { _ in
            counter.reads += 1
            return "FixtureNet"
        }
        let context = historyContext(hostID: hostID, startedAt: t0)
        try await store.begin(context)
        let outcome = SanitizedOutcome(result: .succeeded)
        try await store.finish(operationID: context.operationID, outcome: outcome)
        try await store.finish(operationID: context.operationID, outcome: outcome)
        let records = await store.records(hostID: nil)
        XCTAssertEqual(records.first?.ssid, "FixtureNet")
        XCTAssertEqual(counter.reads, 1, "the SSID must only be read when a finish actually closes an inflight operation")
    }

    func testFinishPruneAndSavePerformanceGate() async throws {
        // 50 hosts x 200 terminal records, preloaded directly into the bytes
        // store so the measurement covers finish + retention + atomic save.
        var envelope = ConnectionHistoryEnvelope()
        var hosts: [UUID] = []
        for hostIndex in 0..<50 {
            let host = UUID()
            hosts.append(host)
            for recordIndex in 0..<200 {
                let stamp = t0.addingTimeInterval(TimeInterval(hostIndex * 200 + recordIndex))
                envelope.records.append(ConnectionRecord(
                    id: UUID(), hostID: host, action: .sshCheck,
                    result: .succeeded, startedAt: stamp, endedAt: stamp
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = InMemoryHistoryBytesStore(precoded: try encoder.encode(envelope))
        let clock = HistoryFixedClock(t0.addingTimeInterval(20_000))
        let store = makeStore(bytes: bytes, clock: clock)

        var durations: [TimeInterval] = []
        for iteration in 0..<60 {
            let context = historyContext(
                hostID: hosts[iteration % hosts.count],
                startedAt: clock.current
            )
            try await store.begin(context)
            clock.current = clock.current.addingTimeInterval(1)
            let start = ProcessInfo.processInfo.systemUptime
            try await store.finish(
                operationID: context.operationID,
                outcome: SanitizedOutcome(result: .succeeded)
            )
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95) - 1]
        XCTAssertLessThan(
            p95, 0.150,
            "finish + prune + atomic save p95 must stay below 150 ms (p95 = \(p95 * 1000) ms, max = \(sorted.last! * 1000) ms)"
        )
        // Retention stayed inside the per-host cap during the run.
        let records = await store.records(hostID: nil)
        XCTAssertLessThanOrEqual(records.count, 50 * ConnectionHistoryCore.maximumRecordsPerHost)
    }
}
