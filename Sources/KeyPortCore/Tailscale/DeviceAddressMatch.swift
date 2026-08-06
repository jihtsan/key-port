public enum DeviceAddressMatch: String, Equatable, Sendable {
    case tailscaleMagicDNS
    case tailscaleIP

    public var title: String {
        switch self {
        case .tailscaleMagicDNS: "Tailscale MagicDNS 精确匹配"
        case .tailscaleIP: "Tailscale IP 精确匹配"
        }
    }
}
