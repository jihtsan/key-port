import Foundation

/// Result of reading the current Wi-Fi network name. Every non-`available`
/// case collapses to `ssid = nil` in the connection record and never blocks
/// the underlying operation.
public enum NetworkHintResult: Hashable, Sendable {
    case available(ssid: String)
    case disabled
    case notDetermined
    case denied
    case restricted
    case servicesDisabled
    case unavailable
}

public protocol NetworkHintProviding: Sendable {
    func currentSSID() async -> NetworkHintResult
}

/// The network hint switch. It defaults to off and lives only on the current
/// Mac; until the C2 signed-build matrix is accepted it stays off.
public protocol NetworkHintSettingsStoring: Sendable {
    var isNetworkHintEnabled: Bool { get }
    func setNetworkHintEnabled(_ enabled: Bool)
}

/// Platform-independent copy of the location authorization states the hint
/// provider maps into. `authorizedAlways` folds into `authorized`.
public enum LocationAuthorizationState: String, Codable, CaseIterable, Hashable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

/// Pure gating for the network hint. The SSID reader closure is invoked only
/// when the switch is on, location services are enabled and authorization was
/// granted, so a denied, restricted, revoked or indeterminate state can never
/// touch the platform API. BSSID and location coordinates are never read.
public enum NetworkHintEvaluator {
    public static func evaluate(
        hintEnabled: Bool,
        authorization: LocationAuthorizationState,
        locationServicesEnabled: Bool,
        ssidReader: () -> String?
    ) -> NetworkHintResult {
        guard hintEnabled else { return .disabled }
        guard locationServicesEnabled else { return .servicesDisabled }
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: break
        }
        guard let ssid = ssidReader(), !ssid.isEmpty else { return .unavailable }
        return .available(ssid: ssid)
    }

    /// Folds every degraded result to nil so the main flow is never blocked.
    public static func recordedSSID(for result: NetworkHintResult) -> String? {
        guard case .available(let ssid) = result else { return nil }
        return ssid
    }
}

/// Decides whether a finishing operation records an SSID. The SSID is read
/// only when the user explicitly enabled the hint and the operation used a
/// private-network address; every other path records nil.
public struct NetworkHintResolver: Sendable {
    private let settings: any NetworkHintSettingsStoring
    private let provider: any NetworkHintProviding
    private let isPrivateAddress: @Sendable (UUID?) async -> Bool

    public init(
        settings: any NetworkHintSettingsStoring,
        provider: any NetworkHintProviding,
        isPrivateAddress: @escaping @Sendable (UUID?) async -> Bool
    ) {
        self.settings = settings
        self.provider = provider
        self.isPrivateAddress = isPrivateAddress
    }

    public func ssidForFinish(addressID: UUID?) async -> String? {
        guard settings.isNetworkHintEnabled else { return nil }
        guard await isPrivateAddress(addressID) else { return nil }
        return NetworkHintEvaluator.recordedSSID(for: await provider.currentSSID())
    }
}
