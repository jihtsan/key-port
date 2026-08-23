import CloudKit
import Foundation
import KeyPortCore

enum CloudSyncState: Equatable, Sendable {
    case disabled
    case checking
    case syncing
    case succeeded(Date)
    case adHocSigned
    case cloudKitDisabled
    case signedOut
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "已关闭"
        case .checking: "正在检查"
        case .syncing: "同步中"
        case .succeeded: "同步成功"
        case .adHocSigned: "使用 ad-hoc 签名"
        case .cloudKitDisabled: "未启用 CloudKit"
        case .signedOut: "未登录 iCloud"
        case .failed: "同步失败"
        }
    }

    var detail: String? {
        switch self {
        case .disabled:
            "非敏感元数据仅保存在此 Mac。"
        case .checking:
            "正在检查签名、CloudKit entitlement 和 iCloud 账户。"
        case .syncing:
            "正在合并此 Mac 与 iCloud 私有数据库中的元数据。"
        case .succeeded:
            "非敏感元数据已与 iCloud 私有数据库合并。"
        case .adHocSigned:
            "ad-hoc 构建不能使用 CloudKit 或 iCloud Keychain。请使用有效的团队签名启动。"
        case .cloudKitDisabled:
            "当前签名未包含 KeyPort 所需的 CloudKit 容器 entitlement。"
        case .signedOut:
            "请登录 iCloud，并允许 KeyPort 使用 iCloud。"
        case .failed(let message):
            message
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "icloud.slash"
        case .checking, .syncing: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.icloud.fill"
        case .adHocSigned: "signature"
        case .cloudKitDisabled: "exclamationmark.icloud"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .failed: "xmark.icloud.fill"
        }
    }
}

protocol CloudSyncing: Sendable {
    func availability() async -> CloudSyncAvailability
    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot
}

enum CloudSyncAvailability: Sendable {
    case available
    case unavailable(CloudSyncError)
}

enum CloudSyncError: LocalizedError, Sendable, Equatable {
    case adHocSignature
    case missingEntitlement
    case accountUnavailable
    case accountRestricted
    case permissionDenied
    case malformedRecord
    case conflict
    case networkFailure(retryAfter: TimeInterval?)
    case temporarilyUnavailable(retryAfter: TimeInterval?)
    case quotaExceeded
    case payloadTooLarge
    case cancelled
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .adHocSignature:
            "当前应用使用 ad-hoc 签名，无法访问 CloudKit。"
        case .missingEntitlement:
            "当前签名未启用 KeyPort 的 CloudKit 容器。"
        case .accountUnavailable:
            "请登录 iCloud，并在系统设置中允许 KeyPort 使用 iCloud。"
        case .accountRestricted:
            "此 iCloud 账户当前不允许 KeyPort 使用 CloudKit。"
        case .permissionDenied:
            "CloudKit 拒绝了访问。请检查 App ID、容器和 Development 环境配置。"
        case .malformedRecord:
            "CloudKit 中的 KeyPort 元数据格式无效。"
        case .conflict:
            "另一台设备持续修改同一份元数据，请稍后再次同步。"
        case .networkFailure:
            "暂时无法连接 iCloud。KeyPort 会在网络恢复后重试。"
        case .temporarilyUnavailable:
            "CloudKit 暂时不可用，KeyPort 会稍后重试。"
        case .quotaExceeded:
            "iCloud 储存空间不足，无法保存 KeyPort 元数据。"
        case .payloadTooLarge:
            "KeyPort 元数据超过 CloudKit 可保存的大小。"
        case .cancelled:
            "iCloud 同步已取消。"
        case .operationFailed:
            "CloudKit 无法完成同步，请稍后重试。"
        }
    }

    var automaticRetryDelay: TimeInterval? {
        switch self {
        case .networkFailure(let retryAfter):
            max(15, retryAfter ?? 0)
        case .temporarilyUnavailable(let retryAfter):
            max(15, retryAfter ?? 0)
        case .conflict:
            5
        default:
            nil
        }
    }
}

