import Darwin
import Foundation

public struct TailscaleDeviceIdentity: Codable, Hashable, Sendable {
    public let nodeID: String
    public let dnsName: String?
    public let addresses: [String]

    public init?(node: TailscaleNode) {
        guard let stableNodeID = node.stableNodeID else { return nil }
        nodeID = stableNodeID
        dnsName = node.dnsName
        addresses = node.addresses
    }

    public func matches(node: TailscaleNode) -> Bool {
        nodeID == node.stableNodeID
    }

    public func matches(host: String) -> Bool {
        addressMatch(for: host) != nil
    }

    public func addressMatch(for host: String) -> DeviceAddressMatch? {
        let candidate = TailscaleHostIdentity.normalize(host)
        guard !candidate.isEmpty else { return nil }
        if TailscaleHostIdentity.normalize(dnsName ?? "") == candidate {
            return .tailscaleMagicDNS
        }
        return addresses.contains { TailscaleHostIdentity.normalize($0) == candidate }
            ? .tailscaleIP
            : nil
    }
}

public extension TailscaleNode {
    func matches(host candidate: String) -> Bool {
        addressMatch(for: candidate) != nil
    }

    func addressMatch(for host: String) -> DeviceAddressMatch? {
        let candidate = TailscaleHostIdentity.normalize(host)
        guard !candidate.isEmpty else { return nil }
        if TailscaleHostIdentity.normalize(dnsName ?? "") == candidate {
            return .tailscaleMagicDNS
        }
        return addresses.contains { TailscaleHostIdentity.normalize($0) == candidate }
            ? .tailscaleIP
            : nil
    }

    var preferredSSHHost: String? {
        TailscaleHostIdentity.clean(dnsName ?? "")
            ?? addresses.compactMap(TailscaleHostIdentity.clean).first(where: { !$0.contains(":") })
            ?? addresses.compactMap(TailscaleHostIdentity.clean).first
    }

}

enum TailscaleHostIdentity {
    static func clean(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func normalize(_ value: String) -> String {
        guard let cleaned = clean(value)?.lowercased() else { return "" }

        var ipv4 = in_addr()
        if cleaned.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4.s_addr) { bytes in
                "ipv4:" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        }

        var ipv6 = in6_addr()
        if cleaned.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                "ipv6:" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        }

        return cleaned
    }
}
