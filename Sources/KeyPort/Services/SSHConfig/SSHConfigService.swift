import Foundation
import KeyPortCore

enum SSHConfigError: LocalizedError {
    case aliasConflict(String)

    var errorDescription: String? {
        switch self { case .aliasConflict(let alias): "SSH 别名“\(alias)”已存在于 ~/.ssh/config 中。" }
    }
}

actor SSHConfigService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths

    init(runner: ProcessRunner = ProcessRunner(), paths: KeyPortPaths = KeyPortPaths()) {
        self.runner = runner
        self.paths = paths
    }

    func discoverConnections() async -> [DiscoveredSSHConnection] {
        guard let config = try? String(contentsOf: paths.userConfig, encoding: .utf8) else { return [] }
        let aliases = SSHConfigGenerator.aliases(in: config).sorted()
        var connections: [DiscoveredSSHConnection] = []

        for alias in aliases {
            guard let result = try? await runner.run("/usr/bin/ssh", arguments: ["-G", "--", alias]),
                  result.succeeded,
                  let connection = SSHConfigDiscoveryParser.parse(alias: alias, output: result.stdout) else { continue }
            connections.append(connection)
        }
        return connections
    }

    func validateAlias(_ alias: String, excluding managedAlias: String? = nil) throws {
        let existing = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let aliases = SSHConfigGenerator.aliases(in: existing)
        if aliases.contains(alias), alias != managedAlias { throw SSHConfigError.aliasConflict(alias) }
    }

    func write(servers: [ServerConnection], keys: [SSHKeyRecord], authorizations: [Authorization]) throws {
        try paths.prepareDirectories()
        let existing = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let existingAliases = SSHConfigGenerator.aliases(in: existing)

        let keyByID = Dictionary(uniqueKeysWithValues: keys.compactMap { key in key.privateKeyPath.map { (key.id, $0) } })
        let serverByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let entries = authorizations.compactMap { authorization -> SSHConfigEntry? in
            guard authorization.status == .authorized,
                  let server = serverByID[authorization.serverID],
                  !existingAliases.contains(server.alias),
                  let identity = keyByID[authorization.keyID] else { return nil }
            return SSHConfigEntry(server: server, identityPath: identity.replacingOccurrences(of: paths.home.path, with: "~"))
        }
        try atomicWrite(SSHConfigGenerator.managedConfig(entries: entries), to: paths.managedConfig, permissions: 0o600, backup: true)
        if !entries.isEmpty {
            let updatedUserConfig = SSHConfigGenerator.addingManagedInclude(to: existing)
            if updatedUserConfig != existing {
                try atomicWrite(updatedUserConfig, to: paths.userConfig, permissions: 0o600, backup: true)
            }
        }
    }

    private func atomicWrite(_ text: String, to destination: URL, permissions: Int, backup: Bool) throws {
        let manager = FileManager.default
        if backup, manager.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let backupURL = destination.appendingPathExtension("keyport-backup-\(stamp)")
            try? manager.copyItem(at: destination, to: backupURL)
        }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temp, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: destination)
        }
    }
}
