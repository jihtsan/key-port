import XCTest
@testable import KeyPortCore

final class SSHKeyVerificationPolicyTests: XCTestCase {
    func testAutomaticCheckRunsAtMostOncePer24Hours() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertTrue(SSHKeyVerificationPolicy.shouldRunAutomaticCheck(lastAttemptAt: nil, now: now))
        XCTAssertFalse(SSHKeyVerificationPolicy.shouldRunAutomaticCheck(
            lastAttemptAt: now.addingTimeInterval(-SSHKeyVerificationPolicy.automaticCheckInterval + 1),
            now: now
        ))
        XCTAssertTrue(SSHKeyVerificationPolicy.shouldRunAutomaticCheck(
            lastAttemptAt: now.addingTimeInterval(-SSHKeyVerificationPolicy.automaticCheckInterval),
            now: now
        ))
    }

    func testConnectionIdentityIncludesHostPortUsernameAndKey() {
        let server = ServerConnection(
            name: "Build",
            host: "BUILD.EXAMPLE.COM.",
            port: 2222,
            username: "deploy",
            alias: "renamed-alias"
        )
        let verified = SSHKeyVerificationPolicy.context(for: server, keyFingerprint: "SHA256:key-a")

        XCTAssertFalse(SSHKeyVerificationPolicy.contextChanged(
            verified: verified,
            current: SSHKeyVerificationPolicy.context(for: server, keyFingerprint: "SHA256:key-a")
        ))

        var displayOnlyChange = server
        displayOnlyChange.name = "New Display Name"
        displayOnlyChange.alias = "new-alias"
        XCTAssertFalse(SSHKeyVerificationPolicy.contextChanged(
            verified: verified,
            current: SSHKeyVerificationPolicy.context(for: displayOnlyChange, keyFingerprint: "SHA256:key-a")
        ))

        var connectionChange = server
        connectionChange.port = 22
        XCTAssertTrue(SSHKeyVerificationPolicy.contextChanged(
            verified: verified,
            current: SSHKeyVerificationPolicy.context(for: connectionChange, keyFingerprint: "SHA256:key-a")
        ))
        XCTAssertTrue(SSHKeyVerificationPolicy.contextChanged(
            verified: verified,
            current: SSHKeyVerificationPolicy.context(for: server, keyFingerprint: "SHA256:key-b")
        ))
    }

    func testNetworkFailurePreservesPreviousSuccessButRejectionClearsIt() {
        let previousSuccess = Date(timeIntervalSince1970: 1_900_000_000)
        let checkedAt = previousSuccess.addingTimeInterval(60)

        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(
                for: .transportFailure,
                previousSuccessAt: previousSuccess,
                checkedAt: checkedAt
            ),
            SSHKeyCheckResult(status: .unreachable, lastSuccessAt: previousSuccess)
        )
        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(
                for: .rejected,
                previousSuccessAt: previousSuccess,
                checkedAt: checkedAt
            ),
            SSHKeyCheckResult(status: .keyAuthenticationFailed, lastSuccessAt: nil)
        )
    }

    func testSuccessfulCheckRefreshesTimestampAndStatus() {
        let checkedAt = Date(timeIntervalSince1970: 1_900_000_100)
        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(for: .succeeded, previousSuccessAt: nil, checkedAt: checkedAt),
            SSHKeyCheckResult(status: .authorized, lastSuccessAt: checkedAt)
        )
    }

    func testBlockedAndLocalFailureStatusMapping() {
        let previousSuccess = Date(timeIntervalSince1970: 1_900_000_000)
        let checkedAt = previousSuccess.addingTimeInterval(60)

        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(for: .missingLocalKey, previousSuccessAt: previousSuccess, checkedAt: checkedAt),
            SSHKeyCheckResult(status: .missingLocalKey, lastSuccessAt: nil)
        )
        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(for: .hostKeyPending, previousSuccessAt: previousSuccess, checkedAt: checkedAt),
            SSHKeyCheckResult(status: .hostKeyPending, lastSuccessAt: previousSuccess)
        )
        XCTAssertEqual(
            SSHKeyVerificationPolicy.result(for: .hostKeyMismatch, previousSuccessAt: previousSuccess, checkedAt: checkedAt),
            SSHKeyCheckResult(status: .hostKeyMismatch, lastSuccessAt: previousSuccess)
        )
    }

    func testCopyValuesAreLiteral() {
        XCTAssertEqual(SSHCopyValue.alias.content(alias: "prod-db-root"), "prod-db-root")
        XCTAssertEqual(SSHCopyValue.command.content(alias: "prod-db-root"), "ssh prod-db-root")
    }

    func testLegacySnapshotMigrationPreservesSuccessfulKeyTime() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = AppSnapshot()
        snapshot.schemaVersion = 5
        snapshot.servers = [ServerConnection(
            name: "Legacy",
            host: "legacy.example",
            username: "root",
            alias: "legacy",
            status: .authorized,
            keyCheck: AuthenticationCheck(
                state: .succeeded,
                detail: "免密 SSH 身份验证成功。",
                checkedAt: checkedAt
            )
        )]

        snapshot.migrateSSHKeyVerificationSchemaIfNeeded()

        XCTAssertEqual(snapshot.schemaVersion, 6)
        XCTAssertEqual(snapshot.servers.first?.lastKeySuccessAt, checkedAt)
    }
}
