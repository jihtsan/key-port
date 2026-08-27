import Foundation

/// Actions that share one operation context and produce exactly one terminal
/// connection record per user action (architecture section 10.1).
public enum ConnectionAction: String, Codable, CaseIterable, Hashable, Sendable {
    case addressValidation
    case serviceDiscovery
    case sshCheck
    case serviceOpen
    case tunnelOperation
}

/// How a service was reached during this operation. Never upgrades trust.
public enum AccessMode: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case tunnel
    case unavailable
}

/// Terminal result of one operation. `interruptedByPreviousTermination` is the
/// recovery terminal for inflight operations whose process died or never
/// resumed from a waiting-for-user state.
public enum OperationResult: String, Codable, CaseIterable, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
    case interruptedByPreviousTermination
}

/// Minimal context persisted atomically by `begin`. `operationID` is also the
/// id of the terminal `ConnectionRecord`.
public struct OperationContext: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let hostID: UUID
    public let addressID: UUID?
    public let sshIdentityID: UUID?
    public let serviceID: UUID?
    public let action: ConnectionAction
    public let startedAt: Date

    public init(
        operationID: UUID,
        hostID: UUID,
        addressID: UUID? = nil,
        sshIdentityID: UUID? = nil,
        serviceID: UUID? = nil,
        action: ConnectionAction,
        startedAt: Date
    ) {
        self.operationID = operationID
        self.hostID = hostID
        self.addressID = addressID
        self.sshIdentityID = sshIdentityID
        self.serviceID = serviceID
        self.action = action
        self.startedAt = startedAt
    }
}

/// The only payload `finish` accepts. Sanitization is enforced by the type
/// system: no free-form text, no commands, no raw probe output can be passed.
public struct SanitizedOutcome: Codable, Hashable, Sendable {
    public var result: OperationResult
    public var failureCode: OperationFailureCode?
    public var accessMode: AccessMode?

    public init(
        result: OperationResult,
        failureCode: OperationFailureCode? = nil,
        accessMode: AccessMode? = nil
    ) {
        self.result = result
        self.failureCode = failureCode
        self.accessMode = accessMode
    }
}

/// One terminal record per user action, stored only in the local
/// `history-v1.json`. The Codable keys of this type are the history
/// allow-list: secrets, full commands, raw discovery/OpenSSH output, BSSID,
/// location and address string copies are not representable here.
public struct ConnectionRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let hostID: UUID
    public let addressID: UUID?
    public let sshIdentityID: UUID?
    public let serviceID: UUID?
    public let action: ConnectionAction
    public let accessMode: AccessMode?
    public let result: OperationResult
    public let failureCode: OperationFailureCode?
    public let startedAt: Date
    public let endedAt: Date
    public let ssid: String?

    public init(
        id: UUID,
        hostID: UUID,
        addressID: UUID? = nil,
        sshIdentityID: UUID? = nil,
        serviceID: UUID? = nil,
        action: ConnectionAction,
        accessMode: AccessMode? = nil,
        result: OperationResult,
        failureCode: OperationFailureCode? = nil,
        startedAt: Date,
        endedAt: Date,
        ssid: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.addressID = addressID
        self.sshIdentityID = sshIdentityID
        self.serviceID = serviceID
        self.action = action
        self.accessMode = accessMode
        self.result = result
        self.failureCode = failureCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.ssid = ssid
    }
}

/// Errors surfaced by history writes. Each maps to exactly one stable failure
/// code from architecture section 11; no synonym codes exist.
public enum ConnectionHistoryError: Error, Hashable, Sendable {
    /// A terminal record already exists with a different outcome, the inflight
    /// context contradicts an existing one, or the operation is unknown.
    case terminalConflict
    /// Reading, encoding or the atomic file replace failed. The completed
    /// remote or network action must not be rolled back because of this error.
    case writeFailed

    public var failureCode: OperationFailureCode {
        switch self {
        case .terminalConflict: .historyTerminalConflict
        case .writeFailed: .historyWriteFailed
        }
    }
}

/// Persisted content of `history-v1.json`. `inflight` is never displayed; it
/// exists so a crash can be closed into exactly one terminal record.
public struct ConnectionHistoryEnvelope: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var inflight: [OperationContext]
    public var records: [ConnectionRecord]

    public init(
        schemaVersion: Int = ConnectionHistoryEnvelope.currentSchemaVersion,
        inflight: [OperationContext] = [],
        records: [ConnectionRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.inflight = inflight
        self.records = records
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == ConnectionHistoryEnvelope.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported history schema version \(version)"
            )
        }
        schemaVersion = version
        inflight = try container.decode([OperationContext].self, forKey: .inflight)
        records = try container.decode([ConnectionRecord].self, forKey: .records)
    }
}

public protocol ConnectionHistoryWriting: Sendable {
    func begin(_ context: OperationContext) async throws
    func finish(operationID: UUID, outcome: SanitizedOutcome) async throws
    func clear(hostID: UUID?) async throws
}

public protocol ConnectionHistoryReading: Sendable {
    func records(hostID: UUID?) async -> [ConnectionRecord]
}

/// Byte-level persistence seam so tests can run the store against memory and
/// inject atomic-replace failures without touching the file system. The calls
/// are synchronous so the store actor never suspends between staging an
/// envelope mutation and committing it.
public protocol ConnectionHistoryBytesStoring: Sendable {
    func load() throws -> Data?
    func atomicReplace(with data: Data) throws
}
