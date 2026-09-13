@testable import KeyPort
import XCTest

final class ServerAccessFormTests: XCTestCase {
    func testAccessFormOnlyMarksNetworkPhasesAsRunning() {
        XCTAssertTrue(ServerAccessFormPhase.checking.isRunning)
        XCTAssertTrue(ServerAccessFormPhase.authorizing.isRunning)
        XCTAssertFalse(ServerAccessFormPhase.hostKeyConfirmation.isRunning)
        XCTAssertFalse(ServerAccessFormPhase.succeeded.isRunning)
    }

    func testFirstAccessSubmissionCanKeepPasswordEphemeral() {
        let submission = ServerEditorSubmission(
            draft: ServerDraft(),
            password: "one-time-password",
            synchronizable: false,
            savePassword: false,
            confirmedHostKeys: [],
            passwordCheck: nil,
            machineConfiguration: nil
        )

        XCTAssertFalse(submission.savePassword)
    }

    func testLegacySubmissionDefaultsToSavingForCompatibility() {
        let submission = ServerEditorSubmission(
            draft: ServerDraft(),
            password: "password",
            synchronizable: false,
            confirmedHostKeys: [],
            passwordCheck: nil,
            machineConfiguration: nil
        )

        XCTAssertTrue(submission.savePassword)
    }
}
