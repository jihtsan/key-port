import XCTest
@testable import KeyPort

final class HostV6WorkbenchFeatureFlagTests: XCTestCase {
    func testWorkbenchFlagDefaultsOffAndCanBeEnabledExplicitly() throws {
        let suiteName = "HostV6WorkbenchFeatureFlagTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(HostV6RuntimeFeatureFlags.isWorkbenchEnabled(defaults: defaults))

        defaults.set(true, forKey: HostV6RuntimeFeatureFlags.workbenchKey)

        XCTAssertTrue(HostV6RuntimeFeatureFlags.isWorkbenchEnabled(defaults: defaults))
    }
}
