import Foundation

public struct ServerConnectionGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let host: String
    public let port: Int
    public let accounts: [ServerConnection]
    public let representative: ServerConnection

    init(id: String, host: String, port: Int, accounts: [ServerConnection], representative: ServerConnection) {
        self.id = id
        self.host = host
        self.port = port
        self.accounts = accounts
        self.representative = representative
    }
}

public enum ServerConnectionGrouping {
    public static func groups(_ connections: [ServerConnection]) -> [ServerConnectionGroup] {
        let grouped = Dictionary(grouping: connections) { connection in
            Endpoint(host: connection.host, port: connection.port)
        }

        return grouped.map { endpoint, accounts in
            let sortedAccounts = accounts.sorted { lhs, rhs in
                let usernameOrder = lhs.username.localizedCaseInsensitiveCompare(rhs.username)
                if usernameOrder != .orderedSame {
                    return usernameOrder == .orderedAscending
                }
                return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
            }
            let representative = accounts.min { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            } ?? sortedAccounts[0]
            return ServerConnectionGroup(
                id: endpoint.id,
                host: representative.host,
                port: endpoint.port,
                accounts: sortedAccounts,
                representative: representative
            )
        }.sorted { lhs, rhs in
            let nameOrder = lhs.representative.name.localizedCaseInsensitiveCompare(rhs.representative.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private struct Endpoint: Hashable {
        let host: String
        let port: Int

        init(host: String, port: Int) {
            self.host = host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            self.port = port
        }

        var id: String { "endpoint:\(host):\(port)" }
    }
}
