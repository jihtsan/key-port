import Foundation
import KeyPortCore
import Darwin

enum SSHConfigError: LocalizedError {
    case aliasConflict(String)
    case relayDependencyUnavailable
    case relayConfigurationInvalid

    var errorDescription: String? {
        switch self {
        case .aliasConflict(let alias): "SSH 别名“\(alias)”已存在于 ~/.ssh/config 中。"
        case .relayDependencyUnavailable:
            "连接前回退辅助程序不可用，已停止写入新的回退配置；请在设置中修复辅助程序。"
        case .relayConfigurationInvalid:
            "连接前回退配置无效，已停止写入 SSH 配置。"
        }
    }
}

enum SSHRelayDependencyStatus: Equatable, Sendable {
    case ready
    case repairable
    case missing
    case notExecutable
    case wrongVersion
}

struct SSHRelayDependencyReport: Equatable, Sendable {
    let status: SSHRelayDependencyStatus
    let path: String
    let detail: String

    var isUsable: Bool { status == .ready }
}

enum SSHConfigHealthStatus: Equatable, Sendable {
    case ready
    case empty
    case managedConfigDrifted
    case relayManifestInvalid
    case relayConfigDrifted
    case relayDependency(SSHRelayDependencyStatus)
}

struct SSHConfigHealthReport: Equatable, Sendable {
    let status: SSHConfigHealthStatus
    let detail: String

