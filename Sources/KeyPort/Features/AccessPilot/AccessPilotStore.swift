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
    }
    let paths: KeyPortPaths
    let workspace: AccessWorkspace
    private(set) var state: State
    private let lockFD: Int32
    private var stateURL: URL { paths.applicationSupport.appendingPathComponent("access-pilot-v1.json") }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KeyPort/AccessPilot")) throws {
        paths = KeyPortPaths(home: home)
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
            workspace = AccessWorkspace(snapshot: Self.snapshot(state), isSimulation: false)
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
    func command(for connection: Connection) throws -> String {
        let config = try writeConfiguration(for: connection)
        return "/usr/bin/ssh -F \(Self.shellQuote(config.path)) \(Self.shellQuote(connection.alias))"
    }
    /// Each saved path owns a config: a selected edge must never silently use another address.
    func writeConfiguration(for connection: Connection) throws -> URL {
        guard UUID(uuidString: connection.id) != nil, (1...65535).contains(connection.port),
              let key = state.keys.first(where: { $0.id == connection.keyID }), let privatePath = key.privateKeyPath,
              AliasDirectory.isValidNewAlias(connection.alias), Self.safeConfigValue(connection.address),
              Self.safeConfigValue(connection.account), Self.safeConfigValue(privatePath),
              Self.safeConfigValue(paths.knownHosts.path) else { throw AccessPilotError.configuration }
        let config = paths.keyPortDirectory.appendingPathComponent("path-\(connection.id).conf")
        let text = """
        Host \(connection.alias)
            HostName "\(connection.address)"
            Port \(connection.port)
            User "\(connection.account)"
            IdentityFile "\(privatePath)"
            UserKnownHostsFile "\(paths.knownHosts.path)"
            GlobalKnownHostsFile /dev/null
            StrictHostKeyChecking yes
            HostKeyAlgorithms ssh-ed25519
            IdentitiesOnly yes
            IdentityAgent none
            PreferredAuthentications publickey
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            ControlMaster no
            ControlPath none
            ClearAllForwardings yes
            ForwardAgent no
            ConnectTimeout 5
            ConnectionAttempts 1

        """
        try write(Data(text.utf8), to: config)
        return config
    }
    static func safeConfigValue(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { $0.isNewline || $0 == "\"" || $0 == "\\" || $0 == "%" || $0 == "\0" }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func commit(_ next: State) throws {
        // Trust metadata is authoritative; regenerate known_hosts before any subsequent SSH request.
        try write(try JSONEncoder().encode(next), to: stateURL)
        state = next
        let lines = Set(next.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n"
        try write(Data(lines.utf8), to: paths.knownHosts)
        workspace.replaceSnapshot(Self.snapshot(next))
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func authorizationID(_ server: String, _ account: String, _ key: String) -> String { "\(server)|\(account)|\(key)" }
    private static func snapshot(_ state: State) -> AccessWorkspaceSnapshot {
        var seen = Set<String>()
        let servers = state.connections.filter { seen.insert($0.serverID).inserted }.map { ServerNaming(id: $0.serverID, alias: $0.alias, description: $0.description) }
        let paths = state.connections.map { ConfiguredAccessPath(id: $0.id, deviceID: state.deviceID, serverID: $0.serverID, account: $0.account, address: $0.address, port: $0.port,
            verification: $0.verification == "verified" ? .verified : $0.verification == "failed" ? .failed : .pending,
            reachability: $0.reachability == "reachable" ? .reachable : $0.reachability == "unreachable" ? .unreachable : .unknown, checkedAt: $0.checkedAt) }
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
