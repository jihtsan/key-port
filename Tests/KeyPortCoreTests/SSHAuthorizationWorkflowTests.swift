import Foundation
import XCTest
@testable import KeyPortCore

final class SSHAuthorizationWorkflowTests: XCTestCase {
    private let accountID = UUID(uuidString: "71000000-0000-4000-8000-000000000001")!
    private let currentDeviceID = "device-current"
    private let otherDeviceID = "device-other"
    private let revokedDeviceID = "device-revoked"

    func testFirstAccessStateMachineKeepsTheWriteAndVerificationBoundary() throws {
        let targetID = UUID(uuidString: "71000000-0000-4000-8000-000000000010")!
        var machine = SSHFirstAccessStateMachine(targetID: targetID)

        XCTAssertThrowsError(try machine.transition(to: .authorized)) {
            XCTAssertEqual(
                $0 as? SSHFirstAccessTransitionError,
                .invalid(from: .targetSelected, to: .authorized)
            )
        }

        try machine.transition(to: .hostKeyReview)
        try machine.transition(to: .credentialRequired)
        try machine.transition(to: .credentialVerified)
        try machine.transition(to: .localKeyRequired)
        try machine.transition(to: .readyToAuthorize)
        try machine.transition(to: .authorizing)
        try machine.transition(to: .writtenAwaitingVerification)

        XCTAssertEqual(machine.state.stage, .writtenAwaitingVerification)
        XCTAssertTrue(machine.state.completedStages.contains(.authorizing))

        try machine.transition(to: .authorized)
        XCTAssertEqual(machine.state.stage, .authorized)
        XCTAssertFalse(machine.state.canResume)

        XCTAssertThrowsError(try machine.transition(to: .authorizing)) {
            XCTAssertEqual($0 as? SSHFirstAccessTransitionError, .terminal(.authorized))
        }
    }

    func testFirstAccessBlockedStateRetainsRecoveryBoundaryAndCanResume() throws {
        let targetID = UUID(uuidString: "71000000-0000-4000-8000-000000000011")!
        var machine = SSHFirstAccessStateMachine(targetID: targetID)
        try machine.transition(to: .hostKeyReview)
        machine.block(
            code: .hostKeyChanged,
            recoveryAction: .reviewHostKey,
            at: .hostKeyReview
        )

        XCTAssertEqual(machine.state.stage, .blocked)
        XCTAssertEqual(machine.state.blockedAt, .hostKeyReview)
        XCTAssertEqual(machine.state.failureCode, .hostKeyChanged)
        XCTAssertEqual(machine.state.recoveryAction, .reviewHostKey)
        XCTAssertTrue(machine.state.canResume)

        try machine.transition(to: .hostKeyReview)
        XCTAssertEqual(machine.state.stage, .hostKeyReview)
        XCTAssertNil(machine.state.failureCode)
    }

    func testFirstAccessExpiryAndCancellationDoNotRewriteTerminalStates() throws {
        let expiredID = UUID(uuidString: "71000000-0000-4000-8000-000000000012")!
        var expired = SSHFirstAccessStateMachine(targetID: expiredID)
        expired.expire()
        XCTAssertEqual(expired.state.stage, .expired)
        expired.cancel()
        XCTAssertEqual(expired.state.stage, .expired)
        XCTAssertEqual(expired.state.failureCode, .expired)

        let cancelledID = UUID(uuidString: "71000000-0000-4000-8000-000000000013")!
        var cancelled = SSHFirstAccessStateMachine(targetID: cancelledID)
        cancelled.cancel()
        XCTAssertEqual(cancelled.state.stage, .cancelled)
        cancelled.expire()
        XCTAssertEqual(cancelled.state.stage, .cancelled)
        XCTAssertEqual(cancelled.state.failureCode, .cancelled)
    }

    func testPasswordRejectionRequiresCredentialIntervention() {
        XCTAssertTrue(SSHAuthorizationFailureCode.passwordRejected.requiresUserAction)
        XCTAssertEqual(
            SSHAuthorizationFailureCode.passwordRejected.suggestedRecoveryAction,
            .providePassword
        )
    }

