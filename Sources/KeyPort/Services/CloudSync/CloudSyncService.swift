import CloudKit
import Foundation
import KeyPortCore
import Security

enum CloudSyncState: Equatable, Sendable {
    case idle
    case syncing
    case available(Date)
    case unavailable(String)

    var title: String {
        switch self {
        case .idle: "未同步"
        case .syncing: "正在同步 CloudKit"
        case .available: "CloudKit 已是最新"
        case .unavailable: "CloudKit 不可用"
        }
    }
}

protocol CloudSyncing: Sendable {
    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot
}

enum CloudSyncError: LocalizedError {
    case accountUnavailable
    case malformedRecord

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: "请登录 iCloud 以同步 KeyPort 元数据。"
        case .malformedRecord: "CloudKit 返回了无效的 KeyPort 元数据记录。"
        }
    }
}

actor CloudKitSyncService: CloudSyncing {
    private let containerIdentifier: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let recordID = CKRecord.ID(recordName: "keyport-metadata-v1")

    init(containerIdentifier: String = "iCloud.com.jihtsan.KeyPort") {
        self.containerIdentifier = containerIdentifier
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot {
        guard hasCloudKitEntitlement() else { throw CloudSyncError.accountUnavailable }
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CloudSyncError.accountUnavailable }
        let database = container.privateCloudDatabase
        let sanitizedLocal = sanitized(local)
        let remote: AppSnapshot
        let record: CKRecord
        do {
            let fetchedRecord = try await database.record(for: recordID)
            guard let data = fetchedRecord["payload"] as? Data else { throw CloudSyncError.malformedRecord }
            remote = try decoder.decode(AppSnapshot.self, from: data)
            record = fetchedRecord
        } catch let error as CKError where error.code == .unknownItem {
            remote = AppSnapshot()
            record = CKRecord(recordType: "KPMetadata", recordID: recordID)
        }

        let merged = merge(local: sanitizedLocal, remote: remote)
        record["schemaVersion"] = merged.schemaVersion as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        record["payload"] = try encoder.encode(merged) as CKRecordValue
        _ = try await database.save(record)

        var restored = merged
        let localPaths = Dictionary(uniqueKeysWithValues: local.keys.map { ($0.fingerprint, $0.privateKeyPath) })
        restored.keys = restored.keys.map { key in
            var value = key
            value.privateKeyPath = localPaths[key.fingerprint] ?? nil
            value.isLocallyAvailable = value.privateKeyPath != nil || value.isInAgent
            return value
        }
        restored.auditEvents = local.auditEvents
        return restored
    }

    private func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else {
            return false
        }
        return (value as? [String])?.contains("CloudKit") == true
    }

    private func sanitized(_ snapshot: AppSnapshot) -> AppSnapshot {
        var value = snapshot
        value.servers = value.servers.map { server in
            var copy = server
            copy.status = .syncPending
            copy.statusDetail = nil
            copy.lastCheckedAt = nil
            copy.passwordCheck = nil
            copy.keyCheck = nil
            copy.lastKeySuccessAt = nil
            copy.lastAutomaticKeyCheckAt = nil
            copy.verifiedKeyContext = nil
            copy.lastObservedHostKeys = nil
            return copy
        }
        value.devices = value.devices.map { device in
            var copy = device
            copy.isCurrent = false
            return copy
        }
        value.keys = value.keys.map { key in
            var copy = key
            copy.privateKeyPath = nil
            copy.isInAgent = false
            copy.isLocallyAvailable = false
            return copy
        }
        value.auditEvents = []
        return value
    }

    private func merge(local: AppSnapshot, remote: AppSnapshot) -> AppSnapshot {
        var result = local
        result.servers = mergeByID(local.servers + remote.servers, id: \.id) { $0.updatedAt > $1.updatedAt }
        result.devices = mergeByID(local.devices + remote.devices, id: \.id) { $0.lastActiveAt > $1.lastActiveAt }
        result.keys = mergeByID(local.keys + remote.keys, id: \.fingerprint) { $0.isLocallyAvailable && !$1.isLocallyAvailable }
        result.authorizations = mergeByID(local.authorizations + remote.authorizations, id: \.id) {
            ($0.lastVerifiedAt ?? .distantPast) > ($1.lastVerifiedAt ?? .distantPast)
        }
        result.nodeAssociations = NodeAssociationMerger.merge(local.nodeAssociations + remote.nodeAssociations)
        return result
    }

    private func mergeByID<Value, ID: Hashable>(_ values: [Value], id: KeyPath<Value, ID>, prefer: (Value, Value) -> Bool) -> [Value] {
        var result: [ID: Value] = [:]
        for value in values {
            let key = value[keyPath: id]
            if let existing = result[key] {
                result[key] = prefer(value, existing) ? value : existing
            } else {
                result[key] = value
            }
        }
        return Array(result.values)
    }
}

actor InMemoryCloudSyncService: CloudSyncing {
    private var remote = AppSnapshot()

    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot {
        remote = local
        remote.keys = remote.keys.map { key in
            var copy = key
            copy.privateKeyPath = nil
            copy.isInAgent = false
            copy.isLocallyAvailable = false
            return copy
        }
        remote.auditEvents = []
        return local
    }
}
