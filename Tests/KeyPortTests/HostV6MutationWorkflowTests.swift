import Foundation
import Security
import XCTest
@testable import KeyPort
@testable import KeyPortCore

final class HostV6MutationWorkflowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)
    private let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    func testMutationRunsJournaledEffectsInRequiredOrderAndDeduplicatesCommandID() async throws {
        let fixture = try makeFixture()
        let command = try deleteHostCommand(envelope: fixture.envelope)

        let first = try await fixture.workflow.transact(command)
        let eventValues = await fixture.events.values

        XCTAssertEqual(first.commandID, command.context.commandID)
        XCTAssertEqual(eventValues, [
            "modelSnapshot",
            "sshConfig",
            "knownHosts",
            "credentialCleanup",
            "cloudV2",
        ])
        let completedJournal = try await fixture.journal.load()
        let completedLedger = try await fixture.ledger.loadLedger()
        XCTAssertNil(completedJournal)
        XCTAssertEqual(completedLedger.results.count, 1)

        let repeated = try await fixture.workflow.transact(command)
        XCTAssertEqual(repeated, first)
        let repeatedEventValues = await fixture.events.values
        XCTAssertEqual(repeatedEventValues, eventValues)

        let committed = try await fixture.authority.recover()
        XCTAssertEqual(committed.synced.hosts.first?.stamp.vector["device/device-a"], 1)
        XCTAssertEqual(
            committed.migrationProvenance.authorityManifest?.firstV6MutationID,
            command.context.mutationID
        )
    }

    func testEveryWorkflowFailurePointRecoversWithoutRepeatingCompletedEffectsOrMutation() async throws {
        for point in MutationFailurePoint.allCases {
            let failure = FailOnce(point: point)
            let fixture = try makeFixture(failure: failure)
            let usesPrivateKeyCleanup = point == .privateKeyCleanup
            let command = usesPrivateKeyCleanup
                ? try retireKeyCommand(envelope: fixture.envelope)
                : try deleteHostCommand(envelope: fixture.envelope)

            if point == .modelSnapshot {
                do {
                    _ = try await fixture.workflow.transact(command)
                    XCTFail("Expected injected failure at \(point.rawValue)")
                } catch is InjectedMutationFailure {
                }
            } else {
                let interrupted = try await fixture.workflow.transact(command)
                XCTAssertEqual(interrupted.status, .committedWithWarnings)
                XCTAssertEqual(interrupted.warnings, [expectedWarning(for: point)])
            }
            let interruptedJournal = try await fixture.journal.load()
            XCTAssertNotNil(interruptedJournal, "Missing recovery journal at \(point.rawValue)")

            let recovered = try await fixture.workflow.recoverPendingMutation()

            XCTAssertEqual(recovered?.commandID, command.context.commandID)
            let completedJournal = try await fixture.journal.load()
            let completedLedger = try await fixture.ledger.loadLedger()
            let eventValues = await fixture.events.values
            XCTAssertNil(completedJournal)
            XCTAssertEqual(completedLedger.results.count, 1)
            XCTAssertEqual(recovered?.warnings, [])
            let expectedEvents = usesPrivateKeyCleanup
                ? ["modelSnapshot", "privateKeyCleanup", "cloudV2"]
                : ["modelSnapshot", "sshConfig", "knownHosts", "credentialCleanup", "cloudV2"]
            XCTAssertEqual(eventValues, expectedEvents, "Incorrect recovery order at \(point.rawValue)")
            let committed = try await fixture.authority.recover()
            let committedStamp = usesPrivateKeyCleanup
                ? committed.synced.sshKeys.first?.stamp
                : committed.synced.hosts.first?.stamp
            XCTAssertEqual(committedStamp?.vector["device/device-a"], 1)
        }
    }

    func testAuthorizationRevocationJournalsRemoteResultAndDoesNotRepeatRemoteActionAfterModelFailure() async throws {
        let failure = FailOnce(point: .modelSnapshot)
        let envelope = try authoritativeEnvelopeWithAuthorization()
        let fixture = try makeFixture(failure: failure, envelope: envelope)
        let authorizationID = try XCTUnwrap(envelope.synced.authorizations.first?.id)
        let context = HostV6.CommandContext(
            commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000400")!,
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000401")!,
            deviceID: "device-a",
            timestamp: now.addingTimeInterval(1),
            expected: try envelope.synced.revisionExpectation(for: .revokeAuthorization(authorizationID))
        )

        do {
            _ = try await fixture.workflow.revokeAuthorization(
                authorizationID: authorizationID,
                context: context
            ) {
                let journal = try? await fixture.journal.load()
                await fixture.events.append("remote:\(journal?.phase.rawValue ?? "missing")")
                return .confirmed
            }
            XCTFail("Expected injected model commit failure")
        } catch is InjectedMutationFailure {
        }

        let interruptedEvents = await fixture.events.snapshot()
        XCTAssertEqual(interruptedEvents, ["remote:remoteActionPrepared"])
        let pending = try await fixture.journal.load()
        XCTAssertEqual(pending?.remoteRevocation?.result, .confirmed)

        let recovered = try await fixture.workflow.recoverPendingMutation()

        XCTAssertEqual(recovered?.commandID, context.commandID)
        let recoveredEvents = await fixture.events.snapshot()
        XCTAssertEqual(
            recoveredEvents,
            ["remote:remoteActionPrepared", "modelSnapshot", "cloudV2"]
        )
        let committed = try await fixture.authority.recover()
        let completedJournal = try await fixture.journal.load()
        XCTAssertEqual(committed.synced.authorizations.first?.remoteState, .revoked)
        XCTAssertNil(completedJournal)
    }

    func testAuthorizationRevocationFailureLeavesModelUnchangedAndDoesNotEnterLedger() async throws {
        let envelope = try authoritativeEnvelopeWithAuthorization()
        let fixture = try makeFixture(envelope: envelope)
        let authorizationID = try XCTUnwrap(envelope.synced.authorizations.first?.id)
        let context = HostV6.CommandContext(
            commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000410")!,
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000411")!,
            deviceID: "device-a",
            timestamp: now.addingTimeInterval(1),
            expected: try envelope.synced.revisionExpectation(for: .revokeAuthorization(authorizationID))
        )

        do {
            _ = try await fixture.workflow.revokeAuthorization(
                authorizationID: authorizationID,
                context: context
            ) {
                let journal = try? await fixture.journal.load()
                await fixture.events.append("remote:\(journal?.phase.rawValue ?? "missing")")
                return .failed(.remoteExecutionFailed)
            }
            XCTFail("Expected remote revocation failure")
        } catch {
            XCTAssertEqual(
                error as? HostV6.ModelCommandError,
                .failure(.remoteExecutionFailed)
            )
        }

        let events = await fixture.events.snapshot()
        let committed = try await fixture.authority.recover()
        let ledger = try await fixture.ledger.loadLedger()
        let journal = try await fixture.journal.load()
        XCTAssertEqual(events, ["remote:remoteActionPrepared"])
        XCTAssertEqual(committed, envelope)
        XCTAssertTrue(ledger.results.isEmpty)
        XCTAssertNil(journal)
    }

    func testGenericTransactionCannotBypassAuthorizationRevocationJournal() async throws {
        let envelope = try authoritativeEnvelopeWithAuthorization()
        let fixture = try makeFixture(envelope: envelope)
        let authorizationID = try XCTUnwrap(envelope.synced.authorizations.first?.id)
        let command = HostV6.ModelCommand.revokeAuthorization(
            authorizationID: authorizationID,
            remoteResult: .confirmed,
            context: .init(
                commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000420")!,
                mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000421")!,
                deviceID: "device-a",
                timestamp: now.addingTimeInterval(1),
                expected: try envelope.synced.revisionExpectation(for: .revokeAuthorization(authorizationID))
            )
        )

        do {
            _ = try await fixture.workflow.transact(command)
            XCTFail("Expected generic revocation transaction rejection")
        } catch {
            XCTAssertEqual(
                error as? HostV6.ModelCommandError,
                .failure(.remoteExecutionFailed)
            )
        }
        let committed = try await fixture.authority.recover()
        let journal = try await fixture.journal.load()
        XCTAssertEqual(committed, envelope)
        XCTAssertNil(journal)
    }

    func testRuntimeAssemblyRequiresEveryExplicitV6FlagAndNeverCreatesAuthorityEvidence() throws {
        let suiteName = "HostV6MutationWorkflowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)

        XCTAssertFalse(HostV6RuntimeFeatureFlags.isCanaryEnabled(defaults: defaults))
        XCTAssertFalse(HostV6RuntimeFeatureFlags.isCloudV2Enabled(defaults: defaults))
        XCTAssertFalse(HostV6RuntimeFeatureFlags.isMutationWorkflowEnabled(defaults: defaults))
        XCTAssertNil(HostV6RuntimeAssembly.makeIfEnabled(
            currentDeviceID: "device-a",
            defaults: defaults,
            paths: paths
        ))

        defaults.set(true, forKey: HostV6RuntimeFeatureFlags.canaryKey)
        defaults.set(true, forKey: HostV6RuntimeFeatureFlags.cloudV2Key)
        XCTAssertNil(HostV6RuntimeAssembly.makeIfEnabled(
            currentDeviceID: "device-a",
            defaults: defaults,
            paths: paths
        ))

        defaults.set(true, forKey: HostV6RuntimeFeatureFlags.mutationWorkflowKey)
        XCTAssertNotNil(HostV6RuntimeAssembly.makeIfEnabled(
            currentDeviceID: "device-a",
            defaults: defaults,
            paths: paths
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.authorityManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateV6.path))
    }

    func testNoOpCommandOnlyRecordsIdempotencyAndDoesNotOpenV6MutationOrCloud() async throws {
        var envelope = try authoritativeEnvelope()
        envelope.synced.hosts[0].deletedAt = now
        envelope.synced.addresses[0].deletedAt = now
        envelope.synced.identities[0].deletedAt = now
        let fixture = try makeFixture(envelope: envelope)
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: .init(
                commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000300")!,
                mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!,
                deviceID: "device-a",
                timestamp: now.addingTimeInterval(1),
                expected: nil
            )
        )

        let result = try await fixture.workflow.transact(command)
        let eventValues = await fixture.events.snapshot()
        let committed = try await fixture.authority.recover()
        let ledger = try await fixture.ledger.loadLedger()

        XCTAssertEqual(result.status, .noOp)
        XCTAssertEqual(eventValues, [])
        XCTAssertNil(committed.migrationProvenance.authorityManifest?.firstV6MutationID)
        XCTAssertEqual(ledger.results[command.context.commandID], result)
    }

    func testClearAuditEventsCommitsLocallyWithoutWritingCloud() async throws {
        var envelope = try authoritativeEnvelope()
        envelope.local.auditEvents = [.init(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000390")!,
            timestamp: now,
            category: "fixture",
            action: "clear",
            targetID: nil,
            result: "fixture-result",
            level: .info
        )]
        envelope = try HostV6.AuthorityController.rebindManifest(in: envelope).envelope
        let fixture = try makeFixture(envelope: envelope)
        let command = HostV6.ModelCommand.clearAuditEvents(context: .init(
            commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000391")!,
            mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000392")!,
            deviceID: "device-a",
            timestamp: now.addingTimeInterval(1),
            expected: nil
        ))

        let result = try await fixture.workflow.transact(command)
        let events = await fixture.events.snapshot()
        let committed = try await fixture.authority.recover()

        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(events, ["modelSnapshot"])
        XCTAssertTrue(committed.local.auditEvents.isEmpty)
    }

    func testCanaryModeRejectsMutationBeforeWritingJournal() async throws {
        var envelope = try authoritativeEnvelope()
        envelope.migrationProvenance.authorityManifest?.mode = .v6Canary
        let fixture = try makeFixture(envelope: envelope)
        let command = try deleteHostCommand(envelope: envelope)

        do {
            _ = try await fixture.workflow.transact(command)
            XCTFail("Expected authority gate rejection")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.authorityGateFailed))
        }
        let journal = try await fixture.journal.load()
        let eventValues = await fixture.events.snapshot()
        XCTAssertNil(journal)
        XCTAssertEqual(eventValues, [])
    }

    func testSSHConfigRebuildIsByteIdempotentWithoutCreatingRecoveryBackups() async throws {
        let home = try temporaryHome(prefix: "keyport-config-idempotency")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let service = SSHConfigService(runner: ProcessRunner(), paths: paths)

        try await service.write(servers: [], keys: [], authorizations: [])
        try await service.write(servers: [], keys: [], authorizations: [])

        let files = try FileManager.default.contentsOfDirectory(
            at: paths.keyPortDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains("keyport-backup") })
    }

    func testWorkflowJournalAndCommandLedgerFilesAreSecureAndRejectCorruption() async throws {
        let home = try temporaryHome(prefix: "keyport-mutation-files")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        let envelope = try authoritativeEnvelope()
        let command = try deleteHostCommand(envelope: envelope)
        let transition = try HostV6.ModelReducer.reduce(
            command,
            envelope: envelope,
            ledger: .empty,
            existingSSHHostAliases: []
        )
        let journal = try HostV6MutationJournal(transition: transition)
        let journalStore = HostV6MutationJournalFileStore(paths: paths)
        let ledgerStore = HostV6CommandLedgerFileStore(paths: paths)

        try await journalStore.save(journal)
        try await ledgerStore.atomicReplaceLedger(transition.ledger)

        XCTAssertEqual(try permissions(paths.v6MutationJournal), 0o600)
        XCTAssertEqual(try permissions(paths.v6CommandLedger), 0o600)
        let loadedJournal = try await journalStore.load()
        let loadedLedger = try await ledgerStore.loadLedger()
        XCTAssertEqual(loadedJournal, journal)
        XCTAssertEqual(loadedLedger, transition.ledger)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.v6MutationJournal)) as? [String: Any]
        )
        object["phase"] = HostV6MutationPhase.cloudV2Committed.rawValue
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: paths.v6MutationJournal)
        do {
            _ = try await journalStore.load()
            XCTFail("Expected valid-phase journal tampering rejection")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.artifactMismatch))
        }

        try Data("corrupt-ledger".utf8).write(to: paths.v6CommandLedger)
        do {
            _ = try await ledgerStore.loadLedger()
            XCTFail("Expected corrupt ledger rejection")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.artifactMismatch))
        }
    }

    func testPrivateKeyCleanupOnlyDeletesExactManagedKeyPaths() async throws {
        let home = try temporaryHome(prefix: "keyport-key-cleanup")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = KeyPortPaths(home: home)
        try paths.prepareDirectories()
        let managed = paths.identitiesDirectory.appendingPathComponent("key_safe")
        let managedPublic = managed.appendingPathExtension("pub")
        let unrelated = paths.sshDirectory.appendingPathComponent("unrelated-private-key")
        try Data("private".utf8).write(to: managed)
        try Data("public".utf8).write(to: managedPublic)
        try Data("unrelated".utf8).write(to: unrelated)

        let envelope = try authoritativeEnvelope()
        let events = MutationEventRecorder()
        let authority = RecordingAuthorityStore(
            envelope: envelope,
            events: events,
            failure: FailOnce(point: nil)
        )
        let runner = ProcessRunner()
        let effects = ProductionHostV6MutationEffects(
            configService: SSHConfigService(runner: runner, paths: paths),
            hostKeyService: HostKeyService(runner: runner, paths: paths),
            keychainService: KeychainService(itemAPI: MissingKeychainItemAPI()),
            cloudCoordinator: HostV6CloudSyncCoordinator(
                transport: EmptyCloudV2Transport(),
                currentDeviceID: "device-a"
            ),
            authorityStore: authority,
            paths: paths
        )
        let local = HostV6.LocalState(keyStates: [.init(
            keyID: "key_safe",
            privateKeyPath: managed.path,
            isInAgent: false,
            isLocallyAvailable: true
        )])

        try await effects.deletePrivateKeyMaterial(["key_safe"], localState: local)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedPublic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let unsafeLocal = HostV6.LocalState(keyStates: [.init(
            keyID: "key_safe",
            privateKeyPath: unrelated.path,
            isInAgent: false,
            isLocallyAvailable: true
        )])
        do {
            try await effects.deletePrivateKeyMaterial(["key_safe"], localState: unsafeLocal)
            XCTFail("Expected unmanaged path rejection")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.artifactMismatch))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let malformedLocal = HostV6.LocalState(keyStates: [.init(
            keyID: "../unrelated-private-key",
            privateKeyPath: unrelated.path,
            isInAgent: false,
            isLocallyAvailable: true
        )])
        do {
            try await effects.deletePrivateKeyMaterial(
                ["../unrelated-private-key"],
                localState: malformedLocal
            )
            XCTFail("Expected malformed key ID rejection")
        } catch {
            XCTAssertEqual(error as? HostV6.CloudV2Error, .failure(.artifactMismatch))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makeFixture(
        failure: FailOnce = FailOnce(point: nil),
        envelope suppliedEnvelope: HostV6.MetadataEnvelope? = nil
    ) throws -> (
        workflow: HostV6MutationWorkflow,
        envelope: HostV6.MetadataEnvelope,
        authority: RecordingAuthorityStore,
        journal: InMemoryWorkflowJournalStore,
        ledger: InMemoryCommandLedgerStore,
        events: MutationEventRecorder
    ) {
        let envelope = try suppliedEnvelope ?? authoritativeEnvelope()
        let events = MutationEventRecorder()
        let authority = RecordingAuthorityStore(envelope: envelope, events: events, failure: failure)
        let journal = InMemoryWorkflowJournalStore(failure: failure)
        let ledger = InMemoryCommandLedgerStore()
        let effects = RecordingMutationEffects(events: events, failure: failure)
        let workflow = HostV6MutationWorkflow(
            authorityStore: authority,
            ledgerStore: ledger,
            journalStore: journal,
            effects: effects,
            existingSSHHostAliases: { Set<String>() }
        )
        return (workflow, envelope, authority, journal, ledger, events)
    }

    private func authoritativeEnvelope() throws -> HostV6.MetadataEnvelope {
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
                    fixedAddressID: addressID,
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
                    preferredAddressID: addressID,
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
                ],
                sshKeys: [.init(
                    id: "key-fixture",
                    deviceID: "device-a",
                    kind: .ed25519,
                    publicKey: "ssh-ed25519 AAAA fixture",
                    fingerprint: "SHA256:key-fixture",
                    origin: .generated,
                    stamp: stamp
                )]
            ),
            local: .init(keyStates: [.init(
                keyID: "key-fixture",
                privateKeyPath: "/fixture/key-fixture",
                isInAgent: false,
                isLocallyAvailable: true
            )]),
            migrationProvenance: .empty
        )
        let payload = try HostV6.CloudPayloadCodec.encode(envelope)
        return try HostV6.AuthorityController.activate(
            envelope: envelope,
            legacyData: HostV6.CanonicalJSON.encode(AppSnapshot()),
            evidence: .init(
                completedRequirements: Set(HostV6.AuthorityRequirement.allCases),
                signedMacDeviceIDs: ["device-a", "device-b"],
                acknowledgedDeviceIDs: ["device-a", "device-b"],
                verifiedCloudPayloadHash: HostV6.CanonicalJSON.sha256(payload),
                cloudChangeTag: "tag-1",
                codeVersion: "6-test"
            )
        ).envelope
    }

    private func authoritativeEnvelopeWithAuthorization() throws -> HostV6.MetadataEnvelope {
        var envelope = try authoritativeEnvelope()
        let identityID = try XCTUnwrap(envelope.synced.identities.first?.id)
        let stamp = try XCTUnwrap(envelope.synced.identities.first?.stamp)
        envelope.synced.authorizations = [.init(
            sshIdentityID: identityID,
            keyID: "key-fixture",
            fingerprint: "SHA256:key-fixture",
            remoteComment: "keyport:fixture",
            remoteState: .authorized,
            relationState: .active,
            authorizedAt: now,
            lastVerifiedAt: now,
            stamp: stamp
        )]
        return try HostV6.AuthorityController.rebindManifest(in: envelope).envelope
    }

    private func expectedWarning(for point: MutationFailurePoint) -> CommittedWarningCode {
        switch point {
        case .sshConfig, .knownHosts:
            return .derivedConfigOutOfDate
        case .credentialCleanup:
            return .credentialCleanupPending
        case .privateKeyCleanup:
            return .keyMaterialCleanupPending
        case .cloudV2, .journalCleanup:
            return .cleanupPending
        case .modelSnapshot:
            XCTFail("Model snapshot failures are not committed warnings")
            return .cleanupPending
        }
    }

    private func deleteHostCommand(
        envelope: HostV6.MetadataEnvelope
    ) throws -> HostV6.ModelCommand {
        .deleteHost(
            hostID: hostID,
            context: .init(
                commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000100")!,
                mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
                deviceID: "device-a",
                timestamp: now.addingTimeInterval(1),
                expected: try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
            )
        )
    }

    private func retireKeyCommand(
        envelope: HostV6.MetadataEnvelope
    ) throws -> HostV6.ModelCommand {
        .retireSSHKey(
            keyID: "key-fixture",
            context: .init(
                commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000200")!,
                mutationID: UUID(uuidString: "00000000-0000-4000-8000-000000000201")!,
                deviceID: "device-a",
                timestamp: now.addingTimeInterval(1),
                expected: try envelope.synced.revisionExpectation(for: .retireSSHKey("key-fixture"))
            )
        )
    }

    private func temporaryHome(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum MutationFailurePoint: String, CaseIterable, Sendable {
    case modelSnapshot
    case sshConfig
    case knownHosts
    case credentialCleanup
    case privateKeyCleanup
    case cloudV2
    case journalCleanup
}

private struct InjectedMutationFailure: Error {}

private actor FailOnce {
    private var point: MutationFailurePoint?

    init(point: MutationFailurePoint?) {
        self.point = point
    }

    func check(_ candidate: MutationFailurePoint) throws {
        guard point == candidate else { return }
        point = nil
        throw InjectedMutationFailure()
    }
}

private actor MutationEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor RecordingAuthorityStore: HostV6AuthorityStoring {
    private var envelope: HostV6.MetadataEnvelope
    private let events: MutationEventRecorder
    private let failure: FailOnce

    init(envelope: HostV6.MetadataEnvelope, events: MutationEventRecorder, failure: FailOnce) {
        self.envelope = envelope
        self.events = events
        self.failure = failure
    }

    func recover() async throws -> HostV6.MetadataEnvelope { envelope }

    func commit(_ plan: HostV6.AuthorityCommitPlan) async throws {
        try await failure.check(.modelSnapshot)
        envelope = plan.envelope
        await events.append(MutationFailurePoint.modelSnapshot.rawValue)
    }
}

private actor InMemoryCommandLedgerStore: HostV6MutationJournalStoring {
    private var ledger = HostV6.CommandLedger.empty
    func loadLedger() async throws -> HostV6.CommandLedger { ledger }
    func atomicReplaceLedger(_ ledger: HostV6.CommandLedger) async throws { self.ledger = ledger }
}

private actor InMemoryWorkflowJournalStore: HostV6MutationWorkflowJournalStoring {
    private var journal: HostV6MutationJournal?
    private let failure: FailOnce

    init(failure: FailOnce) {
        self.failure = failure
    }

    func load() async throws -> HostV6MutationJournal? { journal }
    func save(_ journal: HostV6MutationJournal) async throws { self.journal = journal }
    func remove() async throws {
        try await failure.check(.journalCleanup)
        journal = nil
    }
}

private actor RecordingMutationEffects: HostV6MutationEffectApplying {
    private let events: MutationEventRecorder
    private let failure: FailOnce

    init(events: MutationEventRecorder, failure: FailOnce) {
        self.events = events
        self.failure = failure
    }

    func rebuildSSHConfig(from envelope: HostV6.MetadataEnvelope) async throws {
        try await record(.sshConfig)
    }

    func rebuildKnownHosts(from envelope: HostV6.MetadataEnvelope) async throws {
        try await record(.knownHosts)
    }

    func deleteCredentials(_ identityIDs: [UUID]) async throws {
        try await record(.credentialCleanup)
    }

    func deletePrivateKeyMaterial(
        _ keyIDs: [String],
        localState: HostV6.LocalState
    ) async throws {
        try await record(.privateKeyCleanup)
    }

    func synchronizeCloudV2(
        _ envelope: HostV6.MetadataEnvelope,
        mutationID: UUID
    ) async throws {
        try await record(.cloudV2)
    }

    private func record(_ point: MutationFailurePoint) async throws {
        try await failure.check(point)
        await events.append(point.rawValue)
    }
}

private actor EmptyCloudV2Transport: HostV6CloudV2Transport {
    func fetchV2() async throws -> HostV6CloudRecord? { nil }
    func fetchLegacyV1() async throws -> Data? { nil }
    func saveV2(_ payload: Data, replacing changeTag: String?) async throws -> HostV6CloudRecord {
        HostV6CloudRecord(payload: payload, changeTag: "tag-test")
    }
}

private struct MissingKeychainItemAPI: KeychainItemAPI {
    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus { errSecItemNotFound }
    func add(_ attributes: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }
    func copyMatching(_ query: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        errSecItemNotFound
    }
    func delete(_ query: [CFString: Any]) -> OSStatus { errSecItemNotFound }
}
