import Foundation
import XCTest
@testable import KeyPortCore

final class HostV6ShadowMigrationTests: XCTestCase {
    private let serverAID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let serverBID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let fixtureDate = Date(timeIntervalSince1970: 1_787_616_000)

    func testM1BuildsExpectedHostGraphAndLegacyLedger() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let result = try HostV6.ShadowMigrationEngine(
            currentDeviceID: "device_review_fixture"
        ).prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )

        XCTAssertEqual(result.envelope.schemaVersion, 6)
        XCTAssertNil(result.envelope.migrationProvenance.authorityManifest)
        XCTAssertEqual(result.envelope.synced.hosts.count, 1)
        XCTAssertEqual(result.envelope.synced.addresses.count, 1)
        XCTAssertEqual(result.envelope.synced.identities.map(\.id), [serverAID, serverBID])
        XCTAssertEqual(result.envelope.synced.devices.map(\.id), ["device_review_fixture"])
        XCTAssertEqual(result.envelope.synced.sshKeys.map(\.id), ["key_review_fixture"])
        XCTAssertEqual(result.envelope.synced.authorizations.count, 1)
        XCTAssertEqual(result.envelope.synced.nodeAssociations.count, 1)
        XCTAssertEqual(result.envelope.local.auditEvents.count, 1_000)
        XCTAssertEqual(result.envelope.synced.hostKeyPins.count, 2)
        XCTAssertEqual(result.envelope.synced.knownHostsLines.count, 4)
        XCTAssertEqual(
            HostV6.KnownHostsLine.derivedFileLines(from: result.envelope.synced.knownHostsLines).count,
            3
        )

        let host = try XCTUnwrap(result.envelope.synced.hosts.first)
        XCTAssertEqual(host.stamp.vector, [
            "legacy-v1/server/11111111-1111-4111-8111-111111111111": 10,
            "legacy-v1/server/22222222-2222-4222-8222-222222222222": 1,
        ])
        XCTAssertEqual(
            Set(result.envelope.migrationProvenance.legacySources.map(\.id)),
            [
                "authorization/22222222-2222-4222-8222-222222222222:SHA256:device-key",
                "device/device_review_fixture",
                "key/key_review_fixture",
                "node/database-b.review.example",
                "server/11111111-1111-4111-8111-111111111111",
                "server/22222222-2222-4222-8222-222222222222",
            ]
        )
        XCTAssertEqual(result.report.result, .lossless)
        let node = try XCTUnwrap(result.envelope.synced.nodeAssociations.first)
        XCTAssertEqual(node.id, "database-b.review.example")
        XCTAssertEqual(node.sshIdentityID, serverBID)
        XCTAssertEqual(node.target, ActualNodeReference(
            tailnetKey: "review.example",
            nodeID: "node-review-database-b"
        ))
        XCTAssertEqual(node.state, .linked)
        XCTAssertEqual(node.method, .manual)
        XCTAssertEqual(node.autoLinkEnabled, true)
        XCTAssertEqual(node.stamp.vector["legacy-v1/node/database-b.review.example"], 1)
    }

    func testM1ThreeReplaysAreByteStableAndPreserveEveryLocalField() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let input = encodeLegacy(legacy)
        let first = try engine.prepare(
            legacyData: input,
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let second = try engine.prepare(
            legacyData: input,
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let third = try engine.prepare(
            legacyData: input,
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )

        XCTAssertEqual(first.stateData, second.stateData)
        XCTAssertEqual(second.stateData, third.stateData)
        XCTAssertEqual(first.reportData, second.reportData)
        XCTAssertEqual(second.reportData, third.reportData)
        XCTAssertEqual(
            first.envelope.synced.mergeReviews.map(\.id),
            second.envelope.synced.mergeReviews.map(\.id)
        )

        let states = Dictionary(uniqueKeysWithValues: first.envelope.local.identityStates.map {
            ($0.id, $0)
        })
        XCTAssertEqual(states[serverAID]?.status, .authorized)
        XCTAssertEqual(states[serverAID]?.statusDetail, "legacy-a-authorized")
        XCTAssertEqual(states[serverAID]?.passwordCheck?.detail, "legacy-a-password-ok")
        XCTAssertEqual(states[serverAID]?.keyCheck?.detail, "legacy-a-key-ok")
        XCTAssertEqual(states[serverBID]?.status, .keyAuthenticationFailed)
        XCTAssertEqual(states[serverBID]?.keyCheck?.detail, "legacy-b-key-failed")
        XCTAssertEqual(
            Set(first.envelope.local.hostAnnotations.map(\.notes)),
            ["owner-a-note", "owner-b-note-v1"]
        )
        XCTAssertEqual(first.envelope.local.keyStates.first?.privateKeyPath, fixturePrivateKeyPath)
        XCTAssertEqual(first.envelope.local.keyStates.first?.isInAgent, true)
        XCTAssertEqual(first.envelope.local.keyStates.first?.isLocallyAvailable, true)
        XCTAssertEqual(first.report.proofs.auditEventsUnchanged, true)
        XCTAssertEqual(first.report.proofs.knownHostsProvenancePreserved, true)
        XCTAssertEqual(first.report.proofs.renderedKnownHostsUnchanged, true)
        XCTAssertEqual(first.report.proofs.keychainAccountsUnchanged, true)
        XCTAssertEqual(first.report.proofs.protectedArtifactsUnchanged, true)
    }

    func testM2AdvancesOnlyChangedLegacySourceAndRejectsVersionReuse() throws {
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let b1 = fixtureSnapshot(serverBVersion: 1)
        let first = try engine.prepare(
            legacyData: encodeLegacy(b1),
            previousStateData: nil,
            inspection: inspection(for: b1)
        )
        let b2 = fixtureSnapshot(serverBVersion: 2)
        let second = try engine.prepare(
            legacyData: encodeLegacy(b2),
            previousStateData: first.stateData,
            inspection: inspection(for: b2)
        )

        XCTAssertEqual(second.envelope.synced.hosts.first?.stamp.vector, [
            "legacy-v1/server/11111111-1111-4111-8111-111111111111": 10,
            "legacy-v1/server/22222222-2222-4222-8222-222222222222": 2,
        ])
        XCTAssertEqual(
            second.envelope.synced.identities.first { $0.id == serverBID }?.stamp.vector,
            ["legacy-v1/server/22222222-2222-4222-8222-222222222222": 2]
        )
        XCTAssertEqual(second.envelope.synced.identities.first { $0.id == serverBID }?.alias, "db-bob-v2")
        XCTAssertEqual(second.envelope.synced.hostKeyPins.count, 3)

        let replay = try engine.prepare(
            legacyData: encodeLegacy(b2),
            previousStateData: second.stateData,
            inspection: inspection(for: b2)
        )
        XCTAssertEqual(replay.stateData, second.stateData)
        XCTAssertEqual(replay.report.mergeReviewIDs, second.report.mergeReviewIDs)

        var reusedVersion = b2
        reusedVersion.servers[1].alias = "same-version-different-digest"
        XCTAssertThrowsError(try engine.prepare(
            legacyData: encodeLegacy(reusedVersion),
            previousStateData: second.stateData,
            inspection: inspection(for: reusedVersion)
        )) { error in
            XCTAssertEqual(
                (error as? HostV6.ShadowMigrationError)?.failure.code,
                .legacyVersionReuse
            )
        }
    }

    func testM2ConcurrentV6MutationCreatesDeterministicBlockingReview() throws {
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let b1 = fixtureSnapshot(serverBVersion: 1)
        let first = try engine.prepare(
            legacyData: encodeLegacy(b1),
            previousStateData: nil,
            inspection: inspection(for: b1)
        )
        var locallyMutated = first.envelope
        locallyMutated.synced.hosts[0].name = "V6 local name"
        locallyMutated.synced.hosts[0].stamp = try locallyMutated.synced.hosts[0].stamp.incrementing(
            deviceID: "X",
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            at: fixtureDate.addingTimeInterval(30)
        )
        let b2 = fixtureSnapshot(serverBVersion: 2)
        let result = try engine.prepare(
            legacyData: encodeLegacy(b2),
            previousStateData: try HostV6.CanonicalJSON.encode(locallyMutated),
            inspection: inspection(for: b2)
        )

        let concurrentReview = try XCTUnwrap(result.envelope.synced.mergeReviews.first { review in
            review.entityType == .host
                && review.candidates.contains { $0.vector["device/X"] == 1 }
                && review.candidates.contains {
                    $0.vector["legacy-v1/server/22222222-2222-4222-8222-222222222222"] == 2
                }
        })
        XCTAssertFalse(concurrentReview.isBlocking)
        XCTAssertEqual(
            concurrentReview.id,
            HostV6.StableID.mergeReview(
                entityType: .host,
                entityID: result.envelope.synced.hosts[0].id.uuidString.lowercased(),
                conflictingMutationIDs: concurrentReview.candidates.map(\.mutationID)
            )
        )
        XCTAssertEqual(
            Set(concurrentReview.candidates.compactMap { $0.summaryFields["name"] }),
            ["V6 local name", "Database A"]
        )
    }

    func testM3SourceDeletionTombstonesOnlyBContributionAndStaleB2CannotReviveIt() throws {
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let b1 = fixtureSnapshot(serverBVersion: 1)
        let first = try engine.prepare(
            legacyData: encodeLegacy(b1),
            previousStateData: nil,
            inspection: inspection(for: b1)
        )
        let b2 = fixtureSnapshot(serverBVersion: 2)
        let second = try engine.prepare(
            legacyData: encodeLegacy(b2),
            previousStateData: first.stateData,
            inspection: inspection(for: b2)
        )
        let b3 = fixtureSnapshot(serverBVersion: 3, serverBDeleted: true)
        let deleted = try engine.prepare(
            legacyData: encodeLegacy(b3),
            previousStateData: second.stateData,
            inspection: inspection(for: b3)
        )

        XCTAssertNil(deleted.envelope.synced.hosts.first?.deletedAt)
        XCTAssertNil(deleted.envelope.synced.addresses.first?.deletedAt)
        XCTAssertNil(deleted.envelope.synced.identities.first { $0.id == serverAID }?.deletedAt)
        XCTAssertNotNil(deleted.envelope.synced.identities.first { $0.id == serverBID }?.deletedAt)
        XCTAssertEqual(deleted.envelope.synced.authorizations.first?.relationState, .detached)
        XCTAssertEqual(deleted.envelope.synced.authorizations.first?.remoteState, .authorized)
        XCTAssertNotNil(deleted.envelope.synced.authorizations.first?.deletedAt)
        XCTAssertNotNil(deleted.envelope.synced.nodeAssociations.first?.deletedAt)
        XCTAssertEqual(
            deleted.envelope.synced.knownHostsLines.filter { $0.source.id == serverAID && $0.deletedAt == nil }.count,
            2
        )
        XCTAssertEqual(
            deleted.envelope.synced.knownHostsLines.filter { $0.source.id == serverBID && $0.deletedAt != nil }.count,
            3
        )
        XCTAssertEqual(deleted.envelope.synced.hostKeyPins.filter { $0.deletedAt == nil }.count, 2)
        XCTAssertEqual(deleted.envelope.synced.hostKeyPins.filter { $0.deletedAt != nil }.count, 1)
        XCTAssertEqual(deleted.envelope.local.auditEvents.count, 1_000)

        let staleReplay = try engine.prepare(
            legacyData: encodeLegacy(b2),
            previousStateData: deleted.stateData,
            inspection: inspection(for: b2)
        )
        XCTAssertEqual(staleReplay.stateData, deleted.stateData)
        XCTAssertNotNil(staleReplay.envelope.synced.identities.first { $0.id == serverBID }?.deletedAt)
        XCTAssertNotNil(staleReplay.envelope.synced.hostKeyPins.first {
            $0.fingerprint == "SHA256:b-version-2"
        }?.deletedAt)
    }

    func testM4ReportAndPayloadsProveExplicitAllowlistsAndLocalRestoration() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let result = try HostV6.ShadowMigrationEngine(
            currentDeviceID: "device_review_fixture"
        ).prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let cloud = HostV6.CloudPayload(envelope: result.envelope)
        let archive = HostV6.ArchivePayload(envelope: result.envelope)
        let cloudData = try HostV6.CanonicalJSON.encode(cloud)
        let archiveData = try HostV6.CanonicalJSON.encode(archive)
        let decodedState = try HostV6.CanonicalJSON.decode(
            HostV6.MetadataEnvelope.self,
            from: result.stateData
        )
        let decodedReport = try HostV6.CanonicalJSON.decode(
            HostV6.ShadowMigrationReport.self,
            from: result.reportData
        )

        for forbidden in [fixturePrivateKeyPath, "stable-code-1", "privateKeyPath", "isInAgent", "isCurrent"] {
            XCTAssertFalse(String(decoding: cloudData, as: UTF8.self).contains(forbidden))
            XCTAssertFalse(String(decoding: archiveData, as: UTF8.self).contains(forbidden))
        }
        let restored = cloud.restoringLocalState(from: result.envelope)
        XCTAssertEqual(restored.local.keyStates.first?.privateKeyPath, fixturePrivateKeyPath)
        XCTAssertEqual(restored.local.keyStates.first?.isInAgent, true)
        XCTAssertEqual(restored.local.deviceStates.first?.isCurrent, true)
        XCTAssertEqual(restored.local.auditEvents.count, 1_000)

        XCTAssertEqual(result.report.allowList.cloudSHA256, HostV6.CanonicalJSON.sha256(cloudData))
        XCTAssertEqual(result.report.allowList.archiveSHA256, HostV6.CanonicalJSON.sha256(archiveData))
        XCTAssertTrue(result.report.allowList.forbiddenMatchCounts.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.report.idContinuity.legacyIdentityIDs, result.report.idContinuity.v6IdentityIDs)
        XCTAssertEqual(result.report.references.violationCount, 0)
        XCTAssertEqual(result.report.keychain.writeCallCount, 0)
        XCTAssertEqual(result.report.ssh.aliasesBefore, result.report.ssh.aliasesAfter)
        XCTAssertEqual(result.report.ssh.renderedKnownHostsSHA256Before, result.report.ssh.renderedKnownHostsSHA256After)
        XCTAssertEqual(result.report.authorizations.legacyToV6.count, 1)
        XCTAssertEqual(result.report.causality.sourceVectors.count, 6)
        XCTAssertEqual(decodedState, result.envelope)
        XCTAssertEqual(decodedReport, result.report)
        XCTAssertEqual(decodedReport.stateSHA256, HostV6.CanonicalJSON.sha256(result.stateData))
    }

    func testCoordinatorQueriesSameKeychainAccountsAndPublishesOnlyShadow() async throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let legacyData = encodeLegacy(legacy)
        let credentialInspector = CredentialInspectorSpy(states: [
            serverAID.uuidString.lowercased(): .local,
            serverBID.uuidString.lowercased(): .synchronizable,
        ])
        let artifactInspector = ArtifactInspectorSpy(snapshots: [[
            "state-v1.json": HostV6.CanonicalJSON.sha256(legacyData),
            "ssh-config": "config-hash",
            "known-hosts": "known-hosts-hash",
            "cloud-v1": "cloud-hash",
        ]])
        let stagingStore = ShadowStagingStoreSpy()
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture"),
            credentialInspector: credentialInspector,
            artifactInspector: artifactInspector,
            stagingStore: stagingStore
        )

        let result = try await coordinator.stage(legacyData: legacyData, existingSSHHostAliases: [])

        let queries = await credentialInspector.queries()
        let writeCallCount = await credentialInspector.writeCallCount()
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(Set(queries.prefix(2)), Set(queries.suffix(2)))
        XCTAssertEqual(writeCallCount, 0)
        XCTAssertEqual(publishedState, result.stateData)
        XCTAssertEqual(publishedReport, result.reportData)
        XCTAssertEqual(legacyData, encodeLegacy(legacy))
        XCTAssertNil(result.envelope.migrationProvenance.authorityManifest)
    }

    func testCoordinatorFailureBeforeAtomicPublishKeepsPreviousStagingAndReportsStableCode() async throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let legacyData = encodeLegacy(legacy)
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let oldBundle = try engine.prepare(
            legacyData: legacyData,
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let oldState = oldBundle.stateData
        let oldReport = oldBundle.reportData
        let credentialInspector = CredentialInspectorSpy(states: [
            serverAID.uuidString.lowercased(): .local,
            serverBID.uuidString.lowercased(): .local,
        ])
        let artifactInspector = ArtifactInspectorSpy(snapshots: [[
            "state-v1.json": HostV6.CanonicalJSON.sha256(legacyData),
        ]])
        let stagingStore = ShadowStagingStoreSpy(
            publishedState: oldState,
            publishedReport: oldReport,
            failsBeforePublish: true
        )
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: engine,
            credentialInspector: credentialInspector,
            artifactInspector: artifactInspector,
            stagingStore: stagingStore
        )

        do {
            _ = try await coordinator.stage(legacyData: legacyData, existingSSHHostAliases: [])
            XCTFail("Expected atomic publish failure")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.code, .artifactMismatch)
            XCTAssertEqual(error.failure.objectID, "v6-shadow-staging")
        }
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        let writeCallCount = await credentialInspector.writeCallCount()
        XCTAssertEqual(publishedState, oldState)
        XCTAssertEqual(publishedReport, oldReport)
        XCTAssertEqual(legacyData, encodeLegacy(legacy))
        XCTAssertEqual(writeCallCount, 0)
    }

    func testCoordinatorMalformedLegacySnapshotReturnsStableDecodeFailureWithoutPublishing() async throws {
        let stagingStore = ShadowStagingStoreSpy()
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture"),
            credentialInspector: CredentialInspectorSpy(states: [:]),
            artifactInspector: ArtifactInspectorSpy(snapshots: [[:]]),
            stagingStore: stagingStore
        )

        do {
            _ = try await coordinator.stage(
                legacyData: Data("{not-json".utf8),
                existingSSHHostAliases: []
            )
            XCTFail("Expected malformed legacy snapshot to fail")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.stage, .migration)
            XCTAssertEqual(error.failure.objectID, "state-v1")
            XCTAssertEqual(error.failure.code, .decodeFailed)
            XCTAssertEqual(error.detailCode, "legacyAccountDecode")
        }
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        XCTAssertNil(publishedState)
        XCTAssertNil(publishedReport)
    }

    func testCoordinatorInvariantFailureReturnsStableCodeWithoutPublishing() async throws {
        var legacy = fixtureSnapshot(serverBVersion: 1)
        legacy.auditEvents.append(AuditEvent(
            id: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-000000000001")!,
            timestamp: fixtureDate,
            category: "overflow",
            action: "event-1001",
            result: "must-not-be-truncated"
        ))
        let legacyData = encodeLegacy(legacy)
        let stagingStore = ShadowStagingStoreSpy()
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture"),
            credentialInspector: CredentialInspectorSpy(states: [
                serverAID.uuidString.lowercased(): .local,
                serverBID.uuidString.lowercased(): .local,
            ]),
            artifactInspector: ArtifactInspectorSpy(snapshots: [[
                "state-v1.json": HostV6.CanonicalJSON.sha256(legacyData),
            ]]),
            stagingStore: stagingStore
        )

        do {
            _ = try await coordinator.stage(
                legacyData: legacyData,
                existingSSHHostAliases: []
            )
            XCTFail("Expected audit limit invariant to fail")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.stage, .migration)
            XCTAssertEqual(error.failure.objectID, "state-v6")
            XCTAssertEqual(error.failure.code, .invariantFailed)
            XCTAssertTrue(error.detailCode.contains("auditLimitExceeded"))
        }
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        XCTAssertNil(publishedState)
        XCTAssertNil(publishedReport)
    }

    func testCoordinatorArtifactMismatchReturnsStableCodeWithoutPublishing() async throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let legacyData = encodeLegacy(legacy)
        let stagingStore = ShadowStagingStoreSpy()
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture"),
            credentialInspector: CredentialInspectorSpy(states: [
                serverAID.uuidString.lowercased(): .local,
                serverBID.uuidString.lowercased(): .local,
            ]),
            artifactInspector: ArtifactInspectorSpy(snapshots: [
                ["state-v1.json": HostV6.CanonicalJSON.sha256(legacyData)],
                ["state-v1.json": "after"],
            ]),
            stagingStore: stagingStore
        )

        do {
            _ = try await coordinator.stage(
                legacyData: legacyData,
                existingSSHHostAliases: []
            )
            XCTFail("Expected protected artifact mismatch to fail")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.stage, .migration)
            XCTAssertEqual(error.failure.objectID, "protected-artifacts")
            XCTAssertEqual(error.failure.code, .artifactMismatch)
            XCTAssertEqual(error.detailCode, "hashSetChanged")
        }
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        XCTAssertNil(publishedState)
        XCTAssertNil(publishedReport)
    }

    func testCoordinatorRejectsLegacyBytesThatDoNotMatchProtectedSnapshotHash() async throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let stagingStore = ShadowStagingStoreSpy()
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture"),
            credentialInspector: CredentialInspectorSpy(states: [
                serverAID.uuidString.lowercased(): .local,
                serverBID.uuidString.lowercased(): .local,
            ]),
            artifactInspector: ArtifactInspectorSpy(snapshots: [[
                "state-v1.json": HostV6.CanonicalJSON.sha256(Data("newer-v5-bytes".utf8)),
            ]]),
            stagingStore: stagingStore
        )

        do {
            _ = try await coordinator.stage(
                legacyData: encodeLegacy(legacy),
                existingSSHHostAliases: []
            )
            XCTFail("Expected stale legacy bytes to fail the protected snapshot gate")
        } catch let error as HostV6.ShadowMigrationError {
            XCTAssertEqual(error.failure.stage, .migration)
            XCTAssertEqual(error.failure.objectID, "state-v1")
            XCTAssertEqual(error.failure.code, .artifactMismatch)
            XCTAssertEqual(error.detailCode, "legacyInputHashMismatch")
        }
        let publishedState = await stagingStore.publishedState()
        let publishedReport = await stagingStore.publishedReport()
        XCTAssertNil(publishedState)
        XCTAssertNil(publishedReport)
    }

    func testExistingAliasOwnedByLegacyIdentityIsNotTreatedAsAnExternalConflict() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        var migrationInspection = inspection(for: legacy)
        migrationInspection.existingSSHHostAliases = ["DB-ALICE", "db-bob"]

        let result = try HostV6.ShadowMigrationEngine(
            currentDeviceID: "device_review_fixture"
        ).prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: migrationInspection
        )

        XCTAssertEqual(Set(result.envelope.synced.identities.map(\.alias)), ["db-alice", "db-bob"])
        XCTAssertTrue(result.report.proofs.sshAliasesUnchanged)
    }

    func testImmutableLegacyKeyChangeReturnsStableConflictCode() throws {
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let first = try engine.prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        var changed = legacy
        changed.keys[0].publicKey = "ssh-ed25519 changed-material"

        XCTAssertThrowsError(try engine.prepare(
            legacyData: encodeLegacy(changed),
            previousStateData: first.stateData,
            inspection: inspection(for: changed)
        )) { error in
            let migrationError = error as? HostV6.ShadowMigrationError
            XCTAssertEqual(migrationError?.failure.stage, .migration)
            XCTAssertEqual(migrationError?.failure.objectID, "key/key_review_fixture")
            XCTAssertEqual(migrationError?.failure.code, .legacyImmutableKeyConflict)
            XCTAssertEqual(migrationError?.detailCode, "immutableDigestChanged")
        }
    }

    func testDuplicateLegacyServerIDReturnsStableInvariantFailure() throws {
        var legacy = fixtureSnapshot(serverBVersion: 1)
        legacy.servers[1].id = serverAID
        let migrationInspection = HostV6.ShadowMigrationInspection(
            keychainAccountsBefore: [serverAID.uuidString.lowercased(): .local],
            keychainAccountsAfter: [serverAID.uuidString.lowercased(): .local],
            artifactHashesBefore: ["state-v1.json": "unchanged"],
            artifactHashesAfter: ["state-v1.json": "unchanged"],
            existingSSHHostAliases: []
        )

        XCTAssertThrowsError(try HostV6.ShadowMigrationEngine(
            currentDeviceID: "device_review_fixture"
        ).prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: migrationInspection
        )) { error in
            let migrationError = error as? HostV6.ShadowMigrationError
            XCTAssertEqual(migrationError?.failure.stage, .migration)
            XCTAssertEqual(migrationError?.failure.objectID, "legacy-projection")
            XCTAssertEqual(migrationError?.failure.code, .invariantFailed)
            XCTAssertEqual(migrationError?.detailCode, "duplicateLegacyServerID")
        }
    }

    func testDuplicateLegacyKeyIDAgainstPreviousShadowReturnsStableInvariantFailure() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let first = try engine.prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        var duplicated = legacy
        duplicated.keys.append(legacy.keys[0])

        XCTAssertThrowsError(try engine.prepare(
            legacyData: encodeLegacy(duplicated),
            previousStateData: first.stateData,
            inspection: inspection(for: duplicated)
        )) { error in
            let migrationError = error as? HostV6.ShadowMigrationError
            XCTAssertEqual(migrationError?.failure.stage, .migration)
            XCTAssertEqual(migrationError?.failure.objectID, "state-v6")
            XCTAssertEqual(migrationError?.failure.code, .invariantFailed)
            XCTAssertTrue(migrationError?.detailCode.contains("duplicateEntityID:sshKeyRecord:key_review_fixture") == true)
        }
    }

    func testLegacySchemasOneThroughFiveDecodeThroughTheV5Projection() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")

        for schemaVersion in 1...5 {
            let result = try engine.prepare(
                legacyData: try encodeLegacy(legacy, asSchemaVersion: schemaVersion),
                previousStateData: nil,
                inspection: inspection(for: legacy)
            )

            XCTAssertEqual(result.report.legacySchemaVersion, schemaVersion)
            XCTAssertEqual(result.envelope.synced.identities.map(\.id), [serverAID, serverBID])
            XCTAssertEqual(result.envelope.synced.devices.map(\.id), ["device_review_fixture"])
            XCTAssertEqual(result.envelope.synced.sshKeys.map(\.id), ["key_review_fixture"])
            XCTAssertEqual(result.envelope.synced.authorizations.count, 1)
            XCTAssertEqual(result.envelope.synced.nodeAssociations.count, schemaVersion < 5 ? 0 : 1)
            let states = Dictionary(uniqueKeysWithValues: result.envelope.local.identityStates.map {
                ($0.id, $0)
            })
            XCTAssertEqual(states[serverAID]?.keyCheck?.state, .succeeded)
            XCTAssertEqual(states[serverBID]?.keyCheck?.state, .failed)
        }
    }

    func testFutureLegacySchemaFailsClosedWithStableDecodeCode() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)

        XCTAssertThrowsError(try HostV6.ShadowMigrationEngine(
            currentDeviceID: "device_review_fixture"
        ).prepare(
            legacyData: try encodeLegacy(legacy, asSchemaVersion: 6),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )) { error in
            let migrationError = error as? HostV6.ShadowMigrationError
            XCTAssertEqual(migrationError?.failure.stage, .migration)
            XCTAssertEqual(migrationError?.failure.objectID, "state-v1")
            XCTAssertEqual(migrationError?.failure.code, .decodeFailed)
            XCTAssertEqual(migrationError?.detailCode, "unsupportedLegacySchema")
        }
    }

    func testReorderingLegacyArraysKeepsStateAndStableIDsByteEquivalent() throws {
        var ordered = fixtureSnapshot(serverBVersion: 1)
        let duplicateRawLine = ordered.servers[0].confirmedHostKeys[1].knownHostsLine
        ordered.servers[0].confirmedHostKeys.append(HostKeyRecord(
            algorithm: "ssh-rsa",
            fingerprint: "SHA256:shared-rsa",
            knownHostsLine: duplicateRawLine,
            firstConfirmedAt: fixtureDate.addingTimeInterval(-10),
            lastSeenAt: fixtureDate
        ))
        var reordered = ordered
        reordered.servers.reverse()
        for index in reordered.servers.indices {
            reordered.servers[index].confirmedHostKeys.reverse()
        }
        reordered.devices.reverse()
        reordered.keys.reverse()
        reordered.authorizations.reverse()
        reordered.nodeAssociations.reverse()

        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let first = try engine.prepare(
            legacyData: encodeLegacy(ordered),
            previousStateData: nil,
            inspection: inspection(for: ordered)
        )
        let second = try engine.prepare(
            legacyData: encodeLegacy(reordered),
            previousStateData: nil,
            inspection: inspection(for: reordered)
        )

        XCTAssertNotEqual(first.report.inputSHA256, second.report.inputSHA256)
        XCTAssertEqual(first.stateData, second.stateData)
        XCTAssertEqual(first.report.stateSHA256, second.report.stateSHA256)
        XCTAssertEqual(
            first.envelope.synced.knownHostsLines.map(\.id),
            second.envelope.synced.knownHostsLines.map(\.id)
        )
        XCTAssertEqual(
            first.envelope.synced.mergeReviews.map(\.id),
            second.envelope.synced.mergeReviews.map(\.id)
        )
    }

    func testDeviceSameCounterDifferentDigestCreatesDeterministicBlockingReview() throws {
        let legacy = fixtureSnapshot(serverBVersion: 1)
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let first = try engine.prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        var renamed = legacy
        renamed.devices[0].name = "Review Mac renamed at same counter"

        let result = try engine.prepare(
            legacyData: encodeLegacy(renamed),
            previousStateData: first.stateData,
            inspection: inspection(for: renamed)
        )
        let replay = try engine.prepare(
            legacyData: encodeLegacy(renamed),
            previousStateData: first.stateData,
            inspection: inspection(for: renamed)
        )
        let review = try XCTUnwrap(result.envelope.synced.mergeReviews.first {
            $0.entityType == .device && $0.entityID == "device_review_fixture"
        })

        XCTAssertTrue(review.isBlocking)
        XCTAssertEqual(Set(review.candidates.compactMap { $0.summaryFields["name"] }), [
            "Review Mac",
            "Review Mac renamed at same counter",
        ])
        XCTAssertEqual(review.id, HostV6.StableID.mergeReview(
            entityType: .device,
            entityID: "device_review_fixture",
            conflictingMutationIDs: review.candidates.map(\.mutationID)
        ))
        XCTAssertEqual(result.stateData, replay.stateData)
    }

    func testConflictingLegacyFingerprintsCreateDeterministicBlockingPinReview() throws {
        var legacy = fixtureSnapshot(serverBVersion: 1)
        legacy.servers[1].confirmedHostKeys[1] = hostKey(
            algorithm: "ssh-rsa",
            fingerprint: "SHA256:conflicting-rsa",
            line: "db.example.com ssh-rsa conflicting-review-fixture"
        )
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")

        let result = try engine.prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let replay = try engine.prepare(
            legacyData: encodeLegacy(legacy),
            previousStateData: nil,
            inspection: inspection(for: legacy)
        )
        let rsaPins = result.envelope.synced.hostKeyPins.filter { $0.algorithm == "ssh-rsa" }
        let review = try XCTUnwrap(result.envelope.synced.mergeReviews.first { review in
            review.entityType == .hostKeyPin
                && Set(review.candidates.compactMap { $0.summaryFields["fingerprint"] })
                    == ["SHA256:shared-rsa", "SHA256:conflicting-rsa"]
        })

        XCTAssertEqual(rsaPins.count, 2)
        XCTAssertTrue(rsaPins.allSatisfy { $0.state == .pendingReview })
        XCTAssertTrue(review.isBlocking)
        XCTAssertEqual(review.id, HostV6.StableID.mergeReview(
            entityType: .hostKeyPin,
            entityID: review.entityID,
            conflictingMutationIDs: review.candidates.map(\.mutationID)
        ))
        XCTAssertEqual(result.stateData, replay.stateData)
        XCTAssertTrue(result.report.proofs.knownHostsProvenancePreserved)
    }

    func testRevokedDeviceCannotBeRevivedByLaterActiveLegacyObservation() throws {
        var revoked = fixtureSnapshot(serverBVersion: 1)
        revoked.devices[0].isRevoked = true
        let engine = HostV6.ShadowMigrationEngine(currentDeviceID: "device_review_fixture")
        let first = try engine.prepare(
            legacyData: encodeLegacy(revoked),
            previousStateData: nil,
            inspection: inspection(for: revoked)
        )
        XCTAssertNotNil(first.envelope.synced.devices[0].deletedAt)

        var laterActive = revoked
        laterActive.devices[0].isRevoked = false
        laterActive.devices[0].lastActiveAt = fixtureDate.addingTimeInterval(60)
        let result = try engine.prepare(
            legacyData: encodeLegacy(laterActive),
            previousStateData: first.stateData,
            inspection: inspection(for: laterActive)
        )

        XCTAssertNotNil(result.envelope.synced.devices[0].deletedAt)
        XCTAssertTrue(result.envelope.synced.mergeReviews.contains {
            $0.entityType == .device
                && $0.entityID == "device_review_fixture"
                && $0.isBlocking
                && $0.candidates.contains(where: \.isDeleted)
                && $0.candidates.contains { !$0.isDeleted }
        })
    }

    private func fixtureSnapshot(serverBVersion: Int, serverBDeleted: Bool = false) -> AppSnapshot {
        let sharedRSA = "db.example.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCreviewfixture"
        var snapshot = AppSnapshot()
        snapshot.servers = [
            ServerConnection(
                id: serverAID,
                name: "Database A",
                host: "DB.EXAMPLE.COM.",
                username: "alice",
                alias: "db-alice",
                group: "production",
                notes: "owner-a-note",
                confirmedHostKeys: [
                    hostKey(
                        algorithm: "ssh-ed25519",
                        fingerprint: "SHA256:shared-ed25519",
                        line: "DB.EXAMPLE.COM. ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEdldmlldy1maXh0dXJlLWVkMjU1MTk="
                    ),
                    hostKey(algorithm: "ssh-rsa", fingerprint: "SHA256:shared-rsa", line: sharedRSA),
                ],
                status: .authorized,
                statusDetail: "legacy-a-authorized",
                lastCheckedAt: fixtureDate,
                passwordCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "legacy-a-password-ok",
                    checkedAt: fixtureDate
                ),
                keyCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "legacy-a-key-ok",
                    checkedAt: fixtureDate
                ),
                createdAt: fixtureDate,
                updatedAt: fixtureDate,
                version: 10
            ),
            ServerConnection(
                id: serverBID,
                name: serverBVersion == 1 ? "Database B" : "Database B updated",
                host: "db.example.com",
                username: "bob",
                alias: serverBVersion == 1 ? "db-bob" : "db-bob-v2",
                group: "production",
                notes: "owner-b-note-v\(serverBVersion)",
                confirmedHostKeys: [
                    hostKey(
                        algorithm: "ssh-ed25519",
                        fingerprint: "SHA256:shared-ed25519",
                        line: "db.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEdldmlldy1maXh0dXJlLWVkMjU1MTk="
                    ),
                    hostKey(algorithm: "ssh-rsa", fingerprint: "SHA256:shared-rsa", line: sharedRSA),
                ] + (serverBVersion >= 2 ? [hostKey(
                    algorithm: "ecdsa-sha2-nistp256",
                    fingerprint: "SHA256:b-version-2",
                    line: "db.example.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXJldmlldy1maXh0dXJl"
                )] : []),
                status: serverBVersion == 1 ? .keyAuthenticationFailed : .authorized,
                statusDetail: serverBVersion == 1 ? "legacy-b-key-failed" : "legacy-b-authorized",
                lastCheckedAt: fixtureDate,
                passwordCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "legacy-b-password-ok",
                    checkedAt: fixtureDate
                ),
                keyCheck: AuthenticationCheck(
                    state: serverBVersion == 1 ? .failed : .succeeded,
                    detail: serverBVersion == 1 ? "legacy-b-key-failed" : "legacy-b-key-ok",
                    checkedAt: fixtureDate
                ),
                createdAt: fixtureDate,
                updatedAt: fixtureDate.addingTimeInterval(TimeInterval(serverBVersion)),
                isDeleted: serverBDeleted,
                version: serverBVersion
            ),
        ]
        snapshot.devices = [Device(
            id: "device_review_fixture",
            name: "Review Mac",
            isCurrent: true,
            registeredAt: fixtureDate,
            lastActiveAt: fixtureDate
        )]
        snapshot.keys = [SSHKeyRecord(
            id: "key_review_fixture",
            deviceID: "device_review_fixture",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEdldmlldy1maXh0dXJlLWVkMjU1MTk= keyport:v1:key_review_fixture:review-mac",
            fingerprint: "SHA256:device-key",
            privateKeyPath: fixturePrivateKeyPath,
            isInAgent: true,
            origin: .generated,
            isLocallyAvailable: true
        )]
        snapshot.authorizations = [Authorization(
            serverID: serverBID,
            keyID: "key_review_fixture",
            fingerprint: "SHA256:device-key",
            remoteComment: "keyport:v1:key_review_fixture:review-mac",
            status: .authorized,
            authorizedAt: fixtureDate,
            lastVerifiedAt: fixtureDate,
            updatedAt: fixtureDate,
            version: 1
        )]
        snapshot.nodeAssociations = [NodeAssociation(
            testCaseNodeID: "database-b.review.example",
            serverID: serverBID,
            target: ActualNodeReference(tailnetKey: "review.example", nodeID: "node-review-database-b"),
            state: .linked,
            method: .manual,
            evidenceKinds: [.exactMagicDNS],
            confirmedAt: fixtureDate,
            lastVerifiedAt: fixtureDate,
            updatedAt: fixtureDate,
            revision: 1
        )]
        snapshot.auditEvents = (1...1_000).map { index in
            AuditEvent(
                id: UUID(uuidString: String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index))!,
                timestamp: fixtureDate,
                category: "review-fixture",
                action: "event-\(index)",
                targetID: index.isMultiple(of: 2) ? serverAID.uuidString : serverBID.uuidString,
                result: "stable-code-\(index)",
                level: index.isMultiple(of: 10) ? .warning : .info
            )
        }
        return snapshot
    }

    private func hostKey(algorithm: String, fingerprint: String, line: String) -> HostKeyRecord {
        HostKeyRecord(
            algorithm: algorithm,
            fingerprint: fingerprint,
            knownHostsLine: line,
            firstConfirmedAt: fixtureDate,
            lastSeenAt: fixtureDate
        )
    }

    private func encodeLegacy(_ snapshot: AppSnapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(snapshot)
    }

    private func encodeLegacy(_ snapshot: AppSnapshot, asSchemaVersion schemaVersion: Int) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodeLegacy(snapshot)) as? [String: Any]
        )
        if schemaVersion == 1 {
            object.removeValue(forKey: "schemaVersion")
        } else {
            object["schemaVersion"] = schemaVersion
        }
        if schemaVersion < 5 {
            object.removeValue(forKey: "nodeAssociations")
        }
        if schemaVersion < 3,
           var servers = object["servers"] as? [[String: Any]] {
            for index in servers.indices {
                servers[index].removeValue(forKey: "passwordCheck")
                servers[index].removeValue(forKey: "keyCheck")
            }
            object["servers"] = servers
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func inspection(for snapshot: AppSnapshot) -> HostV6.ShadowMigrationInspection {
        let accounts = Dictionary(uniqueKeysWithValues: snapshot.servers.map {
            ($0.id.uuidString.lowercased(), HostV6.KeychainAccountState.local)
        })
        let artifacts = [
            "state-v1.json": "legacy-hash",
            "ssh-config": "config-hash",
            "known-hosts": "known-hosts-hash",
            "cloud-v1": "cloud-hash",
        ]
        return HostV6.ShadowMigrationInspection(
            keychainAccountsBefore: accounts,
            keychainAccountsAfter: accounts,
            artifactHashesBefore: artifacts,
            artifactHashesAfter: artifacts,
            existingSSHHostAliases: []
        )
    }

    private var fixturePrivateKeyPath: String {
        "/fixture-only/.ssh/keyport/identities/key_review_fixture"
    }
}

