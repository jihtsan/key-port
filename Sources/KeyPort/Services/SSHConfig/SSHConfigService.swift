import Foundation
import KeyPortCore

enum SSHConfigError: LocalizedError {
    case aliasConflict(String)

    var errorDescription: String? {
        switch self { case .aliasConflict(let alias): "SSH 别名“\(alias)”已存在于 ~/.ssh/config 中。" }
    }
}

actor SSHConfigService {
    private struct ManagedConfigDerivationState: Codable {
        enum Phase: String, Codable {
            case transitioning
            case steady
        }

        let schemaVersion: Int
        let phase: Phase
        let previousContentHash: String?
        let targetContentHash: String

        static func transitioning(previous: String?, target: String) -> Self {
            Self(
                schemaVersion: 1,
                phase: .transitioning,
                previousContentHash: previous,
                targetContentHash: target
            )
        }

        static func steady(_ hash: String) -> Self {
            Self(
                schemaVersion: 1,
                phase: .steady,
                previousContentHash: nil,
                targetContentHash: hash
            )
        }
    }

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
        let normalizedAlias = alias.lowercased()
        let aliases = Set(SSHConfigGenerator.aliases(in: existing).map { $0.lowercased() })
        let excludedAlias = managedAlias?.lowercased()
        if aliases.contains(normalizedAlias), normalizedAlias != excludedAlias {
            throw SSHConfigError.aliasConflict(alias)
        }
    }

    func write(servers: [ServerConnection], keys: [SSHKeyRecord], authorizations: [Authorization]) throws {
        try paths.prepareDirectories()
        let existing = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let existingAliases = SSHConfigGenerator.aliases(in: existing)
        let entries = managedEntries(
            servers: servers,
            keys: keys,
            authorizations: authorizations,
            excludingAliases: existingAliases
        )
        let managedConfig = SSHConfigGenerator.managedConfig(entries: entries)
        try writeManagedConfigFailingClosed(managedConfig)
        if !entries.isEmpty {
            let updatedUserConfig = SSHConfigGenerator.addingManagedInclude(to: existing)
            if updatedUserConfig != existing {
                try atomicWrite(updatedUserConfig, to: paths.userConfig, permissions: 0o600, backup: true)
            }
        }
    }

    func adoptExistingManagedConfigBaseline(
        servers: [ServerConnection],
        keys: [SSHKeyRecord],
        authorizations: [Authorization]
    ) throws -> Bool {
        try paths.prepareDirectories()
        let existingUserConfig = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let desiredConfig = SSHConfigGenerator.managedConfig(entries: managedEntries(
            servers: servers,
            keys: keys,
            authorizations: authorizations,
            excludingAliases: SSHConfigGenerator.aliases(in: existingUserConfig)
        ))
        let desiredData = Data(desiredConfig.utf8)
        guard FileManager.default.fileExists(atPath: paths.managedConfig.path) else {
            return desiredData.isEmpty
        }

        let existingData = try Data(contentsOf: paths.managedConfig)
        let existingHash = HostV6.CanonicalJSON.sha256(existingData)
        guard let state = try loadDerivationState() else {
            guard existingData == desiredData else { return false }
            try writeDerivationState(.steady(existingHash))
            return true
        }

        try validateExistingManagedConfig(state: state, existingHash: existingHash)
        guard state.phase == .steady,
              state.targetContentHash == existingHash,
              existingData == desiredData else {
            return false
        }
        return true
    }

    private func writeManagedConfigFailingClosed(_ managedConfig: String) throws {
        let desiredData = Data(managedConfig.utf8)
        let desiredHash = HostV6.CanonicalJSON.sha256(desiredData)
        let existingData = FileManager.default.fileExists(atPath: paths.managedConfig.path)
            ? try Data(contentsOf: paths.managedConfig)
            : nil
        let existingHash = existingData.map(HostV6.CanonicalJSON.sha256)
        let state = try loadDerivationState()

        guard let state else {
            guard existingData == nil || existingData == desiredData else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            if existingData == nil {
                try writeDerivationState(.transitioning(previous: nil, target: desiredHash))
                try atomicWrite(managedConfig, to: paths.managedConfig, permissions: 0o600, backup: false)
            }
            try writeDerivationState(.steady(desiredHash))
            return
        }

        try validateExistingManagedConfig(state: state, existingHash: existingHash)
        if state.phase == .transitioning, desiredHash != state.targetContentHash {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }

        if existingHash == desiredHash {
            if state.phase != .steady {
                try writeDerivationState(.steady(desiredHash))
            }
            return
        }

        try writeDerivationState(.transitioning(previous: existingHash, target: desiredHash))
        try atomicWrite(managedConfig, to: paths.managedConfig, permissions: 0o600, backup: true)
        try writeDerivationState(.steady(desiredHash))
    }

    private func managedEntries(
        servers: [ServerConnection],
        keys: [SSHKeyRecord],
        authorizations: [Authorization],
        excludingAliases existingAliases: Set<String>
    ) -> [SSHConfigEntry] {
        let keyByID = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            key.privateKeyPath.map { (key.id, $0) }
        })
        let serverByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        return authorizations.compactMap { authorization -> SSHConfigEntry? in
            guard authorization.status == .authorized,
                  let server = serverByID[authorization.serverID],
                  !existingAliases.contains(server.alias),
                  let identity = keyByID[authorization.keyID] else { return nil }
            return SSHConfigEntry(
                server: server,
                identityPath: identity.replacingOccurrences(of: paths.home.path, with: "~")
            )
        }
    }

    private func validateExistingManagedConfig(
        state: ManagedConfigDerivationState,
        existingHash: String?
    ) throws {
        guard state.schemaVersion == 1 else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
        switch state.phase {
        case .steady:
            guard existingHash == state.targetContentHash else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
        case .transitioning:
            guard existingHash == state.previousContentHash
                    || existingHash == state.targetContentHash else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
        }
    }

    private func loadDerivationState() throws -> ManagedConfigDerivationState? {
        guard FileManager.default.fileExists(atPath: paths.managedConfigDerivationState.path) else {
            return nil
        }
        do {
            return try HostV6.CanonicalJSON.decode(
                ManagedConfigDerivationState.self,
                from: Data(contentsOf: paths.managedConfigDerivationState)
            )
        } catch {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }

    private func writeDerivationState(_ state: ManagedConfigDerivationState) throws {
        let data = try HostV6.CanonicalJSON.encode(state)
        try atomicWrite(
            String(decoding: data, as: UTF8.self),
            to: paths.managedConfigDerivationState,
            permissions: 0o600,
            backup: false
        )
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
