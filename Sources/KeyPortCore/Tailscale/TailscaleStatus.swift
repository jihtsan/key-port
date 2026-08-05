import Foundation

public struct TailscaleStatus: Hashable, Sendable {
    public let backendState: String
    public let tailnetName: String?
    public let magicDNSSuffix: String?
    public let nodes: [TailscaleNode]

    public init(backendState: String, tailnetName: String?, magicDNSSuffix: String?, nodes: [TailscaleNode]) {
        self.backendState = backendState
        self.tailnetName = tailnetName
        self.magicDNSSuffix = magicDNSSuffix
        self.nodes = nodes
    }
}

public struct TailscaleNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let dnsName: String?
    public let operatingSystem: String?
    public let addresses: [String]
    public let isOnline: Bool
    public let isCurrent: Bool
    public let lastSeen: Date?
    public let relay: String?
    public let isExitNode: Bool
    public let isExitNodeOption: Bool

    public init(
        id: String,
        name: String,
        dnsName: String?,
        operatingSystem: String?,
        addresses: [String],
        isOnline: Bool,
        isCurrent: Bool,
        lastSeen: Date?,
        relay: String?,
        isExitNode: Bool,
        isExitNodeOption: Bool
    ) {
        self.id = id
        self.name = name
        self.dnsName = dnsName
        self.operatingSystem = operatingSystem
        self.addresses = addresses
        self.isOnline = isOnline
        self.isCurrent = isCurrent
        self.lastSeen = lastSeen
        self.relay = relay
        self.isExitNode = isExitNode
        self.isExitNodeOption = isExitNodeOption
    }
}

public enum TailscaleStatusParser {
    public static func parse(_ text: String) throws -> TailscaleStatus {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> TailscaleStatus {
        let rawStatus = try JSONDecoder().decode(RawStatus.self, from: data)
        var nodes: [TailscaleNode] = []

        if let local = rawStatus.localNode {
            nodes.append(node(from: local, fallbackID: "tailscale-self", isCurrent: true))
        }
        nodes.append(contentsOf: rawStatus.peers.map { key, peer in
            node(from: peer, fallbackID: key, isCurrent: false)
        })

        nodes.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }

        return TailscaleStatus(
            backendState: rawStatus.backendState ?? "Unknown",
            tailnetName: nonEmpty(rawStatus.currentTailnet?.name),
            magicDNSSuffix: nonEmpty(rawStatus.currentTailnet?.magicDNSSuffix) ?? nonEmpty(rawStatus.magicDNSSuffix),
            nodes: nodes
        )
    }

    private static func node(from raw: RawNode, fallbackID: String, isCurrent: Bool) -> TailscaleNode {
        let dnsName = nonEmpty(raw.dnsName)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let id = nonEmpty(raw.id) ?? nonEmpty(raw.publicKey) ?? fallbackID
        let name = nonEmpty(raw.hostName) ?? dnsName?.split(separator: ".").first.map(String.init) ?? raw.tailscaleIPs.first ?? id

        return TailscaleNode(
            id: id,
            name: name,
            dnsName: dnsName,
            operatingSystem: nonEmpty(raw.operatingSystem),
            addresses: raw.tailscaleIPs,
            isOnline: raw.online ?? false,
            isCurrent: isCurrent,
            lastSeen: parseDate(raw.lastSeen),
            relay: nonEmpty(raw.relay),
            isExitNode: raw.exitNode ?? false,
            isExitNodeOption: raw.exitNodeOption ?? false
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.hasPrefix("0001-") else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) { return date }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct RawStatus: Decodable {
    let backendState: String?
    let magicDNSSuffix: String?
    let currentTailnet: RawTailnet?
    let localNode: RawNode?
    let peers: [String: RawNode]

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case magicDNSSuffix = "MagicDNSSuffix"
        case currentTailnet = "CurrentTailnet"
        case localNode = "Self"
        case peers = "Peer"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try container.decodeIfPresent(String.self, forKey: .backendState)
        magicDNSSuffix = try container.decodeIfPresent(String.self, forKey: .magicDNSSuffix)
        currentTailnet = try container.decodeIfPresent(RawTailnet.self, forKey: .currentTailnet)
        localNode = try container.decodeIfPresent(RawNode.self, forKey: .localNode)
        peers = try container.decodeIfPresent([String: RawNode].self, forKey: .peers) ?? [:]
    }
}

private struct RawTailnet: Decodable {
    let name: String?
    let magicDNSSuffix: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case magicDNSSuffix = "MagicDNSSuffix"
    }
}

private struct RawNode: Decodable {
    let id: String?
    let publicKey: String?
    let hostName: String?
    let dnsName: String?
    let operatingSystem: String?
    let tailscaleIPs: [String]
    let online: Bool?
    let lastSeen: String?
    let relay: String?
    let exitNode: Bool?
    let exitNodeOption: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case publicKey = "PublicKey"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case operatingSystem = "OS"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
        case lastSeen = "LastSeen"
        case relay = "Relay"
        case exitNode = "ExitNode"
        case exitNodeOption = "ExitNodeOption"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName)
        operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem)
        tailscaleIPs = try container.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
        online = try container.decodeIfPresent(Bool.self, forKey: .online)
        lastSeen = try container.decodeIfPresent(String.self, forKey: .lastSeen)
        relay = try container.decodeIfPresent(String.self, forKey: .relay)
        exitNode = try container.decodeIfPresent(Bool.self, forKey: .exitNode)
        exitNodeOption = try container.decodeIfPresent(Bool.self, forKey: .exitNodeOption)
    }
}
