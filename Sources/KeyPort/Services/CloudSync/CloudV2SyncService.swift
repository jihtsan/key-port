import CloudKit
import Foundation
import KeyPortCore

struct HostV6CloudRecord: Equatable, Sendable {
    let payload: Data
    let changeTag: String
}

enum HostV6CloudTransportError: Error, Equatable, Sendable {
    case conflict
    case malformedRecord
    case cloud(CloudSyncError)
    case operationFailed
}

protocol HostV6CloudV2Transport: Sendable {
    func fetchV2() async throws -> HostV6CloudRecord?
    func fetchLegacyV1() async throws -> Data?
    func saveV2(_ payload: Data, replacing changeTag: String?) async throws -> HostV6CloudRecord
}

struct HostV6CloudSyncResult: Sendable {
    let envelope: HostV6.MetadataEnvelope
    let cloudChangeTag: String
    let payloadHash: String
    let conflictRetryCount: Int
}

actor HostV6CloudSyncCoordinator {
    private let transport: any HostV6CloudV2Transport
    private let importer: HostV6.ShadowMigrationEngine

    init(transport: any HostV6CloudV2Transport, currentDeviceID: String) {
        self.transport = transport
        self.importer = HostV6.ShadowMigrationEngine(currentDeviceID: currentDeviceID)
    }

    func validateAuthorityPrecondition(
        _ local: HostV6.MetadataEnvelope,
        evidence: HostV6.AuthorityActivationEvidence
    ) async throws {
        do {
            guard local.migrationProvenance.authorityManifest == nil else {
                throw HostV6.CloudV2Error.failure(.authorityGateFailed)
            }
            let expectedPayload = try HostV6.CloudPayloadCodec.encode(local)
            guard HostV6.CanonicalJSON.sha256(expectedPayload) == evidence.verifiedCloudPayloadHash,
                  let current = try await transport.fetchV2(),
                  current.changeTag == evidence.cloudChangeTag,
                  current.payload == expectedPayload else {
                throw HostV6.CloudV2Error.failure(.authorityGateFailed)
            }
            _ = try strictPayload(current.payload)
        } catch HostV6CloudTransportError.conflict {
            throw HostV6.CloudV2Error.failure(.concurrentConflict)
        } catch HostV6CloudTransportError.cloud(let error) {
            throw error
        } catch HostV6CloudTransportError.malformedRecord {
            throw CloudSyncError.malformedRecord
        } catch HostV6CloudTransportError.operationFailed {
            throw CloudSyncError.operationFailed
        } catch is CancellationError {
            throw CloudSyncError.cancelled
        }
    }

    func publishPreparedAuthority(
        _ pending: HostV6PreparedAuthorityActivation
    ) async throws -> HostV6.AuthorityCommitPlan? {
        do {
            let authorityPayload = try HostV6.CloudPayloadCodec.encode(pending.plan.envelope)
            guard HostV6.CanonicalJSON.sha256(authorityPayload) == pending.authorityPayloadHash else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            var preAuthority = pending.plan.envelope
            preAuthority.migrationProvenance.authorityManifest = nil
            let evidencePayload = try HostV6.CloudPayloadCodec.encode(preAuthority)
            guard HostV6.CanonicalJSON.sha256(evidencePayload) == pending.evidencePayloadHash else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }

            guard let current = try await transport.fetchV2() else { return nil }
            if let published = try publishedAuthorityPlan(
                from: current,
                restoringLocalStateFrom: pending.plan.envelope
            ) {
                return published
            }
            guard current.changeTag == pending.evidenceChangeTag,
                  current.payload == evidencePayload else {
                return nil
            }

            let saved: HostV6CloudRecord
            do {
                saved = try await transport.saveV2(
                    authorityPayload,
                    replacing: current.changeTag
                )
            } catch HostV6CloudTransportError.conflict {
                guard let concurrent = try await transport.fetchV2() else { return nil }
                return try publishedAuthorityPlan(
                    from: concurrent,
                    restoringLocalStateFrom: pending.plan.envelope
                )
            }
            guard !saved.changeTag.isEmpty,
                  saved.changeTag != current.changeTag,
                  saved.payload == authorityPayload,
                  let readBack = try await transport.fetchV2() else {
                throw HostV6.CloudV2Error.failure(.concurrentConflict)
            }
            if readBack == saved,
               let published = try publishedAuthorityPlan(
                   from: readBack,
                   restoringLocalStateFrom: pending.plan.envelope
               ) {
                return published
            }
            if let published = try publishedAuthorityPlan(
                from: readBack,
                restoringLocalStateFrom: pending.plan.envelope
            ) {
                return published
            }
            throw HostV6.CloudV2Error.failure(.concurrentConflict)
        } catch HostV6CloudTransportError.conflict {
            throw HostV6.CloudV2Error.failure(.concurrentConflict)
        } catch HostV6CloudTransportError.cloud(let error) {
            throw error
        } catch HostV6CloudTransportError.malformedRecord {
            throw CloudSyncError.malformedRecord
        } catch HostV6CloudTransportError.operationFailed {
            throw CloudSyncError.operationFailed
        } catch is CancellationError {
            throw CloudSyncError.cancelled
        }
    }

    func fetchPublishedAuthority(
        restoringLocalStateFrom local: HostV6.MetadataEnvelope
    ) async throws -> HostV6.AuthorityCommitPlan? {
        do {
            guard let current = try await transport.fetchV2() else { return nil }
            return try publishedAuthorityPlan(from: current, restoringLocalStateFrom: local)
        } catch HostV6CloudTransportError.cloud(let error) {
            throw error
        } catch HostV6CloudTransportError.malformedRecord {
            throw CloudSyncError.malformedRecord
        } catch HostV6CloudTransportError.operationFailed {
            throw CloudSyncError.operationFailed
        } catch is CancellationError {
            throw CloudSyncError.cancelled
        }
    }

    func synchronize(_ local: HostV6.MetadataEnvelope) async throws -> HostV6CloudSyncResult {
        if local.migrationProvenance.authorityManifest?.mode == .compatibilityRollback {
            throw HostV6.CloudV2Error.failure(.authorityGateFailed)
        }

        var conflictRetries = 0
        while true {
            try Task.checkCancellation()
            do {
                var candidate = local
                if let legacyData = try await transport.fetchLegacyV1() {
                    candidate = try importer.importCloudV1(legacyData, into: candidate)
                }

                let remote = try await transport.fetchV2()
                if let remote {
                    let payload = try strictPayload(remote.payload)
                    candidate = try HostV6.CloudGraphMergeEngine.merge(local: candidate, remote: payload)
                }
                if candidate.migrationProvenance.authorityManifest != nil {
                    candidate = try HostV6.AuthorityController.rebindManifest(in: candidate).envelope
                }

                let encoded = try HostV6.CloudPayloadCodec.encode(candidate)
                let payloadHash = HostV6.CanonicalJSON.sha256(encoded)
                if remote?.payload == encoded, let changeTag = remote?.changeTag {
                    return HostV6CloudSyncResult(
                        envelope: candidate,
                        cloudChangeTag: changeTag,
                        payloadHash: payloadHash,
                        conflictRetryCount: conflictRetries
                    )
                }

                let saved = try await transport.saveV2(encoded, replacing: remote?.changeTag)
                guard let readBack = try await transport.fetchV2(),
                      readBack.changeTag == saved.changeTag,
                      HostV6.CanonicalJSON.sha256(readBack.payload) == payloadHash else {
                    throw HostV6.CloudV2Error.failure(.concurrentConflict)
                }
                _ = try strictPayload(readBack.payload)
                return HostV6CloudSyncResult(
                    envelope: candidate,
                    cloudChangeTag: readBack.changeTag,
                    payloadHash: payloadHash,
                    conflictRetryCount: conflictRetries
                )
            } catch HostV6CloudTransportError.conflict {
                guard conflictRetries < 4 else {
                    throw HostV6.CloudV2Error.failure(.concurrentConflict)
                }
                conflictRetries += 1
            } catch HostV6.CloudV2Error.failure(.concurrentConflict) {
                guard conflictRetries < 4 else {
                    throw HostV6.CloudV2Error.failure(.concurrentConflict)
                }
                conflictRetries += 1
            } catch HostV6CloudTransportError.cloud(let error) {
                throw error
            } catch HostV6CloudTransportError.malformedRecord {
                throw CloudSyncError.malformedRecord
            } catch HostV6CloudTransportError.operationFailed {
                throw CloudSyncError.operationFailed
            } catch is CancellationError {
                throw CloudSyncError.cancelled
            }
        }
    }

    private func strictPayload(_ data: Data) throws -> HostV6.CloudPayload {
        do {
            return try HostV6.CloudPayloadCodec.decodeStrict(data)
        } catch let error as HostV6.CloudV2Error {
            throw error
        } catch {
            throw HostV6.CloudV2Error.failure(.decodeFailed)
        }
    }

    private func publishedAuthorityPlan(
        from record: HostV6CloudRecord,
        restoringLocalStateFrom local: HostV6.MetadataEnvelope
    ) throws -> HostV6.AuthorityCommitPlan? {
        let payload = try strictPayload(record.payload)
        guard let manifest = payload.migrationProvenance.authorityManifest,
              manifest.mode == .v6Authoritative || manifest.mode == .compatibilityRollback else {
            return nil
        }
        let envelope = payload.restoringLocalState(from: local)
        return try HostV6.AuthorityController.adoptPublishedAuthority(in: envelope)
    }
}

