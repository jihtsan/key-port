import CoreLocation
import CoreWLAN
import Foundation
import KeyPortCore

/// Platform network hint provider. This is the only file in the app that may
/// import CoreWLAN; a static scan test guards that confinement and forbids any
/// BSSID access. The provider never requests location authorization — the user
/// consent flow is a later UI concern — it only reads the current status, and
/// every non-authorized state degrades to a nil record.
struct SystemNetworkHintProvider: NetworkHintProviding {
    private let settings: any NetworkHintSettingsStoring

    init(settings: any NetworkHintSettingsStoring) {
        self.settings = settings
    }

    func currentSSID() async -> NetworkHintResult {
        NetworkHintEvaluator.evaluate(
            hintEnabled: settings.isNetworkHintEnabled,
            authorization: Self.authorizationState(CLLocationManager.authorizationStatus()),
            locationServicesEnabled: CLLocationManager.locationServicesEnabled()
        ) {
            CWWiFiClient.shared().interface()?.ssid()
        }
    }

    static func authorizationState(_ status: CLAuthorizationStatus) -> LocationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized, .authorizedAlways: .authorized
        @unknown default: .notDetermined
        }
    }
}
