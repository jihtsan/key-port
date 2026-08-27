import Foundation
import XCTest
@testable import KeyPortCore

final class HostV6AuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let addressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let identityID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let serviceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    func testAuthorityManifestCannotBeSignedWhenOneC3RequirementIsMissing() throws {
        let envelope = makeEnvelope()
        let legacyData = try legacyData()
        var requirements = Set(HostV6.AuthorityRequirement.allCases)
        requirements.remove(.mixedV5V6)
        let evidence = try makeEvidence(envelope: envelope, completed: requirements)

        XCTAssertThrowsError(try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: legacyData,
            evidence: evidence
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
        XCTAssertNil(envelope.migrationProvenance.authorityManifest)
    }

    func testAuthorityManifestRequiresAcknowledgementFromEveryActiveDevice() throws {
        let envelope = makeEnvelope()
        let evidence = try makeEvidence(envelope: envelope, acknowledged: ["device-a"])

        XCTAssertThrowsError(try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: try legacyData(),
            evidence: evidence
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.mixedVersionPending))
        }
    }

    func testAuthorityActivationBuildsCheckpointAndLosslessReadOnlyCompatibilityView() throws {
        let envelope = makeEnvelope()
        let legacy = try legacyData()
        let plan = try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: legacy,
            evidence: try makeEvidence(envelope: envelope)
        )

        XCTAssertEqual(plan.manifest.mode, .v6Authoritative)
        XCTAssertNil(plan.manifest.firstV6MutationID)
        XCTAssertEqual(plan.manifest.v1Hash, HostV6.CanonicalJSON.sha256(legacy))
        XCTAssertEqual(plan.manifest.acknowledgedDeviceIDs, ["device-a", "device-b"])
        XCTAssertTrue(plan.manifest.notRepresentable.contains(.service(serviceID)))
        XCTAssertEqual(plan.compatibilitySnapshot.servers.map(\.id), [identityID])
        XCTAssertEqual(plan.compatibilitySnapshot.devices.map(\.id), ["device-a", "device-b"])
        XCTAssertEqual(plan.compatibilitySnapshot.keys.first?.privateKeyPath, "/local/private-key")
        XCTAssertEqual(plan.compatibilitySnapshot.keys.first?.isInAgent, true)
        XCTAssertEqual(plan.compatibilitySnapshot.authorizations.first?.keyID, "key-a")
        XCTAssertEqual(plan.compatibilitySnapshot.auditEvents.map(\.id), [uuid(900)])
        XCTAssertEqual(
            plan.manifest.compatibilityHash,
            try HostV6.AuthorityController.compatibilitySemanticHash(plan.compatibilitySnapshot)
        )
        XCTAssertNoThrow(try HostV6.AuthorityController.verifyCheckpoint(plan.checkpointData))
    }

    func testBlockingReviewPreventsAuthorityActivation() throws {
        var envelope = makeEnvelope()
        envelope.synced.mergeReviews = [HostV6.MergeReview(
            id: uuid(80),
            entityType: .host,
            entityID: hostID.uuidString.lowercased(),
            candidates: [
                .init(mutationID: uuid(81), vector: ["device/A": 1], isDeleted: false),
                .init(mutationID: uuid(82), vector: ["device/B": 1], isDeleted: false),
            ],
            isBlocking: true,
            stamp: stamp(["device/A": 1, "device/B": 1], mutation: 80)
        )]

        XCTAssertThrowsError(try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: try legacyData(),
            evidence: try makeEvidence(envelope: envelope)
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
    }

    func testAuthorityActivationRejectsCompatibilitySemanticMismatch() throws {
        let envelope = makeEnvelope()
        var legacy = try HostV6.CanonicalJSON.decode(AppSnapshot.self, from: legacyData())
        legacy.servers[0].alias = "manually-diverged-alias"

        XCTAssertThrowsError(try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: HostV6.CanonicalJSON.encode(legacy),
            evidence: makeEvidence(envelope: envelope)
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
    }

    func testLocalOverlayDoesNotChangeCrossDeviceAuthorityManifestOrCloudPayload() throws {
        let activation = try activate()
        var secondMac = activation.envelope
        secondMac.local.keyStates[0].privateKeyPath = "/another-mac/private-key"
        secondMac.local.keyStates[0].isInAgent = false
        secondMac.local.deviceStates = [
            .init(deviceID: "device-a", isCurrent: false),
            .init(deviceID: "device-b", isCurrent: true),
        ]
        secondMac.local.auditEvents = []

        let rebound = try HostV6.AuthorityController.rebindManifest(in: secondMac)

        XCTAssertEqual(rebound.manifest, activation.manifest)
        XCTAssertEqual(
            try HostV6.CloudPayloadCodec.encode(rebound.envelope),
            try HostV6.CloudPayloadCodec.encode(activation.envelope)
        )
        XCTAssertNotEqual(rebound.compatibilityData, activation.compatibilityData)
    }

    func testRetiredSSHKeyIsNotProjectedAsLocallyUsable() throws {
        var envelope = makeEnvelope()
        envelope.synced.sshKeys[0].deletedAt = now

        let projection = try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: false
        )

        XCTAssertTrue(projection.snapshot.keys.isEmpty)
    }

    func testPostAuthorityBlockingReviewCreatesSafeCheckpointWithoutCompatRoute() throws {
        let activated = try activate()
        var conflicted = activated.envelope
        let identity = try XCTUnwrap(conflicted.synced.identities.first)
        conflicted.synced.mergeReviews = [HostV6.MergeReview(
            id: uuid(90),
            entityType: .sshIdentity,
            entityID: identity.id.uuidString.lowercased(),
            candidates: [
                .init(mutationID: uuid(91), vector: ["device/A": 1], isDeleted: false),
                .init(mutationID: uuid(92), vector: ["device/B": 1], isDeleted: false),
            ],
            isBlocking: true,
            stamp: stamp(["device/A": 1, "device/B": 1], mutation: 90)
        )]

        let plan = try HostV6.AuthorityController.recordMutation(uuid(93), in: conflicted)

        XCTAssertTrue(plan.compatibilitySnapshot.servers.isEmpty)
        XCTAssertTrue(plan.manifest.notRepresentable.contains(.sshIdentity(identity.id)))
        XCTAssertTrue(plan.manifest.notRepresentable.contains(.mergeReview(uuid(90))))
        XCTAssertNoThrow(try HostV6.AuthorityController.verifyCheckpoint(plan.checkpointData))
    }

    func testFirstV6MutationPermanentlyRejectsWritableLegacyRollback() throws {
        let activation = try activate()
        let mutationID = uuid(100)
        let mutation = try HostV6.AuthorityController.recordMutation(
            mutationID,
            in: activation.envelope
        )

        XCTAssertEqual(mutation.manifest.firstV6MutationID, mutationID)
        XCTAssertThrowsError(try HostV6.AuthorityController.requestWritableLegacyRollback(
            envelope: mutation.envelope,
            currentLegacyData: try legacyData()
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.binaryDowngradeUnsafe))
        }
    }

    func testCompatibilityRollbackIsReadOnlyPreservesV6OnlyObjectsAndCanRecoverForward() throws {
        let activation = try activate()
        let mutation = try HostV6.AuthorityController.recordMutation(
            uuid(101),
            in: activation.envelope
        )
        let rollback = try HostV6.AuthorityController.enterCompatibilityRollback(
            envelope: mutation.envelope,
            checkpointData: mutation.checkpointData
        )

        XCTAssertEqual(rollback.manifest.mode, .compatibilityRollback)
        XCTAssertEqual(rollback.compatibilitySnapshot.servers.count, 1)
        XCTAssertTrue(rollback.envelope.synced.services.contains { $0.id == serviceID })
        XCTAssertThrowsError(try HostV6.AuthorityController.authorizeMetadataMutation(in: rollback.envelope)) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }

        let recovered = try HostV6.AuthorityController.forwardRecover(
            envelope: rollback.envelope,
            checkpointData: mutation.checkpointData
        )
        XCTAssertEqual(recovered.migrationProvenance.authorityManifest?.mode, .v6Authoritative)
        XCTAssertEqual(recovered.synced.services.map(\.id), [serviceID])
        XCTAssertEqual(recovered.local.keyStates.first?.privateKeyPath, "/local/private-key")
    }

    func testCorruptCheckpointFailsClosed() throws {
        let activation = try activate()
        let corrupt = Data(activation.checkpointData.dropLast())

        XCTAssertThrowsError(try HostV6.AuthorityController.verifyCheckpoint(corrupt)) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.rollbackProjectionInvalid))
        }
    }

    private func activate() throws -> HostV6.AuthorityCommitPlan {
        let envelope = makeEnvelope()
        return try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: legacyData(),
            evidence: makeEvidence(envelope: envelope)
        )
    }

    private func makeEvidence(
        envelope: HostV6.MetadataEnvelope,
        completed: Set<HostV6.AuthorityRequirement> = Set(HostV6.AuthorityRequirement.allCases),
        acknowledged: [String] = ["device-a", "device-b"]
    ) throws -> HostV6.AuthorityActivationEvidence {
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        return HostV6.AuthorityActivationEvidence(
            completedRequirements: completed,
            signedMacDeviceIDs: ["device-a", "device-b"],
            acknowledgedDeviceIDs: acknowledged,
            verifiedCloudPayloadHash: HostV6.CanonicalJSON.sha256(payload),
            cloudChangeTag: "change-tag-1",
            codeVersion: "6.0-test",
            signerTeamIdentifier: "TEAMID1234",
            signedArtifactDigests: ["artifact-a", "artifact-b"]
        )
    }

    private func makeEnvelope() -> HostV6.MetadataEnvelope {
        let baseStamp = stamp(["legacy/fixture": 1], mutation: 1)
        let host = HostV6.Host(
            id: hostID,
            name: "Database",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: nil,
            createdAt: now,
            stamp: baseStamp
        )
        let address = HostV6.AccessAddress(
            id: addressID,
            hostID: hostID,
            normalizedHost: "db.example.com",
            sshPort: 22,
            originalLabel: "db.example.com",
            source: .legacy,
            sortOrder: 0,
            stamp: baseStamp
        )
        let identity = HostV6.SSHIdentity(
            id: identityID,
            hostID: hostID,
            username: "deploy",
            alias: "database",
            preferredAddressID: addressID,
            createdAt: now,
            stamp: baseStamp
        )
        let devices = ["device-a", "device-b"].map {
            HostV6.Device(
                id: $0,
                name: $0,
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: baseStamp
            )
        }
        let key = HostV6.SSHKeyRecord(
            id: "key-a",
            deviceID: "device-a",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA fixture",
            fingerprint: "SHA256:key-a",
            origin: .generated,
            stamp: baseStamp
        )
        let authorization = HostV6.Authorization(
            sshIdentityID: identityID,
            keyID: key.id,
            fingerprint: key.fingerprint,
            remoteComment: "keyport",
            remoteState: .authorized,
            relationState: .active,
            authorizedAt: now,
            lastVerifiedAt: now,
            stamp: baseStamp
        )
        let node = HostV6.NodeAssociation(
            id: "database.review.example",
            sshIdentityID: identityID,
            target: ActualNodeReference(tailnetKey: "tailnet.example", nodeID: "node-a"),
            state: .linked,
            method: .manual,
            autoLinkEnabled: false,
            stamp: baseStamp
        )
        let service = HostV6.SavedService(
            id: serviceID,
            hostID: hostID,
            name: "Admin",
            serviceProtocol: .https,
            endpoint: .init(bind: .loopbackV4, port: 8443, path: "/admin"),
            isFavorite: true,
            fixedAddressID: nil,
            stamp: baseStamp
        )
        let local = HostV6.LocalState(
            hostAnnotations: [.init(hostID: hostID, legacyIdentityID: identityID, notes: "local note")],
            identityStates: [.init(
                sshIdentityID: identityID,
                status: .authorized,
                statusDetail: "verified",
                lastCheckedAt: now,
                passwordCheck: nil,
                keyCheck: AuthenticationCheck(state: .succeeded, detail: "ok", checkedAt: now),
                machineConfigurationRefreshAttemptedAt: now
            )],
            deviceStates: [
                .init(deviceID: "device-a", isCurrent: true),
                .init(deviceID: "device-b", isCurrent: false),
            ],
            keyStates: [.init(
                keyID: key.id,
                privateKeyPath: "/local/private-key",
                isInAgent: true,
                isLocallyAvailable: true
            )],
            auditEvents: [HostV6.AuditEvent(
                id: uuid(900),
                timestamp: now,
                category: "fixture",
                action: "migrated",
                targetID: identityID.uuidString,
                result: "success",
                level: .info
            )]
        )
        return HostV6.MetadataEnvelope(
            synced: .init(
                hosts: [host],
                addresses: [address],
                identities: [identity],
                devices: devices,
                sshKeys: [key],
                services: [service],
                authorizations: [authorization],
                nodeAssociations: [node]
            ),
            local: local,
            migrationProvenance: .empty
        )
    }

    private func legacyData() throws -> Data {
        try HostV6.AuthorityController.compatibilityProjection(
            from: makeEnvelope(),
            requiresCompleteRoutes: true
        ).data
    }

    private func stamp(_ vector: [String: UInt64], mutation: Int) -> HostV6.SyncStamp {
        HostV6.SyncStamp(vector: vector, mutationID: uuid(mutation), updatedAt: now)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
