import Foundation

public struct SSHConfigEntry: Hashable, Sendable {
    public let server: ServerConnection
    public let identityPath: String

    public init(server: ServerConnection, identityPath: String) {
        self.server = server
        self.identityPath = identityPath
    }
}

public struct DiscoveredSSHConnection: Identifiable, Hashable, Sendable {
    public let alias: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFiles: [String]
    public let proxyJump: String?
    public let proxyCommand: String?
    public let hostKeyAlias: String?

    public var id: String { alias }

    public init(alias: String, host: String, port: Int, username: String, identityFiles: [String], proxyJump: String? = nil, proxyCommand: String? = nil, hostKeyAlias: String? = nil) {
        self.alias = alias
        self.host = host
        self.port = port
        self.username = username
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.proxyCommand = proxyCommand
        self.hostKeyAlias = hostKeyAlias
    }
}

public enum SSHConfigDiscoveryParser {
    public static func parse(alias: String, output: String) -> DiscoveredSSHConnection? {
        var host: String?
        var port: Int?
        var username: String?
        var identityFiles: [String] = []
        var proxyJump: String?
        var proxyCommand: String?
        var hostKeyAlias: String?

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            let value = String(fields[1])

            switch key {
            case "hostname":
                host = value
            case "port":
                port = Int(value)
            case "user":
                username = value
            case "identityfile":
                identityFiles.append(value)
            case "proxyjump":
                proxyJump = value
            case "proxycommand":
                proxyCommand = value
            case "hostkeyalias":
                hostKeyAlias = value
            default:
                continue
            }
        }

        guard !alias.isEmpty,
              let host, !host.isEmpty,
              let port, (1...65_535).contains(port),
              let username, !username.isEmpty else { return nil }

        return DiscoveredSSHConnection(
            alias: alias,
            host: host,
            port: port,
            username: username,
            identityFiles: identityFiles,
            proxyJump: proxyJump,
            proxyCommand: proxyCommand,
            hostKeyAlias: hostKeyAlias
        )
    }
}

public enum SSHConfigGenerator {
    public static let includeLine = "Include ~/.ssh/keyport/config"

    public static func managedConfig(entries: [SSHConfigEntry]) -> String {
        var grouped: [UUID: (server: ServerConnection, identityPaths: [String])] = [:]
        for entry in entries {
            if var group = grouped[entry.server.id] {
                if !group.identityPaths.contains(entry.identityPath) {
                    group.identityPaths.append(entry.identityPath)
                }
                grouped[entry.server.id] = group
            } else {
                grouped[entry.server.id] = (entry.server, [entry.identityPath])
            }
        }

        return grouped.values.sorted { $0.server.alias < $1.server.alias }.map { entry in
            let identities = entry.identityPaths
                .map { "    IdentityFile \($0)" }
                .joined(separator: "\n")
            return """
            Host \(entry.server.alias)
                HostName \(entry.server.host)
                Port \(entry.server.port)
                User \(entry.server.username)
            \(identities)
                IdentitiesOnly yes
                UserKnownHostsFile ~/.ssh/keyport/known_hosts
            """
        }.joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
    }

    public static func addingManagedInclude(to userConfig: String) -> String {
        let lines = userConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(where: { normalizeInclude($0) == normalizeInclude(includeLine) }) { return userConfig }
        let suffix = userConfig.isEmpty ? "" : (userConfig.hasSuffix("\n") ? "" : "\n")
        return includeLine + "\n" + (userConfig.isEmpty ? "" : "\n" + userConfig + suffix)
    }

    public static func aliases(in userConfig: String) -> Set<String> {
        var result = Set<String>()
        for rawLine in userConfig.split(separator: "\n") {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.first?.lowercased() == "host" else { continue }
            let patterns = fields.dropFirst().map(String.init)
            result.formUnion(patterns.filter(isLiteralAlias))
        }
        return result
    }

    private static func isLiteralAlias(_ token: String) -> Bool {
        !token.isEmpty && !token.contains("*") && !token.contains("?") && !token.hasPrefix("!")
    }

    private static func normalizeInclude(_ line: String) -> String {
        line.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() }
            .joined(separator: " ")
    }
}
