import Foundation
@testable import KeyPortCore

final class HistoryFixedClock: HostV6Clock, @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date { current }
}

final class InMemoryHistoryBytesStore: ConnectionHistoryBytesStoring, @unchecked Sendable {
    private var stored: Data?
    private(set) var replaceCount = 0
    var injectedWriteFailure = false
    var injectedLoadFailure = false

    init(precoded data: Data? = nil) {
        stored = data
    }

    func load() throws -> Data? {
        if injectedLoadFailure { throw ConnectionHistoryError.writeFailed }
        return stored
    }

    func atomicReplace(with data: Data) throws {
        if injectedWriteFailure { throw ConnectionHistoryError.writeFailed }
        stored = data
        replaceCount += 1
    }

    func currentData() -> Data? { stored }
}

func historyContext(
    operationID: UUID = UUID(),
    hostID: UUID,
    addressID: UUID? = nil,
    action: ConnectionAction = .sshCheck,
    startedAt: Date
) -> OperationContext {
    OperationContext(
        operationID: operationID,
        hostID: hostID,
        addressID: addressID,
        action: action,
        startedAt: startedAt
    )
}
