import Foundation
import Darwin
import KeyPortCore
import KeyPortInterface
import Observation

/// The only writable workspace authority. UI and SSH inputs are read-only projections.
@MainActor @Observable final class WorkspaceStore {
    struct Document: Codable {
        var version = 2
        var deviceID: String
        var topology: TopologySnapshot
        var defaultPaths: [String: String] = [:]
        var pathKeys: [String: String] = [:]
        var preferredProfilesByAccountID: [String: UUID]?
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
        var profileID: UUID?
        var endpointID: UUID?
        var policyMode: String?
        var policyReady: Bool?
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
    var installation: ManagedAliasInstallation
    let policyInstallation: ManagedSSHPolicyInstallation
    private(set) var installationNotice: String?
    let workspace: AccessWorkspace
    private(set) var document: Document
    private let lockFD: Int32
    private let cloud: any CloudSyncing
    private(set) var syncEnabled = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    private var revision = 0
    private(set) var serverOperationInProgress = false
    func setServerOperationInProgress(_ value: Bool) { serverOperationInProgress = value }
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
    private var pendingSecurityURL: URL { policyInstallation.root.appendingPathComponent("pending-workspace.json") }
    private var stateURL: URL { paths.applicationSupport.appendingPathComponent("workspace-v1.json") }