    func testBatchRetryDoesNotResetSuccessfulItems() throws {
        let first = UUID(uuidString: "71000000-0000-4000-8000-000000000020")!
        let second = UUID(uuidString: "71000000-0000-4000-8000-000000000021")!
        var plan = try SSHAuthorizationBatchPlan(
            targetIDs: [first, second],
            deviceID: currentDeviceID
        )

        try plan.begin()
        try plan.markInProgress(targetID: first)
        try plan.markSucceeded(targetID: first)
        try plan.markInProgress(targetID: second)
        try plan.markFailed(targetID: second, code: .passwordRejected)
        plan.finishIfPossible()

        XCTAssertEqual(plan.phase, .completed)
        XCTAssertEqual(plan.succeededCount, 1)
        XCTAssertEqual(plan.failedCount, 1)

        let firstAttemptCount = try XCTUnwrap(plan.items.first(where: { $0.targetID == first })).attemptCount
        try plan.retryFailed()
        XCTAssertEqual(plan.phase, .pending)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == first })?.state, .succeeded)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == first })?.attemptCount, firstAttemptCount)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == second })?.state, .pending)

        try plan.begin()
        XCTAssertEqual(plan.nextPendingTargetID, second)
    }

    func testBatchInterventionPausesAndResumeOnlyRequeuesBlockedItem() throws {
        let first = UUID(uuidString: "71000000-0000-4000-0000-000000000030")!
        let second = UUID(uuidString: "71000000-0000-4000-0000-000000000031")!
        var plan = try SSHAuthorizationBatchPlan(
            targetIDs: [first, second],
            deviceID: currentDeviceID
        )
        try plan.begin()
        try plan.markInProgress(targetID: first)
        try plan.markSucceeded(targetID: first)
        try plan.markInProgress(targetID: second)
        try plan.markBlocked(targetID: second, code: .hostKeyPending)

        XCTAssertEqual(plan.phase, .paused)
        XCTAssertEqual(plan.blockedTargetID, second)
        XCTAssertEqual(plan.nextPendingTargetID, nil)

        try plan.resumeAfterIntervention()
        XCTAssertEqual(plan.phase, .pending)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == first })?.state, .succeeded)
        XCTAssertEqual(plan.nextPendingTargetID, nil)
        try plan.begin()
        XCTAssertEqual(plan.nextPendingTargetID, second)
    }

    func testInterruptedBatchBecomesExplicitlyResumable() throws {
        let first = UUID(uuidString: "71000000-0000-4000-0000-000000000040")!
        let second = UUID(uuidString: "71000000-0000-4000-0000-000000000041")!
        var plan = try SSHAuthorizationBatchPlan(
            targetIDs: [first, second],
            deviceID: currentDeviceID
        )
        try plan.begin()
        try plan.markInProgress(targetID: first)
        plan.recoverAfterInterruption()

        XCTAssertEqual(plan.phase, .paused)
        XCTAssertEqual(plan.pauseReason, .interrupted)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == first })?.state, .pending)
        XCTAssertEqual(plan.items.first(where: { $0.targetID == first })?.failureCode, .interrupted)
        XCTAssertEqual(plan.nextPendingTargetID, nil)
        try plan.resumeAfterIntervention()
        try plan.begin()
        XCTAssertEqual(plan.nextPendingTargetID, first)
    }

    func testBatchPlanEncodingContainsNoCredentialOrLocalPathFields() throws {
        let plan = try SSHAuthorizationBatchPlan(
            targetIDs: [UUID(uuidString: "71000000-0000-4000-0000-000000000050")!],
            deviceID: currentDeviceID
        )
        let encoded = try JSONEncoder().encode(plan)
        let text = String(decoding: encoded, as: UTF8.self)

        for forbidden in ["password", "privateKey", "privateKeyPath", "known_hosts", "isInAgent"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "unexpected field: \(forbidden)")
        }
    }

    func testProjectionSeparatesCurrentVerificationFromSharedRemoteAuthorization() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentKey = SSHKey(
            id: "key-current",
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA current",
            fingerprint: "SHA256:current",
            privateKeyPath: "/local/current",
            origin: .generated,
            isLocallyAvailable: true
        )
        let otherKey = SSHKey(
            id: "key-other",
            deviceID: otherDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA other",
            fingerprint: "SHA256:other",
            privateKeyPath: nil,
            origin: .generated,
            isLocallyAvailable: false
        )
        let revokedKey = SSHKey(
            id: "key-revoked",
            deviceID: revokedDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA revoked",
            fingerprint: "SHA256:revoked",
            origin: .generated
        )
        let topology = TopologySnapshot(
            profiles: [
                WorkspaceDeviceProfile(id: currentDeviceID, nodeID: UUID(), name: "当前 Mac", isCurrent: true),
                WorkspaceDeviceProfile(id: otherDeviceID, nodeID: UUID(), name: "另一台 Mac"),
                WorkspaceDeviceProfile(id: revokedDeviceID, nodeID: UUID(), name: "旧 Mac", isRevoked: true),
            ],
            sshKeys: [currentKey, otherKey, revokedKey],
            authorizations: [
                SSHAuthorization(
                    accountID: accountID,
                    keyID: currentKey.id,
                    fingerprint: currentKey.fingerprint,
                    remoteComment: "KeyPort:current",
                    remoteState: .authorized
                ),
                SSHAuthorization(
                    accountID: accountID,
                    keyID: otherKey.id,
                    fingerprint: otherKey.fingerprint,
                    remoteComment: "KeyPort:other",
                    remoteState: .authorized
                ),
            ],
            accessVerifications: [
                AccessVerification(
                    accountID: accountID,
                    deviceID: currentDeviceID,
                    status: .authorized,
                    lastCheckedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                    keyCheck: AuthenticationCheck(
                        state: .succeeded,
                        detail: "verified",
                        checkedAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
                    )
                ),
            ]
        )

        let summaries = SSHAuthorizationProjection.summaries(
            for: accountID,
            currentDeviceID: currentDeviceID,
            topology: topology,
            now: now,
            verificationLifetime: 24 * 60 * 60
        )

        XCTAssertEqual(summaries.first(where: { $0.deviceID == currentDeviceID })?.status, .staleVerification)
        XCTAssertEqual(summaries.first(where: { $0.deviceID == currentDeviceID })?.remoteAuthorized, true)
        XCTAssertEqual(summaries.first(where: { $0.deviceID == otherDeviceID })?.status, .remotelyAuthorized)
        XCTAssertEqual(summaries.first(where: { $0.deviceID == otherDeviceID })?.localKeyAvailable, false)
        XCTAssertEqual(summaries.first(where: { $0.deviceID == revokedDeviceID })?.status, .deviceRevoked)

        let encoded = String(decoding: try JSONEncoder().encode(summaries), as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("privateKeyPath"))
    }

    func testAccessEvidenceSeparatesUnknownExpiredAndNetworkChanged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = AccessVerification(
            accountID: accountID,
            deviceID: currentDeviceID,
            networkEpoch: 4,
            status: .authorized,
            lastCheckedAt: now.addingTimeInterval(-60)
        )
        let old = AccessVerification(
            accountID: accountID,
            deviceID: currentDeviceID,
            networkEpoch: 4,
            status: .authorized,
            lastCheckedAt: now.addingTimeInterval(-TopologyEvidencePolicy.accessVerificationValidityDuration - 1)
        )
        let unscoped = AccessVerification(
            accountID: accountID,
            deviceID: currentDeviceID,
            status: .authorized,
            lastCheckedAt: now
        )

        XCTAssertEqual(recent.freshness(at: now, networkEpoch: 4), .fresh)
        XCTAssertEqual(old.freshness(at: now, networkEpoch: 4), .expired)
        XCTAssertEqual(recent.freshness(at: now, networkEpoch: 5), .networkChanged)
        XCTAssertEqual(unscoped.freshness(at: now, networkEpoch: 4), .unknown)
    }

    func testProjectionRequiresCurrentNetworkEvidenceForAuthorizedDevice() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = SSHKey(
            id: "key-current",
            deviceID: currentDeviceID,
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAA current",
            fingerprint: "SHA256:current",
            privateKeyPath: "/local/current",
            origin: .generated,
            isLocallyAvailable: true
        )
        let topology = TopologySnapshot(
            profiles: [WorkspaceDeviceProfile(id: currentDeviceID, nodeID: UUID(), name: "当前 Mac")],
            sshKeys: [key],
            authorizations: [SSHAuthorization(
                accountID: accountID,
                keyID: key.id,
                fingerprint: key.fingerprint,
                remoteComment: "KeyPort:current",
                remoteState: .authorized
            )],
            accessVerifications: [AccessVerification(
                accountID: accountID,
                deviceID: currentDeviceID,
                networkEpoch: 3,
                status: .authorized,
                lastCheckedAt: now.addingTimeInterval(-60),
                keyCheck: AuthenticationCheck(
                    state: .succeeded,
                    detail: "verified",
                    checkedAt: now.addingTimeInterval(-60)
                )
            )]
        )

        let summaries = SSHAuthorizationProjection.summaries(
            for: accountID,
            currentDeviceID: currentDeviceID,
            topology: topology,
            now: now,
            currentNetworkEpoch: 4
        )

        XCTAssertEqual(summaries.first?.status, .staleVerification)
        XCTAssertEqual(summaries.first?.remoteAuthorized, true)
    }
}
