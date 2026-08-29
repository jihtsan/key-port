@testable import KeyPort
import XCTest

final class ServerEditorPrimaryActionTests: XCTestCase {
    func testPasswordlessEditorStartsWithConnectionTest() {
        XCTAssertEqual(
            serverEditorPrimaryAction(
                offersPasswordlessSetup: true,
                passwordValidationPassed: false,
                metadataOnlySaveAllowed: false
            ),
            .testConnection
        )
    }

    func testSuccessfulPasswordCheckTurnsIntoSaveAndAuthorize() {
        XCTAssertEqual(
            serverEditorPrimaryAction(
                offersPasswordlessSetup: true,
                passwordValidationPassed: true,
                metadataOnlySaveAllowed: false
            ),
            .saveAndAuthorize
        )
    }

    func testMetadataOnlyEditCanStillSaveWithoutConnectionTest() {
        XCTAssertEqual(
            serverEditorPrimaryAction(
                offersPasswordlessSetup: false,
                passwordValidationPassed: false,
                metadataOnlySaveAllowed: true
            ),
            .save
        )
    }

    func testPasswordEntryStartsWithPasswordVerification() {
        XCTAssertEqual(
            passwordEntryPrimaryAction(canAuthorize: true, validationPassed: false),
            .verifyPassword
        )
    }

    func testPasswordEntryTurnsIntoSaveAndAuthorizeAfterVerification() {
        XCTAssertEqual(
            passwordEntryPrimaryAction(canAuthorize: true, validationPassed: true),
            .saveAndAuthorize
        )
    }
}
