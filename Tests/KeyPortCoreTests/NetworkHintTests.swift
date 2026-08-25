import Foundation
import XCTest
@testable import KeyPortCore

final class NetworkHintTests: XCTestCase {
    private final class ReaderGuard: @unchecked Sendable {
        var invoked = false
        var value: String?
    }

    private func evaluate(
        hintEnabled: Bool,
        authorization: LocationAuthorizationState,
        servicesEnabled: Bool,
        readerValue: String? = "FixtureNet"
    ) -> (NetworkHintResult, ReaderGuard) {
        let guard_ = ReaderGuard()
        guard_.value = readerValue
        let result = NetworkHintEvaluator.evaluate(
            hintEnabled: hintEnabled,
            authorization: authorization,
            locationServicesEnabled: servicesEnabled
        ) {
            guard_.invoked = true
            return guard_.value
        }
        return (result, guard_)
    }

    func testHintSwitchOffNeverTouchesThePlatformReader() {
        let (result, reader) = evaluate(hintEnabled: false, authorization: .authorized, servicesEnabled: true)
        XCTAssertEqual(result, .disabled)
        XCTAssertFalse(reader.invoked)
    }

    func testLocationServicesOffNeverTouchesThePlatformReader() {
        let (result, reader) = evaluate(hintEnabled: true, authorization: .authorized, servicesEnabled: false)
        XCTAssertEqual(result, .servicesDisabled)
        XCTAssertFalse(reader.invoked)
    }

    func testDeniedRestrictedAndNotDeterminedNeverTouchThePlatformReader() {
        for authorization in [LocationAuthorizationState.denied, .restricted, .notDetermined] {
            let (result, reader) = evaluate(hintEnabled: true, authorization: authorization, servicesEnabled: true)
            switch (authorization, result) {
            case (.denied, .denied), (.restricted, .restricted), (.notDetermined, .notDetermined):
                break
            default:
                XCTFail("authorization \(authorization) produced \(result)")
            }
            XCTAssertFalse(reader.invoked)
            XCTAssertNil(NetworkHintEvaluator.recordedSSID(for: result))
        }
    }

    func testAuthorizedReadsSSIDOnceAndRecordsIt() {
        let (result, reader) = evaluate(hintEnabled: true, authorization: .authorized, servicesEnabled: true)
        XCTAssertEqual(result, .available(ssid: "FixtureNet"))
        XCTAssertTrue(reader.invoked)
        XCTAssertEqual(NetworkHintEvaluator.recordedSSID(for: result), "FixtureNet")
    }

    func testAuthorizedWithoutSSIDDegradesToUnavailable() {
        for readerValue in [nil, ""] as [String?] {
            let (result, reader) = evaluate(
                hintEnabled: true, authorization: .authorized, servicesEnabled: true, readerValue: readerValue
            )
            XCTAssertEqual(result, .unavailable)
            XCTAssertTrue(reader.invoked)
            XCTAssertNil(NetworkHintEvaluator.recordedSSID(for: result))
        }
    }

    // MARK: resolver (settings + private address + provider)

    private final class FakeSettings: NetworkHintSettingsStoring, @unchecked Sendable {
        var enabled = false
        var isNetworkHintEnabled: Bool { enabled }
        func setNetworkHintEnabled(_ enabled: Bool) { self.enabled = enabled }
    }

    private final class FakeProvider: NetworkHintProviding, @unchecked Sendable {
        var result: NetworkHintResult = .available(ssid: "FixtureNet")
        var calls = 0
        func currentSSID() async -> NetworkHintResult {
            calls += 1
            return result
        }
    }

    func testResolverKeepsProviderUntouchedWhileHintIsOff() async {
        let settings = FakeSettings()
        let provider = FakeProvider()
        let resolver = NetworkHintResolver(settings: settings, provider: provider) { _ in true }
        let ssid = await resolver.ssidForFinish(addressID: UUID())
        XCTAssertNil(ssid)
        XCTAssertEqual(provider.calls, 0)
    }

    func testResolverKeepsProviderUntouchedForPublicAddresses() async {
        let settings = FakeSettings()
        settings.enabled = true
        let provider = FakeProvider()
        let resolver = NetworkHintResolver(settings: settings, provider: provider) { _ in false }
        let ssid = await resolver.ssidForFinish(addressID: UUID())
        XCTAssertNil(ssid)
        XCTAssertEqual(provider.calls, 0)
    }

    func testResolverRecordsSSIDOnlyForPrivateAddressWithHintOn() async {
        let settings = FakeSettings()
        settings.enabled = true
        let provider = FakeProvider()
        let resolver = NetworkHintResolver(settings: settings, provider: provider) { _ in true }
        let ssid = await resolver.ssidForFinish(addressID: UUID())
        XCTAssertEqual(ssid, "FixtureNet")
        XCTAssertEqual(provider.calls, 1)
    }

    func testResolverFoldsEveryDegradedResultToNil() async {
        let settings = FakeSettings()
        settings.enabled = true
        for degraded in [
            NetworkHintResult.disabled, .notDetermined, .denied, .restricted, .servicesDisabled, .unavailable,
        ] {
            let provider = FakeProvider()
            provider.result = degraded
            let resolver = NetworkHintResolver(settings: settings, provider: provider) { _ in true }
            let ssid = await resolver.ssidForFinish(addressID: UUID())
            XCTAssertNil(ssid, "\(degraded) must degrade to nil")
        }
    }

    func testSettingsDefaultToOff() {
        let settings = FakeSettings()
        XCTAssertFalse(settings.isNetworkHintEnabled)
        settings.setNetworkHintEnabled(true)
        XCTAssertTrue(settings.isNetworkHintEnabled)
    }
}
