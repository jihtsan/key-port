import Foundation
import XCTest
@testable import KeyPort
@testable import KeyPortCore

final class CloudV2SyncServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)

    func testCloudKitV2UsesIndependentRecordIdentity() {
        XCTAssertEqual(CloudKitV2RecordTransport.recordType, "KPMetadataV2")
        XCTAssertEqual(CloudKitV2RecordTransport.recordName, "keyport-metadata-v2")
        XCTAssertEqual(CloudKitV2RecordTransport.legacyRecordType, "KPMetadata")
        XCTAssertEqual(CloudKitV2RecordTransport.legacyRecordName, "keyport-metadata-v1")
    }

    func testCoordinatorRetriesFourCASConflictsThenVerifiesReadBack() async throws {
        let transport = ScriptedCloudV2Transport(conflictsRemaining: 4)
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        let result = try await coordinator.synchronize(makeEnvelope())
        let metrics = await transport.metrics()

        XCTAssertEqual(metrics.saveAttempts, 5)
        XCTAssertEqual(metrics.legacyFetches, 5)
        XCTAssertGreaterThanOrEqual(metrics.v2Fetches, 6)
        XCTAssertEqual(result.conflictRetryCount, 4)
        XCTAssertEqual(result.cloudChangeTag, "tag-1")
        XCTAssertEqual(
            result.payloadHash,
            HostV6.CanonicalJSON.sha256(try HostV6.CloudPayloadCodec.encode(result.envelope))
        )
    }

    func testCoordinatorFailsAfterFourCASRetriesWithoutOverwritingRemote() async throws {
        let transport = ScriptedCloudV2Transport(conflictsRemaining: 5)
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        do {
            _ = try await coordinator.synchronize(makeEnvelope())
            XCTFail("Expected conflict exhaustion")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.concurrentConflict))
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.saveAttempts, 5)
    }

    func testCoordinatorRetriesAWriteThatFailsReadBackVerification() async throws {
        let transport = ScriptedCloudV2Transport(readBackMismatchOnce: true)
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        let result = try await coordinator.synchronize(makeEnvelope())
        let metrics = await transport.metrics()

        XCTAssertEqual(result.conflictRetryCount, 1)
        XCTAssertEqual(metrics.saveAttempts, 1)
        XCTAssertEqual(result.cloudChangeTag, "tag-1")
    }

    func testAuthorityRoundTripRejectsStaleRemoteTagBeforeCAS() async throws {
        let envelope = makeEnvelope()
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        let transport = ScriptedCloudV2Transport(remoteV2: .init(
            payload: payload,
            changeTag: "tag-newer"
        ))
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )
        let evidence = HostV6.AuthorityActivationEvidence(
            completedRequirements: Set(HostV6.AuthorityRequirement.allCases),
            signedDevices: signedDeviceEvidence(),
            acknowledgedDeviceIDs: ["device-a", "device-b"],
            verifiedCloudPayloadHash: HostV6.CanonicalJSON.sha256(payload),
            cloudChangeTag: "tag-c3",
            codeVersion: "build-current",
            signerTeamIdentifier: "TEAMID1234"
        )

        do {
            _ = try await coordinator.validateAuthorityRoundTrip(envelope, evidence: evidence)
            XCTFail("Expected stale C3 Cloud tag to fail closed")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.v2Fetches, 1)
        XCTAssertEqual(metrics.saveAttempts, 0)
    }

    func testAuthorityRoundTripCASWritesAndReadBackBindsCommittedTag() async throws {
        let envelope = makeEnvelope()
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        let transport = ScriptedCloudV2Transport(remoteV2: .init(
            payload: payload,
            changeTag: "tag-c3"
        ))
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )
        let evidence = activationEvidence(
            payload: payload,
            cloudChangeTag: "tag-c3"
        )

        let receipt = try await coordinator.validateAuthorityRoundTrip(
            envelope,
            evidence: evidence
        )
        let metrics = await transport.metrics()

        XCTAssertEqual(receipt.evidenceChangeTag, "tag-c3")
        XCTAssertEqual(receipt.committedChangeTag, "tag-1")
        XCTAssertEqual(receipt.payloadHash, HostV6.CanonicalJSON.sha256(payload))
        XCTAssertEqual(metrics.saveAttempts, 1)
        XCTAssertGreaterThanOrEqual(metrics.v2Fetches, 2)
    }

    func testAuthorityRoundTripRejectsConcurrentReadBackChange() async throws {
        let envelope = makeEnvelope()
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        let transport = ScriptedCloudV2Transport(
            remoteV2: .init(payload: payload, changeTag: "tag-c3"),
            readBackMismatchOnce: true
        )
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        do {
            _ = try await coordinator.validateAuthorityRoundTrip(
                envelope,
                evidence: activationEvidence(payload: payload, cloudChangeTag: "tag-c3")
            )
            XCTFail("Expected concurrent read-back change to fail closed")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.concurrentConflict))
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.saveAttempts, 1)
    }

    func testCoordinatorDoesNotLeakTransportErrorWrapper() async throws {
        let coordinator = HostV6CloudSyncCoordinator(
            transport: ScriptedCloudV2Transport(fetchV2Error: .cloud(.permissionDenied)),
            currentDeviceID: "device-a"
        )

        do {
            _ = try await coordinator.synchronize(makeEnvelope())
            XCTFail("Expected mapped Cloud error")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, .permissionDenied)
        }
    }

    func testCoordinatorImportsLegacyV1BySourceBeforeWritingV2() async throws {
        var legacy = AppSnapshot()
        let identityID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        legacy.servers = [ServerConnection(
            id: identityID,
            name: "Imported",
            host: "imported.example.com",
            username: "deploy",
            alias: "imported",
            createdAt: now,
            updatedAt: now,
            version: 7
        )]
        let transport = ScriptedCloudV2Transport(
            legacyV1: try HostV6.CanonicalJSON.encode(legacy)
        )
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        let result = try await coordinator.synchronize(
            HostV6.MetadataEnvelope(synced: .init(), local: .init(), migrationProvenance: .empty)
        )

        XCTAssertEqual(result.envelope.synced.identities.map(\.id), [identityID])
        XCTAssertEqual(
            result.envelope.migrationProvenance.legacySources.first { $0.legacyKind == "server" }?.revision,
            7
        )
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.legacySaveAttempts, 0)
    }

    func testCoordinatorRejectsUnexpectedV2FieldsWithoutSaving() async throws {
        let envelope = makeEnvelope()
        let data = try HostV6.CloudPayloadCodec.encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["privateKeyPath"] = "/forbidden/key"
        let transport = ScriptedCloudV2Transport(remoteV2: .init(
            payload: try JSONSerialization.data(withJSONObject: object),
            changeTag: "tag-remote"
        ))
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        do {
            _ = try await coordinator.synchronize(envelope)
            XCTFail("Expected strict allow-list rejection")
        } catch {
            XCTAssertEqual(
                error as? HostV6.CloudV2Error,
                .unexpectedFields(["privateKeyPath"])
            )
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.saveAttempts, 0)
    }

    func testCompatibilityRollbackDoesNotReadOrWriteEitherCloudGeneration() async throws {
        var envelope = makeEnvelope()
        envelope.migrationProvenance.authorityManifest = HostV6.AuthorityManifest(
            mode: .compatibilityRollback,
            v1Hash: "v1",
            v6Hash: "v6",
            compatibilityHash: "compat",
            checkpointHash: "checkpoint",
            acknowledgedDeviceIDs: ["device-a"],
            cloudChangeTag: "tag",
            firstV6MutationID: UUID(),
            codeVersion: "6",
            notRepresentable: []
        )
        let transport = ScriptedCloudV2Transport()
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )

        do {
            _ = try await coordinator.synchronize(envelope)
            XCTFail("Expected read-only compatibility mode")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.v2Fetches, 0)
        XCTAssertEqual(metrics.legacyFetches, 0)
        XCTAssertEqual(metrics.saveAttempts, 0)
    }

    func testCoordinatorRebindsAuthorityManifestAfterConcurrentMergeCreatesReview() async throws {
        let activated = try authoritativeEnvelope()
        var local = activated
        let localMutation = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
        local.synced.hosts[0].name = "Local database"
        local.synced.hosts[0].stamp = try local.synced.hosts[0].stamp.incrementing(
            deviceID: "device-a",
            mutationID: localMutation,
            at: now.addingTimeInterval(1)
        )
        local = try HostV6.AuthorityController.recordMutation(localMutation, in: local).envelope

        var remote = activated
        let remoteMutation = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        remote.synced.hosts[0].name = "Remote database"
        remote.synced.hosts[0].stamp = try remote.synced.hosts[0].stamp.incrementing(
            deviceID: "device-b",
            mutationID: remoteMutation,
            at: now.addingTimeInterval(2)
        )
        remote = try HostV6.AuthorityController.recordMutation(remoteMutation, in: remote).envelope

        let transport = ScriptedCloudV2Transport(remoteV2: .init(
            payload: try HostV6.CloudPayloadCodec.encode(remote),
            changeTag: "tag-remote"
        ))
        let result = try await HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        ).synchronize(local)

        XCTAssertEqual(result.envelope.synced.mergeReviews.filter { !$0.isResolved }.count, 1)
        XCTAssertNoThrow(try HostV6.AuthorityController.verifyCheckpoint(
            HostV6.CanonicalJSON.encode(result.envelope)
        ))
    }

    private func makeEnvelope() -> HostV6.MetadataEnvelope {
        let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let addressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let identityID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let stamp = HostV6.SyncStamp(
            vector: ["device/device-a": 1],
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            updatedAt: now
        )
        return HostV6.MetadataEnvelope(
            synced: .init(
                hosts: [.init(
                    id: hostID,
                    name: "Database",
                    group: "",
                    machineConfiguration: nil,
                    fixedAddressID: nil,
                    createdAt: now,
                    stamp: stamp
                )],
                addresses: [.init(
                    id: addressID,
                    hostID: hostID,
                    normalizedHost: "db.example.com",
                    sshPort: 22,
                    originalLabel: "db.example.com",
                    source: .manual,
                    sortOrder: 0,
                    stamp: stamp
                )],
                identities: [.init(
                    id: identityID,
                    hostID: hostID,
                    username: "deploy",
                    alias: "database",
                    preferredAddressID: nil,
                    createdAt: now,
                    stamp: stamp
                )]
            ),
            local: .init(auditEvents: [.init(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000900")!,
                timestamp: now,
                category: "fixture",
                action: "sync",
                targetID: nil,
                result: "success",
                level: .info
            )]),
            migrationProvenance: .empty
        )
    }

    private func activationEvidence(
        payload: Data,
        cloudChangeTag: String
    ) -> HostV6.AuthorityActivationEvidence {
        HostV6.AuthorityActivationEvidence(
            completedRequirements: Set(HostV6.AuthorityRequirement.allCases),
            signedDevices: signedDeviceEvidence(),
            acknowledgedDeviceIDs: ["device-a", "device-b"],
            verifiedCloudPayloadHash: HostV6.CanonicalJSON.sha256(payload),
            cloudChangeTag: cloudChangeTag,
            codeVersion: "build-current",
            signerTeamIdentifier: "TEAMID1234"
        )
    }

    private func signedDeviceEvidence() -> [HostV6.AuthoritySignedDeviceEvidence] {
        [
            .init(
                deviceID: "device-a",
                signerCertificateSHA256: "certificate-a",
                artifactDigest: "artifact-a"
            ),
            .init(
                deviceID: "device-b",
                signerCertificateSHA256: "certificate-b",
                artifactDigest: "artifact-b"
            ),
        ]
    }

    private func authoritativeEnvelope() throws -> HostV6.MetadataEnvelope {
        var envelope = makeEnvelope()
        let stamp = envelope.synced.hosts[0].stamp
        envelope.synced.devices = [
            .init(
                id: "device-a",
                name: "Mac A",
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: stamp
            ),
            .init(
                id: "device-b",
                name: "Mac B",
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: stamp
            ),
        ]
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        let legacyData = try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: true
        ).data
        let evidence = activationEvidence(payload: payload, cloudChangeTag: "tag-activation")
        return try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: legacyData,
            evidence: evidence,
            cloudRoundTrip: .init(
                evidenceChangeTag: evidence.cloudChangeTag,
                committedChangeTag: "tag-activation-committed",
                payloadHash: evidence.verifiedCloudPayloadHash
            )
        ).envelope
    }
}