    var isUsable: Bool {
        switch status {
        case .ready, .empty: true
        case .managedConfigDrifted, .relayManifestInvalid, .relayConfigDrifted, .relayDependency:
            false
        }
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
    private let transportAdapter: SSHTransportAdapter
    private let relayHelperSourcePath: String?
    private let fileManager: FileManager
    private let dependencyExecutor: any ProcessExecuting

    init(
        runner: ProcessRunner = ProcessRunner(),
        paths: KeyPortPaths = KeyPortPaths(),
        transportAdapter: SSHTransportAdapter = SSHTransportAdapter(),
        relayHelperSourcePath: String? = nil,
        fileManager: FileManager = .default,
        dependencyExecutor: (any ProcessExecuting)? = nil
    ) {
        self.runner = runner
        self.paths = paths
        self.transportAdapter = transportAdapter
        self.relayHelperSourcePath = relayHelperSourcePath
        self.fileManager = fileManager
        self.dependencyExecutor = dependencyExecutor ?? ProcessExecutor()
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

    func write(
        servers: [ServerConnection],
        keys: [SSHKeyRecord],
        authorizations: [Authorization],
        transports: [UUID: SSHConnectionTransport] = [:],
        topology: TopologySnapshot? = nil
    ) async throws {
        try paths.prepareDirectories()
        let existing = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let existingAliases = SSHConfigGenerator.aliases(in: existing)
        let relayServers = servers.filter { server in
            authorizations.contains {
                $0.serverID == server.id
                    && $0.status == .authorized
                    && !$0.isDeleted
            }
        }
        let relayManifest = try relayManifest(for: topology, servers: relayServers)
        let relayHelperPath = try await prepareRelayHelperIfNeeded(for: relayManifest)
        let entries = try managedEntries(
            servers: servers,
            keys: keys,
            authorizations: authorizations,
            excludingAliases: existingAliases,
            transports: transports,
            relayManifest: relayManifest,
            relayHelperPath: relayHelperPath
        )
        let managedConfig = SSHConfigGenerator.managedConfig(entries: entries)
        try writeManagedConfigFailingClosed(managedConfig)
        try writeRelayManifest(relayManifest)
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
        authorizations: [Authorization],
        transports: [UUID: SSHConnectionTransport] = [:],
        topology: TopologySnapshot? = nil
    ) async throws -> Bool {
        try paths.prepareDirectories()
        let existingUserConfig = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let relayServers = servers.filter { server in
            authorizations.contains {
                $0.serverID == server.id
                    && $0.status == .authorized
                    && !$0.isDeleted
            }
        }
        let relayManifest = try relayManifest(for: topology, servers: relayServers)
        let relayHelperPath = try await prepareRelayHelperIfNeeded(for: relayManifest)
        let desiredConfig = SSHConfigGenerator.managedConfig(entries: try managedEntries(
            servers: servers,
            keys: keys,
            authorizations: authorizations,
            excludingAliases: SSHConfigGenerator.aliases(in: existingUserConfig),
            transports: transports,
            relayManifest: relayManifest,
            relayHelperPath: relayHelperPath
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
        excludingAliases existingAliases: Set<String>,
        transports: [UUID: SSHConnectionTransport],
        relayManifest: SSHPreconnectRelayManifest,
        relayHelperPath: URL?
    ) throws -> [SSHConfigEntry] {
        let keyByID = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            key.privateKeyPath.map { (key.id, $0) }
        })
        let serverByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        return try authorizations.compactMap { authorization -> SSHConfigEntry? in
            guard authorization.status == .authorized,
                  let server = serverByID[authorization.serverID],
                  !existingAliases.contains(server.alias),
                  let identity = keyByID[authorization.keyID] else { return nil }
            let transport = try transportAdapter.configuration(
                for: transports[server.id] ?? .direct
            )
            let relayProxyCommand = relayManifest.configuration(for: server.id).flatMap { configuration in
                relayHelperPath.map { helperPath in
                    makeRelayProxyCommand(
                        helperPath: helperPath,
                        manifestPath: paths.sshRelayManifest,
                        profileID: configuration.profileID
                    )
                }
            }
            return SSHConfigEntry(
                server: server,
                identityPath: identity.replacingOccurrences(of: paths.home.path, with: "~"),
                proxyCommand: relayProxyCommand ?? transport.proxyCommand
            )
        }
    }

    /// Reports whether the installed helper is executable and answers the
    /// version probe. A repairable source is distinct from a usable target;
    /// callers must not present a repairable dependency as ready.
    func relayDependencyReport() async -> SSHRelayDependencyReport {
        let targetPath = paths.sshRelayHelper.path
        guard fileManager.fileExists(atPath: targetPath) else {
            if let source = relayHelperSourcePath,
               fileManager.isExecutableFile(atPath: source) {
                return SSHRelayDependencyReport(
                    status: .repairable,
                    path: targetPath,
                    detail: "辅助程序尚未安装到 KeyPort SSH 运行目录。"
                )
            }
            return SSHRelayDependencyReport(
                status: .missing,
                path: targetPath,
                detail: "未找到连接前回退辅助程序。"
            )
        }
        guard isOwnedPrivateFile(paths.sshRelayHelper) else {
            return SSHRelayDependencyReport(
                status: .notExecutable,
                path: targetPath,
                detail: "辅助程序不是当前用户拥有的私有可执行文件。"
            )
        }
        guard fileManager.isExecutableFile(atPath: targetPath) else {
            return SSHRelayDependencyReport(
                status: .notExecutable,
                path: targetPath,
                detail: "辅助程序没有可执行权限。"
            )
        }

        let limits = ProcessExecutionLimits(
            timeout: 2,
            maximumStdoutBytes: 4 * 1024,
            maximumStderrBytes: 4 * 1024,
            maximumCombinedOutputBytes: 4 * 1024,
            terminationGrace: 0.25
        )
        let result: ProcessExecutionResult?
        do {
            result = try await dependencyExecutor.execute(ProcessExecutionRequest(
                executable: targetPath,
                arguments: ["--version"],
                limits: limits
            ))
        } catch {
            return SSHRelayDependencyReport(
                status: .wrongVersion,
                path: targetPath,
                detail: "辅助程序无法完成版本探测。"
            )
        }
        guard let result,
              result.succeeded,
              String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == SSHPreconnectRelayRuntime.versionString else {
            return SSHRelayDependencyReport(
                status: .wrongVersion,
                path: targetPath,
                detail: "辅助程序版本或能力不符合当前配置协议。"
            )
        }
        return SSHRelayDependencyReport(status: .ready, path: targetPath, detail: "辅助程序和配置协议可用。")
    }

    /// Copies the bundled helper into the owner-only runtime directory. This
    /// is deliberately limited to KeyPort's own target path and uses an
    /// atomic replacement, so a failed repair cannot leave a partial binary.
    func repairRelayDependency() throws {
        guard let source = relayHelperSourcePath,
              fileManager.isExecutableFile(atPath: source) else {
            throw SSHConfigError.relayDependencyUnavailable
        }
        try paths.prepareDirectories()
        let destination = paths.sshRelayHelper
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: URL(fileURLWithPath: source), to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        guard isOwnedPrivateFile(destination), fileManager.isExecutableFile(atPath: destination.path) else {
            throw SSHConfigError.relayDependencyUnavailable
        }
    }

    func configurationHealth() async -> SSHConfigHealthReport {
        let managedState: ManagedConfigDerivationState?
        do {
            managedState = try loadDerivationState()
        } catch {
            return SSHConfigHealthReport(status: .managedConfigDrifted, detail: "KeyPort SSH 配置校验记录损坏。")
        }
        let hasManagedConfig = fileManager.fileExists(atPath: paths.managedConfig.path)
        guard hasManagedConfig || managedState == nil else {
            return SSHConfigHealthReport(status: .managedConfigDrifted, detail: "KeyPort SSH 配置文件缺失。")
        }
        if let managedState {
            guard let data = try? Data(contentsOf: paths.managedConfig),
                  managedState.phase == .steady,
                  managedState.targetContentHash == HostV6.CanonicalJSON.sha256(data) else {
                return SSHConfigHealthReport(status: .managedConfigDrifted, detail: "KeyPort SSH 配置已被外部修改。")
            }
        }

        guard fileManager.fileExists(atPath: paths.sshRelayManifest.path) else {
            if let config = try? String(contentsOf: paths.managedConfig, encoding: .utf8),
               config.contains(SSHPreconnectRelayRuntime.executableName) {
                return SSHConfigHealthReport(
                    status: .relayManifestInvalid,
                    detail: "SSH 配置引用了缺失的连接前回退清单。"
                )
            }
            return SSHConfigHealthReport(status: hasManagedConfig ? .ready : .empty, detail: "KeyPort SSH 派生配置可用。")
        }
        guard isOwnedPrivateFile(paths.sshRelayManifest),
              let data = try? Data(contentsOf: paths.sshRelayManifest),
              let manifest = try? HostV6.CanonicalJSON.decode(
                  SSHPreconnectRelayManifest.self,
                  from: data
              ),
              (try? manifest.validate()) != nil else {
            return SSHConfigHealthReport(status: .relayManifestInvalid, detail: "连接前回退配置无法通过校验。")
        }
        guard !manifest.configurations.isEmpty else {
            if let config = try? String(contentsOf: paths.managedConfig, encoding: .utf8),
               config.contains(SSHPreconnectRelayRuntime.executableName) {
                return SSHConfigHealthReport(
                    status: .relayConfigDrifted,
                    detail: "SSH 配置仍引用连接前回退 helper，但当前清单为空。"
                )
            }
            return SSHConfigHealthReport(status: hasManagedConfig ? .ready : .empty, detail: "KeyPort SSH 派生配置可用。")
        }
        let dependency = await relayDependencyReport()
        guard dependency.isUsable else {
            return SSHConfigHealthReport(
                status: .relayDependency(dependency.status),
                detail: dependency.detail
            )
        }
        let expectedPath = shellQuote(paths.sshRelayHelper.path)
        guard let config = try? String(contentsOf: paths.managedConfig, encoding: .utf8),
              manifest.configurations.allSatisfy({ configuration in
                  config.contains("--profile-id \(configuration.profileID.uuidString)")
                      && config.contains(expectedPath)
              }) else {
            return SSHConfigHealthReport(status: .relayConfigDrifted, detail: "SSH 配置与连接前回退清单不一致。")
        }
        return SSHConfigHealthReport(status: .ready, detail: "KeyPort SSH 配置和连接前回退辅助程序可用。")
    }

    private func relayManifest(
        for topology: TopologySnapshot?,
        servers: [ServerConnection]
    ) throws -> SSHPreconnectRelayManifest {
        if let topology {
            do {
                return try SSHPreconnectRelayConfigurationBuilder.makeManifest(
                    profiles: topology.activeConnectionProfiles,
                    servers: servers,
                    topology: topology
                )
            } catch is SSHPreconnectRelayConfigurationError {
                throw SSHConfigError.relayConfigurationInvalid
            }
        }
        guard fileManager.fileExists(atPath: paths.sshRelayManifest.path) else {
            return SSHPreconnectRelayManifest(configurations: [])
        }
        guard isOwnedPrivateFile(paths.sshRelayManifest),
              let data = try? Data(contentsOf: paths.sshRelayManifest),
              let manifest = try? HostV6.CanonicalJSON.decode(
                  SSHPreconnectRelayManifest.self,
                  from: data
              ),
              (try? manifest.validate()) != nil else {
            throw SSHConfigError.relayConfigurationInvalid
        }
        return manifest
    }

    private func prepareRelayHelperIfNeeded(
        for manifest: SSHPreconnectRelayManifest
    ) async throws -> URL? {
        guard !manifest.configurations.isEmpty else { return nil }
        let target = paths.sshRelayHelper
        if isOwnedPrivateFile(target), fileManager.isExecutableFile(atPath: target.path) {
            let dependency = await relayDependencyReport()
            if dependency.isUsable { return target }
        }
        guard let source = relayHelperSourcePath,
              fileManager.isExecutableFile(atPath: source) else {
            throw SSHConfigError.relayDependencyUnavailable
        }
        try repairRelayDependency()
        guard isOwnedPrivateFile(target), fileManager.isExecutableFile(atPath: target.path) else {
            throw SSHConfigError.relayDependencyUnavailable
        }
        guard (await relayDependencyReport()).isUsable else {
            throw SSHConfigError.relayDependencyUnavailable
        }
        return target
    }

    private func writeRelayManifest(_ manifest: SSHPreconnectRelayManifest) throws {
        let data = try HostV6.CanonicalJSON.encode(manifest)
        try atomicWrite(
            String(decoding: data, as: UTF8.self),
            to: paths.sshRelayManifest,
            permissions: 0o600,
            backup: true
        )
    }

    private func makeRelayProxyCommand(
        helperPath: URL,
        manifestPath: URL,
        profileID: UUID
    ) -> String {
        "\(shellQuote(helperPath.path)) --config \(shellQuote(manifestPath.path)) --profile-id \(profileID.uuidString) --forward-host %h --forward-port %p"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        let manager = fileManager
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

    private func isOwnedPrivateFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            return false
        }
        return (info.st_mode & 0o077) == 0
    }
}
