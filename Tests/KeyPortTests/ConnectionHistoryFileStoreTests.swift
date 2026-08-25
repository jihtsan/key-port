import Foundation
import XCTest
@testable import KeyPort
@testable import KeyPortCore

final class ConnectionHistoryFileStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testHistoryFileRoundTripsAcrossStoreInstancesWithOwnerOnlyPermissions() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        XCTAssertEqual(paths.connectionHistory.lastPathComponent, "history-v1.json")

        let store = ConnectionHistoryStore(
            bytesStore: FileConnectionHistoryBytesStore(fileURL: paths.connectionHistory),
            clock: HistoryFixedClockRef(t0)
        )
        let context = OperationContext(operationID: UUID(), hostID: hostID, action: .sshCheck, startedAt: t0)
        try await store.begin(context)
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.connectionHistory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "history file must be owner-only")

        // A new instance over the same file sees the record (durability), and
        // deleting the file is the sanctioned harmless rollback.
        let reloaded = ConnectionHistoryStore(
            bytesStore: FileConnectionHistoryBytesStore(fileURL: paths.connectionHistory),
            clock: HistoryFixedClockRef(t0)
        )
        let reloadedRecords = await reloaded.records(hostID: nil)
        XCTAssertEqual(reloadedRecords.count, 1)
    }

    func testCorruptHistoryFileIsResetByNextSave() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        try Data("corrupted".utf8).write(to: paths.connectionHistory)

        let store = ConnectionHistoryStore(
            bytesStore: FileConnectionHistoryBytesStore(fileURL: paths.connectionHistory),
            clock: HistoryFixedClockRef(t0)
        )
        let initialRecords = await store.records(hostID: nil)
        XCTAssertTrue(initialRecords.isEmpty)
        let context = OperationContext(operationID: UUID(), hostID: hostID, action: .sshCheck, startedAt: t0)
        try await store.begin(context)
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .cancelled))
        let saved = await store.records(hostID: nil)
        XCTAssertEqual(saved.first?.result, .cancelled)
    }

    func testClearOnlyTouchesTheHistoryFile() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        let sentinel = paths.applicationSupport.appendingPathComponent("sentinel.json")
        try Data("{}".utf8).write(to: sentinel)

        let store = ConnectionHistoryStore(
            bytesStore: FileConnectionHistoryBytesStore(fileURL: paths.connectionHistory),
            clock: HistoryFixedClockRef(t0)
        )
        let context = OperationContext(operationID: UUID(), hostID: hostID, action: .serviceOpen, startedAt: t0)
        try await store.begin(context)
        try await store.finish(operationID: context.operationID, outcome: SanitizedOutcome(result: .succeeded))
        try await store.clear(hostID: nil)

        let remaining = await store.records(hostID: nil)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "clearing history must not delete other files (hosts, identities, audit, config)")
    }
}

/// Reference clock wrapper so tests in this target do not need a Core-side
/// mutable clock.
private final class HistoryFixedClockRef: HostV6Clock, @unchecked Sendable {
    private let value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}
