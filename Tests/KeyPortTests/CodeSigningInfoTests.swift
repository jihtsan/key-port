import XCTest
@testable import KeyPort

final class CodeSigningInfoTests: XCTestCase {
    func testTaskEntitlementValueIsUsedWhenLegacyDictionaryIsUnavailable() {
        let reader = CodeSigningEntitlementReader(
            taskValue: { key in
                key == "keychain-access-groups"
                    ? ["TEAM.com.jihtsan.KeyPort"]
                    : nil
            },
            legacyValue: { _ in nil }
        )

        XCTAssertEqual(
            reader.value(for: "keychain-access-groups") as? [String],
            ["TEAM.com.jihtsan.KeyPort"]
        )
    }

    func testLegacyEntitlementValueRemainsFallback() {
        let reader = CodeSigningEntitlementReader(
            taskValue: { _ in nil },
            legacyValue: { key in
                key == "com.apple.application-identifier"
                    ? "TEAM.com.jihtsan.KeyPort"
                    : nil
            }
        )

        XCTAssertEqual(
            reader.value(for: "com.apple.application-identifier") as? String,
            "TEAM.com.jihtsan.KeyPort"
        )
    }
}
