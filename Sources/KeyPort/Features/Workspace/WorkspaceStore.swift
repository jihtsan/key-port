import Foundation
import Darwin
import KeyPortCore
import KeyPortInterface
import Observation

/// The only writable workspace authority. UI and SSH inputs are read-only projections.
@MainActor @Observable final class WorkspaceStore {
    struct Document: Codable {
        var version = 1
        var deviceID: String
        var topology: TopologySnapshot
        var defaultPaths: [String: String] = [:]
        var pathKeys: [String: String] = [:]
    }
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
    let installation: ManagedAliasInstallation
    let workspace: AccessWorkspace
    private(set) var document: Document
    private let lockFD: Int32
    private let cloud: any CloudSyncing
    private(set) var syncEnabled = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    private var revision = 0
    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "KeyPort.cloudSyncEnabled")
        if enabled { scheduleSync() } else { syncTask?.cancel(); syncState = .disabled }
    }
    private func scheduleSync() {
        guard syncEnabled, syncState != .syncing else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.synchronize(automatically: true)
        }
    }
    private(set) var syncState: CloudSyncState = .disabled
    private(set) var syncUnavailable: CloudSyncError?
    private(set) var checkingSyncAvailability = false
    func checkSyncAvailability() async {
        guard !checkingSyncAvailability else { return }
        checkingSyncAvailability = true
        defer { checkingSyncAvailability = false }
        switch await cloud.availability() {
        case .available:
            syncUnavailable = nil
            switch syncState {
            case .adHocSigned, .cloudKitDisabled, .signedOut: syncState = .disabled
            default: break
            }
        case .unavailable(let error): syncUnavailable = error
        }
    }
    var topology: TopologySnapshot { document.topology }
    private var stateURL: URL { paths.applicationSupport.appendingPathComponent("workspace-v1.json") }

    init(home: URL? = nil, userHome: URL? = nil, cloud: any CloudSyncing = CloudKitSyncService(), deviceID: String? = nil) throws {
        paths = KeyPortPaths(home: home ?? FileManager.default.homeDirectoryForCurrentUser)
        installation = .init(home: userHome ?? home ?? FileManager.default.homeDirectoryForCurrentUser)
        self.cloud = cloud
        try paths.prepareDirectories()
        lockFD = Darwin.open(paths.applicationSupport.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw WorkspaceError.storage }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lockFD); throw WorkspaceError.alreadyOpen }
        do {
            let url = paths.applicationSupport.appendingPathComponent("workspace-v1.json")
            let loaded: Document
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = try Self.decoder().decode(Document.self, from: Data(contentsOf: url))
                try Self.validate(loaded)
            } else {
                loaded = try WorkspaceMigration.load(paths: paths, deviceID: deviceID)
                try Self.validate(loaded)
                let data = try Self.encoder().encode(loaded)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            document = loaded
            workspace = AccessWorkspace(snapshot: Self.snapshot(Self.project(loaded), configDirectory: paths.keyPortDirectory, nodes: loaded.topology.nodes), isSimulation: false)
        } catch { Darwin.close(lockFD); throw error }
    }
    deinit { Darwin.close(lockFD) }
    static func validate(_ document: Document) throws {
        let t = document.topology
        func unique<T: Hashable>(_ ids: [T]) -> Bool { Set(ids).count == ids.count }
        guard document.version == 1, t.schemaVersion == TopologySnapshot.currentSchemaVersion,
              unique(t.nodes.map(\.id)), unique(t.profiles.map(\.id)), unique(t.endpoints.map(\.id)),
              unique(t.services.map(\.id)), unique(t.sshAccounts.map(\.id)), unique(t.sshConnectionProfiles.map(\.id)),
              unique(t.sshKeys.map(\.id)), unique(t.hostKeyTrusts.map(\.id)), unique(t.authorizations.map(\.id)) else { throw WorkspaceError.storage }
    }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    var state: State { Self.project(document) }
    var aliases: AliasDirectory { .init(entries: state.connections.map { .init(alias: $0.alias, source: .managed, ownerID: $0.serverID) }) }

    static func project(_ document: Document) -> State {
        let t = document.topology
        var result = State(); result.deviceID = document.deviceID; result.defaultPaths = document.defaultPaths
        result.keys = t.sshKeys.map { .init(id: $0.id, deviceID: $0.deviceID, kind: $0.kind, publicKey: $0.publicKey, fingerprint: $0.fingerprint, privateKeyPath: $0.privateKeyPath, isInAgent: $0.isInAgent, origin: $0.origin, isLocallyAvailable: $0.isLocallyAvailable) }
        for trust in t.hostKeyTrusts where !trust.isDeleted && trust.state == .confirmed {
            guard let e = t.activeEndpoints.first(where: { $0.id == trust.endpointID }) else { continue }
            result.trusts.append(.init(serverID: e.nodeID.uuidString, address: e.address, port: Int(e.port), key: .init(algorithm: trust.algorithm, fingerprint: trust.fingerprint, knownHostsLine: trust.knownHostsLine)))
        }
        for p in t.activeConnectionProfiles {
            guard let a = t.activeAccounts.first(where: { $0.id == p.accountID }), let n = t.nodes.first(where: { $0.id == a.nodeID && !$0.isDeleted }) else { continue }
            // Automatic routes remain stored intact; the UI exposes their explicitly selected first candidate.
            let endpointID = p.routePolicy.fixedEndpointID ?? p.candidateEndpointIDs.first
            guard let e = t.activeEndpoints.first(where: { $0.id == endpointID && $0.nodeID == n.id && $0.protocol == .ssh }) else { continue }
            let id = p.id.uuidString
            let localKey = t.sshKeys.first { $0.id == document.pathKeys[id] && $0.deviceID == document.deviceID && $0.privateKeyPath != nil }
                ?? t.sshKeys.first { k in k.deviceID == document.deviceID && k.privateKeyPath != nil && t.authorizations.contains { $0.accountID == a.id && $0.keyID == k.id && !$0.isDeleted && $0.remoteState == .authorized } }
                ?? t.sshKeys.first { $0.deviceID == document.deviceID && $0.privateKeyPath != nil }
            let v = t.accessVerifications.first { $0.profileID == p.id && $0.endpointID == e.id && $0.deviceID == document.deviceID }
            let r = t.reachabilityObservations.first { $0.endpointID == e.id && $0.observerDeviceID == document.deviceID }
            result.connections.append(.init(id: id, serverID: n.id.uuidString, alias: p.sshAlias, description: n.name, address: e.address, port: Int(e.port), account: a.username, keyID: localKey?.id ?? "", verification: localKey != nil && v?.status == .authorized ? "verified" : v == nil ? "pending" : "failed", reachability: r.map { $0.wasReachable ? "reachable" : "unreachable" } ?? "unknown", checkedAt: v?.lastCheckedAt))
            for auth in t.authorizations where auth.accountID == a.id && !auth.isDeleted && auth.relationState == .active {
                result.authorizations[authorizationID(n.id.uuidString, a.username, auth.keyID)] = auth.remoteState == .authorized ? "installed" : auth.remoteState == .revoked ? "absent" : "unknown"
            }
        }
        return result
    }
    func addKey(_ key: SSHKeyRecord) throws {
        var next = document
        next.topology.sshKeys.removeAll { $0.id == key.id }
        next.topology.sshKeys.append(.init(id: key.id, deviceID: key.deviceID, kind: key.kind, publicKey: key.publicKey, fingerprint: key.fingerprint, privateKeyPath: key.privateKeyPath, isInAgent: key.isInAgent, origin: key.origin, isLocallyAvailable: key.isLocallyAvailable))
        try commit(next)
    }
    static func ensureEndpoint(_ trust: Trust, in t: inout TopologySnapshot) throws -> UUID {
        guard let nodeID = UUID(uuidString: trust.serverID), let port = UInt16(exactly: trust.port) else { throw WorkspaceError.storage }
        if !t.nodes.contains(where: { $0.id == nodeID }) { t.nodes.append(.init(id: nodeID, name: "", roles: [.sshHost])) }
        if let e = t.activeEndpoints.first(where: { $0.nodeID == nodeID && $0.address == trust.address && $0.port == port && $0.protocol == .ssh }) { return e.id }
        let id = UUID(); t.endpoints.append(.init(id: id, nodeID: nodeID, address: trust.address, port: port, protocol: .ssh)); return id
    }
    func trust(_ trust: Trust) throws {
        var next = document
        let id = try Self.ensureEndpoint(trust, in: &next.topology)
        let previous = next.topology.hostKeyTrusts.first { $0.endpointID == id && $0.algorithm == trust.key.algorithm && $0.fingerprint == trust.key.fingerprint }
        next.topology.hostKeyTrusts.removeAll { $0.endpointID == id && $0.algorithm == trust.key.algorithm }
        next.topology.hostKeyTrusts.append(.init(id: previous?.id ?? TopologyStableID.hostKeyTrust(endpointID: id, algorithm: trust.key.algorithm, fingerprint: trust.key.fingerprint), endpointID: id, algorithm: trust.key.algorithm, fingerprint: trust.key.fingerprint, knownHostsLine: trust.key.knownHostsLine, firstConfirmedAt: previous?.firstConfirmedAt ?? Date()))
        try commit(next)
    }
    func save(draft: AccessFormDraft, serverID: String, key: SSHKeyRecord) throws -> String {
        guard AccessFormDraft.isValidHost(draft.address), !draft.account.isEmpty, draft.account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }), aliases.validationMessage(for: draft.alias, editingEntryID: serverID) == nil,
              let nodeID = UUID(uuidString: serverID), let port = UInt16(draft.port), port > 0 else { throw WorkspaceError.configuration }
        try installation.validateAlias(draft.alias)
        var next = document
        if !next.topology.nodes.contains(where: { $0.id == nodeID }) { next.topology.nodes.append(.init(id: nodeID, name: draft.description, roles: [.sshHost])) }
        guard let index = next.topology.nodes.firstIndex(where: { $0.id == nodeID && !$0.isDeleted }) else { throw WorkspaceError.storage }
        let endpoint = next.topology.activeEndpoints.first(where: { $0.nodeID == nodeID && $0.address == draft.address && $0.port == port && $0.protocol == .ssh })
            ?? Endpoint(id: UUID(), nodeID: nodeID, address: draft.address, port: port, protocol: .ssh)
        if !next.topology.endpoints.contains(where: { $0.id == endpoint.id }) { next.topology.endpoints.append(endpoint) }
        next.topology.nodes[index].name = draft.description; next.topology.nodes[index].updatedAt = Date()
        let account = next.topology.activeAccounts.first { $0.nodeID == nodeID && $0.username == draft.account }
            ?? SSHAccount(id: UUID(), nodeID: nodeID, username: draft.account)
        if !next.topology.sshAccounts.contains(where: { $0.id == account.id }) { next.topology.sshAccounts.append(account) }
        let existing = next.topology.activeConnectionProfiles.first { $0.accountID == account.id && $0.routePolicy.fixedEndpointID == endpoint.id }
        let id = existing?.id ?? UUID()
        next.topology.sshConnectionProfiles.removeAll { $0.id == id }
        next.topology.sshConnectionProfiles.append(.init(id: id, accountID: account.id, sshAlias: draft.alias, routePolicy: .fixed(endpointID: endpoint.id), createdAt: existing?.createdAt ?? Date(), updatedAt: Date(), version: (existing?.version ?? 0) + 1))
        next.pathKeys[id.uuidString] = key.id
        if next.defaultPaths[serverID] == nil { next.defaultPaths[serverID] = id.uuidString }
        next.topology.accessVerifications.removeAll { $0.profileID == id && $0.deviceID == state.deviceID }
        try commit(next); workspace.select(.path(id.uuidString)); return id.uuidString
    }
    func record(_ status: AccessAuthorizationStatus, serverID: String, account: String, keyID: String) throws {
        var next = document
        guard let a = next.topology.activeAccounts.first(where: { $0.nodeID.uuidString == serverID && $0.username == account }),
              let key = next.topology.sshKeys.first(where: { $0.id == keyID }) else { throw WorkspaceError.storage }
        next.topology.authorizations.removeAll { $0.accountID == a.id && $0.fingerprint == key.fingerprint }
        next.topology.authorizations.append(.init(accountID: a.id, keyID: key.id, fingerprint: key.fingerprint, remoteComment: "", remoteState: status == .installed ? .authorized : status == .absent ? .revoked : .unknown, updatedAt: Date()))
        if status != .installed {
            next.topology.accessVerifications.removeAll { $0.accountID == a.id && $0.deviceID == state.deviceID }
        }
        try commit(next)
    }
    func checked(_ id: String, success: Bool, unreachable: Bool = false) throws {
        var next = document
        guard let p = next.topology.activeConnectionProfiles.first(where: { $0.id.uuidString == id }), let e = p.routePolicy.fixedEndpointID else { throw WorkspaceError.storage }
        next.topology.accessVerifications.removeAll { $0.profileID == p.id && $0.deviceID == state.deviceID }
        next.topology.accessVerifications.append(.init(accountID: p.accountID, deviceID: state.deviceID, profileID: p.id, endpointID: e, status: success ? .authorized : .keyAuthenticationFailed, lastCheckedAt: Date()))
        next.topology.reachabilityObservations.removeAll { $0.endpointID == e && $0.observerDeviceID == state.deviceID }
        if success || unreachable { next.topology.reachabilityObservations.append(.init(endpointID: e, observerDeviceID: state.deviceID, networkEpoch: 0, observedAt: Date(), wasReachable: success)) }
        try commit(next)
    }
    func isDefault(_ connection: Connection) -> Bool { document.defaultPaths[connection.serverID] == connection.id }
    func synchronizeAliases() throws {
        try write(Data((Set(state.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n").utf8), to: paths.knownHosts)
        try export(state); try cleanPathConfigurations()
        for c in state.connections where c.verification == "verified" { _ = try writeConfiguration(for: c) }
    }
    func setDefault(_ id: String) throws {
        guard let c = state.connections.first(where: { $0.id == id }), c.verification == "verified" else { throw WorkspaceError.configuration }
        var next = document; next.defaultPaths[c.serverID] = id; try commit(next); try synchronizeAliases()
    }
    func rename(serverID: String, alias: String, replacingAlias: String? = nil) throws {
        guard AliasDirectory.isValidNewAlias(alias), aliases.validationMessage(for: alias, editingEntryID: serverID) == nil else { throw WorkspaceError.aliasConflict }
        try installation.validateAlias(alias)
        var next = document
        let ids = Set(next.topology.activeAccounts.filter { $0.nodeID.uuidString == serverID }.map(\.id))
        for i in next.topology.sshConnectionProfiles.indices where ids.contains(next.topology.sshConnectionProfiles[i].accountID) && (replacingAlias == nil || next.topology.sshConnectionProfiles[i].sshAlias == replacingAlias) {
            next.topology.sshConnectionProfiles[i].sshAlias = alias
            next.topology.sshConnectionProfiles[i].updatedAt = Date(); next.topology.sshConnectionProfiles[i].version += 1
        }
        try commit(next); try synchronizeAliases()
    }
    func remove(_ id: String) throws {
        var next = document
        guard let i = next.topology.sshConnectionProfiles.firstIndex(where: { $0.id.uuidString == id }) else { return }
        next.topology.sshConnectionProfiles[i].isDeleted = true; next.topology.sshConnectionProfiles[i].updatedAt = Date(); next.topology.sshConnectionProfiles[i].version += 1
        next.defaultPaths = next.defaultPaths.filter { $0.value != id }; next.pathKeys.removeValue(forKey: id)
        try commit(next); try synchronizeAliases()
    }
    func renameDevice(_ id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkspaceError.configuration }
        var next = document
        guard let i = next.topology.profiles.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.storage }
        next.topology.profiles[i].name = name; next.topology.profiles[i].modifiedAt = Date()
        try commit(next)
    }
    func synchronize(automatically: Bool = false) async {
        guard !automatically || syncEnabled else { return }
        guard syncState != .syncing else { return }
        syncState = .syncing
        let sentRevision = revision
        do {
            let sent = topology
            let merged = try await cloud.synchronize(sent)
            if automatically && !syncEnabled { syncState = .disabled; return }
            // A local SSH operation may have completed while CloudKit was suspended.
            var next = document
            next.topology = TopologyCloudMetadataSnapshotPolicy.restoringLocalState(in: TopologyCloudMetadataSnapshotPolicy.merge(local: topology, remote: merged), from: topology)
            let localChanged = sentRevision != revision
            try commit(next, scheduleSync: false); syncState = .succeeded(Date())
            if localChanged { scheduleSync() }
        } catch let error as CloudSyncError {
            if automatically && !syncEnabled { syncState = .disabled; return }
            switch error {
            case .adHocSignature: syncState = .adHocSigned
            case .missingEntitlement: syncState = .cloudKitDisabled
            case .accountUnavailable: syncState = .signedOut
            default: syncState = .failed(error.localizedDescription)
            }
        } catch { syncState = .failed(error.localizedDescription) }
    }
    func importMetadata(_ imported: TopologySnapshot) throws {
        var next = document
        next.topology = TopologyCloudMetadataSnapshotPolicy.restoringLocalState(in: TopologyCloudMetadataSnapshotPolicy.merge(local: topology, remote: imported), from: topology)
        try commit(next)
    }
    private func commit(_ next: Document, scheduleSync shouldSchedule: Bool = true) throws {
        try Self.validate(next)
        // Persist authority first. Derived SSH files can always be rebuilt on retry.
        try write(try Self.encoder().encode(next), to: stateURL)
        document = next
        revision += 1
        if shouldSchedule { scheduleSync() }
        workspace.replaceSnapshot(Self.snapshot(state, configDirectory: paths.keyPortDirectory, nodes: topology.nodes))
        let lines = Set(state.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n"
        try write(Data(lines.utf8), to: paths.knownHosts)
        try export(state)
    }
    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            if old == data { return }
            if url == stateURL {
                let backup = paths.applicationSupport.appendingPathComponent("workspace-backup-\(UUID().uuidString).json")
                try old.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func authorizationID(_ server: String, _ account: String, _ key: String) -> String { "\(server)|\(account)|\(key)" }
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
        guard let current = state.connections.first(where: { $0.id == connection.id }), current.verification == "verified" else { throw WorkspaceError.configuration }
        try synchronizeAliases()
        if isDefault(current) { return "ssh " + current.alias }
        let config = try writeConfiguration(for: current)
        return "/usr/bin/ssh -F \(Self.shellQuote(config.path)) \(Self.shellQuote(current.alias))"
    }
    private func entry(_ connection: Connection, state: State) throws -> SSHConfigEntry {
        guard UUID(uuidString: connection.id) != nil,
              let key = state.keys.first(where: { $0.id == connection.keyID }), let privatePath = key.privateKeyPath else { throw WorkspaceError.configuration }
        return SSHConfigEntry(server: ServerConnection(name: connection.description, host: connection.address,
            port: connection.port, username: connection.account, alias: connection.alias), identityPath: privatePath)
    }
    private func export(_ value: State) throws {
        let connections = value.connections.filter { value.defaultPaths?[$0.serverID] == $0.id && $0.verification == "verified" }
        let entries = try connections.map { try entry($0, state: value) }
        try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: Set(topology.sshConnectionProfiles.map { $0.sshAlias.lowercased() })) {
            try installation.install(entries: entries, knownHosts: paths.knownHosts)
        }
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
    private static func snapshot(_ state: State, configDirectory: URL, nodes: [Node]) -> AccessWorkspaceSnapshot {
        var seen = Set<String>()
        var servers = state.connections.filter { seen.insert($0.serverID).inserted }.map { ServerNaming(id: $0.serverID, alias: $0.alias, description: $0.description) }
        for node in nodes where !node.isDeleted && node.roles.contains(.sshHost) && !seen.contains(node.id.uuidString) {
            servers.append(.init(id: node.id.uuidString, alias: "server-" + node.id.uuidString.prefix(8).lowercased(), description: node.name))
        }
        let paths = state.connections.map { ConfiguredAccessPath(id: $0.id, deviceID: state.deviceID, serverID: $0.serverID, account: $0.account, address: $0.address, port: $0.port,
            verification: $0.verification == "verified" ? .verified : $0.verification == "failed" ? .failed : .pending,
            reachability: $0.reachability == "reachable" ? .reachable : $0.reachability == "unreachable" ? .unreachable : .unknown, checkedAt: $0.checkedAt,
            terminalCommand: $0.verification != "verified" ? nil : state.defaultPaths?[$0.serverID] == $0.id ? "ssh " + $0.alias : "/usr/bin/ssh -F " + shellQuote(configDirectory.appendingPathComponent("path-\($0.id).conf").path) + " " + shellQuote($0.alias),
            isDefaultConnection: state.defaultPaths?[$0.serverID] == $0.id, sshAlias: $0.alias) }
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

enum WorkspaceError: LocalizedError {
    case storage, alreadyOpen, aliasConflict, configuration, missingKey, terminal
    var errorDescription: String? {
        switch self {
        case .storage: "工作区记录无效、重复或版本不受支持，未覆盖原数据。"
        case .alreadyOpen: "工作区正由另一个进程使用。"
        case .aliasConflict: "SSH 别名已被占用。"
        case .configuration: "连接配置不完整或尚未通过此 Mac 的验证。"
        case .missingKey: "此 Mac 缺少该账户可用的本地私钥，请先配置免密访问。"
        case .terminal: "无法完成终端交接，请复制连接命令。"
        }
    }
}