    init(home: URL? = nil, userHome: URL? = nil, cloud: any CloudSyncing = CloudKitSyncService(), deviceID: String? = nil, relayHelper: URL? = nil) throws {
        paths = KeyPortPaths(home: home ?? FileManager.default.homeDirectoryForCurrentUser)
        installation = .init(home: userHome ?? home ?? FileManager.default.homeDirectoryForCurrentUser)
        var policy = ManagedSSHPolicyInstallation(home: userHome ?? home ?? FileManager.default.homeDirectoryForCurrentUser)
        if let relayHelper { policy.bundledHelper = relayHelper }
        policyInstallation = policy
        self.cloud = cloud
        try paths.prepareDirectories()
        lockFD = Darwin.open(paths.applicationSupport.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw WorkspaceError.storage }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lockFD); throw WorkspaceError.alreadyOpen }
        do {
            let url = paths.applicationSupport.appendingPathComponent("workspace-v1.json")
            var loaded: Document
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
            let pending = policy.root.appendingPathComponent("pending-workspace.json")
            if FileManager.default.fileExists(atPath: pending.path) {
                let data = try SSHRelayOwnedFile.read(pending, limit: 16 * 1024 * 1024)
                let recovered = try Self.decoder().decode(Document.self, from: data)
                try Self.validate(recovered)
                guard recovered.deviceID == loaded.deviceID else { throw WorkspaceError.storage }
                if try Data(contentsOf: url) != data {
                    let backup = paths.applicationSupport.appendingPathComponent("workspace-recovery-backup-" + UUID().uuidString + ".json")
                    try FileManager.default.copyItem(at: url, to: backup)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                loaded = recovered
            }
            document = loaded
            workspace = AccessWorkspace(snapshot: Self.snapshot(Self.project(loaded), configDirectory: paths.keyPortDirectory, nodes: loaded.topology.nodes), isSimulation: false)
        } catch { Darwin.close(lockFD); throw error }
    }
    deinit { Darwin.close(lockFD) }
    static func validate(_ document: Document) throws {
        let t = document.topology
        func unique<T: Hashable>(_ ids: [T]) -> Bool { Set(ids).count == ids.count }
        guard (1...2).contains(document.version), t.schemaVersion == TopologySnapshot.currentSchemaVersion,
              t.sshConnectionProfiles.allSatisfy({ $0.policyVersion == nil || $0.policyVersion == 1 }),
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
            let endpointIDs = p.policyVersion == 1 ? p.candidateEndpointIDs : [p.routePolicy.fixedEndpointID ?? p.candidateEndpointIDs.first].compactMap { $0 }
            let localKey = t.sshKeys.first { $0.id == document.pathKeys[p.id.uuidString] && $0.deviceID == document.deviceID && $0.privateKeyPath != nil }
            let plan = try? SSHPolicyCompiler.compile(profile: p, topology: t, deviceID: document.deviceID, keyID: localKey?.id)
            for eid in endpointIDs {
                guard let e = t.activeEndpoints.first(where: { $0.id == eid && $0.nodeID == n.id && $0.protocol == .ssh }) else { continue }
                let id = p.policyVersion == 1 ? SSHPolicyUpgrade.pathID(profileID: p.id, endpointID: e.id) : p.id.uuidString
                let v = t.accessVerifications.first { $0.profileID == p.id && $0.endpointID == e.id && $0.deviceID == document.deviceID }
                let trust = t.hostKeyTrusts.first { !$0.isDeleted && $0.state == .confirmed && $0.endpointID == e.id && $0.algorithm == "ssh-ed25519" }
                let bound = p.policyVersion != 1 || (localKey != nil && trust != nil && v?.policyEvidenceBinding == SSHPolicyCompiler.evidence(endpoint: e, fingerprint: trust!.fingerprint, keyFingerprint: localKey!.fingerprint, username: a.username))
                let r = t.reachabilityObservations.first { $0.endpointID == e.id && $0.observerDeviceID == document.deviceID }
                result.connections.append(.init(id: id, serverID: n.id.uuidString, alias: p.sshAlias, description: n.name, address: e.address, port: Int(e.port), account: a.username, keyID: localKey?.id ?? "", verification: localKey != nil && bound && v?.status == .authorized ? "verified" : v == nil || !bound ? "pending" : "failed", reachability: r.map { $0.wasReachable ? "reachable" : "unreachable" } ?? "unknown", checkedAt: v?.lastCheckedAt, profileID: p.id, endpointID: e.id, policyMode: p.policyVersion == 1 ? (p.policyConflict == true ? "策略冲突 · 请确认顺序" : p.routePolicy.fixedEndpointID == nil ? "按顺序自动回退" : "固定地址") : nil, policyReady: p.policyVersion == 1 ? plan != nil : nil))
            }
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
        guard AccessFormDraft.isValidHost(draft.address), draft.addresses.allSatisfy(AccessFormDraft.isValidHost), draft.additionalAddresses.allSatisfy({ AccessFormDraft.isValidHost($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), !draft.account.isEmpty, draft.account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }), aliases.validationMessage(for: draft.alias, editingEntryID: serverID) == nil,
              let nodeID = UUID(uuidString: serverID), let port = UInt16(draft.port), port > 0 else { throw WorkspaceError.configuration }
        try installation.validateAlias(draft.alias)
        var next = document
        if !next.topology.nodes.contains(where: { $0.id == nodeID }) { next.topology.nodes.append(.init(id: nodeID, name: draft.description, roles: [.sshHost])) }
        guard let index = next.topology.nodes.firstIndex(where: { $0.id == nodeID && !$0.isDeleted }) else { throw WorkspaceError.storage }
        if !next.topology.nodes[index].roles.contains(.sshHost) {
            next.topology.nodes[index].roles.append(.sshHost)
            next.topology.nodes[index].removedRoles?.removeAll { $0 == .sshHost }
            next.topology.nodes[index].roleVersion = (next.topology.nodes[index].roleVersion ?? 0) + 1
        }
        next.topology.nodes[index].name = draft.description; next.topology.nodes[index].updatedAt = Date()
        let account = next.topology.activeAccounts.first { $0.nodeID == nodeID && $0.username == draft.account }
            ?? SSHAccount(id: UUID(), nodeID: nodeID, username: draft.account)
        guard !next.topology.activeConnectionProfiles.contains(where: { $0.sshAlias.caseInsensitiveCompare(draft.alias) == .orderedSame && $0.accountID != account.id }) else { throw WorkspaceError.aliasConflict }
        if !next.topology.sshAccounts.contains(where: { $0.id == account.id }) { next.topology.sshAccounts.append(account) }
        let existing = next.topology.activeConnectionProfiles.first { $0.accountID == account.id && $0.sshAlias.caseInsensitiveCompare(draft.alias) == .orderedSame }
        var endpoints: [UUID] = []
        for address in draft.addresses {
            let endpoint = next.topology.activeEndpoints.first { $0.nodeID == nodeID && $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.port == port && $0.protocol == .ssh }
                ?? Endpoint(id: UUID(), nodeID: nodeID, address: address, port: port, protocol: .ssh)
            if !next.topology.endpoints.contains(where: { $0.id == endpoint.id }) { next.topology.endpoints.append(endpoint) }
            endpoints.append(endpoint.id)
        }
        guard let first = endpoints.first else { throw WorkspaceError.configuration }
        let profileID = existing?.id ?? UUID()
        if existing == nil {
            next.topology.sshConnectionProfiles.append(.init(id: profileID, accountID: account.id, sshAlias: draft.alias, routePolicy: .fixed(endpointID: first)))
        }
        guard existing?.policyConflict != true else { throw WorkspaceError.configuration }
        let previous = existing.map { policyEndpoints($0.id) } ?? []
        var seen = Set<UUID>()
        let candidates = (previous + endpoints).filter { seen.insert($0).inserted }
        let automatic = draft.automaticRouting ?? (existing?.policyVersion == 1 ? existing?.routePolicy.fixedEndpointID == nil : existing == nil && candidates.count > 1)
        let canonical = try SSHPolicyUpgrade.apply(profileID: profileID, endpointIDs: candidates, automatic: automatic, to: &next.topology)
        next.pathKeys[canonical.uuidString] = key.id
        next.topology.accessVerifications.removeAll { $0.profileID == canonical && $0.endpointID == first && $0.deviceID == state.deviceID }
        let id = SSHPolicyUpgrade.pathID(profileID: canonical, endpointID: first)
        if next.defaultPaths[serverID] == nil { next.defaultPaths[serverID] = id }
        next.version = 2
        try commit(next); workspace.select(.path(id)); return id
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
    func checked(_ id: String, success: Bool, unreachable: Bool = false, identityMismatch: Bool = false) throws {
        var next = document
        guard let c = state.connections.first(where: { $0.id == id }), let pid = c.profileID, let eid = c.endpointID,
              let p = next.topology.activeConnectionProfiles.first(where: { $0.id == pid }),
              let endpoint = next.topology.activeEndpoints.first(where: { $0.id == eid }) else { throw WorkspaceError.storage }
        next.topology.accessVerifications.removeAll { $0.profileID == p.id && $0.endpointID == eid && $0.deviceID == state.deviceID }
        var v = AccessVerification(accountID: p.accountID, deviceID: state.deviceID, profileID: p.id, endpointID: eid, status: success ? .authorized : identityMismatch ? .hostKeyMismatch : .keyAuthenticationFailed, lastCheckedAt: Date())
        if success, let trust = next.topology.hostKeyTrusts.first(where: { !$0.isDeleted && $0.state == .confirmed && $0.endpointID == eid && $0.algorithm == "ssh-ed25519" }), let key = next.topology.sshKeys.first(where: { $0.id == c.keyID }) {
            v.policyEvidenceBinding = SSHPolicyCompiler.evidence(endpoint: endpoint, fingerprint: trust.fingerprint, keyFingerprint: key.fingerprint, username: c.account)
        }
        next.topology.accessVerifications.append(v)
        next.topology.reachabilityObservations.removeAll { $0.endpointID == eid && $0.observerDeviceID == state.deviceID }
        if success || unreachable { next.topology.reachabilityObservations.append(.init(endpointID: eid, observerDeviceID: state.deviceID, networkEpoch: 0, observedAt: Date(), wasReachable: success)) }
        try commit(next)
    }
    func isDefault(_ connection: Connection) -> Bool { connection.policyMode != nil || document.defaultPaths[connection.serverID] == connection.id }
    func refreshSelectionEvents() {
        var snapshot = Self.snapshot(state, configDirectory: paths.keyPortDirectory, nodes: topology.nodes)
        for i in snapshot.configuredPaths.indices {
            guard let text = snapshot.configuredPaths[i].profileID, let profileID = UUID(uuidString: text),
                  let data = try? SSHRelayOwnedFile.read(policyInstallation.root.appendingPathComponent("events/" + profileID.uuidString + ".json"), limit: 16_384),
                  let event = try? JSONDecoder().decode(SSHRelaySelectionEvent.self, from: data), event.profileID == profileID,
                  let endpoint = topology.activeEndpoints.first(where: { $0.id == event.endpointID }),
                  topology.activeConnectionProfiles.contains(where: { $0.id == profileID && $0.candidateEndpointIDs.contains(endpoint.id) }) else { continue }
            let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
            snapshot.configuredPaths[i].selectionSummary = "最近 TCP 选址：" + endpoint.address + ":" + String(endpoint.port) + " · " + formatter.string(from: event.selectedAt) + "（不代表 SSH 登录成功）"
        }
        workspace.replaceSnapshot(snapshot)
    }
    func synchronizeAliases() throws {
        do {
            try write(Data((Set(state.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n").utf8), to: paths.knownHosts)
            try export(state); try cleanPathConfigurations()
            for c in state.connections + legacyDiagnosticConnections() where c.verification == "verified" { _ = try writeConfiguration(for: c) }
            if FileManager.default.fileExists(atPath: pendingSecurityURL.path) { try FileManager.default.removeItem(at: pendingSecurityURL) }
            installationNotice = nil
            refreshSelectionEvents()
        } catch {
            installationNotice = "本机终端配置未就绪：" + error.localizedDescription
            throw error
        }
    }
    func setDefault(_ id: String) throws {
        guard let c = state.connections.first(where: { $0.id == id }), c.verification == "verified" else { throw WorkspaceError.configuration }
        guard let pid = c.profileID, let eid = c.endpointID else { throw WorkspaceError.configuration }
        try updatePolicy(profileID: pid, endpoints: [eid] + policyEndpoints(pid).filter { $0 != eid }, automatic: false)
    }

    func rename(serverID: String, alias: String, replacingAlias: String? = nil) throws {
        guard AliasDirectory.isValidNewAlias(alias), aliases.validationMessage(for: alias, editingEntryID: serverID) == nil else { throw WorkspaceError.aliasConflict }
        try installation.validateAlias(alias)
        var next = document
        guard !next.topology.activeConnectionProfiles.contains(where: { p in p.sshAlias.caseInsensitiveCompare(alias) == .orderedSame && next.topology.activeAccounts.contains { $0.id == p.accountID && $0.nodeID.uuidString != serverID } }) else { throw WorkspaceError.aliasConflict }
        let ids = Set(next.topology.activeAccounts.filter { $0.nodeID.uuidString == serverID }.map(\.id))
        let affected = next.topology.activeConnectionProfiles.filter { ids.contains($0.accountID) && (replacingAlias == nil || $0.sshAlias == replacingAlias) }
        guard Set(affected.map(\.accountID)).count <= 1 else { throw WorkspaceError.aliasConflict }
        for i in next.topology.sshConnectionProfiles.indices where ids.contains(next.topology.sshConnectionProfiles[i].accountID) && (replacingAlias == nil || next.topology.sshConnectionProfiles[i].sshAlias == replacingAlias) {
            next.topology.sshConnectionProfiles[i].sshAlias = alias
            next.topology.sshConnectionProfiles[i].updatedAt = Date(); next.topology.sshConnectionProfiles[i].version += 1
        }
        try commit(next); try synchronizeAliases()
    }
    func remove(_ id: String) throws {
        var next = document
        guard let c = state.connections.first(where: { $0.id == id }), let pid = c.profileID,
              let i = next.topology.sshConnectionProfiles.firstIndex(where: { $0.id == pid }) else { return }
        if next.topology.sshConnectionProfiles[i].policyVersion == 1 {
            next.topology.sshConnectionProfiles[i].candidateEndpointIDs.removeAll { $0 == c.endpointID }
            if next.topology.sshConnectionProfiles[i].candidateEndpointIDs.isEmpty { next.topology.sshConnectionProfiles[i].isDeleted = true }
        } else { next.topology.sshConnectionProfiles[i].isDeleted = true }
        next.topology.sshConnectionProfiles[i].updatedAt = Date(); next.topology.sshConnectionProfiles[i].version += 1
        next.topology.accessVerifications.removeAll { $0.profileID == pid && $0.endpointID == c.endpointID }
        next.defaultPaths = next.defaultPaths.filter { $0.value != id }
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
        guard syncState != .syncing, !serverOperationInProgress else { return }
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
    func commit(_ next: Document, scheduleSync shouldSchedule: Bool = true) throws {
        try Self.validate(next)
        let invalidating = Self.invalidatesAccess(document, next)
        if invalidating {
            // Durable pending authority is replayed on startup before any SSH files
            // can be regenerated. A failed config transaction cannot restore old consent.
            try policyInstallation.prepareRoot()
            try write(try Self.encoder().encode(next), to: pendingSecurityURL)
            document = next
            revision += 1
            workspace.replaceSnapshot(Self.snapshot(state, configDirectory: paths.keyPortDirectory, nodes: topology.nodes))
            installationNotice = "连接配置正在更新，旧入口将停用；若操作中断请重试安装。"
            // Invalidate dependencies first: even a failed Include transaction cannot
            // reactivate an obsolete manifest or host identity through rollback.
            try invalidateOldPolicyFiles(except: policyInstallation.root.appendingPathComponent("no-active-generation"))
            try write(Data(), to: paths.knownHosts)
            try installation.install(entries: [], knownHosts: paths.knownHosts)
        }
        let generation = try prepared(next)
        // Persist authority after dependency preparation; activation errors remain visible and retryable.
        try write(try Self.encoder().encode(next), to: stateURL)
        document = next
        revision += 1
        if shouldSchedule { scheduleSync() }
        workspace.replaceSnapshot(Self.snapshot(state, configDirectory: paths.keyPortDirectory, nodes: topology.nodes))
        let lines = Set(state.trusts.map(\.key.knownHostsLine)).sorted().joined(separator: "\n") + "\n"
        try write(Data(lines.utf8), to: paths.knownHosts)
        do { try installation.install(entries: generation.entries, knownHosts: generation.knownHosts) }
        catch {
            installationNotice = invalidating ? "策略已保存，旧连接已停用；本机配置安装失败，请重试。" : "策略已保存，终端仍使用上一代配置；请重试安装。"
            throw error
        }
        try invalidateOldPolicyFiles(except: generation.knownHosts.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: pendingSecurityURL.path) { try FileManager.default.removeItem(at: pendingSecurityURL) }
        installationNotice = nil
        try cleanPathConfigurations()
        for connection in legacyDiagnosticConnections() { _ = try writeConfiguration(for: connection) }
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
            where url.lastPathComponent.hasPrefix("path-") && ["conf", "known_hosts"].contains(url.pathExtension) {
            let id = String(url.deletingPathExtension().lastPathComponent.dropFirst(5))
            if UUID(uuidString: id) != nil, !(state.connections + legacyDiagnosticConnections()).contains(where: { $0.id == id && $0.verification == "verified" }) {
                let backup = paths.keyPortDirectory.appendingPathComponent("retired-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try FileManager.default.moveItem(at: url, to: backup.appendingPathComponent(url.lastPathComponent))
            }
        }
    }
    func command(for connection: Connection) throws -> String {
        guard let current = state.connections.first(where: { $0.id == connection.id }) else { throw WorkspaceError.configuration }
        if current.policyMode != nil { guard current.policyReady == true else { throw WorkspaceError.configuration } }
        else { guard state.connections.contains(where: { $0.serverID == current.serverID && $0.alias == current.alias && $0.account == current.account && $0.verification == "verified" && isDefault($0) }) else { throw WorkspaceError.configuration } }
        try synchronizeAliases()
        guard (try? String(contentsOf: installation.managed).contains("Host " + current.alias + "\n")) == true else { throw WorkspaceError.aliasConflict }
        return "ssh " + current.alias
    }
    func diagnosticCommand(for connection: Connection) throws -> String {
        guard state.connections.contains(where: { $0.id == connection.id && $0.verification == "verified" }) else { throw WorkspaceError.configuration }
        let config = try writeConfiguration(for: connection)
        return "/usr/bin/ssh -F \(Self.shellQuote(config.path)) \(Self.shellQuote(connection.alias))"
    }
    private func entry(_ connection: Connection, state: State) throws -> SSHConfigEntry {
        guard UUID(uuidString: connection.id) != nil,
              let key = state.keys.first(where: { $0.id == connection.keyID }), let privatePath = key.privateKeyPath else { throw WorkspaceError.configuration }
        return SSHConfigEntry(server: ServerConnection(name: connection.description, host: connection.address,
            port: connection.port, username: connection.account, alias: connection.alias), identityPath: privatePath)
    }
    private func prepared(_ next: Document) throws -> ManagedSSHPolicyInstallation.Generation {
        let value = Self.project(next)
        let conflicts = Set(Dictionary(grouping: next.topology.activeConnectionProfiles, by: { $0.sshAlias.lowercased() }).filter { Set($0.value.map(\.accountID)).count > 1 }.keys)
        let connections = value.connections.filter { !conflicts.contains($0.alias.lowercased()) && $0.policyMode == nil && value.defaultPaths?[$0.serverID] == $0.id && $0.verification == "verified" }
        let plans = next.topology.activeConnectionProfiles.filter { !conflicts.contains($0.sshAlias.lowercased()) }.compactMap { try? SSHPolicyCompiler.compile(profile: $0, topology: next.topology, deviceID: next.deviceID, keyID: next.pathKeys[$0.id.uuidString]) }
        return try policyInstallation.prepare(plans: plans, directEntries: connections.map { try entry($0, state: value) }, knownHostsLines: value.trusts.map(\.key.knownHostsLine))
    }
    private func export(_ value: State) throws {
        let generation = try prepared(document)
        try WorkspaceConfigurationMigration.retire(paths: paths, migratedAliases: Set(topology.sshConnectionProfiles.map { $0.sshAlias.lowercased() })) {
            try installation.install(entries: generation.entries, knownHosts: generation.knownHosts)
        }
        try invalidateOldPolicyFiles(except: generation.knownHosts.deletingLastPathComponent())
    }
    /// A selected nondefault edge always uses its own explicit configuration.
    func writeConfiguration(for connection: Connection) throws -> URL {
        let config = paths.keyPortDirectory.appendingPathComponent("path-\(connection.id).conf")
        let identity = try entry(connection, state: state)
        guard let node = UUID(uuidString: connection.serverID) else { throw WorkspaceError.configuration }
        let alias = "keyport-node-" + node.uuidString.lowercased()
        let hosts = paths.keyPortDirectory.appendingPathComponent("path-\(connection.id).known_hosts")
        let lines = state.trusts.filter { $0.serverID == connection.serverID && $0.address == connection.address && $0.port == connection.port && $0.key.algorithm == "ssh-ed25519" }.compactMap { trust -> String? in
            guard let parsed = PublicKeyParser.parse(trust.key.knownHostsLine), parsed.fingerprint == trust.key.fingerprint else { return nil }
            return "\(alias) \(parsed.type) \(parsed.blob)"
        }
        try write(Data((lines.joined(separator: "\n") + "\n").utf8), to: hosts)
        let pinned = SSHConfigEntry(server: identity.server, identityPath: identity.identityPath, policyHostKeyAlias: alias)
        let text = try SSHConfigGenerator.policyConfig(entries: [pinned], knownHostsPath: hosts.path)
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
        func group(_ c: Connection) -> String { c.serverID + "|" + c.account + "|" + c.alias.lowercased() }
        let legacyReady = Set(state.connections.filter { $0.policyMode == nil && $0.verification == "verified" && state.defaultPaths?[$0.serverID] == $0.id }.map(group))
        let paths = state.connections.map { ConfiguredAccessPath(id: $0.id, deviceID: state.deviceID, serverID: $0.serverID, account: $0.account, address: $0.address, port: $0.port,
            verification: $0.verification == "verified" ? .verified : $0.verification == "failed" ? .failed : .pending,
            reachability: $0.reachability == "reachable" ? .reachable : $0.reachability == "unreachable" ? .unreachable : .unknown, checkedAt: $0.checkedAt,
            terminalCommand: ($0.policyReady ?? legacyReady.contains(group($0))) ? "ssh " + $0.alias : nil,
            isDefaultConnection: $0.policyMode != nil || state.defaultPaths?[$0.serverID] == $0.id, sshAlias: $0.alias, profileID: $0.profileID?.uuidString, policyMode: $0.policyMode) }
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
