import Foundation
import KeyPortCore

/// UserDefaults-backed network hint switch. The flag is stored only on the
/// current Mac and defaults to off; it is never synchronized or archived.
/// UserDefaults is thread-safe but not declared Sendable, hence @unchecked.
struct UserDefaultsNetworkHintSettings: NetworkHintSettingsStoring, @unchecked Sendable {
    static let key = "KeyPort.networkHintEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isNetworkHintEnabled: Bool {
        defaults.bool(forKey: Self.key)
    }

    func setNetworkHintEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}