actor CloudKitV2RecordTransport: HostV6CloudV2Transport {
    static let recordType = "KPMetadataV2"
    static let recordName = "keyport-metadata-v2"
    static let legacyRecordType = "KPMetadata"
    static let legacyRecordName = "keyport-metadata-v1"

    private let containerIdentifier: String
    private var fetchedV2Record: CKRecord?

    init(containerIdentifier: String = "iCloud.com.jihtsan.KeyPort") {
        self.containerIdentifier = containerIdentifier
    }

    func fetchV2() async throws -> HostV6CloudRecord? {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard record.recordType == Self.recordType,
                  let payload = record["payload"] as? Data,
                  let changeTag = record.recordChangeTag else {
                throw HostV6CloudTransportError.malformedRecord
            }
            fetchedV2Record = record
            return HostV6CloudRecord(payload: payload, changeTag: changeTag)
        } catch let error as CKError where error.code == .unknownItem {
            fetchedV2Record = nil
            return nil
        } catch let error as HostV6CloudTransportError {
            throw error
        } catch {
            throw map(error)
        }
    }

    func fetchLegacyV1() async throws -> Data? {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: Self.legacyRecordName)
        do {
            let record = try await database.record(for: recordID)
            guard record.recordType == Self.legacyRecordType,
                  let payload = record["payload"] as? Data else {
                throw HostV6CloudTransportError.malformedRecord
            }
            return payload
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as HostV6CloudTransportError {
            throw error
        } catch {
            throw map(error)
        }
    }

    func saveV2(_ payload: Data, replacing changeTag: String?) async throws -> HostV6CloudRecord {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let record: CKRecord
        if let changeTag {
            guard let fetchedV2Record, fetchedV2Record.recordChangeTag == changeTag else {
                throw HostV6CloudTransportError.conflict
            }
            record = fetchedV2Record
        } else {
            guard fetchedV2Record == nil else { throw HostV6CloudTransportError.conflict }
            record = CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: Self.recordName)
            )
        }
        record["schemaVersion"] = NSNumber(value: 6)
        record["updatedAt"] = Date() as CKRecordValue
        record["payload"] = payload as CKRecordValue

        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let savedResult = result.saveResults[record.recordID] else {
                throw HostV6CloudTransportError.operationFailed
            }
            let saved = try savedResult.get()
            guard let savedPayload = saved["payload"] as? Data,
                  let savedTag = saved.recordChangeTag else {
                throw HostV6CloudTransportError.malformedRecord
            }
            fetchedV2Record = saved
            return HostV6CloudRecord(payload: savedPayload, changeTag: savedTag)
        } catch let error as HostV6CloudTransportError {
            throw error
        } catch {
            throw map(error)
        }
    }

    private func map(_ error: Error) -> HostV6CloudTransportError {
        guard let error = error as? CKError else { return .operationFailed }
        if error.code == .partialFailure,
           let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           let first = partial.values.first {
            return map(first)
        }
        let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        switch error.code {
        case .serverRecordChanged, .batchRequestFailed:
            return .conflict
        case .notAuthenticated:
            return .cloud(.accountUnavailable)
        case .managedAccountRestricted:
            return .cloud(.accountRestricted)
        case .permissionFailure:
            return .cloud(.permissionDenied)
        case .badContainer, .badDatabase, .missingEntitlement:
            return .cloud(.missingEntitlement)
        case .networkFailure, .networkUnavailable:
            return .cloud(.networkFailure(retryAfter: retryAfter))
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable,
             .serverResponseLost:
            return .cloud(.temporarilyUnavailable(retryAfter: retryAfter))
        case .quotaExceeded:
            return .cloud(.quotaExceeded)
        case .limitExceeded:
            return .cloud(.payloadTooLarge)
        case .operationCancelled:
            return .cloud(.cancelled)
        default:
            return .operationFailed
        }
    }
}
