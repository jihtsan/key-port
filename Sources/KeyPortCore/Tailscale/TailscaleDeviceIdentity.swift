import Foundation

public struct TailscaleDeviceIdentity: Codable, Hashable, Sendable {
    public let nodeID: String
    public let dnsName: String?
    public let addresses: [String]

    public init(node: TailscaleNode) {
        nodeID = node.id
        dnsName = node.dnsName
        addresses = node.addresses
    }

    public func matches(node: TailscaleNode) -> Bool {
        if nodeID == node.id { return true }

        let knownAddresses = Set(addresses.map(TailscaleHostIdentity.normalize).filter { !$0.isEmpty })
        if node.addresses.contains(where: { knownAddresses.contains(TailscaleHostIdentity.normalize($0)) }) {
            return true
        }

        guard let dnsName else { return false }
        return TailscaleHostIdentity.normalize(dnsName) == TailscaleHostIdentity.normalize(node.dnsName ?? "")
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
        clean(value)?.lowercased() ?? ""
    }
}