private actor ScriptedCloudV2Transport: HostV6CloudV2Transport {
    struct Metrics: Sendable {
        var v2Fetches: Int
        var legacyFetches: Int
        var saveAttempts: Int
        var legacySaveAttempts: Int
    }

    private var remoteV2: HostV6CloudRecord?
    private let legacyV1: Data?
    private var conflictsRemaining: Int
    private var v2Fetches = 0
    private var legacyFetches = 0
    private var saveAttempts = 0
    private var successfulSaves = 0
    private var readBackMismatchOnce: Bool
    private var shouldReturnReadBackMismatch = false
    private var fetchV2Error: HostV6CloudTransportError?

    init(
        remoteV2: HostV6CloudRecord? = nil,
        legacyV1: Data? = nil,
        conflictsRemaining: Int = 0,
        readBackMismatchOnce: Bool = false,
        fetchV2Error: HostV6CloudTransportError? = nil
    ) {
        self.remoteV2 = remoteV2
        self.legacyV1 = legacyV1
        self.conflictsRemaining = conflictsRemaining
        self.readBackMismatchOnce = readBackMismatchOnce
        self.fetchV2Error = fetchV2Error
    }

    func fetchV2() async throws -> HostV6CloudRecord? {
        v2Fetches += 1
        if let fetchV2Error {
            self.fetchV2Error = nil
            throw fetchV2Error
        }
        if shouldReturnReadBackMismatch {
            shouldReturnReadBackMismatch = false
            readBackMismatchOnce = false
            return remoteV2.map { HostV6CloudRecord(payload: $0.payload, changeTag: "mismatched-tag") }
        }
        return remoteV2
    }

    func fetchLegacyV1() async throws -> Data? {
        legacyFetches += 1
        return legacyV1
    }

    func saveV2(_ payload: Data, replacing changeTag: String?) async throws -> HostV6CloudRecord {
        saveAttempts += 1
        if conflictsRemaining > 0 {
            conflictsRemaining -= 1
            throw HostV6CloudTransportError.conflict
        }
        guard remoteV2?.changeTag == changeTag else {
            throw HostV6CloudTransportError.conflict
        }
        successfulSaves += 1
        let saved = HostV6CloudRecord(payload: payload, changeTag: "tag-\(successfulSaves)")
        remoteV2 = saved
        shouldReturnReadBackMismatch = readBackMismatchOnce
        return saved
    }

    func metrics() -> Metrics {
        Metrics(
            v2Fetches: v2Fetches,
            legacyFetches: legacyFetches,
            saveAttempts: saveAttempts,
            legacySaveAttempts: 0
        )
    }
}
