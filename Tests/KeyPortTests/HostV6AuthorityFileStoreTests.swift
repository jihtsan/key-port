import Foundation
import XCTest
@testable import KeyPort
@testable import KeyPortCore

final class HostV6AuthorityFileStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)

    func testInterruptedCommitRecoversStateCheckpointCompatAndManifest() async throws {
        for failurePoint in HostV6AuthorityFileStore.FailurePoint.allCases {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let paths = KeyPortPaths(home: home)
            let plan = try authorityPlan()
            let interrupted = HostV6AuthorityFileStore(
                paths: paths,
                failureInjector: { point in
                    if point == failurePoint { throw InjectedFailure() }
                }
            )

            do {
                try await interrupted.commit(plan)
                XCTFail("Expected injected interruption at \(failurePoint)")
            } catch is InjectedFailure {
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.v6CommitJournal.path))

            let recovered = try await HostV6AuthorityFileStore(paths: paths).recover()
            XCTAssertEqual(
                try HostV6.CanonicalJSON.encode(recovered),
                try HostV6.CanonicalJSON.encode(plan.envelope),
                "Recovery mismatch at \(failurePoint)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.v6CommitJournal.path))
            XCTAssertEqual(try permissions(paths.stateV6), 0o600)
            XCTAssertEqual(try permissions(paths.stateV1Compatibility), 0o600)
            XCTAssertEqual(try permissions(paths.authorityManifest), 0o600)
            XCTAssertEqual(try permissions(paths.checkpoint(for: plan.manifest.checkpointHash)), 0o600)
        }
    }

    func testPreparedActivationSurvivesRestartBeforeCloudCAS() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let fixture = try authorityFixture()
        let transport = RecoverableAuthorityCloudTransport(remote: .init(
            payload: fixture.preAuthorityPayload,
            changeTag: fixture.evidence.cloudChangeTag
        ))
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )
        try await coordinator.validateAuthorityPrecondition(
            fixture.preAuthorityEnvelope,
            evidence: fixture.evidence
        )
        try await HostV6AuthorityFileStore(paths: paths).prepareActivation(
            fixture.plan,
            evidence: fixture.evidence
        )

        let restartedStore = HostV6AuthorityFileStore(paths: paths)
        let pendingResult = try await restartedStore.pendingActivation()
        let pending = try XCTUnwrap(pendingResult)
        let publishedResult = try await coordinator.publishPreparedAuthority(
            pending,
            currentBuildIdentifier: fixture.evidence.codeVersion
        )
        let published = try XCTUnwrap(publishedResult)
        try await restartedStore.completePreparedActivation(using: published)

        let recovered = try await restartedStore.recover()
        let remoteRecord = await transport.remoteRecord()
        let remote = try XCTUnwrap(remoteRecord)
        let remotePayload = try HostV6.CloudPayloadCodec.decodeStrict(remote.payload)
        XCTAssertEqual(recovered.migrationProvenance.authorityManifest, fixture.plan.manifest)
        XCTAssertEqual(remotePayload.migrationProvenance.authorityManifest, fixture.plan.manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.authorityActivationJournal.path))
    }

    func testPreparedActivationRejectsDifferentBuildBeforeCloudCAS() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let fixture = try authorityFixture()
        let originalRecord = HostV6CloudRecord(
            payload: fixture.preAuthorityPayload,
            changeTag: fixture.evidence.cloudChangeTag
        )
        let transport = RecoverableAuthorityCloudTransport(remote: originalRecord)
        let coordinator = HostV6CloudSyncCoordinator(
            transport: transport,
            currentDeviceID: "device-a"
        )
        try await coordinator.validateAuthorityPrecondition(
            fixture.preAuthorityEnvelope,
            evidence: fixture.evidence
        )
        try await HostV6AuthorityFileStore(paths: paths).prepareActivation(
            fixture.plan,
            evidence: fixture.evidence
        )
        let suiteName = "HostV6AuthorityFileStoreTests.runtime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let upgradedRuntime = try XCTUnwrap(HostV6RuntimeAssembly.makeIfEnabled(
            currentDeviceID: "device-a",
            defaults: defaults,
            paths: paths,
            evidenceVerifier: HostV6C3EvidenceVerifier(
                currentTeamIdentifier: { "TEAMID1234" },
                currentBuildIdentifier: { "6-next-build" }
            ),
            cloudTransport: transport
        ))

        do {
            _ = try await upgradedRuntime.loadPresentationSnapshot(
                from: SnapshotStore(paths: paths)
            )
            XCTFail("Expected a build A activation intent to be rejected by build B")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }

        let remoteRecord = await transport.remoteRecord()
        XCTAssertEqual(remoteRecord, originalRecord)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.authorityActivationJournal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.authorityManifest.path))
    }

    func testPublishedActivationRecoversEveryInterruptedLocalCommitPhase() async throws {
        for failurePoint in HostV6AuthorityFileStore.FailurePoint.allCases {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let paths = KeyPortPaths(home: home)
            let fixture = try authorityFixture()
            let transport = RecoverableAuthorityCloudTransport(remote: .init(
                payload: fixture.preAuthorityPayload,
                changeTag: fixture.evidence.cloudChangeTag
            ))
            let coordinator = HostV6CloudSyncCoordinator(
                transport: transport,
                currentDeviceID: "device-a"
            )
            let interruptedStore = HostV6AuthorityFileStore(
                paths: paths,
                failureInjector: { point in
                    if point == failurePoint { throw InjectedFailure() }
                }
            )
            try await coordinator.validateAuthorityPrecondition(
                fixture.preAuthorityEnvelope,
                evidence: fixture.evidence
            )
            try await interruptedStore.prepareActivation(fixture.plan, evidence: fixture.evidence)
            let pendingResult = try await interruptedStore.pendingActivation()
            let pending = try XCTUnwrap(pendingResult)
            let publishedResult = try await coordinator.publishPreparedAuthority(
                pending,
                currentBuildIdentifier: fixture.evidence.codeVersion
            )
            let published = try XCTUnwrap(publishedResult)

            do {
                try await interruptedStore.completePreparedActivation(using: published)
                XCTFail("Expected injected interruption at \(failurePoint)")
            } catch is InjectedFailure {
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: paths.authorityActivationJournal.path),
                "Activation intent missing at \(failurePoint)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: paths.v6CommitJournal.path),
                "Local commit journal missing at \(failurePoint)"
            )

            let restartedStore = HostV6AuthorityFileStore(paths: paths)
            let restartedPendingResult = try await restartedStore.pendingActivation()
            let restartedPending = try XCTUnwrap(restartedPendingResult)
            let confirmedResult = try await coordinator.publishPreparedAuthority(
                restartedPending,
                currentBuildIdentifier: fixture.evidence.codeVersion
            )
            let confirmed = try XCTUnwrap(confirmedResult)
            try await restartedStore.completePreparedActivation(using: confirmed)
            let recovered = try await restartedStore.recover()

            XCTAssertEqual(
                recovered.migrationProvenance.authorityManifest,
                fixture.plan.manifest,
                "Recovery mismatch at \(failurePoint)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.authorityActivationJournal.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.v6CommitJournal.path))
        }
    }

    func testCorruptCurrentStateRecoversFromCommittedCheckpoint() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let plan = try authorityPlan()
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(plan)
        try Data("corrupt-current".utf8).write(to: paths.stateV6)

        let recovered = try await store.recover()

        XCTAssertEqual(recovered.migrationProvenance.authorityManifest, plan.manifest)
        XCTAssertEqual(
            try HostV6.CanonicalJSON.encode(recovered),
            try Data(contentsOf: paths.stateV6)
        )
    }

    func testValidCurrentStateRepairsCorruptCompatibilityProjection() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let plan = try authorityPlan()
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(plan)
        try Data("corrupt-compatibility".utf8).write(to: paths.stateV1Compatibility)

        _ = try await store.recover()

        XCTAssertEqual(try Data(contentsOf: paths.stateV1Compatibility), plan.compatibilityData)
    }

    func testCommitRejectsCompatibilityBytesThatDoNotEncodePlanSnapshot() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        var plan = try authorityPlan()
        plan.compatibilityData = Data("not-a-compatibility-snapshot".utf8)

        do {
            try await HostV6AuthorityFileStore(paths: paths).commit(plan)
            XCTFail("Expected compatibility bytes to be bound to the validated snapshot")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.rollbackProjectionInvalid))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateV1Compatibility.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.v6CommitJournal.path))
    }

    func testCorruptCurrentStateAndCheckpointFailClosed() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let plan = try authorityPlan()
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(plan)
        try Data("corrupt-current".utf8).write(to: paths.stateV6)
        try Data("corrupt-checkpoint".utf8).write(
            to: paths.checkpoint(for: plan.manifest.checkpointHash)
        )

        do {
            _ = try await store.recover()
            XCTFail("Expected rollbackProjectionInvalid")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.rollbackProjectionInvalid))
        }
    }

    func testRecoveryWithoutManifestUsesNewestValidCheckpointAndRejectsMismatchedFilename() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let first = try authorityPlan()
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(first)

        var nextEnvelope = first.envelope
        nextEnvelope.synced.hosts[0].name = "Database updated"
        let mutationID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        nextEnvelope.synced.hosts[0].stamp = try nextEnvelope.synced.hosts[0].stamp.incrementing(
            deviceID: "device-a",
            mutationID: mutationID,
            at: now.addingTimeInterval(1)
        )
        let second = try HostV6.AuthorityController.recordMutation(mutationID, in: nextEnvelope)
        try await store.commit(second)

        let firstURL = paths.checkpoint(for: first.manifest.checkpointHash)
        let secondURL = paths.checkpoint(for: second.manifest.checkpointHash)
        let mismatchedURL = paths.v6CheckpointsDirectory.appendingPathComponent("zzzz-mismatched.json")
        try FileManager.default.copyItem(at: firstURL, to: mismatchedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100)],
            ofItemAtPath: firstURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-50)],
            ofItemAtPath: mismatchedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: secondURL.path
        )
        try Data("corrupt-current".utf8).write(to: paths.stateV6)
        try FileManager.default.removeItem(at: paths.authorityManifest)

        let recovered = try await store.recover()

        XCTAssertEqual(recovered.synced.hosts[0].name, "Database updated")
        XCTAssertEqual(
            recovered.migrationProvenance.authorityManifest?.checkpointHash,
            second.manifest.checkpointHash
        )
    }

    func testValidCurrentStateDoesNotTrustExternalManifestWithOnlyMatchingCheckpointHash() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let plan = try authorityPlan()
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(plan)

        var tampered = plan.manifest
        tampered.mode = .v6Canary
        tampered.v1Hash = "tampered-v1-hash"
        try HostV6.CanonicalJSON.encode(tampered).write(to: paths.authorityManifest)

        let recovered = try await store.recover()
        let repairedManifest = try HostV6.CanonicalJSON.decode(
            HostV6.AuthorityManifest.self,
            from: Data(contentsOf: paths.authorityManifest)
        )

        XCTAssertEqual(recovered.migrationProvenance.authorityManifest, plan.manifest)
        XCTAssertEqual(repairedManifest, plan.manifest)
    }

    func testCheckpointFallbackRejectsExternalManifestThatClearsFirstMutationBoundary() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let activation = try authorityPlan()
        let mutationID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let mutation = try HostV6.AuthorityController.recordMutation(mutationID, in: activation.envelope)
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(mutation)
        try Data("corrupt-current".utf8).write(to: paths.stateV6)

        var tampered = mutation.manifest
        tampered.firstV6MutationID = nil
        try HostV6.CanonicalJSON.encode(tampered).write(to: paths.authorityManifest)

        do {
            _ = try await store.recover()
            XCTFail("Expected altered first mutation boundary to fail closed")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.rollbackProjectionInvalid))
        }
    }

    func testCheckpointFallbackAllowsOnlyCompatibilityModeTransitionFromMatchingManifest() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let activation = try authorityPlan()
        let mutationID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        let mutation = try HostV6.AuthorityController.recordMutation(mutationID, in: activation.envelope)
        let rollback = try HostV6.AuthorityController.enterCompatibilityRollback(
            envelope: mutation.envelope,
            checkpointData: mutation.checkpointData
        )
        let store = HostV6AuthorityFileStore(paths: paths)
        try await store.commit(rollback)
        try Data("corrupt-current".utf8).write(to: paths.stateV6)

        let recovered = try await store.recover()

        XCTAssertEqual(
            recovered.migrationProvenance.authorityManifest?.mode,
            .compatibilityRollback
        )
        XCTAssertEqual(
            recovered.migrationProvenance.authorityManifest?.firstV6MutationID,
            mutationID
        )
    }

    private func authorityPlan() throws -> HostV6.AuthorityCommitPlan {
        try authorityFixture().plan
    }

    private func authorityFixture() throws -> (
        plan: HostV6.AuthorityCommitPlan,
        evidence: HostV6.AuthorityActivationEvidence,
        preAuthorityEnvelope: HostV6.MetadataEnvelope,
        preAuthorityPayload: Data
    ) {
        let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let addressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let identityID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let stamp = HostV6.SyncStamp(
            vector: ["legacy/fixture": 1],
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            updatedAt: now
        )
        let envelope = HostV6.MetadataEnvelope(
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
                    source: .legacy,
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
                )],
                devices: [
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
            ),
            local: .init(),
            migrationProvenance: .empty
        )
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        let legacyData = try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: true
        ).data
        let evidence = HostV6.AuthorityActivationEvidence(
            completedRequirements: Set(HostV6.AuthorityRequirement.allCases),
            signedDevices: [
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
            ],
            acknowledgedDeviceIDs: ["device-a", "device-b"],
            verifiedCloudPayloadHash: HostV6.CanonicalJSON.sha256(payload),
            cloudChangeTag: "tag-1",
            codeVersion: "6-test",
            signerTeamIdentifier: "TEAMID1234"
        )
        let plan = try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: legacyData,
            evidence: evidence,
            cloudRoundTrip: .init(
                evidenceChangeTag: evidence.cloudChangeTag,
                committedChangeTag: "tag-committed",
                payloadHash: evidence.verifiedCloudPayloadHash
            )
        )
        return (plan, evidence, envelope, payload)
    }

    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private struct InjectedFailure: Error {}

private actor RecoverableAuthorityCloudTransport: HostV6CloudV2Transport {
    private var remote: HostV6CloudRecord?
    private var saveCount = 0

    init(remote: HostV6CloudRecord?) {
        self.remote = remote
    }

    func fetchV2() async throws -> HostV6CloudRecord? { remote }
    func fetchLegacyV1() async throws -> Data? { nil }

    func saveV2(_ payload: Data, replacing changeTag: String?) async throws -> HostV6CloudRecord {
        guard remote?.changeTag == changeTag else {
            throw HostV6CloudTransportError.conflict
        }
        saveCount += 1
        let saved = HostV6CloudRecord(payload: payload, changeTag: "tag-published-\(saveCount)")
        remote = saved
        return saved
    }

    func remoteRecord() -> HostV6CloudRecord? { remote }
}
