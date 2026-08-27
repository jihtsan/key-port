import Foundation
import XCTest
@testable import KeyPortCore

final class HostV6GraphTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_616_000)
    private let later = Date(timeIntervalSince1970: 1_787_616_100)
    private let hostID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let addressID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let alternateAddressID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let identityID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let pinID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    private let lineID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    private let serviceID = UUID(uuidString: "60000000-0000-4000-8000-000000000001")!
    private let reviewID = UUID(uuidString: "70000000-0000-4000-8000-000000000001")!
    private let keyID = "key_fixture"
    private let currentDeviceID = "device_current"
    private let otherDeviceID = "device_other"
    private let nodeID = "database.review.example"

    func testValidGraphSatisfiesReferencesAndReportsActionBlockersSeparately() {
        let graph = makeEnvelope().synced
        XCTAssertEqual(graph.validate(existingSSHHostAliases: []), [])
        XCTAssertEqual(graph.actionBlockers(for: hostID), [.mergeReview(reviewID)])

        var pendingGraph = graph
        var pendingPin = pendingGraph.hostKeyPins[0]
        pendingPin.state = .pendingReview
        pendingGraph.hostKeyPins.append(pendingPinWithUniqueID(pendingPin))
        XCTAssertTrue(pendingGraph.actionBlockers(for: hostID).contains { blocker in
            if case .hostKeyPending = blocker { return true }
            return false
        })
    }

    func testCredentialReviewBlocksHostActionsThatReferenceTheKey() {
        var graph = makeEnvelope().synced
        graph.mergeReviews[0].entityType = .sshKeyRecord
        graph.mergeReviews[0].entityID = keyID

        XCTAssertEqual(graph.actionBlockers(for: hostID), [.mergeReview(reviewID)])
    }

    func testValidationRejectsDeletedParentsMissingCredentialReferencesAndAliasCollisions() {
        var graph = makeEnvelope().synced
        graph.hosts[0].deletedAt = later
        graph.sshKeys[0].deviceID = "missing-device"
        graph.authorizations[0].keyID = "missing-key"

        let codes = Set(graph.validate(existingSSHHostAliases: ["database-deploy"]).map(\.code))
        XCTAssertTrue(codes.contains(.activeReferenceTargetsDeletedEntity))
        XCTAssertTrue(codes.contains(.missingReference))
        XCTAssertTrue(codes.contains(.duplicateAlias))
    }

    func testValidationRejectsCrossHostFixedAddressAndConfirmedPinWithoutLine() {
        var graph = makeEnvelope().synced
        let otherHostID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        graph.hosts.append(HostV6.Host(
            id: otherHostID,
            name: "Other",
            group: "",
            machineConfiguration: nil,
            fixedAddressID: addressID,
            createdAt: now,
            stamp: stamp(20)
        ))
        graph.knownHostsLines[0].deletedAt = later

        let codes = Set(graph.validate(existingSSHHostAliases: []).map(\.code))
        XCTAssertTrue(codes.contains(.crossHostAddressReference))
        XCTAssertTrue(codes.contains(.confirmedPinWithoutActiveLine))
    }

    func testDeleteHostCascadesRelationsButPreservesCredentialInventory() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(
                command: 1,
                expected: try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
            )
        )

        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        let graph = transition.envelope.synced

        XCTAssertNotNil(graph.hosts.first?.deletedAt)
        XCTAssertTrue(graph.addresses.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(graph.identities.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(graph.hostKeyPins.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(graph.knownHostsLines.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(graph.services.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(graph.nodeAssociations.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(graph.authorizations.first?.relationState, .detached)
        XCTAssertEqual(graph.authorizations.first?.remoteState, .authorized)
        XCTAssertNotNil(graph.authorizations.first?.deletedAt)
        XCTAssertNil(graph.devices.first(where: { $0.id == currentDeviceID })?.deletedAt)
        XCTAssertNil(graph.sshKeys.first?.deletedAt)
        XCTAssertEqual(graph.mergeReviews.first?.resolutionReason, .resolvedByTargetDeletion)
        XCTAssertEqual(transition.result.status, .committedWithWarnings)
        XCTAssertEqual(transition.result.warnings, [.remoteAuthorizationMayRemain])
        XCTAssertTrue(transition.result.pendingEffects.contains(.rebuildSSHConfig))
        XCTAssertTrue(transition.result.pendingEffects.contains(.rebuildKnownHosts))
        XCTAssertEqual(graph.validate(existingSSHHostAliases: []), [])
    }

    func testDeleteHostResolvesReviewForAlreadyTombstonedChild() throws {
        var envelope = makeEnvelope()
        envelope.synced.hostKeyPins[0].deletedAt = now
        envelope.synced.knownHostsLines[0].deletedAt = now
        envelope.synced.mergeReviews[0].entityType = .hostKeyPin
        envelope.synced.mergeReviews[0].entityID = pinID.uuidString.lowercased()
        envelope.synced.mergeReviews[0].candidates[0].isDeleted = true
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(
                command: 23,
                expected: try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
            )
        )

        let transition = try reduce(command, envelope: envelope, ledger: .empty)

        XCTAssertEqual(
            transition.envelope.synced.mergeReviews[0].resolutionReason,
            .resolvedByTargetDeletion
        )
        XCTAssertTrue(transition.result.affectedEntities.contains(.mergeReview(reviewID)))
    }

    func testDuplicateCommandIDReturnsRecordedResultWithoutIncrementingVector() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(
                command: 2,
                expected: try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
            )
        )
        let first = try reduce(command, envelope: envelope, ledger: .empty)
        let replay = try reduce(command, envelope: first.envelope, ledger: first.ledger)

        XCTAssertEqual(replay.result, first.result)
        XCTAssertEqual(replay.envelope, first.envelope)
        XCTAssertEqual(replay.ledger, first.ledger)
        XCTAssertEqual(replay.envelope.synced.hosts[0].stamp.vector["device/\(currentDeviceID)"], 1)
    }

    func testNewDeleteCommandAgainstExistingTombstoneIsNoOp() throws {
        let envelope = makeEnvelope()
        let firstCommand = HostV6.ModelCommand.deleteService(
            serviceID: serviceID,
            context: context(
                command: 17,
                expected: try envelope.synced.revisionExpectation(for: .deleteService(serviceID))
            )
        )
        let first = try reduce(firstCommand, envelope: envelope, ledger: .empty)
        let firstStamp = first.envelope.synced.services[0].stamp
        let secondCommand = HostV6.ModelCommand.deleteService(
            serviceID: serviceID,
            context: context(
                command: 18,
                expected: try first.envelope.synced.revisionExpectation(for: .deleteService(serviceID))
            )
        )
        let second = try reduce(
            secondCommand,
            envelope: first.envelope,
            ledger: first.ledger
        )
        XCTAssertEqual(second.result.status, .noOp)
        XCTAssertEqual(second.envelope.synced.services[0].stamp, firstStamp)
    }

    func testDeleteHostRejectsRelatedRevisionRaceWithoutPartialMutation() throws {
        let envelope = makeEnvelope()
        let expectation = try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
        var raced = envelope
        raced.synced.addresses[0].stamp = stamp(99)
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(command: 3, expected: expectation)
        )

        assertFailure(.staleRevision) {
            _ = try reduce(command, envelope: raced, ledger: .empty)
        }
        XCTAssertNil(raced.synced.hosts[0].deletedAt)
        XCTAssertNil(raced.synced.addresses[0].deletedAt)
    }

    func testDeleteHostRejectsExpectationForAnotherCommandTarget() throws {
        let envelope = makeEnvelope()
        let wrongExpectation = try envelope.synced.revisionExpectation(for: .deleteService(serviceID))
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(command: 19, expected: wrongExpectation)
        )

        assertFailure(.staleRevision) {
            _ = try reduce(command, envelope: envelope, ledger: .empty)
        }
    }

    func testDeleteHostRejectsExpectationMissingRelatedRevisions() throws {
        let envelope = makeEnvelope()
        let fullExpectation = try envelope.synced.revisionExpectation(for: .deleteHost(hostID))
        let incompleteExpectation = HostV6.RevisionExpectation(target: fullExpectation.target)
        let command = HostV6.ModelCommand.deleteHost(
            hostID: hostID,
            context: context(command: 20, expected: incompleteExpectation)
        )

        assertFailure(.staleRevision) {
            _ = try reduce(command, envelope: envelope, ledger: .empty)
        }
    }

    func testDeleteIdentityCascadesAuthorizationAndNodeOnly() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.deleteIdentity(
            identityID: identityID,
            context: context(
                command: 4,
                expected: try envelope.synced.revisionExpectation(for: .deleteIdentity(identityID))
            )
        )
        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        let graph = transition.envelope.synced

        XCTAssertNotNil(graph.identities[0].deletedAt)
        XCTAssertNotNil(graph.authorizations[0].deletedAt)
        XCTAssertNotNil(graph.nodeAssociations[0].deletedAt)
        XCTAssertNil(graph.hosts[0].deletedAt)
        XCTAssertTrue(graph.addresses.allSatisfy { $0.deletedAt == nil })
        XCTAssertNil(graph.services[0].deletedAt)
        XCTAssertNil(graph.sshKeys[0].deletedAt)
        XCTAssertEqual(transition.result.warnings, [.remoteAuthorizationMayRemain])
        XCTAssertTrue(transition.result.pendingEffects.contains(.deleteCredential(identityID)))
    }

    func testDeleteIdentityResolvesReviewForAlreadyDetachedAuthorization() throws {
        var envelope = makeEnvelope()
        envelope.synced.authorizations[0].relationState = .detached
        envelope.synced.authorizations[0].deletedAt = now
        envelope.synced.mergeReviews[0].entityType = .authorization
        envelope.synced.mergeReviews[0].entityID = envelope.synced.authorizations[0].id
        envelope.synced.mergeReviews[0].candidates[0].isDeleted = true
        let command = HostV6.ModelCommand.deleteIdentity(
            identityID: identityID,
            context: context(
                command: 24,
                expected: try envelope.synced.revisionExpectation(for: .deleteIdentity(identityID))
            )
        )

        let transition = try reduce(command, envelope: envelope, ledger: .empty)

        XCTAssertEqual(
            transition.envelope.synced.mergeReviews[0].resolutionReason,
            .resolvedByTargetDeletion
        )
    }

    func testDeleteAddressRequiresPolicyAndAtomicallyClearsReferencesAndPins() throws {
        let envelope = makeEnvelope()
        let expectation = try envelope.synced.revisionExpectation(for: .deleteAddress(addressID))
        let missingPolicy = HostV6.ModelCommand.deleteAddress(
            addressID: addressID,
            referencePolicy: nil,
            context: context(command: 5, expected: expectation)
        )
        assertFailure(.addressStillReferenced) {
            _ = try reduce(missingPolicy, envelope: envelope, ledger: .empty)
        }

        let clear = HostV6.ModelCommand.deleteAddress(
            addressID: addressID,
            referencePolicy: .clear,
            context: context(command: 6, expected: expectation)
        )
        let transition = try reduce(clear, envelope: envelope, ledger: .empty)
        let graph = transition.envelope.synced
        XCTAssertNotNil(graph.addresses.first(where: { $0.id == addressID })?.deletedAt)
        XCTAssertNil(graph.hosts[0].fixedAddressID)
        XCTAssertNil(graph.identities[0].preferredAddressID)
        XCTAssertNil(graph.services[0].fixedAddressID)
        XCTAssertNotNil(graph.hostKeyPins[0].deletedAt)
        XCTAssertNotNil(graph.knownHostsLines[0].deletedAt)
        XCTAssertNil(graph.addresses.first(where: { $0.id == alternateAddressID })?.deletedAt)
        XCTAssertNil(graph.mergeReviews[0].resolvedAt)
        XCTAssertEqual(graph.validate(existingSSHHostAliases: []), [])
    }

    func testDeleteAddressResolvesReviewForAlreadyTombstonedPin() throws {
        var envelope = makeEnvelope()
        envelope.synced.hostKeyPins[0].deletedAt = now
        envelope.synced.knownHostsLines[0].deletedAt = now
        envelope.synced.mergeReviews[0].entityType = .hostKeyPin
        envelope.synced.mergeReviews[0].entityID = pinID.uuidString.lowercased()
        envelope.synced.mergeReviews[0].candidates[0].isDeleted = true
        let command = HostV6.ModelCommand.deleteAddress(
            addressID: addressID,
            referencePolicy: .clear,
            context: context(
                command: 25,
                expected: try envelope.synced.revisionExpectation(for: .deleteAddress(addressID))
            )
        )

        let transition = try reduce(command, envelope: envelope, ledger: .empty)

        XCTAssertEqual(
            transition.envelope.synced.mergeReviews[0].resolutionReason,
            .resolvedByTargetDeletion
        )
    }

    func testDeleteLastAddressForActiveIdentityIsRejected() throws {
        var envelope = makeEnvelope()
        envelope.synced.addresses.removeAll { $0.id == alternateAddressID }
        let command = HostV6.ModelCommand.deleteAddress(
            addressID: addressID,
            referencePolicy: .clear,
            context: context(
                command: 7,
                expected: try envelope.synced.revisionExpectation(for: .deleteAddress(addressID))
            )
        )
        assertFailure(.lastAddressForActiveIdentity) {
            _ = try reduce(command, envelope: envelope, ledger: .empty)
        }
    }

    func testDeleteServiceOnlyTombstonesService() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.deleteService(
            serviceID: serviceID,
            context: context(
                command: 8,
                expected: try envelope.synced.revisionExpectation(for: .deleteService(serviceID))
            )
        )
        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        XCTAssertNotNil(transition.envelope.synced.services[0].deletedAt)
        XCTAssertNil(transition.envelope.synced.hosts[0].deletedAt)
        XCTAssertEqual(transition.result.pendingEffects, [.closeServiceTunnel(serviceID)])
    }

    func testRetireKeyIsBlockedUntilEveryAuthorizationIsRemotelyRevoked() throws {
        let envelope = makeEnvelope()
        let blocked = HostV6.ModelCommand.retireSSHKey(
            keyID: keyID,
            context: context(
                command: 9,
                expected: try envelope.synced.revisionExpectation(for: .retireSSHKey(keyID))
            )
        )
        assertFailure(.keyStillAuthorized) {
            _ = try reduce(blocked, envelope: envelope, ledger: .empty)
        }

        var revoked = envelope
        revoked.synced.authorizations[0].remoteState = .revoked
        let allowed = HostV6.ModelCommand.retireSSHKey(
            keyID: keyID,
            context: context(
                command: 10,
                expected: try revoked.synced.revisionExpectation(for: .retireSSHKey(keyID))
            )
        )
        let transition = try reduce(allowed, envelope: revoked, ledger: .empty)
        XCTAssertNotNil(transition.envelope.synced.sshKeys[0].deletedAt)
        XCTAssertNil(transition.envelope.synced.devices[0].deletedAt)
        XCTAssertEqual(transition.result.pendingEffects, [.deletePrivateKeyMaterial(keyID)])
    }

    func testRevokeDeviceDoesNotCascadeKeysOrAuthorizations() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.revokeDevice(
            deviceID: currentDeviceID,
            context: context(
                command: 11,
                expected: try envelope.synced.revisionExpectation(for: .revokeDevice(currentDeviceID))
            )
        )
        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        XCTAssertNotNil(transition.envelope.synced.devices.first(where: { $0.id == currentDeviceID })?.deletedAt)
        XCTAssertNil(transition.envelope.synced.sshKeys[0].deletedAt)
        XCTAssertNil(transition.envelope.synced.authorizations[0].deletedAt)

        var noTakeover = envelope
        noTakeover.synced.devices.removeAll { $0.id == otherDeviceID }
        let blocked = HostV6.ModelCommand.revokeDevice(
            deviceID: currentDeviceID,
            context: context(
                command: 12,
                expected: try noTakeover.synced.revisionExpectation(for: .revokeDevice(currentDeviceID))
            )
        )
        assertFailure(.authorityGateFailed) {
            _ = try reduce(blocked, envelope: noTakeover, ledger: .empty)
        }
    }

    func testRevokeAuthorizationRequiresRecordedRemoteSuccess() throws {
        let envelope = makeEnvelope()
        let authorizationID = envelope.synced.authorizations[0].id
        let expectation = try envelope.synced.revisionExpectation(for: .revokeAuthorization(authorizationID))
        let failed = HostV6.ModelCommand.revokeAuthorization(
            authorizationID: authorizationID,
            remoteResult: .failed(.remoteExecutionFailed),
            context: context(command: 13, expected: expectation)
        )
        assertFailure(.remoteExecutionFailed) {
            _ = try reduce(failed, envelope: envelope, ledger: .empty)
        }

        let confirmed = HostV6.ModelCommand.revokeAuthorization(
            authorizationID: authorizationID,
            remoteResult: .confirmed,
            context: context(command: 14, expected: expectation)
        )
        let transition = try reduce(confirmed, envelope: envelope, ledger: .empty)
        let authorization = transition.envelope.synced.authorizations[0]
        XCTAssertEqual(authorization.remoteState, .revoked)
        XCTAssertEqual(authorization.relationState, .detached)
        XCTAssertNotNil(authorization.deletedAt)
    }

    func testRevokeDetachedAuthorizationRecordsNewCausalMutation() throws {
        var envelope = makeEnvelope()
        envelope.synced.authorizations[0].relationState = .detached
        envelope.synced.authorizations[0].deletedAt = now
        let authorizationID = envelope.synced.authorizations[0].id
        let commandContext = context(
            command: 22,
            expected: try envelope.synced.revisionExpectation(for: .revokeAuthorization(authorizationID))
        )
        let command = HostV6.ModelCommand.revokeAuthorization(
            authorizationID: authorizationID,
            remoteResult: .confirmed,
            context: commandContext
        )

        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        let authorization = transition.envelope.synced.authorizations[0]

        XCTAssertEqual(authorization.remoteState, .revoked)
        XCTAssertEqual(authorization.deletedAt, now)
        XCTAssertEqual(authorization.stamp.mutationID, commandContext.mutationID)
        XCTAssertEqual(authorization.stamp.vector["device/\(currentDeviceID)"], 1)
        XCTAssertEqual(transition.result.affectedEntities, [.authorization(authorizationID)])
    }

    func testResolveMergeReviewJoinsCandidateVectorsAndIncrementsCurrentDevice() throws {
        let envelope = makeEnvelope()
        var replacement = envelope.synced.hosts[0]
        replacement.name = "Resolved Database"
        replacement.stamp = HostV6.SyncStamp(
            vector: ["device/A": 2],
            mutationID: uuid(81),
            updatedAt: now
        )
        let command = HostV6.ModelCommand.resolveMergeReview(
            reviewID: reviewID,
            replacement: .host(replacement),
            context: context(
                command: 15,
                expected: try envelope.synced.revisionExpectation(for: .resolveMergeReview(reviewID))
            )
        )
        let transition = try reduce(command, envelope: envelope, ledger: .empty)
        let resolvedHost = transition.envelope.synced.hosts[0]
        let review = transition.envelope.synced.mergeReviews[0]
        XCTAssertEqual(resolvedHost.name, "Resolved Database")
        XCTAssertEqual(resolvedHost.stamp.vector["device/A"], 2)
        XCTAssertEqual(resolvedHost.stamp.vector["device/B"], 3)
        XCTAssertEqual(resolvedHost.stamp.vector["device/\(currentDeviceID)"], 1)
        XCTAssertEqual(review.resolutionReason, .userSelected)
        XCTAssertFalse(review.isBlocking)
    }

    func testResolveIdentityReviewRejectsAliasFromExistingSSHConfig() throws {
        var envelope = makeEnvelope()
        envelope.synced.mergeReviews[0].entityType = .sshIdentity
        envelope.synced.mergeReviews[0].entityID = identityID.uuidString.lowercased()
        var replacement = envelope.synced.identities[0]
        replacement.alias = "shared-alias"
        replacement.stamp = HostV6.SyncStamp(
            vector: ["device/A": 2],
            mutationID: uuid(81),
            updatedAt: now
        )
        let command = HostV6.ModelCommand.resolveMergeReview(
            reviewID: reviewID,
            replacement: .sshIdentity(replacement),
            context: context(
                command: 21,
                expected: try envelope.synced.revisionExpectation(for: .resolveMergeReview(reviewID))
            )
        )

        XCTAssertThrowsError(try reduce(
            command,
            envelope: envelope,
            ledger: .empty,
            existingSSHHostAliases: ["shared-alias"]
        )) { error in
            guard case .invariantFailed(let violations) = error as? HostV6.ModelCommandError else {
                return XCTFail("Expected invariant failure, got \(error)")
            }
            XCTAssertTrue(violations.contains { $0.code == .duplicateAlias })
        }
    }

    func testClearAuditEventsIsLocalOnlyAndIdempotent() throws {
        let envelope = makeEnvelope()
        let command = HostV6.ModelCommand.clearAuditEvents(context: context(command: 16, expected: nil))
        let first = try reduce(command, envelope: envelope, ledger: .empty)
        XCTAssertTrue(first.envelope.local.auditEvents.isEmpty)
        XCTAssertEqual(first.envelope.synced, envelope.synced)

        let replay = try reduce(command, envelope: first.envelope, ledger: first.ledger)
        XCTAssertEqual(replay, first)
    }

    func testEnvelopeValidationRejectsOversizedAuditAndTombstonedAuthorizationWithMissingKey() {
        var envelope = makeEnvelope()
        envelope.synced.authorizations[0].deletedAt = later
        envelope.synced.authorizations[0].relationState = .detached
        envelope.synced.authorizations[0].keyID = "missing-key"
        let seed = envelope.local.auditEvents[0]
        envelope.local.auditEvents = (0 ... 1_000).map { index in
            var event = seed
            event.id = uuid(1_000 + index)
            return event
        }

        let codes = Set(envelope.validate(existingSSHHostAliases: []).map(\.code))
        XCTAssertTrue(codes.contains(.missingReference))
        XCTAssertTrue(codes.contains(.auditLimitExceeded))
    }

    func testEnvelopeValidationRejectsReviewForMissingLegacySource() {
        var envelope = makeEnvelope()
        envelope.synced.mergeReviews[0].entityType = .legacySourceRevision
        envelope.synced.mergeReviews[0].entityID = "server:missing"

        let violations = envelope.validate(existingSSHHostAliases: [])

        XCTAssertTrue(violations.contains {
            $0.code == .unresolvedReviewTargetsTombstone
                && $0.subject == .mergeReview(reviewID)
        })
    }

    private func makeEnvelope() -> HostV6.MetadataEnvelope {
        let host = HostV6.Host(
            id: hostID,
            name: "Database",
            group: "Production",
            machineConfiguration: nil,
            fixedAddressID: addressID,
            createdAt: now,
            stamp: stamp(1)
        )
        let addresses = [
            HostV6.AccessAddress(
                id: addressID,
                hostID: hostID,
                normalizedHost: "db.example.com",
                sshPort: 22,
                originalLabel: "DB.EXAMPLE.COM.",
                source: .legacy,
                sortOrder: 0,
                stamp: stamp(2)
            ),
            HostV6.AccessAddress(
                id: alternateAddressID,
                hostID: hostID,
                normalizedHost: "100.64.0.10",
                sshPort: 22,
                originalLabel: "100.64.0.10",
                source: .tailscale,
                sortOrder: 1,
                stamp: stamp(3)
            ),
        ]
        let identity = HostV6.SSHIdentity(
            id: identityID,
            hostID: hostID,
            username: "deploy",
            alias: "database-deploy",
            preferredAddressID: addressID,
            createdAt: now,
            stamp: stamp(4)
        )
        let devices = [
            HostV6.Device(
                id: currentDeviceID,
                name: "Current Mac",
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: stamp(5)
            ),
            HostV6.Device(
                id: otherDeviceID,
                name: "Other Mac",
                registeredAt: now,
                lastActiveAt: now,
                tailscaleIdentity: nil,
                stamp: stamp(6)
            ),
        ]
        let key = HostV6.SSHKeyRecord(
            id: keyID,
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA fixture",
            fingerprint: "SHA256:key",
            origin: .generated,
            stamp: stamp(7)
        )
        let pin = HostV6.HostKeyPin(
            id: pinID,
            hostID: hostID,
            addressID: addressID,
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:host",
            state: .confirmed,
            firstConfirmedAt: now,
            lastSeenAt: now,
            stamp: stamp(8)
        )
        let line = HostV6.KnownHostsLine(
            id: lineID,
            pinID: pinID,
            rawLine: "db.example.com ssh-ed25519 AAAA host",
            source: .legacyIdentity(identityID),
            duplicateOrdinal: 0,
            stamp: stamp(9)
        )
        let service = HostV6.SavedService(
            id: serviceID,
            hostID: hostID,
            name: "Admin",
            serviceProtocol: .https,
            endpoint: HostV6.RemoteServiceEndpoint(bind: .loopbackV4, port: 8443, path: "/admin"),
            isFavorite: true,
            fixedAddressID: addressID,
            stamp: stamp(10)
        )
        let authorization = HostV6.Authorization(
            sshIdentityID: identityID,
            keyID: keyID,
            fingerprint: "SHA256:key",
            remoteComment: "keyport:v1:key_fixture:device_current",
            remoteState: .authorized,
            relationState: .active,
            authorizedAt: now,
            lastVerifiedAt: now,
            stamp: stamp(11)
        )
        let node = HostV6.NodeAssociation(
            id: nodeID,
            sshIdentityID: identityID,
            target: ActualNodeReference(tailnetKey: "review.example", nodeID: "node-1"),
            state: .linked,
            method: .manual,
            autoLinkEnabled: true,
            stamp: stamp(12)
        )
        let review = HostV6.MergeReview(
            id: reviewID,
            entityType: .host,
            entityID: hostID.uuidString.lowercased(),
            candidates: [
                HostV6.MergeCandidate(mutationID: uuid(81), vector: ["device/A": 2], isDeleted: false),
                HostV6.MergeCandidate(mutationID: uuid(82), vector: ["device/B": 3], isDeleted: false),
            ],
            isBlocking: true,
            stamp: stamp(13)
        )
        let graph = HostV6.SyncedGraph(
            hosts: [host],
            addresses: addresses,
            identities: [identity],
            devices: devices,
            sshKeys: [key],
            hostKeyPins: [pin],
            knownHostsLines: [line],
            services: [service],
            authorizations: [authorization],
            nodeAssociations: [node],
            mergeReviews: [review]
        )
        let local = HostV6.LocalState(
            deviceStates: [HostV6.LocalDeviceState(deviceID: currentDeviceID, isCurrent: true)],
            keyStates: [HostV6.LocalSSHKeyState(
                keyID: keyID,
                privateKeyPath: "/fixture/private-key",
                isInAgent: true,
                isLocallyAvailable: true
            )],
            auditEvents: [HostV6.AuditEvent(
                id: uuid(90),
                timestamp: now,
                category: "fixture",
                action: "created",
                targetID: hostID.uuidString,
                result: "success",
                level: .info
            )]
        )
        return HostV6.MetadataEnvelope(synced: graph, local: local, migrationProvenance: .empty)
    }

    private func context(
        command: Int,
        expected: HostV6.RevisionExpectation?
    ) -> HostV6.CommandContext {
        HostV6.CommandContext(
            commandID: uuid(100 + command),
            mutationID: uuid(200 + command),
            deviceID: currentDeviceID,
            timestamp: later,
            expected: expected
        )
    }

    private func stamp(_ value: Int) -> HostV6.SyncStamp {
        HostV6.SyncStamp(vector: ["legacy/fixture": UInt64(value)], mutationID: uuid(value), updatedAt: now)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    private func pendingPinWithUniqueID(_ pin: HostV6.HostKeyPin) -> HostV6.HostKeyPin {
        var result = pin
        result.id = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
        result.algorithm = "ssh-rsa"
        result.fingerprint = "SHA256:pending"
        return result
    }

    private func reduce(
        _ command: HostV6.ModelCommand,
        envelope: HostV6.MetadataEnvelope,
        ledger: HostV6.CommandLedger,
        existingSSHHostAliases: Set<String> = []
    ) throws -> HostV6.ModelTransition {
        try HostV6.ModelReducer.reduce(
            command,
            envelope: envelope,
            ledger: ledger,
            existingSSHHostAliases: existingSSHHostAliases
        )
    }

    private func assertFailure(
        _ expected: OperationFailureCode,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? HostV6.ModelCommandError, .failure(expected), file: file, line: line)
        }
    }
}
