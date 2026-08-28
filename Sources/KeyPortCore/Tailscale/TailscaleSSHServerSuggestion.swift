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

        guard let preferredHost = node.preferredSSHHost else { return nil }

        let suggestedName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        nodeID = node.id
        name = suggestedName.isEmpty ? preferredHost : suggestedName
        host = preferredHost
        port = 22
        group = "Tailscale"
        alias = KeyPortNaming.alias(group: group, name: name)
        normalizedHosts = Set(([node.dnsName].compactMap { $0 } + node.addresses).map(TailscaleHostIdentity.normalize))
    }

    public func matches(host candidate: String) -> Bool {
        normalizedHosts.contains(TailscaleHostIdentity.normalize(candidate))
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
        let base = KeyPortNaming.accountAlias(serverAlias: alias, username: username)
        return KeyPortNaming.availableAlias(base, avoiding: existingAliases)
    }

    private func availableAlias(_ base: String, avoiding existingAliases: Set<String>) -> String {
        KeyPortNaming.availableAlias(base, avoiding: existingAliases)
    }
}
