import Foundation
import XCTest
@testable import KeyPortCore

final class HostV6CloudSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let addressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let identityA = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let identityB = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    func testStrictCloudCodecRejectsUnknownFields() throws {
        let envelope = makeEnvelope()
        let encoded = try HostV6.CloudPayloadCodec.encode(envelope)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["privateKeyPath"] = "/forbidden/private-key"
        let injected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try HostV6.CloudPayloadCodec.decodeStrict(injected)) { error in
            XCTAssertEqual(
                error as? HostV6.CloudV2Error,
                .unexpectedFields(["privateKeyPath"])
            )
        }
    }

    func testCloudPayloadEncoderEnforcesStrictlyLessThanEightHundredKiB() throws {
        let envelope = makeEnvelope()
        let encoded = try HostV6.CloudPayloadCodec.encode(envelope)

        XCTAssertLessThan(encoded.count, HostV6.CloudPayloadCodec.maximumPayloadByteCount)
        XCTAssertThrowsError(
            try HostV6.CloudPayloadCodec.encode(envelope, maximumByteCount: encoded.count)
        ) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.payloadTooLarge))
        }
    }

    func testCapacityFixtureFitsFiftyHostsWithFourAddressesFourIdentitiesAndTwentyServicesEach() throws {
        var hosts: [HostV6.Host] = []
        var addresses: [HostV6.AccessAddress] = []
        var identities: [HostV6.SSHIdentity] = []
        var services: [HostV6.SavedService] = []
        let commonStamp = stamp(["device/capacity": 1], mutation: 999)

        for hostIndex in 0..<50 {
            let fixtureHostID = uuid(10_000 + hostIndex)
            hosts.append(.init(
                id: fixtureHostID,
                name: "Capacity host \(hostIndex)",
                group: "Fixture",
                machineConfiguration: nil,
                fixedAddressID: uuid(20_000 + hostIndex * 4),
                createdAt: now,
                stamp: commonStamp
            ))
            for itemIndex in 0..<4 {
                let address = uuid(20_000 + hostIndex * 4 + itemIndex)
                addresses.append(.init(
                    id: address,
                    hostID: fixtureHostID,
                    normalizedHost: "host-\(hostIndex)-\(itemIndex).example.com",
                    sshPort: UInt16(22 + itemIndex),
                    originalLabel: "host-\(hostIndex)-\(itemIndex).example.com",
                    source: .manual,
                    sortOrder: itemIndex,
                    stamp: commonStamp
                ))
                identities.append(.init(
                    id: uuid(30_000 + hostIndex * 4 + itemIndex),
                    hostID: fixtureHostID,
                    username: "deploy-\(itemIndex)",
                    alias: "capacity-\(hostIndex)-\(itemIndex)",
                    preferredAddressID: address,
                    createdAt: now,
                    stamp: commonStamp
                ))
            }
            for serviceIndex in 0..<20 {
                services.append(.init(
                    id: uuid(40_000 + hostIndex * 20 + serviceIndex),
                    hostID: fixtureHostID,
                    name: "Service \(serviceIndex)",
                    serviceProtocol: serviceIndex.isMultiple(of: 2) ? .https : .tcp,
                    endpoint: .init(
                        bind: .loopbackV4,
                        port: UInt16(8_000 + serviceIndex),
                        path: serviceIndex.isMultiple(of: 2) ? "/health" : nil
                    ),
                    isFavorite: serviceIndex < 2,
                    fixedAddressID: nil,
                    stamp: commonStamp
                ))
            }
        }

        let envelope = HostV6.MetadataEnvelope(
            synced: .init(hosts: hosts, addresses: addresses, identities: identities, services: services),
            local: .init(),
            migrationProvenance: .empty
        )
        let encoded = try HostV6.CloudPayloadCodec.encode(envelope)

        XCTAssertEqual(hosts.count, 50)
        XCTAssertEqual(addresses.count, 200)
        XCTAssertEqual(identities.count, 200)
        XCTAssertEqual(services.count, 1_000)
        XCTAssertLessThan(encoded.count, HostV6.CloudPayloadCodec.maximumPayloadByteCount)
    }

    func testConcurrentCloudMergeCreatesDeterministicReviewAndRestoresLocalOverlay() throws {
        var local = makeEnvelope(hostStamp: stamp(["device/A": 1], mutation: 10))
        local.local.keyStates = [HostV6.LocalSSHKeyState(
            keyID: "key-a",
            privateKeyPath: "/local/private-key",
            isInAgent: true,
            isLocallyAvailable: true
        )]
        local.local.auditEvents = [auditEvent(id: 900)]

        var remote = makeEnvelope(hostStamp: stamp(["device/B": 1], mutation: 11))
        remote.synced.hosts[0].name = "Remote database"
        remote.local = .init()

        let first = try HostV6.CloudGraphMergeEngine.merge(
            local: local,
            remote: HostV6.CloudPayload(envelope: remote)
        )
        let repeated = try HostV6.CloudGraphMergeEngine.merge(
            local: first,
            remote: HostV6.CloudPayload(envelope: remote)
        )

        XCTAssertEqual(first.local, local.local)
        XCTAssertEqual(first.synced.hosts[0].name, "Database")
        XCTAssertEqual(first.synced.mergeReviews.count, 1)
        XCTAssertEqual(first.synced.mergeReviews[0].id, HostV6.StableID.mergeReview(
            entityType: .host,
            entityID: hostID.uuidString.lowercased(),
            conflictingMutationIDs: [
                local.synced.hosts[0].stamp.mutationID,
                remote.synced.hosts[0].stamp.mutationID,
            ]
        ))
        XCTAssertEqual(repeated.synced.mergeReviews, first.synced.mergeReviews)
    }

    func testCloudMergeKeepsCausallyNewerTombstoneWithoutReview() throws {
        var local = makeEnvelope(hostStamp: stamp(["device/A": 2], mutation: 20))
        local.synced.identities[0].deletedAt = now
        local.synced.identities[0].stamp = stamp(["device/A": 2], mutation: 21)

        var remote = makeEnvelope(hostStamp: stamp(["device/A": 1], mutation: 19))
        remote.synced.identities[0].stamp = stamp(["device/A": 1], mutation: 18)

        let result = try HostV6.CloudGraphMergeEngine.merge(
            local: local,
            remote: HostV6.CloudPayload(envelope: remote)
        )

        XCTAssertEqual(result.synced.identities[0].deletedAt, now)
        XCTAssertFalse(result.synced.mergeReviews.contains {
            $0.entityType == .sshIdentity && $0.entityID == identityA.uuidString.lowercased()
        })
    }

    func testAuthorityManifestMergeIsDirectionIndependentAndRejectsModeMismatch() throws {
        var left = makeEnvelope()
        var right = makeEnvelope()
        left.migrationProvenance.authorityManifest = authorityManifest(
            mode: .v6Authoritative,
            suffix: "a",
            acknowledgedDeviceIDs: ["device-a"]
        )
        right.migrationProvenance.authorityManifest = authorityManifest(
            mode: .v6Authoritative,
            suffix: "b",
            acknowledgedDeviceIDs: ["device-b"]
        )

        let leftRight = try HostV6.CloudGraphMergeEngine.merge(
            local: left,
            remote: HostV6.CloudPayload(envelope: right)
        )
        let rightLeft = try HostV6.CloudGraphMergeEngine.merge(
            local: right,
            remote: HostV6.CloudPayload(envelope: left)
        )

        XCTAssertEqual(leftRight.migrationProvenance, rightLeft.migrationProvenance)
        XCTAssertEqual(
            leftRight.migrationProvenance.authorityManifest?.acknowledgedDeviceIDs,
            ["device-a", "device-b"]
        )

        right.migrationProvenance.authorityManifest?.mode = .v6Canary
        XCTAssertThrowsError(try HostV6.CloudGraphMergeEngine.merge(
            local: left,
            remote: HostV6.CloudPayload(envelope: right)
        )) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
    }

    func testLegacyCloudImporterAdvancesEachSourceAndReplayIsByteStable() throws {
        let importer = HostV6.ShadowMigrationEngine(currentDeviceID: "device-current")
        let base = HostV6.MetadataEnvelope(
            synced: .init(),
            local: .init(auditEvents: [auditEvent(id: 901)]),
            migrationProvenance: .empty
        )
        let a10b1 = legacySnapshot(bVersion: 1, bAlias: "database-b")
        let a10b2 = legacySnapshot(bVersion: 2, bAlias: "database-b-v2")

        let first = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(a10b1),
            into: base
        )
        let second = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(a10b2),
            into: first
        )
        let replayed = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(a10b2),
            into: second
        )

        let host = try XCTUnwrap(second.synced.hosts.first)
        XCTAssertEqual(host.stamp.vector["legacy-v1/server/\(identityA.uuidString.lowercased())"], 10)
        XCTAssertEqual(host.stamp.vector["legacy-v1/server/\(identityB.uuidString.lowercased())"], 2)
        XCTAssertEqual(
            second.synced.identities.first { $0.id == identityB }?.alias,
            "database-b-v2"
        )
        XCTAssertEqual(second.local, base.local)
        XCTAssertEqual(
            try HostV6.CanonicalJSON.encode(replayed),
            try HostV6.CanonicalJSON.encode(second)
        )
    }

    func testLegacyCloudImporterRejectsSameRevisionWithDifferentDigest() throws {
        let importer = HostV6.ShadowMigrationEngine(currentDeviceID: "device-current")
        let base = HostV6.MetadataEnvelope(synced: .init(), local: .init(), migrationProvenance: .empty)
        let first = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(legacySnapshot(bVersion: 1, bAlias: "database-b")),
            into: base
        )

        XCTAssertThrowsError(try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(legacySnapshot(bVersion: 1, bAlias: "reused-version")),
            into: first
        )) { error in
            XCTAssertEqual(
                (error as? HostV6.ShadowMigrationError)?.failure.code,
                .legacyVersionReuse
            )
        }
    }

    func testLegacyImportAfterV6MutationCreatesReviewAndResolvedVectorPreventsReopening() throws {
        let importer = HostV6.ShadowMigrationEngine(currentDeviceID: "device-current")
        let base = HostV6.MetadataEnvelope(synced: .init(), local: .init(), migrationProvenance: .empty)
        var current = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(legacySnapshot(bVersion: 1, bAlias: "database-b")),
            into: base
        )
        current.synced.hosts[0].name = "Locally edited"
        current.synced.hosts[0].stamp = try current.synced.hosts[0].stamp.incrementing(
            deviceID: "device-current",
            mutationID: uuid(70),
            at: now.addingTimeInterval(10)
        )
        let importedHostID = current.synced.hosts[0].id

        let imported = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(legacySnapshot(bVersion: 2, bAlias: "database-b-v2")),
            into: current
        )
        let review = try XCTUnwrap(imported.synced.mergeReviews.first {
            $0.entityType == .host && $0.entityID == importedHostID.uuidString.lowercased()
        })
        var resolved = imported
        let joined = review.candidates.reduce(into: [String: UInt64]()) {
            $0 = HostV6.SyncStamp.join($0, $1.vector)
        }
        resolved.synced.hosts[0].stamp = try HostV6.SyncStamp(
            vector: joined,
            mutationID: review.candidates[0].mutationID,
            updatedAt: now
        ).incrementing(deviceID: "device-current", mutationID: uuid(71), at: now.addingTimeInterval(11))
        resolved.synced.mergeReviews[0].resolvedAt = now.addingTimeInterval(11)
        resolved.synced.mergeReviews[0].resolutionMutationID = uuid(71)
        resolved.synced.mergeReviews[0].resolutionReason = .userSelected
        resolved.synced.mergeReviews[0].isBlocking = false
        resolved.synced.mergeReviews[0].stamp = resolved.synced.hosts[0].stamp

        let replayed = try importer.importCloudV1(
            HostV6.CanonicalJSON.encode(legacySnapshot(bVersion: 2, bAlias: "database-b-v2")),
            into: resolved
        )

        XCTAssertEqual(replayed.synced.hosts[0].name, "Locally edited")
        XCTAssertEqual(replayed.synced.mergeReviews.filter { !$0.isResolved }.count, 0)
        XCTAssertEqual(replayed.synced.mergeReviews.count, 1)
    }

    private func makeEnvelope(hostStamp: HostV6.SyncStamp? = nil) -> HostV6.MetadataEnvelope {
        let commonStamp = stamp(["legacy/fixture": 1], mutation: 1)
        let host = HostV6.Host(
            id: hostID,
            name: "Database",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: nil,
            createdAt: now,
            stamp: hostStamp ?? commonStamp
        )
        let address = HostV6.AccessAddress(
            id: addressID,
            hostID: hostID,
            normalizedHost: "db.example.com",
            sshPort: 22,
            originalLabel: "db.example.com",
            source: .legacy,
            sortOrder: 0,
            stamp: commonStamp
        )
        let identity = HostV6.SSHIdentity(
            id: identityA,
            hostID: hostID,
            username: "deploy",
            alias: "database",
            preferredAddressID: nil,
            createdAt: now,
            stamp: commonStamp
        )
        let device = HostV6.Device(
            id: "device-a",
            name: "Mac A",
            registeredAt: now,
            lastActiveAt: now,
            tailscaleIdentity: nil,
            stamp: commonStamp
        )
        let key = HostV6.SSHKeyRecord(
            id: "key-a",
            deviceID: device.id,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA fixture",
            fingerprint: "SHA256:key-a",
            origin: .generated,
            stamp: commonStamp
        )
        return HostV6.MetadataEnvelope(
            synced: HostV6.SyncedGraph(
                hosts: [host],
                addresses: [address],
                identities: [identity],
                devices: [device],
                sshKeys: [key]
            ),
            local: .init(),
            migrationProvenance: .empty
        )
    }

    private func legacySnapshot(bVersion: Int, bAlias: String) -> AppSnapshot {
        var snapshot = AppSnapshot()
        snapshot.servers = [
            ServerConnection(
                id: identityA,
                name: "Database",
                host: "db.example.com",
                username: "deploy-a",
                alias: "database-a",
                createdAt: now,
                updatedAt: now,
                version: 10
            ),
            ServerConnection(
                id: identityB,
                name: "Database",
                host: "db.example.com",
                username: "deploy-b",
                alias: bAlias,
                createdAt: now,
                updatedAt: now.addingTimeInterval(TimeInterval(bVersion)),
                version: bVersion
            ),
        ]
        return snapshot
    }

    private func auditEvent(id: Int) -> HostV6.AuditEvent {
        HostV6.AuditEvent(
            id: uuid(id),
            timestamp: now,
            category: "fixture",
            action: "sync",
            targetID: nil,
            result: "success",
            level: .info
        )
    }

    private func authorityManifest(
        mode: HostV6.AuthorityMode,
        suffix: String,
        acknowledgedDeviceIDs: [String]
    ) -> HostV6.AuthorityManifest {
        HostV6.AuthorityManifest(
            mode: mode,
            v1Hash: "v1-common",
            v6Hash: "v6-\(suffix)",
            compatibilityHash: "compat-\(suffix)",
            checkpointHash: "checkpoint-\(suffix)",
            acknowledgedDeviceIDs: acknowledgedDeviceIDs,
            cloudChangeTag: "tag-\(suffix)",
            firstV6MutationID: uuid(suffix == "a" ? 801 : 802),
            codeVersion: "6-\(suffix)",
            notRepresentable: []
        )
    }

    private func stamp(_ vector: [String: UInt64], mutation: Int) -> HostV6.SyncStamp {
        HostV6.SyncStamp(vector: vector, mutationID: uuid(mutation), updatedAt: now)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
