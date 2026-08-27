import Foundation
import XCTest
@testable import KeyPortCore

final class HostV6ContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let addressID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let identityID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    func testUUIDV5MatchesRFCAndStableEntityIDsAreDeterministic() {
        let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(
            HostV6.StableID.uuidV5(namespace: dnsNamespace, name: "www.widgets.com"),
            UUID(uuidString: "21f7f8de-8051-5b89-8680-0195ef798b6a")
        )

        let firstHost = HostV6.StableID.host(legacyEndpointKey: "db.example.com:22")
        let repeatedHost = HostV6.StableID.host(legacyEndpointKey: "db.example.com:22")
        let otherHost = HostV6.StableID.host(legacyEndpointKey: "db.example.com:2222")
        XCTAssertEqual(firstHost, repeatedHost)
        XCTAssertNotEqual(firstHost, otherHost)
        XCTAssertEqual(
            HostV6.StableID.address(hostID: firstHost, endpointKey: "db.example.com:22"),
            HostV6.StableID.address(hostID: firstHost, endpointKey: "db.example.com:22")
        )
        XCTAssertEqual(
            HostV6.StableID.legacyEndpointKey(host: " DB.EXAMPLE.COM. ", port: 22),
            "endpoint:db.example.com:22"
        )
        XCTAssertEqual(
            HostV6.StableID.host(legacyHost: " DB.EXAMPLE.COM. ", port: 22),
            HostV6.StableID.host(legacyHost: "db.example.com", port: 22)
        )
    }

    func testKnownHostsLineIDsPreserveRawLineMultiplicity() {
        let pinID = HostV6.StableID.hostKeyPin(
            addressID: addressID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:shared"
        )
        let rawLine = "db.example.com ssh-ed25519 AAAA-shared"
        let first = HostV6.StableID.knownHostsLine(
            pinID: pinID,
            sourceID: identityID,
            rawLine: rawLine,
            duplicateOrdinal: 0
        )
        let duplicate = HostV6.StableID.knownHostsLine(
            pinID: pinID,
            sourceID: identityID,
            rawLine: rawLine,
            duplicateOrdinal: 1
        )
        XCTAssertNotEqual(first, duplicate)

        let lines = [
            HostV6.KnownHostsLine(
                id: first,
                pinID: pinID,
                rawLine: rawLine,
                source: .legacyIdentity(identityID),
                duplicateOrdinal: 0,
                stamp: stamp(1)
            ),
            HostV6.KnownHostsLine(
                id: duplicate,
                pinID: pinID,
                rawLine: rawLine,
                source: .legacyIdentity(identityID),
                duplicateOrdinal: 1,
                stamp: stamp(1, mutation: "00000000-0000-4000-8000-000000000002")
            ),
        ]
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(HostV6.KnownHostsLine.derivedFileLines(from: lines), [rawLine])
    }

    func testRemoteServiceEndpointNormalizesPathToLeadingSlash() {
        let normalized = HostV6.RemoteServiceEndpoint(bind: .loopbackV4, port: 8080, path: "admin")
        let alreadyNormalized = HostV6.RemoteServiceEndpoint(bind: .loopbackV4, port: 8080, path: "/admin")

        XCTAssertEqual(normalized.path, "/admin")
        XCTAssertEqual(alreadyNormalized.path, "/admin")
    }

    func testRemoteServiceEndpointNormalizesDecodedPath() throws {
        let endpoint = HostV6.RemoteServiceEndpoint(bind: .loopbackV4, port: 8080, path: "/admin")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(endpoint)) as? [String: Any]
        )
        json["path"] = "admin"

        let decoded = try JSONDecoder().decode(
            HostV6.RemoteServiceEndpoint.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(decoded.path, "/admin")
    }

    func testVersionVectorCompareJoinAndIncrement() throws {
        let base = HostV6.SyncStamp(
            vector: ["legacy-v1/server/A": 10, "legacy-v1/server/B": 1],
            mutationID: uuid("00000000-0000-4000-8000-000000000010"),
            updatedAt: now
        )
        let imported = HostV6.SyncStamp(
            vector: ["legacy-v1/server/A": 10, "legacy-v1/server/B": 2],
            mutationID: uuid("00000000-0000-4000-8000-000000000011"),
            updatedAt: now
        )
        let local = HostV6.SyncStamp(
            vector: ["legacy-v1/server/A": 10, "legacy-v1/server/B": 1, "device/X": 1],
            mutationID: uuid("00000000-0000-4000-8000-000000000012"),
            updatedAt: now
        )

        XCTAssertEqual(base.compared(to: imported), .before)
        XCTAssertEqual(imported.compared(to: base), .after)
        XCTAssertEqual(imported.compared(to: local), .concurrent)
        XCTAssertEqual(imported.joined(with: local), [
            "device/X": 1,
            "legacy-v1/server/A": 10,
            "legacy-v1/server/B": 2,
        ])

        let incremented = try base.incrementing(
            deviceID: "X",
            mutationID: uuid("00000000-0000-4000-8000-000000000013"),
            at: now.addingTimeInterval(1)
        )
        XCTAssertEqual(incremented.vector["device/X"], 1)
        XCTAssertEqual(incremented.vector["legacy-v1/server/A"], 10)
    }

    func testCausallyNewerTombstoneCannotBeRevivedByStaleActiveEntity() {
        let active = host(stamp: stamp(1))
        var deleted = active
        deleted.deletedAt = now
        deleted.stamp = stamp(2, mutation: "00000000-0000-4000-8000-000000000020")

        let firstMerge = HostV6.MergeEngine.merge(active, deleted)
        XCTAssertEqual(firstMerge.selected.deletedAt, now)
        XCTAssertNil(firstMerge.review)

        let repeatedMerge = HostV6.MergeEngine.merge(firstMerge.selected, active)
        XCTAssertEqual(repeatedMerge.selected.deletedAt, now)
        XCTAssertNil(repeatedMerge.review)
    }

    func testConcurrentDeleteStaysHiddenAndCreatesDeterministicReview() throws {
        var active = host(stamp: HostV6.SyncStamp(
            vector: ["device/A": 2],
            mutationID: uuid("00000000-0000-4000-8000-000000000031"),
            updatedAt: now
        ))
        active.fixedAddressID = nil
        var deleted = active
        deleted.deletedAt = now
        deleted.stamp = HostV6.SyncStamp(
            vector: ["device/B": 3],
            mutationID: uuid("00000000-0000-4000-8000-000000000030"),
            updatedAt: now
        )

        let result = HostV6.MergeEngine.merge(active, deleted)
        XCTAssertEqual(result.selected.deletedAt, now)
        XCTAssertEqual(result.review?.id, HostV6.StableID.mergeReview(
            entityType: .host,
            entityID: hostID.uuidString.lowercased(),
            conflictingMutationIDs: [active.stamp.mutationID, deleted.stamp.mutationID]
        ))
        XCTAssertEqual(result.review?.isBlocking, true)
        let review = try XCTUnwrap(result.review)
        let mergedGraph = HostV6.SyncedGraph(hosts: [result.selected], mergeReviews: [review])
        XCTAssertEqual(mergedGraph.validate(existingSSHHostAliases: []), [])
    }

    func testEqualVectorWithDifferentMutationsCreatesReviewInsteadOfSilentSelection() {
        let left = host(stamp: HostV6.SyncStamp(
            vector: ["device/A": 1],
            mutationID: uuid("00000000-0000-4000-8000-000000000035"),
            updatedAt: now
        ))
        var right = left
        right.name = "Conflicting Name"
        right.stamp.mutationID = uuid("00000000-0000-4000-8000-000000000036")

        let result = HostV6.MergeEngine.merge(left, right)
        XCTAssertNotNil(result.review)
        XCTAssertFalse(result.review?.isBlocking == true)
        XCTAssertEqual(
            Set(result.review?.candidates.compactMap { $0.summaryFields["name"] } ?? []),
            ["Database", "Conflicting Name"]
        )
    }

    func testCredentialConflictProducesBlockingStructuredCandidates() {
        let left = HostV6.Device(
            id: "device-review",
            name: "Mac A",
            registeredAt: now,
            lastActiveAt: now,
            tailscaleIdentity: nil,
            stamp: HostV6.SyncStamp(
                vector: ["device/A": 1],
                mutationID: uuid("00000000-0000-4000-8000-000000000037"),
                updatedAt: now
            )
        )
        var right = left
        right.name = "Mac B"
        right.stamp = HostV6.SyncStamp(
            vector: ["device/B": 1],
            mutationID: uuid("00000000-0000-4000-8000-000000000038"),
            updatedAt: now
        )

        let result = HostV6.MergeEngine.merge(left, right)
        XCTAssertTrue(result.review?.isBlocking == true)
        XCTAssertEqual(
            Set(result.review?.candidates.compactMap { $0.summaryFields["name"] } ?? []),
            ["Mac A", "Mac B"]
        )
    }

    func testWarningCodesCannotBeDecodedAsTerminalFailures() {
        XCTAssertNil(OperationFailureCode(rawValue: "partialParse"))
        XCTAssertNil(OperationFailureCode(rawValue: "remoteAuthorizationMayRemain"))
        XCTAssertEqual(DiscoveryWarningCode(rawValue: "partialParse"), .partialParse)
        XCTAssertEqual(CommittedWarningCode(rawValue: "remoteAuthorizationMayRemain"), .remoteAuthorizationMayRemain)

        XCTAssertEqual(Set(DiscoveryWarningCode.allCases.map(\.rawValue)), [
            "permissionLimited", "partialParse", "truncated", "containerMappingNotObservable",
        ])
        XCTAssertEqual(Set(CommittedWarningCode.allCases.map(\.rawValue)), [
            "derivedConfigOutOfDate",
            "credentialCleanupPending",
            "keyMaterialCleanupPending",
            "remoteAuthorizationMayRemain",
            "cleanupPending",
        ])
    }

    func testStableFailureCodeSetMatchesArchitectureSectionEleven() {
        XCTAssertEqual(Set(OperationFailureCode.allCases.map(\.rawValue)), [
            "invalidAddress", "dnsUnresolved", "tcpTimeout", "tcpRefused", "networkChanged",
            "probeCancelled", "fixedAddressUnavailable", "addressChoiceStale", "invalidAddressChoice",
            "hostKeyPending", "hostKeyChanged", "identityUnavailable", "keyAuthenticationFailed",
            "strictHostKeyRejected", "unsupportedOS", "toolUnavailable", "outputLimit", "parseFailed",
            "remoteExecutionFailed", "protocolUnconfirmed", "directUnavailable", "targetVerificationRequired",
            "originSensitiveTunnelUnsupported", "tlsHandledExternally", "localPortUnavailable",
            "localPortReleaseTimeout", "forwardRejected", "targetConnectionRefused", "targetConnectionTimeout",
            "targetProbeIndeterminate", "brokerExited", "capacityReached", "tunnelCapacityReached",
            "closedForSleep", "closedForNetworkChange", "cleanupPending", "reservationCancelled",
            "targetRefused", "targetTimeout", "unknownBrokerOutput", "serviceAccessDisabled",
            "invalidTunnelRequest", "staleRevision", "addressStillReferenced",
            "lastAddressForActiveIdentity", "keyStillAuthorized", "decodeFailed", "invariantFailed",
            "artifactMismatch", "legacyVersionReuse", "legacyImmutableKeyConflict", "concurrentConflict",
            "payloadTooLarge", "mixedVersionPending", "authorityGateFailed", "rollbackProjectionInvalid",
            "binaryDowngradeUnsafe", "unexpectedCloudField", "historyWriteFailed", "historyTerminalConflict",
            "hintDenied", "hintUnavailable",
        ])
    }

    func testCloudDecoderRejectsUnknownFieldsWithStablePaths() throws {
        let envelope = HostV6.MetadataEnvelope(
            synced: HostV6.SyncedGraph(
                hosts: [host(stamp: stamp(1))],
                addresses: [address(stamp: stamp(1))],
                identities: [identity(stamp: stamp(1))]
            ),
            local: .init(),
            migrationProvenance: .empty
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(HostV6.CloudPayload(envelope: envelope)))
                as? [String: Any]
        )
        json["ssid"] = "SECRET_SSID_MARKER"
        var synced = try XCTUnwrap(json["synced"] as? [String: Any])
        var hosts = try XCTUnwrap(synced["hosts"] as? [[String: Any]])
        hosts[0]["rawCommand"] = "SECRET_COMMAND_MARKER"
        synced["hosts"] = hosts
        json["synced"] = synced

        let injected = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertThrowsError(try HostV6.CloudPayloadCodec.decode(injected)) { error in
            XCTAssertEqual(
                error as? HostV6.CloudV2Error,
                .unexpectedFields(["ssid", "synced.hosts[].rawCommand"])
            )
        }
    }

    func testPublicCloudDecoderFailsClosedForUnknownFields() throws {
        let encoded = try HostV6.CloudPayloadCodec.encode(.init(
            synced: .init(),
            local: .init(),
            migrationProvenance: .empty
        ))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["privateKeyPath"] = "/must-not-be-accepted"
        let injected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try HostV6.CloudPayloadCodec.decode(injected)) { error in
            XCTAssertEqual(
                error as? HostV6.CloudV2Error,
                .unexpectedFields(["privateKeyPath"])
            )
        }
    }

    func testCloudDecoderRejectsNestedUnexpectedFields() throws {
        var conflictedHost = host(stamp: stamp(1))
        conflictedHost.machineConfiguration = RemoteMachineConfiguration(
            hostname: "db",
            operatingSystem: "macOS",
            kernel: "fixture",
            architecture: "arm64",
            synchronizedAt: now
        )
        let review = HostV6.MergeReview(
            id: uuid("00000000-0000-4000-8000-000000000041"),
            entityType: .host,
            entityID: hostID.uuidString.lowercased(),
            candidates: [HostV6.MergeCandidate(
                mutationID: uuid("00000000-0000-4000-8000-000000000042"),
                vector: ["device/review": 1],
                isDeleted: false,
                summaryFields: ["name": "Database"]
            )],
            isBlocking: false,
            stamp: stamp(2)
        )
        let envelope = HostV6.MetadataEnvelope(
            synced: HostV6.SyncedGraph(
                hosts: [conflictedHost],
                addresses: [address(stamp: stamp(1))],
                identities: [identity(stamp: stamp(1))],
                mergeReviews: [review]
            ),
            local: .init(),
            migrationProvenance: .empty
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(HostV6.CloudPayload(envelope: envelope)))
                as? [String: Any]
        )
        var synced = try XCTUnwrap(json["synced"] as? [String: Any])
        var hosts = try XCTUnwrap(synced["hosts"] as? [[String: Any]])
        var machine = try XCTUnwrap(hosts[0]["machineConfiguration"] as? [String: Any])
        machine["rawCommand"] = "SECRET_NESTED_COMMAND"
        hosts[0]["machineConfiguration"] = machine
        synced["hosts"] = hosts

        var reviews = try XCTUnwrap(synced["mergeReviews"] as? [[String: Any]])
        var candidates = try XCTUnwrap(reviews[0]["candidates"] as? [[String: Any]])
        var fields = try XCTUnwrap(candidates[0]["summaryFields"] as? [String: Any])
        fields["privateKeyPath"] = "/SECRET_NESTED_PATH"
        candidates[0]["summaryFields"] = fields
        reviews[0]["candidates"] = candidates
        synced["mergeReviews"] = reviews
        json["synced"] = synced

        let injected = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertThrowsError(try HostV6.CloudPayloadCodec.decode(injected)) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .unexpectedFields([
                "synced.hosts[].machineConfiguration.rawCommand",
                "synced.mergeReviews[].candidates[].summaryFields.privateKeyPath",
            ]))
        }
    }

    func testCloudDecoderDiagnosesUnexpectedFieldsThroughoutNestedDTOs() throws {
        let line = HostV6.KnownHostsLine(
            id: uuid("00000000-0000-4000-8000-000000000061"),
            pinID: uuid("00000000-0000-4000-8000-000000000062"),
            rawLine: "db.example.com ssh-ed25519 AAAA fixture",
            source: .legacyIdentity(identityID),
            duplicateOrdinal: 0,
            stamp: stamp(1)
        )
        let service = HostV6.SavedService(
            id: uuid("00000000-0000-4000-8000-000000000063"),
            hostID: hostID,
            name: "Admin",
            serviceProtocol: .https,
            endpoint: .init(
                bind: .specific(.init(value: "127.0.0.1", family: .v4)),
                port: 8443,
                path: "/admin"
            ),
            isFavorite: true,
            fixedAddressID: addressID,
            stamp: stamp(1)
        )
        let association = HostV6.NodeAssociation(
            id: "database.review.example",
            sshIdentityID: identityID,
            target: ActualNodeReference(tailnetKey: "review.example", nodeID: "node-1"),
            state: .linked,
            method: .manual,
            autoLinkEnabled: true,
            stamp: stamp(1)
        )
        let legacySource = HostV6.LegacySourceRevision(
            id: "server:fixture",
            legacyKind: "server",
            legacyID: identityID.uuidString,
            revision: 1,
            digest: "fixture-digest",
            sourceDeleted: false,
            derivedEntityIDs: [.host(hostID)],
            stamp: stamp(1)
        )
        let manifest = HostV6.AuthorityManifest(
            mode: .v6Canary,
            v1Hash: "v1",
            v6Hash: "v6",
            compatibilityHash: "compat",
            checkpointHash: "checkpoint",
            acknowledgedDeviceIDs: ["device_fixture"],
            cloudChangeTag: nil,
            firstV6MutationID: nil,
            codeVersion: "fixture",
            notRepresentable: [.service(service.id)]
        )
        let envelope = HostV6.MetadataEnvelope(
            synced: HostV6.SyncedGraph(
                hosts: [host(stamp: stamp(1))],
                addresses: [address(stamp: stamp(1))],
                identities: [identity(stamp: stamp(1))],
                devices: [HostV6.Device(
                    id: "device_fixture",
                    name: "Review Mac",
                    registeredAt: now,
                    lastActiveAt: now,
                    tailscaleIdentity: nil,
                    stamp: stamp(1)
                )],
                knownHostsLines: [line],
                services: [service],
                nodeAssociations: [association]
            ),
            local: .init(),
            migrationProvenance: .init(legacySources: [legacySource], authorityManifest: manifest)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(HostV6.CloudPayload(envelope: envelope)))
                as? [String: Any]
        )
        var synced = try XCTUnwrap(json["synced"] as? [String: Any])

        var devices = try XCTUnwrap(synced["devices"] as? [[String: Any]])
        devices[0]["tailscaleIdentity"] = [
            "nodeID": "node-1", "dnsName": "node.review.ts.net", "addresses": ["100.64.0.1"],
            "ssid": "SECRET_SSID",
        ]
        synced["devices"] = devices

        var services = try XCTUnwrap(synced["services"] as? [[String: Any]])
        var endpoint = try XCTUnwrap(services[0]["endpoint"] as? [String: Any])
        endpoint["rawCommand"] = "SECRET_COMMAND"
        var bind = try XCTUnwrap(endpoint["bind"] as? [String: Any])
        var specific = try XCTUnwrap(bind["specific"] as? [String: Any])
        specific["debugStream"] = "SECRET_DEBUG_STREAM"
        var encodedAddress = try XCTUnwrap(specific["_0"] as? [String: Any])
        encodedAddress["ssid"] = "SECRET_BIND_SSID"
        specific["_0"] = encodedAddress
        bind["specific"] = specific
        endpoint["bind"] = bind
        services[0]["endpoint"] = endpoint
        synced["services"] = services

        var lines = try XCTUnwrap(synced["knownHostsLines"] as? [[String: Any]])
        var source = try XCTUnwrap(lines[0]["source"] as? [String: Any])
        var legacyIdentity = try XCTUnwrap(source["legacyIdentity"] as? [String: Any])
        legacyIdentity["password"] = "SECRET_PASSWORD"
        source["legacyIdentity"] = legacyIdentity
        lines[0]["source"] = source
        synced["knownHostsLines"] = lines

        var associations = try XCTUnwrap(synced["nodeAssociations"] as? [[String: Any]])
        var target = try XCTUnwrap(associations[0]["target"] as? [String: Any])
        target["privateKeyPath"] = "SECRET_PRIVATE_PATH"
        associations[0]["target"] = target
        synced["nodeAssociations"] = associations
        json["synced"] = synced

        var provenance = try XCTUnwrap(json["migrationProvenance"] as? [String: Any])
        var sources = try XCTUnwrap(provenance["legacySources"] as? [[String: Any]])
        var derived = try XCTUnwrap(sources[0]["derivedEntityIDs"] as? [[String: Any]])
        var derivedHost = try XCTUnwrap(derived[0]["host"] as? [String: Any])
        derivedHost["rawPayload"] = "SECRET_RAW_PAYLOAD"
        derived[0]["host"] = derivedHost
        sources[0]["derivedEntityIDs"] = derived
        provenance["legacySources"] = sources

        var encodedManifest = try XCTUnwrap(provenance["authorityManifest"] as? [String: Any])
        var notRepresentable = try XCTUnwrap(encodedManifest["notRepresentable"] as? [[String: Any]])
        var referencedService = try XCTUnwrap(notRepresentable[0]["service"] as? [String: Any])
        referencedService["history"] = "SECRET_HISTORY"
        notRepresentable[0]["service"] = referencedService
        encodedManifest["notRepresentable"] = notRepresentable
        provenance["authorityManifest"] = encodedManifest
        json["migrationProvenance"] = provenance

        let injected = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertThrowsError(try HostV6.CloudPayloadCodec.decode(injected)) { error in
            XCTAssertEqual(error as? HostV6.CloudV2Error, .unexpectedFields([
                "migrationProvenance.authorityManifest.notRepresentable[].service.history",
                "migrationProvenance.legacySources[].derivedEntityIDs[].host.rawPayload",
                "synced.devices[].tailscaleIdentity.ssid",
                "synced.knownHostsLines[].source.legacyIdentity.password",
                "synced.nodeAssociations[].target.privateKeyPath",
                "synced.services[].endpoint.bind.specific._0.ssid",
                "synced.services[].endpoint.bind.specific.debugStream",
                "synced.services[].endpoint.rawCommand",
            ]))
        }
    }

    func testRepositoryEnvironmentUsesOnlyInjectedIdentityTimeStorageAndCapabilities() async throws {
        let commandID = uuid("00000000-0000-4000-8000-000000000050")
        let mutationID = uuid("00000000-0000-4000-8000-000000000051")
        let journalStore = InMemoryMutationJournalStore()
        let environment = HostV6.RepositoryEnvironment(
            clock: FixedClock(value: now),
            uuidGenerator: SequenceUUIDGenerator(values: [commandID, mutationID]),
            deviceIDProvider: FixedDeviceIDProvider(value: "fixture-device"),
            metadataStore: InMemoryMetadataStore(),
            mutationJournalStore: journalStore,
            platformCapabilities: FixedPlatformCapabilities()
        )

        let context = environment.makeCommandContext(expected: nil)
        XCTAssertEqual(context.commandID, commandID)
        XCTAssertEqual(context.mutationID, mutationID)
        XCTAssertEqual(context.deviceID, "fixture-device")
        XCTAssertEqual(context.timestamp, now)
        XCTAssertTrue(environment.platformCapabilities.supports(.atomicFileReplace))
        XCTAssertFalse(environment.platformCapabilities.supports(.cloudMetadataV2))
        try await environment.mutationJournalStore.atomicReplaceLedger(HostV6.CommandLedger.empty)
        let loadedLedger = try await journalStore.loadLedger()
        XCTAssertEqual(loadedLedger, .empty)
    }

    func testCloudAndArchivePayloadsUseExplicitAllowlists() throws {
        let keyID = "key_fixture"
        let deviceID = "device_fixture"
        let privatePathMarker = "/PRIVATE_KEY_PATH_MARKER"
        let auditMarker = "AUDIT_RESULT_MARKER"
        let localDetailMarker = "RAW_COMMAND_OUTPUT_MARKER"
        let graph = HostV6.SyncedGraph(
            hosts: [host(stamp: stamp(1))],
            addresses: [address(stamp: stamp(1))],
            identities: [identity(stamp: stamp(1))],
            devices: [HostV6.Device(
                id: deviceID,
                name: "Review Mac",
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: stamp(1)
            )],
            sshKeys: [HostV6.SSHKeyRecord(
                id: keyID,
                deviceID: deviceID,
                kind: .ed25519,
                publicKey: "ssh-ed25519 AAAA fixture",
                fingerprint: "SHA256:key",
                origin: .generated,
                stamp: stamp(1)
            )],
            mergeReviews: [HostV6.MergeReview(
                id: uuid("00000000-0000-4000-8000-000000000043"),
                entityType: .host,
                entityID: hostID.uuidString.lowercased(),
                candidates: [HostV6.MergeCandidate(
                    mutationID: uuid("00000000-0000-4000-8000-000000000044"),
                    vector: ["device/review": 1],
                    isDeleted: false,
                    summaryFields: ["name": "Database", "privateKeyPath": privatePathMarker]
                )],
                isBlocking: false,
                stamp: stamp(1)
            )]
        )
        let envelope = HostV6.MetadataEnvelope(
            synced: graph,
            local: HostV6.LocalState(
                identityStates: [HostV6.LocalSSHIdentityState(
                    sshIdentityID: identityID,
                    status: .authorized,
                    statusDetail: localDetailMarker,
                    lastCheckedAt: now,
                    passwordCheck: AuthenticationCheck(state: .succeeded, detail: localDetailMarker, checkedAt: now),
                    keyCheck: nil,
                    machineConfigurationRefreshAttemptedAt: now
                )],
                deviceStates: [HostV6.LocalDeviceState(deviceID: deviceID, isCurrent: true)],
                keyStates: [HostV6.LocalSSHKeyState(
                    keyID: keyID,
                    privateKeyPath: privatePathMarker,
                    isInAgent: true,
                    isLocallyAvailable: true
                )],
                auditEvents: [HostV6.AuditEvent(
                    id: uuid("00000000-0000-4000-8000-000000000040"),
                    timestamp: now,
                    category: "fixture",
                    action: "scan",
                    targetID: nil,
                    result: auditMarker,
                    level: .warning
                )]
            ),
            migrationProvenance: .empty
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let cloudData = try encoder.encode(HostV6.CloudPayload(envelope: envelope))
        let archiveData = try encoder.encode(HostV6.ArchivePayload(envelope: envelope))

        for data in [cloudData, archiveData] {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(privatePathMarker))
            XCTAssertFalse(text.contains(auditMarker))
            XCTAssertFalse(text.contains(localDetailMarker))
            XCTAssertFalse(text.contains("isCurrent"))
            let object = try JSONSerialization.jsonObject(with: data)
            let keys = jsonKeys(in: object)
            XCTAssertFalse(keys.contains("ssid"))
            XCTAssertFalse(keys.contains("bssid"))
        }

        let cloudJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: cloudData) as? [String: Any])
        XCTAssertEqual(Set(cloudJSON.keys), ["schemaVersion", "synced", "migrationProvenance"])
        let synced = try XCTUnwrap(cloudJSON["synced"] as? [String: Any])
        XCTAssertEqual(Set(synced.keys), Set(HostV6.SyncedGraph.cloudCodingKeys))

        let cloudDevices = try XCTUnwrap(synced["devices"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(cloudDevices.first).keys), [
            "id", "name", "registeredAt", "lastActiveAt", "stamp",
        ])
        let cloudKeys = try XCTUnwrap(synced["sshKeys"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(cloudKeys.first).keys), [
            "id", "deviceID", "kind", "publicKey", "fingerprint", "origin", "stamp",
        ])

        let restored = HostV6.CloudPayload(envelope: envelope).restoringLocalState(from: envelope)
        XCTAssertEqual(restored.local.keyStates.first?.privateKeyPath, privatePathMarker)
        XCTAssertEqual(restored.local.auditEvents.first?.result, auditMarker)
    }

    private func host(stamp: HostV6.SyncStamp) -> HostV6.Host {
        HostV6.Host(
            id: hostID,
            name: "Database",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: addressID,
            createdAt: now,
            stamp: stamp
        )
    }

    private func address(stamp: HostV6.SyncStamp) -> HostV6.AccessAddress {
        HostV6.AccessAddress(
            id: addressID,
            hostID: hostID,
            normalizedHost: "db.example.com",
            sshPort: 22,
            originalLabel: "DB.EXAMPLE.COM.",
            source: .legacy,
            sortOrder: 0,
            stamp: stamp
        )
    }

    private func identity(stamp: HostV6.SyncStamp) -> HostV6.SSHIdentity {
        HostV6.SSHIdentity(
            id: identityID,
            hostID: hostID,
            username: "deploy",
            alias: "database-deploy",
            preferredAddressID: addressID,
            createdAt: now,
            stamp: stamp
        )
    }

    private func stamp(
        _ counter: UInt64,
        mutation: String = "00000000-0000-4000-8000-000000000001"
    ) -> HostV6.SyncStamp {
        HostV6.SyncStamp(vector: ["device/review": counter], mutationID: uuid(mutation), updatedAt: now)
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func jsonKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys.map { $0.lowercased() })) { result, entry in
                result.formUnion(jsonKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, item in
                result.formUnion(jsonKeys(in: item))
            }
        }
        return []
    }
}

private struct FixedClock: HostV6Clock {
    let value: Date
    func now() -> Date { value }
}

private final class SequenceUUIDGenerator: HostV6UUIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(values: [UUID]) {
        self.values = values
    }

    func nextUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private struct FixedDeviceIDProvider: HostV6DeviceIDProviding {
    let value: String
    func currentDeviceID() -> String { value }
}

private actor InMemoryMetadataStore: HostV6MetadataBytesStoring {
    private var data: Data?
    func load() async throws -> Data? { data }
    func atomicReplace(with data: Data) async throws { self.data = data }
}

private actor InMemoryMutationJournalStore: HostV6MutationJournalStoring {
    private var ledger = HostV6.CommandLedger.empty
    func loadLedger() async throws -> HostV6.CommandLedger { ledger }
    func atomicReplaceLedger(_ ledger: HostV6.CommandLedger) async throws { self.ledger = ledger }
}

private struct FixedPlatformCapabilities: HostV6PlatformCapabilityProviding {
    func supports(_ capability: HostV6.PlatformCapability) -> Bool {
        capability == .atomicFileReplace
    }
}
