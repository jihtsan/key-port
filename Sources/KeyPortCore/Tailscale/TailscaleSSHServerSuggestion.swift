import Foundation

public struct TailscaleSSHServerSuggestion: Identifiable, Equatable, Sendable {
    public let nodeID: String
    public let name: String
    public let host: String
    public let port: Int
    public let group: String
    public let alias: String

    private let normalizedHosts: Set<String>

    public var id: String { nodeID }

    public init?(node: TailscaleNode) {
        guard !node.isCurrent else { return nil }

        let dnsHost = node.dnsName.flatMap(Self.cleanedHost)
        let addressHosts = node.addresses.compactMap(Self.cleanedHost)
        guard let preferredHost = dnsHost
            ?? addressHosts.first(where: { !$0.contains(":") })
            ?? addressHosts.first else { return nil }

        let suggestedName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        nodeID = node.id
        name = suggestedName.isEmpty ? preferredHost : suggestedName
        host = preferredHost
        port = 22
        group = "Tailscale"
        alias = KeyPortNaming.alias(group: group, name: name)
        normalizedHosts = Set(([dnsHost].compactMap { $0 } + addressHosts).map(Self.normalizedHost))
    }

    public func matches(host candidate: String) -> Bool {
        normalizedHosts.contains(Self.normalizedHost(candidate))
    }

    public func matchesAccount(
        host: String,
        port: Int,
        username: String,
        server: ServerConnection
    ) -> Bool {
        matches(host: host)
            && server.port == port
            && server.username == username
            && matches(host: server.host)
    }

    public func availableAlias(avoiding existingAliases: Set<String>) -> String {
        availableAlias(alias, avoiding: existingAliases)
    }

    public func suggestedAlias(username: String, avoiding existingAliases: Set<String>) -> String {
        let usernameSlug = KeyPortNaming.slug(username)
        let base = usernameSlug.isEmpty ? alias : "\(alias)-\(usernameSlug)"
        return availableAlias(base, avoiding: existingAliases)
    }

    private func availableAlias(_ base: String, avoiding existingAliases: Set<String>) -> String {
        guard existingAliases.contains(base) else { return base }

        var suffix = 2
        while existingAliases.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static func cleanedHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func normalizedHost(_ value: String) -> String {
        cleanedHost(value)?.lowercased() ?? ""
    }
}
