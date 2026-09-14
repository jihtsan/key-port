import Foundation
import Darwin
import KeyPortCore
import KeyPortInterface

/// Local acceptance workspace. This is not a new synced authority or a migration of v6.
@MainActor final class AccessPilotStore {
    struct Trust: Codable {
        var serverID: String
        var address: String
        var port: Int
        var key: HostKeyRecord
    }
    struct Connection: Codable {
        var id: String
        var serverID: String
        var alias: String
        var description: String
        var address: String
        var port: Int
        var account: String
        var keyID: String
        var verification = "pending"
        var reachability = "unknown"
        var checkedAt: Date?
    }
    struct State: Codable {
        var version = 1
        var deviceID = UUID().uuidString
        var keys: [SSHKeyRecord] = []
        var trusts: [Trust] = []
        var connections: [Connection] = []
        var authorizations: [String: String] = [:]
        var defaultPaths: [String: String]? = nil
    }
    let paths: KeyPortPaths
    let installation: SSHConfigService.AliasInstallation
    let workspace: AccessWorkspace
    private(set) var state: State
    private let lockFD: Int32
    private var stateURL: URL { paths.applicationSupport.appendingPathComponent("access-pilot-v1.json") }

    init(home: URL? = nil, userHome: URL? = nil) throws {
        paths = KeyPortPaths(home: home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeyPort/AccessPilot"))
        installation = .init(home: userHome ?? home ?? FileManager.default.homeDirectoryForCurrentUser)
        try paths.prepareDirectories()
        let lockURL = paths.applicationSupport.appendingPathComponent("access-pilot.lock")
        lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw AccessPilotError.storage }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lockFD); throw AccessPilotError.alreadyOpen }
        do {
            let url = paths.applicationSupport.appendingPathComponent("access-pilot-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
                guard state.version == 1 else { throw AccessPilotError.storage }
            } else { state = State() }
            if state.defaultPaths == nil {
                state.defaultPaths = [:]
                for connection in state.connections where state.defaultPaths?[connection.serverID] == nil {
                    state.defaultPaths?[connection.serverID] = connection.id
                }
            }
            workspace = AccessWorkspace(snapshot: Self.snapshot(state, configDirectory: paths.keyPortDirectory), isSimulation: false)
        } catch { Darwin.close(lockFD); throw error }
    }
    deinit { Darwin.close(lockFD) }

    var aliases: AliasDirectory {
        .init(entries: state.connections.map { .init(alias: $0.alias, source: .managed, ownerID: $0.serverID) })
    }
    func addKey(_ key: SSHKeyRecord) throws {
        var next = state; next.keys.removeAll { $0.id == key.id }; next.keys.append(key); try commit(next)
    }
    func trust(_ trust: Trust) throws {
        var next = state
        next.trusts.removeAll { $0.address == trust.address && $0.port == trust.port }
        next.trusts.append(trust)
        try commit(next)
    }
    func save(draft: AccessFormDraft, serverID: String, key: SSHKeyRecord) throws -> String {
        guard aliases.validationMessage(for: draft.alias, editingEntryID: serverID) == nil else { throw AccessPilotError.aliasConflict }
        try installation.validateAlias(draft.alias)
        var next = state
        // A new address remains a separate path; editing display metadata never creates another node.
        let existing = next.connections.first { $0.serverID == serverID && $0.account == draft.account && $0.address == draft.address && $0.port == Int(draft.port) }
        let connection = Connection(id: existing?.id ?? UUID().uuidString, serverID: serverID,
            alias: draft.alias, description: draft.description, address: draft.address, port: Int(draft.port)!, account: draft.account, keyID: key.id)
        next.connections.removeAll { $0.id == connection.id }
        for i in next.connections.indices where next.connections[i].serverID == serverID {
            next.connections[i].alias = draft.alias; next.connections[i].description = draft.description
        }
        next.connections.append(connection)
        if next.defaultPaths?[serverID] == nil { next.defaultPaths?[serverID] = connection.id }
        try commit(next); workspace.select(.path(connection.id)); return connection.id
    }
    func record(_ status: AccessAuthorizationStatus, serverID: String, account: String, keyID: String) throws {
        var next = state
        next.authorizations[Self.authorizationID(serverID, account, keyID)] = status == .installed ? "installed" : status == .absent ? "absent" : "unknown"
        try commit(next)
    }
    func checked(_ id: String, success: Bool, unreachable: Bool = false) throws {
        var next = state
        guard let index = next.connections.firstIndex(where: { $0.id == id }) else { throw AccessPilotError.storage }
        next.connections[index].verification = success ? "verified" : "failed"
        next.connections[index].reachability = unreachable ? "unreachable" : success ? "reachable" : "unknown"
        next.connections[index].checkedAt = Date()
        try commit(next)
    }
    func isDefault(_ connection: Connection) -> Bool { state.defaultPaths?[connection.serverID] == connection.id }
    func synchronizeAliases() throws {
        try export(state)
        try cleanPathConfigurations()
        for connection in state.connections where connection.verification == "verified" { _ = try writeConfiguration(for: connection) }
    }
    func setDefault(_ id: String) throws {
        guard let connection = state.connections.first(where: { $0.id == id }), connection.verification == "verified" else { throw AccessPilotError.configuration }
        var next = state; next.defaultPaths?[connection.serverID] = id; try commit(next)
        try synchronizeAliases()
    }
    func rename(serverID: String, alias: String) throws {
        guard AliasDirectory.isValidNewAlias(alias), aliases.validationMessage(for: alias, editingEntryID: serverID) == nil else { throw AccessPilotError.aliasConflict }
        var next = state
        for i in next.connections.indices where next.connections[i].serverID == serverID { next.connections[i].alias = alias }
        try commit(next)
        try synchronizeAliases()
    }
    func remove(_ id: String) throws {
        var next = state
        guard let connection = next.connections.first(where: { $0.id == id }) else { return }
        next.connections.removeAll { $0.id == id }
        // Never silently move the short alias to a different endpoint after deletion.
        if next.defaultPaths?[connection.serverID] == id { next.defaultPaths?.removeValue(forKey: connection.serverID) }
        try commit(next)
        try synchronizeAliases()
    }
    private func cleanPathConfigurations() throws {
        for url in try FileManager.default.contentsOfDirectory(at: paths.keyPortDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("path-") && url.pathExtension == "conf" {
            let id = String(url.deletingPathExtension().lastPathComponent.dropFirst(5))
            if UUID(uuidString: id) != nil, !state.connections.contains(where: { $0.id == id && $0.verification == "verified" }) {
                let backup = paths.keyPortDirectory.appendingPathComponent("retired-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try FileManager.default.moveItem(at: url, to: backup.appendingPathComponent(url.lastPathComponent))
            }
        }
    }
    func command(for connection: Connection) throws -> String {
        guard let current = state.connections.first(where: { $0.id == connection.id }), current.verification == "verified" else { throw AccessPilotError.configuration }
        try synchronizeAliases()
        if isDefault(current) { return "ssh " + current.alias }
        let config = try writeConfiguration(for: current)
        return "/usr/bin/ssh -F \(Self.shellQuote(config.path)) \(Self.shellQuote(current.alias))"
    }
    private func entry(_ connection: Connection, state: State) throws -> SSHConfigEntry {
        guard UUID(uuidString: connection.id) != nil,
              let key = state.keys.first(where: { $0.id == connection.keyID }), let privatePath = key.privateKeyPath else { throw AccessPilotError.configuration }
        return SSHConfigEntry(server: ServerConnection(name: connection.description, host: connection.address,
            port: connection.port, username: connection.account, alias: connection.alias), identityPath: privatePath)
    }
    private func export(_ value: State) throws {
        let connections = value.connections.filter { value.defaultPaths?[$0.serverID] == $0.id && $0.verification == "verified" }
        let entries = try connections.map { try entry($0, state: value) }
        try installation.install(entries: entries, knownHosts: paths.knownHosts)
    }
    /// A selected nondefault edge always uses its own explicit configuration.
    func writeConfiguration(for connection: Connection) throws -> URL {
        let config = paths.keyPortDirectory.appendingPathComponent("path-\(connection.id).conf")
        let text = try SSHConfigGenerator.directConfig(entries: [entry(connection, state: state)], knownHostsPath: paths.knownHosts.path)
        try write(Data(text.utf8), to: config)
        return config
    }
    static func safeConfigValue(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { $0.isNewline || $0 == "\"" || $0 == "\\" || $0 == "%" || $0 == "\0" }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func commit(_ next: State) throws {
        let old = state
        do {
            let lines = Set(next.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n"
            try write(Data(lines.utf8), to: paths.knownHosts)
            try export(next)
            try write(try JSONEncoder().encode(next), to: stateURL)
        } catch {
            // Keep saved facts and derived configuration aligned on ordinary write failures.
            let lines = Set(old.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n"
            try write(Data(lines.utf8), to: paths.knownHosts)
            try export(old)
            throw error
        }
        state = next
        workspace.replaceSnapshot(Self.snapshot(next, configDirectory: paths.keyPortDirectory))
    }
    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            if existing == data { return }
            if url == stateURL {
                let backup = paths.applicationSupport.appendingPathComponent("access-pilot-backup-" + UUID().uuidString + ".json")
                try existing.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func authorizationID(_ server: String, _ account: String, _ key: String) -> String { "\(server)|\(account)|\(key)" }
    private static func snapshot(_ state: State, configDirectory: URL) -> AccessWorkspaceSnapshot {
        var seen = Set<String>()
        let servers = state.connections.filter { seen.insert($0.serverID).inserted }.map { ServerNaming(id: $0.serverID, alias: $0.alias, description: $0.description) }
        let paths = state.connections.map { ConfiguredAccessPath(id: $0.id, deviceID: state.deviceID, serverID: $0.serverID, account: $0.account, address: $0.address, port: $0.port,
            verification: $0.verification == "verified" ? .verified : $0.verification == "failed" ? .failed : .pending,
            reachability: $0.reachability == "reachable" ? .reachable : $0.reachability == "unreachable" ? .unreachable : .unknown, checkedAt: $0.checkedAt,
            terminalCommand: $0.verification != "verified" ? nil : state.defaultPaths?[$0.serverID] == $0.id ? "ssh " + $0.alias : "/usr/bin/ssh -F " + shellQuote(configDirectory.appendingPathComponent("path-\($0.id).conf").path) + " " + shellQuote($0.alias),
            isDefaultConnection: state.defaultPaths?[$0.serverID] == $0.id) }
        var authorizations: [AccessAuthorizationKey: AccessAuthorizationStatus] = [:]
        for connection in state.connections {
            let status = state.authorizations[authorizationID(connection.serverID, connection.account, connection.keyID)]
            let account = AccessAuthorizationKey(deviceID: state.deviceID, serverID: connection.serverID, account: connection.account)
            let value: AccessAuthorizationStatus = status == "installed" ? .installed : status == "absent" ? .absent : .unknown
            if authorizations[account] == .installed || value == .installed { authorizations[account] = .installed }
            else if authorizations[account] == .unknown || value == .unknown { authorizations[account] = .unknown }
            else { authorizations[account] = .absent }
        }
        return .init(deviceID: state.deviceID, servers: servers, configuredPaths: paths, authorizations: authorizations)
    }
}

enum AccessPilotError: Error {
    case storage, alreadyOpen, aliasConflict, configuration, missingKey, terminal
}