private actor CredentialInspectorSpy: HostV6ShadowCredentialInspecting {
    private let states: [String: HostV6.KeychainAccountState]
    private var queriedAccountIDs: [String] = []

    init(states: [String: HostV6.KeychainAccountState]) {
        self.states = states
    }

    func accountState(for accountID: String) async -> HostV6.KeychainAccountState {
        queriedAccountIDs.append(accountID)
        return states[accountID] ?? .missing
    }

    func queries() -> [String] { queriedAccountIDs }
    func writeCallCount() -> Int { 0 }
}

private actor ArtifactInspectorSpy: HostV6ShadowArtifactInspecting {
    private let snapshots: [[String: String]]
    private var index = 0

    init(snapshots: [[String: String]]) {
        self.snapshots = snapshots
    }

    func protectedArtifactHashes() async throws -> [String: String] {
        defer { index += 1 }
        return snapshots[min(index, snapshots.count - 1)]
    }
}

private actor ShadowStagingStoreSpy: HostV6ShadowStagingStoring {
    private var state: Data?
    private var report: Data?
    private let failsBeforePublish: Bool

    init(
        publishedState: Data? = nil,
        publishedReport: Data? = nil,
        failsBeforePublish: Bool = false
    ) {
        state = publishedState
        report = publishedReport
        self.failsBeforePublish = failsBeforePublish
    }

    func previousStateData() async throws -> Data? { state }

    func atomicPublish(stateData: Data, reportData: Data) async throws {
        if failsBeforePublish { throw StagingFixtureError.injectedBeforePublish }
        state = stateData
        report = reportData
    }

    func publishedState() -> Data? { state }
    func publishedReport() -> Data? { report }
}

private enum StagingFixtureError: Error {
    case injectedBeforePublish
}