actor CloudKitSyncService: CloudSyncing {
    private static let recordType = "KPMetadata"
    private static let recordName = "keyport-metadata-v1"

    private let containerIdentifier: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let recordID: CKRecord.ID

    init(containerIdentifier: String = "iCloud.com.jihtsan.KeyPort") {
        self.containerIdentifier = containerIdentifier
        self.recordID = CKRecord.ID(recordName: Self.recordName)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func availability() async -> CloudSyncAvailability {
        if let signingError = signingConfigurationError() {
            return .unavailable(signingError)
        }

        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available:
                return .available
            case .noAccount:
                return .unavailable(.accountUnavailable)
            case .restricted:
                return .unavailable(.accountRestricted)
            case .couldNotDetermine, .temporarilyUnavailable:
                return .unavailable(.temporarilyUnavailable(retryAfter: nil))
            @unknown default:
                return .unavailable(.operationFailed)
            }
        } catch {
            return .unavailable(mapCloudKitError(error))
        }
    }

    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot {
        switch await availability() {
        case .available:
            break
        case .unavailable(let error):
            throw error
        }

        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let sanitizedLocal = CloudMetadataSnapshotPolicy.sanitized(local)
        var conflictAttempts = 0
        var transientAttempts = 0

        while true {
            try Task.checkCancellation()
            do {
                let (record, remote, isNewRecord) = try await fetchRecord(from: database)
                let merged = CloudMetadataSnapshotPolicy.merge(local: sanitizedLocal, remote: remote)
                let payload = try encoder.encode(merged)
                let storedSchemaVersion = (record["schemaVersion"] as? NSNumber)?.intValue
                let payloadIsCurrent = !isNewRecord
                    && (record["payload"] as? Data) == payload
                    && storedSchemaVersion == merged.schemaVersion

                if !payloadIsCurrent {
                    record["schemaVersion"] = NSNumber(value: merged.schemaVersion)
                    record["updatedAt"] = Date() as CKRecordValue
                    record["payload"] = payload as CKRecordValue
                    try await save(record, to: database)
                }

                return CloudMetadataSnapshotPolicy.restoringLocalState(in: merged, from: local)
            } catch is CancellationError {
                throw CloudSyncError.cancelled
            } catch {
                let mapped = mapCloudKitError(error)
                if case .conflict = mapped, conflictAttempts < 4 {
                    conflictAttempts += 1
                    continue
                }
                if let delay = shortRetryDelay(for: mapped, attempt: transientAttempts), transientAttempts < 2 {
                    transientAttempts += 1
                    try await sleep(seconds: delay)
                    continue
                }
                throw mapped
            }
        }
    }

    private func fetchRecord(from database: CKDatabase) async throws -> (CKRecord, AppSnapshot, Bool) {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return (CKRecord(recordType: Self.recordType, recordID: recordID), AppSnapshot(), true)
        }

        guard let data = record["payload"] as? Data else {
            throw CloudSyncError.malformedRecord
        }
        do {
            let decoded = try decoder.decode(AppSnapshot.self, from: data)
            return (record, CloudMetadataSnapshotPolicy.sanitized(decoded), false)
        } catch {
            throw CloudSyncError.malformedRecord
        }
    }

    private func save(_ record: CKRecord, to database: CKDatabase) async throws {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let recordResult = result.saveResults[record.recordID] else {
            throw CloudSyncError.operationFailed
        }
        _ = try recordResult.get()
    }

    private func signingConfigurationError() -> CloudSyncError? {
        guard CodeSigningInfo.teamIdentifier != nil else { return .adHocSignature }
        guard CodeSigningInfo.entitlementContains("CloudKit", key: "com.apple.developer.icloud-services"),
              CodeSigningInfo.entitlementContains(containerIdentifier, key: "com.apple.developer.icloud-container-identifiers"),
              let environment = CodeSigningInfo.entitlementValue("com.apple.developer.icloud-container-environment") as? String,
              environment == "Development" || environment == "Production" else {
            return .missingEntitlement
        }
        return nil
    }

    private func mapCloudKitError(_ error: Error) -> CloudSyncError {
        if let error = error as? CloudSyncError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? CKError else { return .operationFailed }

        if error.code == .partialFailure,
           let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           let firstError = partialErrors.values.first {
            return mapCloudKitError(firstError)
        }

        let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        switch error.code {
        case .notAuthenticated:
            return .accountUnavailable
        case .managedAccountRestricted:
            return .accountRestricted
        case .permissionFailure:
            return .permissionDenied
        case .badContainer, .badDatabase, .missingEntitlement:
            return .missingEntitlement
        case .networkFailure, .networkUnavailable:
            return .networkFailure(retryAfter: retryAfter)
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable, .serverResponseLost:
            return .temporarilyUnavailable(retryAfter: retryAfter)
        case .serverRecordChanged, .batchRequestFailed:
            return .conflict
        case .quotaExceeded:
            return .quotaExceeded
        case .limitExceeded:
            return .payloadTooLarge
        case .operationCancelled:
            return .cancelled
        default:
            return .operationFailed
        }
    }

    private func shortRetryDelay(for error: CloudSyncError, attempt: Int) -> TimeInterval? {
        switch error {
        case .networkFailure(let retryAfter), .temporarilyUnavailable(let retryAfter):
            return min(8, retryAfter ?? pow(2, Double(attempt)))
        default:
            return nil
        }
    }

    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

actor InMemoryCloudSyncService: CloudSyncing {
    private var remote = AppSnapshot()

    func availability() async -> CloudSyncAvailability { .available }

    func synchronize(_ local: AppSnapshot) async throws -> AppSnapshot {
        let merged = CloudMetadataSnapshotPolicy.merge(local: local, remote: remote)
        remote = merged
        return CloudMetadataSnapshotPolicy.restoringLocalState(in: merged, from: local)
    }
}
