import XCTest
@testable import KeyPort
@testable import KeyPortCore

final class HostWorkbenchPresentationTests: XCTestCase {
    func testLoadingStateTakesPrecedenceOverEmptyAndSearchStates() {
        XCTAssertEqual(
            HostWorkbenchListState.resolve(isLoading: true, rowCount: 0, searchText: ""),
            .loading
        )
        XCTAssertEqual(
            HostWorkbenchListState.resolve(isLoading: false, rowCount: 0, searchText: ""),
            .empty
        )
        XCTAssertEqual(
            HostWorkbenchListState.resolve(isLoading: false, rowCount: 0, searchText: "router"),
            .noResults
        )
        XCTAssertEqual(
            HostWorkbenchListState.resolve(isLoading: false, rowCount: 1, searchText: ""),
            .populated
        )
    }

    func testDeniedNetworkHintPresentsPermissionDegradationAndSettingsAction() {
        let presentation = NetworkHintStatusPresentation(result: .denied)

        XCTAssertEqual(presentation.title, "已拒绝")
        XCTAssertTrue(presentation.detail.contains("网络提示"))
        XCTAssertTrue(presentation.detail.contains("位置权限"))
        XCTAssertTrue(presentation.needsLocationSettings)
        XCTAssertEqual(presentation.systemImage, "location.slash")
    }

    @MainActor
    func testWorkbenchFlagKeepsHostSurfaceVisibleBeforeSnapshotFinishesLoading() throws {
        let suiteName = "HostWorkbenchPresentationTests.(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: HostV6RuntimeFeatureFlags.workbenchKey)
        let model = AppModel(defaults: defaults)

        XCTAssertTrue(model.isHostWorkbenchEnabled)
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(
            HostWorkbenchListState.resolve(isLoading: !model.isLoaded, rowCount: 0, searchText: ""),
            .loading
        )
    }
}
