import Foundation
import KeyPortCore
import Observation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case graph, nodes, activity
    case servers, keys, devices, logs

    static let workspaceCases: [Self] = [.graph, .nodes, .activity]
    static let compatibilityCases: [Self] = [.servers, .keys, .devices, .logs]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .graph: "Graph"
        case .nodes: "节点"
        case .activity: "活动"
        case .servers: "服务器"
        case .keys: "密钥"
        case .devices: "设备"
        case .logs: "审计日志"
        }
    }
    var systemImage: String {
        switch self {
        case .graph: "point.3.connected.trianglepath.dotted"
        case .nodes: "circle.grid.3x3"
        case .activity: "clock.arrow.circlepath"
        case .servers: "server.rack"
        case .keys: "key"
        case .devices: "laptopcomputer"
        case .logs: "list.bullet.rectangle"
        }
    }
}

struct ServerDraft: Sendable {
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var alias = ""
    var group = ""
    var notes = ""
    var usesSuggestedAlias = true
    var tailscaleSuggestion: TailscaleSSHServerSuggestion?
    var aliasesToAvoid = Set<String>()
    /// Temporary Node context carried by the editor when adding a child SSH
    /// account. It is materialized into `SSHAccount.nodeID` on save.
    var targetNodeID: UUID?
    var targetEndpointID: UUID?

    init() {}

    init(server: ServerConnection) {
        name = server.name
        host = server.host
        port = server.port
        username = server.username
        alias = server.alias
        group = server.group
        notes = server.notes
        usesSuggestedAlias = false
    }

    init(newAccountFor server: ServerConnection, aliasesToAvoid: Set<String>) {
        name = server.name
        host = server.host
        port = server.port
        group = server.group
        notes = server.notes
        self.aliasesToAvoid = aliasesToAvoid
        updateSuggestedAlias()
    }

    init(
        node: Node,
        endpoint: Endpoint?,
        fallbackHost: String?,
        aliasesToAvoid: Set<String>
    ) {
        name = node.name
        host = endpoint?.address ?? fallbackHost ?? ""
        port = endpoint.map { Int($0.port) } ?? 22
        group = node.group
        notes = node.notes
        self.aliasesToAvoid = aliasesToAvoid
        targetNodeID = node.id
        targetEndpointID = endpoint?.id
        updateSuggestedAlias()
    }

    init(tailscaleSuggestion: TailscaleSSHServerSuggestion, aliasesToAvoid: Set<String>) {
        name = tailscaleSuggestion.name
        host = tailscaleSuggestion.host
        port = tailscaleSuggestion.port
        group = tailscaleSuggestion.group
        self.tailscaleSuggestion = tailscaleSuggestion
        self.aliasesToAvoid = aliasesToAvoid
        alias = tailscaleSuggestion.suggestedAlias(username: username, avoiding: aliasesToAvoid)
    }

    mutating func updateSuggestedAlias() {
        guard usesSuggestedAlias else { return }
        alias = suggestedAlias
    }

    mutating func noteAliasEdit() {
        usesSuggestedAlias = alias.isEmpty || alias == suggestedAlias
    }

    private var suggestedAlias: String {
        if let tailscaleSuggestion {
            return tailscaleSuggestion.suggestedAlias(username: username, avoiding: aliasesToAvoid)
        }
        let base = KeyPortNaming.accountAlias(group: group, name: name, username: username)
        return KeyPortNaming.availableAlias(base, avoiding: aliasesToAvoid)
    }
}

struct NodeEndpointDraft: Sendable {
    var address = ""
    var label = ""
    var port = 22
    var networkScope: NetworkScope = .publicNetwork
}

/// Account-only editor state. Network coordinates and SSH aliases belong to
/// `SSHAccessSetupDraft`, never to this value.
struct SSHAccountDraft: Sendable {
    let nodeID: UUID
    var accountID: UUID?
    var label: String
    var username: String

    init(
        nodeID: UUID,
        accountID: UUID? = nil,
        label: String = "",
        username: String = ""
    ) {
        self.nodeID = nodeID
        self.accountID = accountID
        self.label = label
        self.username = username
    }
}

struct SSHAccountEditorSubmission: Sendable {
    let draft: SSHAccountDraft
    let password: String
    let synchronizable: Bool
}

/// One editable connection profile for the passwordless setup flow. The
/// selected account is stable; the endpoint and alias describe how to reach it.
struct SSHAccessSetupDraft: Sendable {
    var nodeID: UUID
    var profileID: UUID?
    var accountID: UUID
    var endpointID: UUID
    var sshAlias: String
    var sshInput: String
}

struct SSHAccessInputResolution: Sendable {
    let profileID: UUID?
    let accountID: UUID
    let endpointID: UUID
    let sshAlias: String?
}

enum ServerEditorValidationState: Equatable, Sendable {
    case confirmationRequired
    case succeeded
    case failed
}

struct ServerEditorValidationResult: Sendable {
    let state: ServerEditorValidationState
    let check: AuthenticationCheck
    let logLines: [String]
    let observedHostKeys: [HostKeyRecord]
    let confirmedHostKeys: [HostKeyRecord]
    let machineConfiguration: RemoteMachineConfiguration?
}

struct ServerEditorSubmission: Sendable {
    let draft: ServerDraft
    let password: String
    let synchronizable: Bool
    let confirmedHostKeys: [HostKeyRecord]
    let passwordCheck: AuthenticationCheck?
    let machineConfiguration: RemoteMachineConfiguration?
}

struct SSHCheckLog: Sendable {
    let serverID: UUID
    let title: String
    var lines: [String]
}

enum TailscaleDiscoveryState: Equatable {
    case idle
    case refreshing
    case available
    case unavailable(String)
}

struct KeyServerRow: Identifiable {
    let server: ServerConnection
    let key: SSHKeyRecord?
    let authorization: Authorization?

    var id: String { "server:\(server.id.uuidString)" }
}

struct KeyConnectionRow: Identifiable {
    let connection: DiscoveredSSHConnection?
    let serverRow: KeyServerRow?

    var id: String { serverRow?.id ?? "config:\(connection?.alias ?? "unknown")" }
    var alias: String { connection?.alias ?? serverRow?.server.alias ?? "未知" }
    var host: String { connection?.host ?? serverRow?.server.host ?? "" }
    var port: Int { connection?.port ?? serverRow?.server.port ?? 22 }
}

private struct SSHAccountSortKey: Comparable {
    let username: String
    let port: Int
    let alias: String

    init(_ server: ServerConnection) {
        username = server.username
        port = server.port
        alias = server.alias
    }

    init(_ connection: DiscoveredSSHConnection) {
        username = connection.username
        port = connection.port
        alias = connection.alias
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let usernameOrder = lhs.username.localizedCaseInsensitiveCompare(rhs.username)
        if usernameOrder != .orderedSame { return usernameOrder == .orderedAscending }
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
    }
}

private enum ServerCheckKind: Equatable {
    case password
    case key

    var auditAction: String {
        switch self {
        case .password: "password-check"
        case .key: "key-check"
        }
    }

    var checkingDetail: String {
        switch self {
        case .password: "正在验证密码登录..."
        case .key: "正在检测免密登录..."
        }
    }
}

enum PasswordlessPrimaryAction: Equatable, Sendable {
    case verify
    case enable
    case generateKeyAndEnable
    case enterPasswordAndEnable
    case reviewHostIdentity
    case checking

    var title: String {
        switch self {
        case .verify: "检测免密"
        case .enable: "启用免密"
        case .generateKeyAndEnable: "生成密钥并启用免密"
        case .enterPasswordAndEnable: "输入密码并启用免密"
        case .reviewHostIdentity: "核对主机身份"
        case .checking: "正在检测免密"
        }
    }

    var systemImage: String {
        switch self {
        case .verify: "checkmark.shield"
        case .enable: "key.horizontal.fill"
        case .generateKeyAndEnable: "key.badge.plus"
        case .enterPasswordAndEnable: "key.viewfinder"
        case .reviewHostIdentity: "exclamationmark.shield"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    var help: String {
        switch self {
        case .verify:
            "只测试当前 Mac 的密钥登录，不会修改服务器"
        case .enable:
            "使用已保存的密码安装当前 Mac 公钥，并验证免密登录"
        case .generateKeyAndEnable:
            "先为当前 Mac 生成密钥，再安装公钥并验证免密登录"
        case .enterPasswordAndEnable:
            "输入并验证服务器密码后，安装当前 Mac 公钥"
        case .reviewHostIdentity:
            "核对服务器返回的 Host Key 指纹后再继续"
        case .checking:
            "正在检测当前 Mac 的免密登录状态"
        }
    }
}

private struct SharedServerFields {
    let name: String
    let host: String
    let port: Int
    let group: String
    let notes: String
    let confirmedHostKeys: [HostKeyRecord]
    let machineConfiguration: RemoteMachineConfiguration?
    let machineConfigurationRefreshAttemptedAt: Date

    func apply(to server: inout ServerConnection, preservesMachineConfigurationWhenUnavailable: Bool = false) {
        server.name = name
        server.host = host
        server.port = port
        server.group = group
        server.notes = notes
        server.confirmedHostKeys = confirmedHostKeys
        if machineConfiguration != nil || !preservesMachineConfigurationWhenUnavailable {
            server.machineConfiguration = machineConfiguration
            server.machineConfigurationRefreshAttemptedAt = machineConfigurationRefreshAttemptedAt
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private struct ActiveDiscoveryOperation {
        let operationID: UUID
        let hostID: UUID
    }

    var snapshot = AppSnapshot()
    /// Unified Node/Endpoint/Service authority. `snapshot` is retained only as
    /// the SSH/Keychain compatibility projection during this refactor.
    private(set) var topology = TopologySnapshot.empty
    var destination: SidebarDestination = .nodes
    var selectedServerID: UUID?
    var selectedKeyID: String?
    var selectedKeyItemID: String?
    var selectedDeviceItemID: DevicePresence.ID?
    var searchText = ""
    var isLoaded = false
    private(set) var isMetadataReadOnly = false
    var isBusy = false
    var errorMessage: String?
    var pendingHostKeys: [HostKeyRecord] = []
    var pendingHostKeyServerID: UUID?
    private var pendingHostKeyEndpointID: UUID?
    private var pendingHostKeyCheckKind: ServerCheckKind?
    private var pendingHostKeyResumesAuthorization = false
    var cloudState: CloudSyncState = .disabled
    var lastCloudSyncAt: Date?
    var serverIDsWithStoredPassword = Set<UUID>()
    var serverIDsWithSynchronizablePassword = Set<UUID>()
    var passwordPromptServerID: UUID?
    private var passwordPromptEndpointID: UUID?
    var passwordSaveError: String?
    var isSavingPassword = false
    var discoveredSSHConnections: [DiscoveredSSHConnection] = []
    var listenerDiscoveryResults: [UUID: DiscoveryResult] = [:]
    private(set) var discoveryEnabled: Bool
    var retainedSSHCheckLog: SSHCheckLog?
    var machineConfigurationSyncingServerID: UUID?
    var machineConfigurationSyncError: String?
    var machineConfigurationSyncErrorServerID: UUID?
    var tailscaleStatus: TailscaleStatus?
    var tailscaleDiscoveryState: TailscaleDiscoveryState = .idle
    var nodeAssociationCandidates: [String: [NodeAssociationCandidate]] = [:]
    let graphWorkspace = GraphWorkspaceModel()
    let canSynchronizePasswords = KeychainService.synchronizableItemsAvailable

    private let store: SnapshotStore
    private let topologyStore: TopologyStore
    private let keychain: KeychainService
    private let keyService: SSHKeyService
    private let hostKeyService: HostKeyService
    private let sshService: OpenSSHService
    private let configService: SSHConfigService
    private let tailscaleService: TailscaleService
    private let localAuthentication: LocalAuthenticationService
    private let cloudSync: any CloudSyncing
    private let hostV6Runtime: HostV6Runtime?
    private let defaults: UserDefaults
    private let discoveryExecutor: any ProcessExecuting
    private let discoveryAdapter: any ListenerDiscoveryAdapter
    private let discoveryCoordinator: DiscoveryCoordinator
    private let archiveService = MetadataArchiveService()
    private let audit = AuditLogService()
    private let clipboard = ClipboardService()
    private let terminal = TerminalService()
    private let fileSelection = FileSelectionService()
    private var scheduledCloudSync: Task<Void, Never>?
    private var isSynchronizingCloud = false
    private var isInitialLoadInProgress = false
    private var automaticCloudRetryAttempt = 0
    private var activeDiscoveryOperations: [UUID: ActiveDiscoveryOperation] = [:]
    private var activeDiscoveryOperationsByHost: [UUID: UUID] = [:]
    private var discoveryGeneration = 0

    init(
        hostV6Runtime: HostV6Runtime? = nil,
        cloudSync: any CloudSyncing = CloudKitSyncService(),
        paths: KeyPortPaths = KeyPortPaths(),
        defaults: UserDefaults = .standard,
        discoveryExecutor: (any ProcessExecuting)? = nil,
        discoveryAdapter: (any ListenerDiscoveryAdapter)? = nil,
        discoveryCoordinator: DiscoveryCoordinator = DiscoveryCoordinator()
    ) {
        let storedCloudSyncAt = defaults.object(forKey: "KeyPort.lastCloudSyncAt") as? Date
        self.discoveryEnabled = DiscoveryFeatureFlags.isEnabled(defaults: defaults)
        self.lastCloudSyncAt = storedCloudSyncAt
        self.cloudState = defaults.bool(forKey: "KeyPort.cloudSyncEnabled") ? .checking : .disabled
        let runner = ProcessRunner()
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyPortAskPass").path
        let siblingHelper = executableDirectory?.appendingPathComponent("KeyPortAskPass").path ?? bundledHelper
        let helper = FileManager.default.isExecutableFile(atPath: bundledHelper) ? bundledHelper : siblingHelper

        self.store = SnapshotStore(paths: paths)
        self.topologyStore = TopologyStore(paths: paths)
        self.keychain = KeychainService()
        self.keyService = SSHKeyService(runner: runner, paths: paths)
        self.hostKeyService = HostKeyService(runner: runner, paths: paths)
        self.sshService = OpenSSHService(runner: runner, paths: paths, askPassPath: helper)
        self.configService = SSHConfigService(runner: runner, paths: paths)
        self.tailscaleService = TailscaleService(runner: runner)
        self.localAuthentication = LocalAuthenticationService()
        self.cloudSync = cloudSync
        self.hostV6Runtime = hostV6Runtime
        self.defaults = defaults
        self.discoveryExecutor = discoveryExecutor ?? ProcessExecutor()
        self.discoveryAdapter = discoveryAdapter ?? SSHListenerDiscoveryAdapter()
        self.discoveryCoordinator = discoveryCoordinator
    }

    var activeServers: [ServerConnection] {
        snapshot.servers
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var authorizedSSHAccounts: [ServerConnection] {
        activeServers
            .filter { $0.status == .authorized }
            .sorted { SSHAccountSortKey($0) < SSHAccountSortKey($1) }
    }

    var activeServerGroups: [ServerConnectionGroup] {
        let groups = ServerConnectionGrouping.groups(activeServers)
        guard !searchText.isEmpty else { return groups }

        let needle = searchText.localizedLowercase
        return groups.filter { group in
            group.accounts.contains { server in
                [server.name, server.host, server.username, server.group, server.alias]
                    .contains { $0.localizedLowercase.contains(needle) }
            }
        }
    }

    private var managedAliases: Set<String> {
        Set(snapshot.servers.lazy.filter { !$0.isDeleted }.map(\.alias))
    }

    var selectedServer: ServerConnection? {
        guard let selectedServerID else { return nil }
        return snapshot.servers.first { $0.id == selectedServerID && !$0.isDeleted }
    }

    var currentDevice: Device? { snapshot.devices.first(where: \.isCurrent) }
    var deviceListItems: [DevicePresence] {
        DevicePresenceMerger.merge(devices: snapshot.devices, tailscaleNodes: tailscaleStatus?.nodes ?? [])
    }
    var selectedDeviceItem: DevicePresence? {
        guard let selectedDeviceItemID else { return deviceListItems.first(where: \.isCurrent) ?? deviceListItems.first }
        return deviceListItems.first { $0.id == selectedDeviceItemID }
    }

    func managedServers(for suggestion: TailscaleSSHServerSuggestion) -> [ServerConnection] {
        snapshot.servers.filter {
            !$0.isDeleted && suggestion.matches(host: $0.host)
        }.sorted {
            SSHAccountSortKey($0) < SSHAccountSortKey($1)
        }
    }

    func devicePresence(for server: ServerConnection) -> DevicePresence? {
        deviceListItems.first { $0.matches(host: server.host) }
    }

    func devicePresence(for key: SSHKeyRecord) -> DevicePresence? {
        deviceListItems.first { $0.registeredDevice?.id == key.deviceID }
    }

    func nodeAssociations(for serverID: UUID) -> [NodeAssociation] {
        snapshot.nodeAssociations.filter { $0.serverID == serverID }.sorted {
            $0.testCaseNodeID.localizedCaseInsensitiveCompare($1.testCaseNodeID) == .orderedAscending
        }
    }

    func nodeAssociation(testCaseNodeID: String) -> NodeAssociation? {
        let normalizedID = LogicalNodeName.normalize(testCaseNodeID)
        return snapshot.nodeAssociations.first { $0.testCaseNodeID == normalizedID }
    }

    func candidates(for testCaseNodeID: String) -> [NodeAssociationCandidate] {
        nodeAssociationCandidates[LogicalNodeName.normalize(testCaseNodeID)] ?? []
    }

    var stableAssociationTargets: [(target: ActualNodeReference, node: TailscaleNode)] {
        guard let status = tailscaleStatus else { return [] }
        return status.nodes.compactMap { node in
            NodeAssociationEngine.target(for: node, status: status).map { ($0, node) }
        }.sorted {
            $0.node.name.localizedCaseInsensitiveCompare($1.node.name) == .orderedAscending
        }
    }

    func canExecuteTestCaseNode(_ testCaseNodeID: String) -> Bool {
        let normalizedID = LogicalNodeName.normalize(testCaseNodeID)
        guard let association = snapshot.nodeAssociations.first(where: { $0.testCaseNodeID == normalizedID }),
              association.allowsExecution,
              let server = snapshot.servers.first(where: { $0.id == association.serverID && !$0.isDeleted }) else {
            return false
        }
        return server.status != .hostKeyMismatch
    }

    @discardableResult
    func evaluateNodeAssociation(
        testCaseNodeID: String,
        serverID: UUID,
        expectedRevision: Int?
    ) async -> NodeAssociation? {
        guard await authorizeLegacyMutation() else { return nil }
        guard !isBusy,
              let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let existing = nodeAssociation(testCaseNodeID: testCaseNodeID)
            try requireObservedRevision(existing, expectedRevision: expectedRevision)
            let evaluation = try NodeAssociationEngine.evaluate(
                testCaseNodeID: testCaseNodeID,
                serverID: serverID,
                route: effectiveSSHRoute(for: server),
                status: tailscaleStatus,
                sourceState: tailscaleStatus?.isCompleteAssociationSnapshot == true ? .complete : .unavailable,
                logicalNameContext: logicalNameContext(for: server),
                existing: existing,
                hostKeyChanged: server.status == .hostKeyMismatch
            )
            nodeAssociationCandidates[evaluation.association.testCaseNodeID] = evaluation.candidates
            upsertNodeAssociation(evaluation.association)
            appendAudit(
                category: "node-association",
                action: "evaluate",
                targetID: evaluation.association.testCaseNodeID,
                result: evaluation.association.state.rawValue
            )
            await persist()
            return evaluation.association
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func confirmNodeAssociation(
        testCaseNodeID: String,
        serverID: UUID,
        target: ActualNodeReference,
        expectedRevision: Int?
    ) async -> NodeAssociation? {
        guard await authorizeLegacyMutation() else { return nil }
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        let logicalID = LogicalNodeName.normalize(testCaseNodeID)
        guard !logicalID.isEmpty else {
            present(NodeAssociationMutationError.invalidTestCaseNodeID)
            return nil
        }
        do {
            let existing = nodeAssociation(testCaseNodeID: logicalID)
            try requireObservedRevision(existing, expectedRevision: expectedRevision)
            let association = existing ?? NodeAssociation(testCaseNodeID: logicalID, serverID: serverID)
            guard association.serverID == serverID else { throw NodeAssociationMutationError.serverConflict }
            let confirmed = try NodeAssociationEngine.confirm(
                association,
                target: target,
                expectedRevision: association.revision,
                validTargets: Set(stableAssociationTargets.map(\.target))
            )
            upsertNodeAssociation(confirmed)
            appendAudit(category: "node-association", action: "confirm", targetID: logicalID, result: "manual")
            await persist()
            return confirmed
        } catch {
            present(error)
            return nil
        }
    }

    func unlinkNodeAssociation(testCaseNodeID: String, expectedRevision: Int) async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy,
              let association = nodeAssociation(testCaseNodeID: testCaseNodeID) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let unlinked = try NodeAssociationEngine.unlink(
                association,
                expectedRevision: expectedRevision
            )
            upsertNodeAssociation(unlinked)
            appendAudit(category: "node-association", action: "unlink", targetID: association.testCaseNodeID, result: "tombstoned")
            await persist()
        } catch {
            present(error)
        }
    }

    func resumeAutomaticNodeAssociation(testCaseNodeID: String, expectedRevision: Int) async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy,
              let association = nodeAssociation(testCaseNodeID: testCaseNodeID),
              let server = snapshot.servers.first(where: { $0.id == association.serverID && !$0.isDeleted }) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let resumed = try NodeAssociationEngine.resumeAutomaticMatching(
                association,
                expectedRevision: expectedRevision
            )
            upsertNodeAssociation(resumed)
            let evaluation = try NodeAssociationEngine.evaluate(
                testCaseNodeID: resumed.testCaseNodeID,
                serverID: resumed.serverID,
                route: effectiveSSHRoute(for: server),
                status: tailscaleStatus,
                sourceState: tailscaleStatus?.isCompleteAssociationSnapshot == true ? .complete : .unavailable,
                logicalNameContext: logicalNameContext(for: server),
                existing: resumed,
                hostKeyChanged: server.status == .hostKeyMismatch
            )
            nodeAssociationCandidates[evaluation.association.testCaseNodeID] = evaluation.candidates
            upsertNodeAssociation(evaluation.association)
            await persist()
        } catch {
            present(error)
        }
    }

    func servers(for item: DevicePresence) -> [ServerConnection] {
        activeServers.filter { item.matches(host: $0.host) }.sorted {
            SSHAccountSortKey($0) < SSHAccountSortKey($1)
        }
    }

    func unmanagedSSHConnections(for item: DevicePresence) -> [DiscoveredSSHConnection] {
        let managedAccounts = servers(for: item)
        return discoveredSSHConnections.filter { connection in
            item.matches(host: connection.host)
                && !managedAccounts.contains {
                    $0.port == connection.port && $0.username == connection.username
                }
        }.sorted {
            SSHAccountSortKey($0) < SSHAccountSortKey($1)
        }
    }

    func keys(for item: DevicePresence) -> [SSHKeyRecord] {
        guard let deviceID = item.registeredDevice?.id else { return [] }
        return snapshot.keys.filter { $0.deviceID == deviceID }.sorted {
            keyDisplayName($0).localizedCaseInsensitiveCompare(keyDisplayName($1)) == .orderedAscending
        }
    }

    func authorizedServers(for key: SSHKeyRecord) -> [ServerConnection] {
        authorizedServers(matching: [key.id])
    }

    func authorizedServers(for item: DevicePresence) -> [ServerConnection] {
        authorizedServers(matching: Set(keys(for: item).map(\.id)))
    }

    private func authorizedServers(matching keyIDs: Set<String>) -> [ServerConnection] {
        let serverIDs = Set(snapshot.authorizations.lazy
            .filter { !$0.isDeleted && $0.status == .authorized && keyIDs.contains($0.keyID) }
            .map(\.serverID))
        return activeServers.filter { serverIDs.contains($0.id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func key(for authorization: Authorization) -> SSHKeyRecord? {
        snapshot.keys.first { $0.id == authorization.keyID || $0.fingerprint == authorization.fingerprint }
    }

    func newServerDraft() -> ServerDraft {
        var draft = ServerDraft()
        draft.aliasesToAvoid = managedAliases
        return draft
    }

    func newAccountDraft(for serverID: UUID) -> ServerDraft? {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else {
            return nil
        }
        if let profile = topology.connectionProfile(id: serverID),
           let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }),
           let node = topology.node(id: account.nodeID) {
            if let nodeDraft = newAccountDraft(
                forNodeID: node.id,
                endpointID: profile.routePolicy.fixedEndpointID
            ) {
                return nodeDraft
            }
        }
        return ServerDraft(newAccountFor: server, aliasesToAvoid: managedAliases)
    }

    func serverEditorDraft(for serverID: UUID) -> ServerDraft? {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else {
            return nil
        }
        var draft = ServerDraft(server: server)
        if let profile = topology.connectionProfile(id: serverID),
           let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }) {
            draft.targetNodeID = account.nodeID
            draft.targetEndpointID = profile.routePolicy.fixedEndpointID
        }
        return draft
    }

    func newAccountDraft(forNodeID nodeID: UUID, endpointID: UUID? = nil) -> ServerDraft? {
        guard let node = topology.node(id: nodeID) else { return nil }
        let endpoints = topology.endpoints(for: nodeID, endpointProtocol: .ssh)
        let endpoint: Endpoint?
        if let endpointID {
            endpoint = endpoints.first { $0.id == endpointID }
        } else {
            endpoint = endpoints.first
        }
        let isCurrentDevice = topology.profiles.contains {
            $0.nodeID == nodeID && $0.isCurrent && !$0.isRevoked
        }
        guard endpoint != nil || isCurrentDevice else { return nil }
        return ServerDraft(
            node: node,
            endpoint: endpoint,
            fallbackHost: isCurrentDevice ? "localhost" : nil,
            aliasesToAvoid: managedAliases
        )
    }

    func newEndpointDraft(forNodeID nodeID: UUID) -> NodeEndpointDraft? {
        guard topology.node(id: nodeID) != nil else { return nil }
        return NodeEndpointDraft()
    }

    func sshAccountDraft(
        forNodeID nodeID: UUID,
        accountID: UUID? = nil
    ) -> SSHAccountDraft? {
        guard topology.node(id: nodeID) != nil else { return nil }
        guard let accountID else {
            return SSHAccountDraft(nodeID: nodeID)
        }
        guard let account = topology.activeAccounts.first(where: {
            $0.id == accountID && $0.nodeID == nodeID
        }) else { return nil }
        return SSHAccountDraft(
            nodeID: nodeID,
            accountID: account.id,
            label: account.label,
            username: account.username
        )
    }

    func sshAccounts(forNodeID nodeID: UUID) -> [SSHAccount] {
        topology.accounts(for: nodeID)
    }

    func sshAccount(id accountID: UUID) -> SSHAccount? {
        topology.activeAccounts.first { $0.id == accountID }
    }

    func sshAccountID(forConnectionProfileID profileID: UUID) -> UUID? {
        topology.connectionProfile(id: profileID)?.accountID
    }

    func keyPortNodeID(for suggestion: TailscaleSSHServerSuggestion) -> UUID? {
        let identityNodeIDs = Set(topology.activeTailscaleNodes.compactMap { identity -> UUID? in
            guard identity.tailscaleNodeID == suggestion.nodeID
                    || identity.matches(host: suggestion.host) else { return nil }
            return identity.keyPortNodeID
        })
        if !identityNodeIDs.isEmpty {
            return identityNodeIDs.count == 1 ? identityNodeIDs.first : nil
        }

        let endpointNodeIDs = Set(topology.activeEndpoints.compactMap { endpoint -> UUID? in
            guard endpoint.serviceID == nil,
                  endpoint.protocol == .ssh,
                  TopologyStableID.normalize(endpoint.address)
                    == TopologyStableID.normalize(suggestion.host) else { return nil }
            return endpoint.nodeID
        })
        return endpointNodeIDs.count == 1 ? endpointNodeIDs.first : nil
    }

    func sshConnectionProfiles(forNodeID nodeID: UUID) -> [SSHConnectionProfile] {
        topology.connectionProfiles(forNodeID: nodeID)
    }

    func sshAccessSetupDraft(
        forNodeID nodeID: UUID,
        profileID: UUID? = nil,
        endpointID: UUID? = nil
    ) -> SSHAccessSetupDraft? {
        guard let node = topology.node(id: nodeID) else { return nil }
        let endpoints = topology.endpoints(for: nodeID, endpointProtocol: .ssh)
        guard !endpoints.isEmpty else { return nil }

        let profile = profileID.flatMap(topology.connectionProfile(id:))
        let accounts = topology.accounts(for: nodeID)
        let account = profile
            .flatMap { selected in accounts.first { $0.id == selected.accountID } }
            ?? accounts.first
        guard let account else { return nil }
        let endpoint = endpointID.flatMap { id in endpoints.first { $0.id == id } }
            ?? profile?.routePolicy.fixedEndpointID.flatMap { id in endpoints.first { $0.id == id } }
            ?? endpoints.first
        guard let endpoint else { return nil }
        let alias = profile?.sshAlias ?? suggestedSSHAlias(
            nodeID: node.id,
            accountID: account.id,
            endpointID: endpoint.id,
            excludingProfileID: nil
        )
        return SSHAccessSetupDraft(
            nodeID: node.id,
            profileID: profile?.id,
            accountID: account.id,
            endpointID: endpoint.id,
            sshAlias: alias,
            sshInput: sshCommand(account: account, endpoint: endpoint)
        )
    }

    func sshCommand(accountID: UUID, endpointID: UUID) -> String? {
        guard let account = topology.activeAccounts.first(where: { $0.id == accountID }),
              let endpoint = topology.endpoint(id: endpointID),
              !endpoint.isDeleted,
              endpoint.nodeID == account.nodeID,
              endpoint.protocol == .ssh else { return nil }
        return sshCommand(account: account, endpoint: endpoint)
    }

    func suggestedSSHAlias(
        nodeID: UUID,
        accountID: UUID,
        endpointID: UUID,
        excludingProfileID: UUID?
    ) -> String {
        guard let node = topology.node(id: nodeID),
              let account = topology.activeAccounts.first(where: {
                  $0.id == accountID && $0.nodeID == nodeID
              }),
              let endpoint = topology.endpoint(id: endpointID) else {
            return "ssh-profile"
        }
        let base = [
            KeyPortNaming.slug(node.name),
            KeyPortNaming.slug(endpoint.networkScope.rawValue),
            KeyPortNaming.slug(account.username),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "-")
        var existing = Set(topology.activeConnectionProfiles
            .filter { $0.id != excludingProfileID }
            .map { $0.sshAlias.lowercased() })
        existing.formUnion(discoveredSSHConnections.map { $0.alias.lowercased() })
        return KeyPortNaming.availableAlias(base.isEmpty ? "ssh-profile" : base, avoiding: existing)
    }

    func sshAliasValidationMessage(_ alias: String, excludingProfileID: UUID?) -> String? {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeyPortNaming.isValidAlias(value) else {
            return "别名只能包含小写字母、数字和单个连字符。"
        }
        guard !topology.activeConnectionProfiles.contains(where: {
            $0.id != excludingProfileID
                && $0.sshAlias.caseInsensitiveCompare(value) == .orderedSame
        }) else {
            return "这个 SSH 别名已经被其他连接配置使用。"
        }
        let existingProfileAlias = excludingProfileID
            .flatMap(topology.connectionProfile(id:))?
            .sshAlias
        guard !discoveredSSHConnections.contains(where: {
            $0.alias.caseInsensitiveCompare(value) == .orderedSame
                && existingProfileAlias?.caseInsensitiveCompare(value) != .orderedSame
        }) else {
            return "这个 SSH 别名已经存在于 ~/.ssh/config 中。"
        }
        return nil
    }

    func resolveSSHAccessInput(
        _ input: String,
        forNodeID nodeID: UUID
    ) throws -> SSHAccessInputResolution {
        var intent = try SSHConnectionIntentParser.parse(input)
        intent.nodeID = nodeID
        let currentDeviceID = currentDevice?.id
            ?? defaults.string(forKey: "KeyPort.deviceID")
            ?? "local"
        let plan = try SSHConnectionPlanner().plan(
            for: intent,
            in: topology,
            currentDeviceID: currentDeviceID,
            networkEpoch: 0
        )
        return SSHAccessInputResolution(
            profileID: plan.profileID,
            accountID: plan.accountID,
            endpointID: plan.endpointID,
            sshAlias: plan.sshAlias
        )
    }

    @discardableResult
    func saveSSHAccount(_ submission: SSHAccountEditorSubmission) async throws -> UUID {
        try await requireLegacyMutation()
        guard hostV6Runtime == nil else {
            throw SSHServiceError.operationFailed("当前 V6 兼容模式暂不支持编辑 SSH 账户。")
        }

        let draft = submission.draft
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw SSHServiceError.operationFailed("请输入 SSH 用户名。")
        }
        guard let nodeIndex = topology.nodes.firstIndex(where: {
            $0.id == draft.nodeID && !$0.isDeleted
        }) else {
            throw SSHServiceError.operationFailed("目标节点不存在或已被删除。")
        }

        let previousAccount: SSHAccount?
        if let accountID = draft.accountID {
            guard let account = topology.activeAccounts.first(where: {
                $0.id == accountID && $0.nodeID == draft.nodeID
            }) else {
                throw SSHServiceError.operationFailed("要编辑的 SSH 账户已不存在。")
            }
            previousAccount = account
        } else {
            previousAccount = nil
        }

        let accountID = TopologyStableID.sshAccount(
            nodeID: draft.nodeID,
            username: username
        )
        guard !topology.activeAccounts.contains(where: {
            $0.id == accountID && $0.id != previousAccount?.id
        }) else {
            throw SSHServiceError.operationFailed("这个节点已经存在同名 SSH 用户。")
        }

        var credentialData: Data?
        var previousCredentialOwnerID: UUID?
        var previousStorage: ServerPasswordStorage?
        if let previousAccount {
            let ownerID = await storedCredentialOwnerID(forAccountID: previousAccount.id)
            if let ownerID {
                previousCredentialOwnerID = ownerID
                previousStorage = await keychain.serverPasswordStorage(serverID: ownerID)
                let shouldCopyCredential = !submission.password.isEmpty
                    || ownerID != accountID
                    || previousAccount.id != accountID
                    || previousStorage?.isSynchronizable != submission.synchronizable
                if shouldCopyCredential && submission.password.isEmpty {
                    var credential = try await keychain.serverCredential(serverID: ownerID)
                    credentialData = credential.passwordData
                    credential.passwordData.resetBytes(in: credential.passwordData.indices)
                }
            }
        }
        if !submission.password.isEmpty {
            credentialData = Data(submission.password.utf8)
        }
        defer {
            if credentialData != nil {
                credentialData!.resetBytes(in: credentialData!.indices)
            }
        }

        if let credentialData {
            try await keychain.saveServerCredential(
                username: username,
                passwordData: credentialData,
                serverID: accountID,
                synchronizable: submission.synchronizable
            )
        }

        let now = Date()
        let relatedProfileIDs = previousAccount.map {
            topology.connectionProfiles(for: $0.id).map(\.id)
        } ?? []
        if let previousAccount, previousAccount.id != accountID {
            if let oldIndex = topology.sshAccounts.firstIndex(where: { $0.id == previousAccount.id }) {
                topology.sshAccounts[oldIndex].isDeleted = true
                topology.sshAccounts[oldIndex].updatedAt = now
                topology.sshAccounts[oldIndex].version += 1
            }
            topology.sshAccounts.append(SSHAccount(
                id: accountID,
                nodeID: draft.nodeID,
                username: username,
                label: label,
                createdAt: previousAccount.createdAt,
                updatedAt: now,
                version: previousAccount.version + 1
            ))
            for index in topology.sshConnectionProfiles.indices
                where topology.sshConnectionProfiles[index].accountID == previousAccount.id {
                topology.sshConnectionProfiles[index].accountID = accountID
                topology.sshConnectionProfiles[index].updatedAt = now
                topology.sshConnectionProfiles[index].version += 1
            }
            for index in topology.authorizations.indices
                where topology.authorizations[index].accountID == previousAccount.id {
                topology.authorizations[index].accountID = accountID
                topology.authorizations[index].updatedAt = now
            }
            for index in topology.accessVerifications.indices
                where topology.accessVerifications[index].accountID == previousAccount.id {
                topology.accessVerifications[index].accountID = accountID
            }
        } else if let index = topology.sshAccounts.firstIndex(where: { $0.id == accountID }) {
            topology.sshAccounts[index].username = username
            topology.sshAccounts[index].label = label
            topology.sshAccounts[index].updatedAt = now
            topology.sshAccounts[index].isDeleted = false
            topology.sshAccounts[index].version += 1
        } else {
            topology.sshAccounts.append(SSHAccount(
                id: accountID,
                nodeID: draft.nodeID,
                username: username,
                label: label,
                createdAt: now,
                updatedAt: now
            ))
        }

        var node = topology.nodes[nodeIndex]
        node.roles = Array(Set(node.roles + [.sshHost])).sorted { $0.rawValue < $1.rawValue }
        node.updatedAt = now
        topology.nodes[nodeIndex] = node

        let currentDeviceID = currentDevice?.id
            ?? defaults.string(forKey: "KeyPort.deviceID")
            ?? "local"
        snapshot = TopologySnapshotMigration.legacyProjection(
            from: topology,
            currentDeviceID: currentDeviceID
        )
        appendAudit(
            category: "ssh-account",
            action: previousAccount == nil ? "create" : "update",
            targetID: accountID.uuidString,
            result: relatedProfileIDs.isEmpty ? "account-only" : "profiles-preserved"
        )
        await persist()

        if let previousAccount, previousAccount.id != accountID {
            let obsoleteCredentialIDs = Set(
                [previousAccount.id, previousCredentialOwnerID].compactMap { $0 }
            ).subtracting([accountID])
            for credentialID in obsoleteCredentialIDs {
                try? await keychain.deleteServerCredential(serverID: credentialID)
                serverIDsWithStoredPassword.remove(credentialID)
                serverIDsWithSynchronizablePassword.remove(credentialID)
            }
        }
        if credentialData != nil {
            cacheCredentialAvailability(
                ownerID: accountID,
                accountID: accountID,
                synchronizable: submission.synchronizable
            )
        } else if previousStorage != nil {
            await refreshPasswordAvailability()
        }

        if !relatedProfileIDs.isEmpty {
            try await configService.write(
                servers: activeServers,
                keys: snapshot.keys,
                authorizations: snapshot.authorizations
            )
            appendAudit(
                category: "ssh-config",
                action: "write",
                targetID: accountID.uuidString,
                result: "account-updated"
            )
            await persist()
        }
        return accountID
    }

    @discardableResult
    func saveSSHConnectionProfile(_ draft: SSHAccessSetupDraft) async throws -> UUID {
        try await requireLegacyMutation()
        guard hostV6Runtime == nil else {
            throw SSHServiceError.operationFailed("当前 V6 兼容模式暂不支持编辑连接配置。")
        }
        guard topology.node(id: draft.nodeID) != nil,
              let account = topology.activeAccounts.first(where: {
                  $0.id == draft.accountID && $0.nodeID == draft.nodeID
              }),
              let endpoint = topology.endpoint(id: draft.endpointID),
              !endpoint.isDeleted,
              endpoint.nodeID == draft.nodeID,
              endpoint.serviceID == nil,
              endpoint.protocol == .ssh else {
            throw SSHServiceError.operationFailed("所选账户或网络路径已失效，请重新选择。")
        }
        if let message = sshAliasValidationMessage(
            draft.sshAlias,
            excludingProfileID: draft.profileID
        ) {
            throw SSHServiceError.operationFailed(message)
        }

        let now = Date()
        let profileID = draft.profileID ?? UUID()
        let alias = draft.sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingAlias = topology.connectionProfile(id: profileID)?.sshAlias
        try await configService.validateAlias(alias, excluding: existingAlias)
        if let index = topology.sshConnectionProfiles.firstIndex(where: { $0.id == profileID }) {
            topology.sshConnectionProfiles[index].accountID = account.id
            topology.sshConnectionProfiles[index].sshAlias = alias
            topology.sshConnectionProfiles[index].routePolicy = .fixed(endpointID: endpoint.id)
            topology.sshConnectionProfiles[index].updatedAt = now
            topology.sshConnectionProfiles[index].isDeleted = false
            topology.sshConnectionProfiles[index].version += 1
        } else {
            topology.sshConnectionProfiles.append(SSHConnectionProfile(
                id: profileID,
                accountID: account.id,
                sshAlias: alias,
                routePolicy: .fixed(endpointID: endpoint.id),
                createdAt: now,
                updatedAt: now
            ))
        }

        let currentDeviceID = currentDevice?.id
            ?? defaults.string(forKey: "KeyPort.deviceID")
            ?? "local"
        snapshot = TopologySnapshotMigration.legacyProjection(
            from: topology,
            currentDeviceID: currentDeviceID
        )
        selectedServerID = profileID
        appendAudit(
            category: "ssh-profile",
            action: draft.profileID == nil ? "create" : "update",
            targetID: profileID.uuidString,
            result: endpoint.networkScope.rawValue
        )
        await persist(profileBindings: [SSHConnectionProfileNodeBinding(
            profileID: profileID,
            nodeID: draft.nodeID,
            endpointID: endpoint.id
        )])
        try await configService.write(
            servers: activeServers,
            keys: snapshot.keys,
            authorizations: snapshot.authorizations
        )
        appendAudit(category: "ssh-config", action: "write", targetID: profileID.uuidString, result: "success")
        await persist()
        return profileID
    }

    private func sshCommand(account: SSHAccount, endpoint: Endpoint) -> String {
        let port = endpoint.port == 22 ? "" : "-p \(endpoint.port) "
        return "ssh \(port)\(account.username)@\(endpoint.address)"
    }

    func confirmedHostKeys(forNodeID nodeID: UUID, endpointID: UUID? = nil) -> [HostKeyRecord] {
        let endpointIDs: Set<UUID>
        if let endpointID {
            endpointIDs = [endpointID]
        } else {
            endpointIDs = Set(topology.endpoints(for: nodeID, endpointProtocol: .ssh).map(\.id))
        }
        return topology.hostKeyTrusts
            .filter {
                endpointIDs.contains($0.endpointID)
                    && !$0.isDeleted
                    && $0.state == .confirmed
            }
            .map {
                HostKeyRecord(
                    algorithm: $0.algorithm,
                    fingerprint: $0.fingerprint,
                    knownHostsLine: $0.knownHostsLine,
                    firstConfirmedAt: $0.firstConfirmedAt,
                    lastSeenAt: $0.lastSeenAt
                )
            }
            .sorted { ($0.algorithm, $0.fingerprint) < ($1.algorithm, $1.fingerprint) }
    }

    func saveNodeEndpoint(_ draft: NodeEndpointDraft, forNodeID nodeID: UUID) async throws {
        try await requireLegacyMutation()
        let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            throw SSHServiceError.operationFailed("请输入节点地址或 IP。")
        }
        guard (1...65_535).contains(draft.port) else {
            throw SSHServiceError.operationFailed("请输入 1 到 65535 之间的有效端口。")
        }
        guard let nodeIndex = topology.nodes.firstIndex(where: { $0.id == nodeID && !$0.isDeleted }) else {
            throw SSHServiceError.operationFailed("目标节点不存在或已被删除。")
        }

        let port = UInt16(draft.port)
        let normalizedAddress = TopologyStableID.normalize(address)
        let existingEndpointIndex = topology.endpoints.firstIndex { endpoint in
            endpoint.nodeID == nodeID
                && endpoint.serviceID == nil
                && endpoint.protocol == .ssh
                && endpoint.port == port
                && TopologyStableID.normalize(endpoint.address) == normalizedAddress
        }
        if let existingEndpointIndex {
            guard topology.endpoints[existingEndpointIndex].source != .tailscale else {
                throw SSHServiceError.operationFailed("这个地址由 Tailscale 自动维护，请直接使用自动发现的网络要求。")
            }
            topology.endpoints[existingEndpointIndex].isDeleted = false
            topology.endpoints[existingEndpointIndex].label = label.isEmpty ? address : label
            topology.endpoints[existingEndpointIndex].networkScope = draft.networkScope
            topology.endpoints[existingEndpointIndex].source = .manual
        } else {
            let nextPriority = (topology.endpoints(for: nodeID).map(\.priority).max() ?? -1) + 1
            topology.endpoints.append(Endpoint(
                id: TopologyStableID.nodeEndpoint(
                    nodeID: nodeID,
                    address: address,
                    port: port,
                    protocol: .ssh
                ),
                nodeID: nodeID,
                address: address,
                label: label.isEmpty ? address : label,
                port: port,
                protocol: .ssh,
                networkScope: draft.networkScope,
                source: .manual,
                priority: nextPriority
            ))
        }

        var node = topology.nodes[nodeIndex]
        node.roles = Array(Set(node.roles + [.sshHost])).sorted { $0.rawValue < $1.rawValue }
        node.updatedAt = .now
        topology.nodes[nodeIndex] = node
        appendAudit(category: "endpoint", action: "create", targetID: nodeID.uuidString, result: draft.networkScope.rawValue)
        await persist()
    }

    func tailscaleServerDraft(
        for suggestion: TailscaleSSHServerSuggestion,
        existingServer: ServerConnection? = nil
    ) -> ServerDraft {
        guard let existingServer else {
            return ServerDraft(
                tailscaleSuggestion: suggestion,
                aliasesToAvoid: managedAliases
            )
        }

        var draft = ServerDraft(server: existingServer)
        draft.tailscaleSuggestion = suggestion
        if let profile = topology.connectionProfile(id: existingServer.id),
           let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }) {
            draft.targetNodeID = account.nodeID
            draft.targetEndpointID = profile.routePolicy.fixedEndpointID
        }
        draft.aliasesToAvoid = Set(
            snapshot.servers.lazy
                .filter { !$0.isDeleted && $0.id != existingServer.id }
                .map(\.alias)
        )
        return draft
    }

    func existingTailscaleServerID(
        for suggestion: TailscaleSSHServerSuggestion,
        draft: ServerDraft
    ) -> UUID? {
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return activeServers.first {
            suggestion.matchesAccount(
                host: draft.host,
                port: draft.port,
                username: username,
                server: $0
            )
        }?.id
    }
    var pendingPreviousHostKeys: [HostKeyRecord] {
        guard let pendingHostKeyServerID else { return [] }
        return snapshot.servers.first(where: { $0.id == pendingHostKeyServerID })?.confirmedHostKeys ?? []
    }
    var currentDeviceKeys: [SSHKeyRecord] {
        guard let currentDevice else { return [] }
        return snapshot.keys.filter { $0.deviceID == currentDevice.id && $0.isLocallyAvailable }
    }

    var keyServerRows: [KeyServerRow] {
        snapshot.servers.filter { !$0.isDeleted }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map { server in
            let authorization = snapshot.authorizations.first { authorization in
                guard authorization.serverID == server.id,
                      !authorization.isDeleted,
                      authorization.status == .authorized,
                      let key = key(for: authorization) else { return false }
                return key.deviceID == currentDevice?.id
            }
            let selectedKey = key(for: server)
            return KeyServerRow(server: server, key: selectedKey, authorization: authorization)
        }
    }

    var keyConnectionRows: [KeyConnectionRow] {
        var rows: [KeyConnectionRow] = []
        var representedServerIDs = Set<UUID>()

        for connection in discoveredSSHConnections {
            let server = server(matching: connection)
            let serverRow = server.flatMap { server in keyServerRows.first { $0.server.id == server.id } }
            if let server { representedServerIDs.insert(server.id) }
            rows.append(KeyConnectionRow(connection: connection, serverRow: serverRow))
        }

        rows.append(contentsOf: keyServerRows
            .filter { !representedServerIDs.contains($0.server.id) }
            .map { KeyConnectionRow(connection: connection(for: $0.server), serverRow: $0) })

        return rows.sorted { lhs, rhs in
            lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    var selectedKeyServerRow: KeyServerRow? {
        guard let selectedKeyItemID else { return nil }
        return keyServerRows.first { $0.id == selectedKeyItemID }
    }

    var selectedStandaloneKey: SSHKeyRecord? {
        guard let selectedKeyItemID, selectedKeyItemID.hasPrefix("identity:") else { return nil }
        let keyID = String(selectedKeyItemID.dropFirst("identity:".count))
        return snapshot.keys.first { $0.id == keyID }
    }

    var selectedDiscoveredSSHConnection: DiscoveredSSHConnection? {
        guard let selectedKeyItemID, selectedKeyItemID.hasPrefix("config:") else { return nil }
        let alias = String(selectedKeyItemID.dropFirst("config:".count))
        return discoveredSSHConnections.first { $0.alias == alias }
    }

    var promptedPasswordServer: ServerConnection? {
        guard let passwordPromptServerID else { return nil }
        return snapshot.servers.first { $0.id == passwordPromptServerID && !$0.isDeleted }
    }

    func load() async {
        guard !isLoaded else { return }
        isInitialLoadInProgress = true
        do {
            if let hostV6Runtime {
                let presentation = try await hostV6Runtime.loadPresentationSnapshot(from: store)
                snapshot = presentation.snapshot
                isMetadataReadOnly = !presentation.mode.allowsLegacyWrites
                graphWorkspace.update(
                    envelope: presentation.graphEnvelope,
                    currentDeviceID: presentation.graphEnvelope?.local.deviceStates.first(where: \.isCurrent)?.deviceID
                        ?? snapshot.devices.first(where: \.isCurrent)?.id
                )
                if presentation.mode.allowsLegacyWrites {
                    _ = try? await configService.adoptExistingManagedConfigBaseline(
                        servers: snapshot.servers.filter { !$0.isDeleted },
                        keys: snapshot.keys,
                        authorizations: snapshot.authorizations
                    )
                    normalizeStableMetadataIDs()
                    ensureCurrentDevice()
                    try await refreshKeys(recordAudit: false)
                } else {
                    discoveredSSHConnections = await configService.discoverConnections()
                }
                await refreshPasswordAvailability()
                if selectedServerID == nil { selectedServerID = activeServers.first?.id }
                if selectedKeyItemID == nil {
                    selectedKeyItemID = keyServerRows.first?.id
                        ?? discoveredSSHConnections.first.map { "config:\($0.alias)" }
                        ?? snapshot.keys.first.map { "identity:\($0.id)" }
                }
                if selectedDeviceItemID == nil {
                    selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
                }
                isLoaded = true
                if presentation.mode.allowsLegacyWrites {
                    await refreshTailscale()
                    appendAudit(category: "app", action: "load", result: "success")
                    await refreshMissingMachineConfigurations()
                    await persist()
                }
                isInitialLoadInProgress = false
                if presentation.mode.allowsLegacyWrites {
                    scheduleCloudSyncIfNeeded()
                }
                return
            } else {
                snapshot = try await store.load()
                ensureCurrentDevice()
                let currentDeviceID = snapshot.devices.first(where: \.isCurrent)?.id
                    ?? defaults.string(forKey: "KeyPort.deviceID")
                    ?? KeyPortNaming.newDeviceID()
                let currentDeviceName = snapshot.devices.first(where: { $0.id == currentDeviceID })?.name
                    ?? Host.current().localizedName
                    ?? "此 Mac"
                let migrated = TopologySnapshotMigration.fromLegacy(
                    snapshot,
                    currentDeviceID: currentDeviceID,
                    currentDeviceName: currentDeviceName
                )
                let storedTopology: TopologySnapshot?
                do {
                    storedTopology = try await topologyStore.load()
                } catch {
                    // A corrupt or partially-written topology must not hide a
                    // valid legacy SSH snapshot. Rebuild the topology below.
                    storedTopology = nil
                }
                if let storedTopology,
                   storedTopology.schemaVersion <= TopologySnapshot.currentSchemaVersion,
                   storedTopology.profiles.contains(where: { $0.id == currentDeviceID }) {
                    topology = TopologySnapshotMigration.refreshed(
                        from: snapshot,
                        preserving: storedTopology,
                        currentDeviceID: currentDeviceID,
                        currentDeviceName: currentDeviceName
                    )
                    snapshot = TopologySnapshotMigration.legacyProjection(
                        from: topology,
                        currentDeviceID: currentDeviceID
                    )
                } else {
                    topology = migrated
                    try await topologyStore.save(topology)
                }
                isMetadataReadOnly = false
                graphWorkspace.update(
                    topology: topology,
                    currentDeviceID: currentDeviceID,
                    tailscaleStatus: tailscaleStatus
                )
                _ = try? await configService.adoptExistingManagedConfigBaseline(
                    servers: snapshot.servers.filter { !$0.isDeleted },
                    keys: snapshot.keys,
                    authorizations: snapshot.authorizations
                )
                normalizeStableMetadataIDs()
                ensureCurrentDevice()
                try await refreshKeys(recordAudit: false)
                discoveredSSHConnections = await configService.discoverConnections()
                await refreshPasswordAvailability()
                if selectedServerID == nil { selectedServerID = activeServers.first?.id }
                if selectedKeyItemID == nil {
                    selectedKeyItemID = keyServerRows.first?.id
                        ?? discoveredSSHConnections.first.map { "config:\($0.alias)" }
                        ?? snapshot.keys.first.map { "identity:\($0.id)" }
                }
                if selectedDeviceItemID == nil {
                    selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
                }
                isLoaded = true
                await refreshTailscale()
                appendAudit(category: "app", action: "load", result: "success")
                await refreshMissingMachineConfigurations()
                await persist()
                isInitialLoadInProgress = false
                scheduleCloudSyncIfNeeded()
            }
        } catch {
            isLoaded = true
            isInitialLoadInProgress = false
            if hostV6Runtime != nil {
                isMetadataReadOnly = true
            }
            present(error)
        }
    }

    /// 用户明确触发的一次性监听发现。结果只进入内存，不调用 `persist()`，
    /// 也不创建、更新或删除任何 v5 Server/Service 对象。
    func discoverListeners(
        for serverID: UUID,
        limits: DiscoveryLimits = .default
    ) async throws -> DiscoveryResult {
        guard discoveryEnabled else { throw ListenerDiscoveryTriggerError.featureDisabled }
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else {
            throw ListenerDiscoveryTriggerError.hostNotFound
        }
        guard server.status == .authorized else {
            throw ListenerDiscoveryTriggerError.hostNotAuthorized
        }
        guard let route = sshOperationServer(for: server) else {
            throw StableOperationFailure(
                stage: .sshTrust,
                objectID: serverID.uuidString.lowercased(),
                code: .identityUnavailable,
                recoveryAction: .edit
            )
        }
        guard let identity = key(for: route) else {
            throw StableOperationFailure(
                stage: .sshTrust,
                objectID: serverID.uuidString.lowercased(),
                code: .identityUnavailable,
                recoveryAction: .prepareLocalKey
            )
        }

        let operationID = UUID()
        let generation = discoveryGeneration
        let hostID = HostV6.StableID.host(
            legacyHost: route.host,
            port: UInt16(clamping: route.port)
        )
        activeDiscoveryOperations[serverID] = ActiveDiscoveryOperation(
            operationID: operationID,
            hostID: hostID
        )
        activeDiscoveryOperationsByHost[hostID] = operationID
        let executor = discoveryExecutor
        let adapter = discoveryAdapter
        defer {
            if activeDiscoveryOperations[serverID]?.operationID == operationID {
                activeDiscoveryOperations.removeValue(forKey: serverID)
            }
            if activeDiscoveryOperationsByHost[hostID] == operationID {
                activeDiscoveryOperationsByHost.removeValue(forKey: hostID)
            }
        }

        let result = try await discoveryCoordinator.discover(
            hostID: hostID,
            operationID: operationID
        ) {
            let session = try await TrustedSSHSession.establish(
                route: route,
                observedHostKeys: route.confirmedHostKeys,
                identity: identity,
                executor: executor
            )
            return try await adapter.discover(using: session, limits: limits)
        }

        try Task.checkCancellation()
        guard discoveryEnabled,
              discoveryGeneration == generation,
              activeDiscoveryOperations[serverID]?.operationID == operationID,
              activeDiscoveryOperationsByHost[hostID] == operationID else {
            throw DiscoveryCoordinatorError.cancelled
        }
        listenerDiscoveryResults[serverID] = result
        return result
    }

    /// 页面关闭或用户取消时立即丢弃本机内存中的候选，并取消远端进程。
    func clearListenerDiscovery(for serverID: UUID) async {
        await cancelListenerDiscovery(for: serverID)
        listenerDiscoveryResults.removeValue(forKey: serverID)
    }

    func cancelListenerDiscovery(for serverID: UUID) async {
        guard let active = activeDiscoveryOperations[serverID] else { return }
        activeDiscoveryOperations.removeValue(forKey: serverID)
        if activeDiscoveryOperationsByHost[active.hostID] == active.operationID {
            activeDiscoveryOperationsByHost.removeValue(forKey: active.hostID)
        }
        await discoveryCoordinator.cancel(operationID: active.operationID)
    }

    /// 关闭 flag 即可回滚该切片；同时清除候选并请求取消所有在途发现。
    func setDiscoveryEnabled(_ enabled: Bool) {
        let stateChanged = discoveryEnabled != enabled
        discoveryEnabled = enabled
        defaults.set(enabled, forKey: DiscoveryFeatureFlags.discoveryEnabledKey)
        if stateChanged || !enabled {
            discoveryGeneration &+= 1
        }
        guard !enabled else { return }

        let operationIDs = Set(activeDiscoveryOperations.values.map(\.operationID))
        activeDiscoveryOperations.removeAll()
        activeDiscoveryOperationsByHost.removeAll()
        listenerDiscoveryResults.removeAll()
        for operationID in operationIDs {
            Task { await discoveryCoordinator.cancel(operationID: operationID) }
        }
    }

    func cloudSyncSettingChanged(_ enabled: Bool) {
        scheduledCloudSync?.cancel()
        scheduledCloudSync = nil
        automaticCloudRetryAttempt = 0
        guard enabled else {
            cloudState = .disabled
            return
        }
        cloudState = .checking
        Task { await synchronizeCloud(userInitiated: false) }
    }

    func validateServerEditor(
        draft: ServerDraft,
        password: String,
        existingServerID: UUID?,
        trustedHostKeys: [HostKeyRecord]
    ) async -> ServerEditorValidationResult {
        var log = ["正在解析 \(draft.username)@\(draft.host):\(draft.port)", "正在扫描服务器主机密钥..."]
        guard await authorizeLegacyMutation() else {
            let detail = errorMessage ?? "v6 已取得元数据写权，旧编辑流程已停用。"
            log.append(detail)
            return failedEditorValidation(
                detail: detail,
                log: log,
                confirmedHostKeys: trustedHostKeys
            )
        }
        let server = editorServer(draft: draft, existingServerID: existingServerID, confirmedHostKeys: trustedHostKeys)

        do {
            try await validateEditorDraft(draft, existingServerID: existingServerID)
            let observed = try await hostKeyService.scan(server: server)
            log.append("已收到 \(observed.count) 个主机密钥指纹。")

            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: trustedHostKeys) {
            case .pending:
                let detail = "请确认显示的主机密钥指纹以继续。"
                log.append(detail)
                return ServerEditorValidationResult(
                    state: .confirmationRequired,
                    check: AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now),
                    logLines: log,
                    observedHostKeys: observed,
                    confirmedHostKeys: trustedHostKeys,
                    machineConfiguration: nil
                )
            case .changed(let algorithms):
                let detail = "以下算法的主机密钥已变更：\(algorithms.joined(separator: "、"))。请确认替换后的指纹以继续。"
                log.append(detail)
                return ServerEditorValidationResult(
                    state: .confirmationRequired,
                    check: AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now),
                    logLines: log,
                    observedHostKeys: observed,
                    confirmedHostKeys: trustedHostKeys,
                    machineConfiguration: nil
                )
            case .confirmed:
                log.append("主机身份已确认。")
            }

            var serversForKnownHosts = activeServers.filter { $0.id != server.id }
            serversForKnownHosts.append(server)
            try await hostKeyService.persistConfirmedKeys(
                trustedHostKeys,
                allServers: serversForKnownHosts
            )

            var passwordData: Data
            if !password.isEmpty {
                passwordData = Data(password.utf8)
            } else if let existingServerID,
                      await storedCredentialOwnerID(forProfileID: existingServerID) != nil {
                var credential = try await serverCredential(forProfileID: existingServerID)
                passwordData = credential.passwordData
                credential.passwordData.resetBytes(in: credential.passwordData.indices)
            } else {
                let detail = "检查 SSH 前请输入服务器密码。"
                log.append(detail)
                return failedEditorValidation(detail: detail, log: log, confirmedHostKeys: trustedHostKeys)
            }
            defer { passwordData.resetBytes(in: passwordData.indices) }

            log.append("正在测试仅使用密码的 SSH 身份验证...")
            guard try await sshService.testPassword(server: server, passwordData: passwordData) else {
                let detail = "服务器拒绝了该密码。"
                log.append(detail)
                return failedEditorValidation(detail: detail, log: log, confirmedHostKeys: trustedHostKeys)
            }

            log.append("密码登录验证成功。")
            let machineConfiguration = try await sshService.inspectMachineWithPassword(server: server, passwordData: passwordData)
            if machineConfiguration != nil {
                log.append("远程机器配置已同步。")
            } else {
                log.append("身份验证已通过，但无法获取机器配置。")
            }
            let check = AuthenticationCheck(
                state: .succeeded,
                detail: "密码登录验证成功。",
                checkedAt: .now
            )
            return ServerEditorValidationResult(
                state: .succeeded,
                check: check,
                logLines: log,
                observedHostKeys: [],
                confirmedHostKeys: trustedHostKeys,
                machineConfiguration: machineConfiguration
            )
        } catch {
            let message = UserFacingText.localizedError(error)
            log.append(message)
            return failedEditorValidation(
                detail: message,
                log: log,
                confirmedHostKeys: trustedHostKeys
            )
        }
    }

    func saveServerEditor(_ submission: ServerEditorSubmission, existingServerID: UUID?) async throws -> UUID {
        try await requireLegacyMutation()
        try await validateEditorDraft(submission.draft, existingServerID: existingServerID)
        let existingServer = existingServerID.flatMap { id in
            snapshot.servers.first(where: { $0.id == id && !$0.isDeleted })
        }
        if let passwordCheck = submission.passwordCheck {
            guard passwordCheck.state == .succeeded else {
                throw SSHServiceError.operationFailed("请先成功完成 SSH 检查再保存。")
            }
        } else {
            guard let existingServer else {
                throw SSHServiceError.operationFailed("新建服务器前，请先成功完成 SSH 检查。")
            }
            let sameAuthenticationContext = existingServer.host.trimmingCharacters(in: .whitespacesAndNewlines)
                == submission.draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
                && existingServer.port == submission.draft.port
                && existingServer.username.trimmingCharacters(in: .whitespacesAndNewlines)
                    == submission.draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sameAuthenticationContext,
                  submission.password.isEmpty,
                  submission.confirmedHostKeys == existingServer.confirmedHostKeys else {
                throw SSHServiceError.operationFailed("连接信息或主机身份已变更，请先成功完成 SSH 检查。")
            }
        }
        if existingServerID == nil && submission.password.isEmpty {
            throw SSHServiceError.missingPassword
        }

        let now = Date()
        let confirmedKeys = submission.confirmedHostKeys.map { key in
            HostKeyRecord(
                algorithm: key.algorithm,
                fingerprint: key.fingerprint,
                knownHostsLine: key.knownHostsLine,
                firstConfirmedAt: key.firstConfirmedAt ?? now,
                lastSeenAt: now
            )
        }
        let trimmedName = submission.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = submission.draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = submission.draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = submission.draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = submission.draft.group.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverID = existingServerID ?? UUID()

        var passwordData: Data
        let hasNewPassword = !submission.password.isEmpty
        if hasNewPassword {
            passwordData = Data(submission.password.utf8)
        } else if let existingServerID {
            var credential = try await serverCredential(forProfileID: existingServerID)
            passwordData = credential.passwordData
            credential.passwordData.resetBytes(in: credential.passwordData.indices)
        } else {
            throw SSHServiceError.missingPassword
        }
        defer { passwordData.resetBytes(in: passwordData.indices) }
        let credentialOwnerID = credentialOwnerID(
            forProfileID: serverID,
            targetNodeID: submission.draft.targetNodeID,
            username: trimmedUsername
        )
        let passwordStorageChanged = hasStoredPassword(serverID: serverID)
            && isPasswordSynchronizable(serverID: serverID) != submission.synchronizable
        try await keychain.saveServerCredential(
            username: trimmedUsername,
            passwordData: passwordData,
            serverID: credentialOwnerID,
            synchronizable: submission.synchronizable
        )
        cacheCredentialAvailability(
            ownerID: credentialOwnerID,
            profileID: serverID,
            synchronizable: submission.synchronizable
        )
        if passwordStorageChanged {
            appendAudit(
                category: "keychain",
                action: "change-password-storage",
                targetID: serverID.uuidString,
                result: submission.synchronizable ? "synchronizable" : "local"
            )
        }

        let peerServerIDs = existingServerID.map(serverIDsSharingEndpoint(with:)) ?? []
        let machineConfiguration = submission.passwordCheck == nil
            ? existingServer?.machineConfiguration
            : submission.machineConfiguration
        let machineConfigurationRefreshAttemptedAt = submission.passwordCheck == nil
            ? existingServer?.machineConfigurationRefreshAttemptedAt ?? now
            : submission.machineConfiguration?.synchronizedAt ?? now
        let sharedFields = SharedServerFields(
            name: trimmedName,
            host: trimmedHost,
            port: submission.draft.port,
            group: trimmedGroup,
            notes: submission.draft.notes,
            confirmedHostKeys: confirmedKeys,
            machineConfiguration: machineConfiguration,
            machineConfigurationRefreshAttemptedAt: machineConfigurationRefreshAttemptedAt
        )

        if let existingServerID,
           let index = snapshot.servers.firstIndex(where: { $0.id == existingServerID }) {
            let authenticationContextChanged = snapshot.servers[index].host != trimmedHost
                || snapshot.servers[index].port != submission.draft.port
                || snapshot.servers[index].username != trimmedUsername
            sharedFields.apply(to: &snapshot.servers[index])
            snapshot.servers[index].username = trimmedUsername
            snapshot.servers[index].alias = trimmedAlias
            if let passwordCheck = submission.passwordCheck {
                snapshot.servers[index].passwordCheck = passwordCheck
                snapshot.servers[index].lastCheckedAt = passwordCheck.checkedAt
            }
            if authenticationContextChanged {
                snapshot.servers[index].keyCheck = nil
                snapshot.servers[index].status = key(for: snapshot.servers[index]) == nil ? .missingLocalKey : .needsAuthorization
                snapshot.servers[index].statusDetail = "连接信息已变更。密码登录已验证，请重新检测免密。"
            }
            snapshot.servers[index].updatedAt = now
            snapshot.servers[index].version += 1

            for peerID in peerServerIDs where peerID != existingServerID {
                guard let peerIndex = snapshot.servers.firstIndex(where: { $0.id == peerID }) else { continue }
                let endpointChanged = snapshot.servers[peerIndex].host != trimmedHost
                    || snapshot.servers[peerIndex].port != submission.draft.port
                sharedFields.apply(
                    to: &snapshot.servers[peerIndex],
                    preservesMachineConfigurationWhenUnavailable: true
                )
                if endpointChanged {
                    snapshot.servers[peerIndex].passwordCheck = nil
                    snapshot.servers[peerIndex].keyCheck = nil
                    snapshot.servers[peerIndex].status = key(for: snapshot.servers[peerIndex]) == nil ? .missingLocalKey : .needsAuthorization
                    snapshot.servers[peerIndex].statusDetail = "服务器端点已变更，请重新检测此用户的免密登录。"
                    snapshot.servers[peerIndex].lastCheckedAt = nil
                }
                snapshot.servers[peerIndex].updatedAt = now
                snapshot.servers[peerIndex].version += 1
            }
            appendAudit(
                category: "server",
                action: "update",
                targetID: existingServerID.uuidString,
                result: submission.passwordCheck == nil ? "metadata-only" : "password-verified"
            )
        } else {
            let server = ServerConnection(
                id: serverID,
                name: trimmedName,
                host: trimmedHost,
                port: submission.draft.port,
                username: trimmedUsername,
                alias: trimmedAlias,
                group: trimmedGroup,
                notes: submission.draft.notes,
                confirmedHostKeys: confirmedKeys,
                status: preferredKey == nil ? .missingLocalKey : .needsAuthorization,
                statusDetail: "密码登录已验证，现在可以为当前 Mac 启用免密。",
                lastCheckedAt: submission.passwordCheck?.checkedAt,
                passwordCheck: submission.passwordCheck,
                machineConfiguration: machineConfiguration,
                machineConfigurationRefreshAttemptedAt: machineConfigurationRefreshAttemptedAt
            )
            snapshot.servers.append(server)
            appendAudit(category: "server", action: "create", targetID: serverID.uuidString, result: "password-verified")
        }

        selectedServerID = serverID
        try await hostKeyService.persistConfirmedKeys(confirmedKeys, allServers: snapshot.servers.filter { !$0.isDeleted })
        ensureAuthorizationRecordForVerifiedServer(serverID: serverID)
        try await configService.write(servers: activeServers, keys: snapshot.keys, authorizations: snapshot.authorizations)
        appendAudit(category: "ssh-config", action: "write", targetID: serverID.uuidString, result: "success")
        let profileBindings: [SSHConnectionProfileNodeBinding]
        if let targetNodeID = submission.draft.targetNodeID {
            let bindingProfileIDs: [UUID]
            if existingServerID != nil {
                bindingProfileIDs = Array(Set(peerServerIDs).union([serverID])).sorted {
                    $0.uuidString < $1.uuidString
                }
            } else {
                bindingProfileIDs = [serverID]
            }
            profileBindings = bindingProfileIDs.map { profileID in
                SSHConnectionProfileNodeBinding(
                    profileID: profileID,
                    nodeID: targetNodeID,
                    endpointID: submission.draft.targetEndpointID
                )
            }
        } else {
            profileBindings = []
        }
        await persist(profileBindings: profileBindings)
        return serverID
    }

    func deleteSelectedServer() async {
        guard let id = selectedServerID else { return }
        await deleteServer(id)
    }

    func deleteServer(_ id: UUID) async {
        guard await authorizeLegacyMutation() else { return }
        guard let index = snapshot.servers.firstIndex(where: { $0.id == id }) else { return }
        let credentialIDs = credentialOwnerIDs(forProfileID: id)
        let siblingProfiles = accountID(forProfileID: id).map { accountID in
            profileIDs(forAccountID: accountID).filter { $0 != id }
        } ?? []
        snapshot.servers[index].isDeleted = true
        snapshot.servers[index].updatedAt = .now
        snapshot.servers[index].version += 1
        if siblingProfiles.isEmpty {
            for credentialID in credentialIDs {
                try? await keychain.deleteServerCredential(serverID: credentialID)
                serverIDsWithStoredPassword.remove(credentialID)
                serverIDsWithSynchronizablePassword.remove(credentialID)
            }
        }
        serverIDsWithStoredPassword.remove(id)
        serverIDsWithSynchronizablePassword.remove(id)
        appendAudit(category: "server", action: "delete", targetID: id.uuidString, result: "tombstoned")
        if selectedServerID == id { selectedServerID = activeServers.first?.id }
        await persist()
        await writeConfig()
    }

    func refreshKeys(recordAudit: Bool = true) async throws {
        try await requireLegacyMutation()
        ensureCurrentDevice()
        guard let device = currentDevice else { return }
        let scanned = try await keyService.scan(deviceID: device.id)
        discoveredSSHConnections = await configService.discoverConnections()
        reconcileImportedServerAliases()
        migrateImportedConnectionKeyStatusIfNeeded()
        migrateLegacyAuthenticationChecksIfNeeded()
        migrateDeviceNetworkIdentitySchemaIfNeeded()
        snapshot.migrateNodeAssociationsSchemaIfNeeded()
        let existingByFingerprint = Dictionary(uniqueKeysWithValues: snapshot.keys.map { ($0.fingerprint, $0) })
        let merged = scanned.map { key -> SSHKeyRecord in
            guard let existing = existingByFingerprint[key.fingerprint] else { return key }
            var value = key
            value.id = existing.id
            value.deviceID = existing.deviceID
            return value
        }
        let remoteOnly = snapshot.keys.filter { existing in !merged.contains(where: { $0.fingerprint == existing.fingerprint }) }
        snapshot.keys = remoteOnly + merged
        if recordAudit { appendAudit(category: "key", action: "scan", result: "found-\(merged.count)") }
        await persist()
    }

    func generateKey() async {
        guard await authorizeLegacyMutation() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try await generateCurrentDeviceKey()
            appendAudit(category: "key", action: "generate", targetID: key.id, result: "ed25519-success")
            await persist()
        } catch { present(error) }
    }

    func importKey() async {
        guard await authorizeLegacyMutation() else { return }
        guard let device = currentDevice, let url = await fileSelection.selectPrivateKey() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try await keyService.importPrivateKey(from: url, device: device)
            if snapshot.keys.contains(where: { $0.fingerprint == key.fingerprint }) {
                errorMessage = "KeyPort 中已存在该公钥指纹。"
                return
            }
            snapshot.keys.append(key)
            selectedKeyID = key.id
            selectedKeyItemID = "identity:\(key.id)"
            appendAudit(category: "key", action: "import", targetID: key.id, result: key.kind.rawValue)
            await persist()
        } catch { present(error) }
    }

    func addSelectedKeyToAgent() async {
        guard await authorizeLegacyMutation() else { return }
        guard let selectedKeyID, let key = snapshot.keys.first(where: { $0.id == selectedKeyID }) else { return }
        do {
            try await keyService.addToAgent(key)
            if let index = snapshot.keys.firstIndex(where: { $0.id == selectedKeyID }) { snapshot.keys[index].isInAgent = true }
            appendAudit(category: "key", action: "load-agent", targetID: selectedKeyID, result: "success")
            await persist()
        } catch { present(error) }
    }

    func checkPasswordSelected() async {
        guard let id = selectedServerID else { return }
        await checkPassword(serverID: id)
    }

    func checkKeySelected() async {
        guard let id = selectedServerID else { return }
        await checkKey(serverID: id)
    }

    func checkPassword(serverID: UUID) async {
        await check(serverID: serverID, kind: .password)
    }

    func checkKey(serverID: UUID) async {
        await check(serverID: serverID, kind: .key)
    }

    func checkKey(serverID: UUID, endpoint: Endpoint?) async {
        await check(serverID: serverID, kind: .key, endpointOverride: endpoint)
    }

    func passwordlessPrimaryAction(for server: ServerConnection) -> PasswordlessPrimaryAction {
        if server.status == .checking || server.status == .syncing {
            return .checking
        }
        if server.confirmedHostKeys.isEmpty
            || server.status == .hostKeyPending
            || server.status == .hostKeyMismatch {
            return .reviewHostIdentity
        }
        if server.status == .authorized, privateKey(for: server) != nil {
            return .verify
        }
        if privateKey(for: server) == nil {
            return .generateKeyAndEnable
        }
        if !hasStoredPassword(serverID: server.id) {
            return .enterPasswordAndEnable
        }
        return .enable
    }

    func performPasswordlessPrimaryAction(serverID: UUID) async {
        await performPasswordlessPrimaryAction(serverID: serverID, endpoint: nil)
    }

    func performPasswordlessPrimaryAction(serverID: UUID, endpoint: Endpoint?) async {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        switch passwordlessPrimaryAction(for: server) {
        case .verify, .reviewHostIdentity:
            await checkKey(serverID: serverID, endpoint: endpoint)
        case .enable, .generateKeyAndEnable:
            await authorizeCurrentDevice(serverID: serverID, endpoint: endpoint)
        case .enterPasswordAndEnable:
            requestPassword(for: serverID, endpoint: endpoint)
        case .checking:
            break
        }
    }

    func synchronizeSSHAuthorizationSelected() async {
        guard let id = selectedServerID else { return }
        await synchronizeSSHAuthorization(serverID: id)
    }

    func synchronizeSSHAuthorization(serverID: UUID) async {
        await synchronizeSSHAuthorization(serverID: serverID, endpoint: nil)
    }

    func synchronizeSSHAuthorization(serverID: UUID, endpoint: Endpoint?) async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy,
              let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        guard let compatibleRouteServer = sshOperationServer(for: server) else {
            markSSHRouteUnavailable(serverID: serverID, kind: .key)
            return
        }
        let routeServer = self.server(compatibleRouteServer, using: endpoint)

        isBusy = true
        retainedSSHCheckLog = SSHCheckLog(
            serverID: serverID,
            title: "SSH 授权同步",
            lines: ["正在同步 \(server.username)@\(routeServer.endpoint)...", "正在扫描服务器主机密钥..."]
        )
        updateAuthenticationCheck(id: serverID, kind: .key, state: .checking, detail: "正在检查主机身份并准备 SSH 授权。", checkedAt: nil)
        updateServer(id: serverID, status: .syncing, detail: "正在同步 SSH 授权，完成公钥复检后才会显示免密可用。")
        defer { isBusy = false }

        var didReachEndpoint = false
        do {
            let observed = try await hostKeyService.scan(server: routeServer)
            didReachEndpoint = true
            appendSSHCheckLog("已收到 \(observed.count) 个主机密钥指纹。", serverID: serverID)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: routeServer.confirmedHostKeys) {
            case .pending:
                let detail = "同步 SSH 授权前，请核对主机密钥指纹。"
                updateServer(id: serverID, status: .hostKeyPending, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = .key
                pendingHostKeyEndpointID = endpoint?.id
                pendingHostKeyResumesAuthorization = true
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "host-key", action: "authorization-sync", targetID: serverID.uuidString, result: "pending-confirmation", level: .warning)
                recordSSHConnectionEvidence(
                    serverID: serverID,
                    routedServer: routeServer,
                    endpointOverride: endpoint,
                    wasReachable: true
                )
                await persist()
                return
            case .changed(let algorithms):
                let detail = "发生变更的算法：\(algorithms.joined(separator: "、"))。同步 SSH 授权已被阻止。"
                updateServer(id: serverID, status: .hostKeyMismatch, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = .key
                pendingHostKeyEndpointID = endpoint?.id
                pendingHostKeyResumesAuthorization = true
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "host-key", action: "authorization-sync", targetID: serverID.uuidString, result: "mismatch-blocked", level: .error)
                recordSSHConnectionEvidence(
                    serverID: serverID,
                    routedServer: routeServer,
                    endpointOverride: endpoint,
                    wasReachable: true
                )
                await persist()
                return
            case .confirmed:
                break
            }

            guard let key = key(for: server), key.isLocallyAvailable, key.privateKeyPath != nil else {
                let detail = "此 Mac 没有可用于 SSH 授权的本地私钥。请先生成或导入密钥。"
                updateServer(id: serverID, status: .missingLocalKey, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "authorization", action: "sync", targetID: serverID.uuidString, result: "missing-key", level: .warning)
                recordSSHConnectionEvidence(
                    serverID: serverID,
                    routedServer: routeServer,
                    endpointOverride: endpoint,
                    wasReachable: true
                )
                await persist()
                return
            }

            guard await storedCredentialOwnerID(forProfileID: serverID) != nil else {
                let detail = "同步 SSH 授权前，请添加并验证当前 SSH 账户的密码。"
                updateServer(id: serverID, status: .needsAuthorization, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                passwordSaveError = nil
                requestPassword(for: serverID, endpoint: endpoint)
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "authorization", action: "sync", targetID: serverID.uuidString, result: "missing-password", level: .warning)
                recordSSHConnectionEvidence(
                    serverID: serverID,
                    routedServer: routeServer,
                    endpointOverride: endpoint,
                    wasReachable: true
                )
                await persist()
                return
            }

            updateAuthenticationCheck(id: serverID, kind: .key, state: .checking, detail: "正在使用 Keychain 密码安装公钥并进行复检。", checkedAt: nil)
            appendSSHCheckLog("正在安装当前 Mac 公钥并执行强制公钥复检...", serverID: serverID)
            try await localAuthentication.authorize(reason: "在 \(server.name) 上同步此 Mac 的 SSH 授权")
            try await authorize(server: routeServer, key: key)
            await synchronizeMachineConfigurationWithKey(server: routeServer, key: key)
            appendSSHCheckLog("公钥复检成功，免密 SSH 已可用。", serverID: serverID)
            appendAudit(category: "authorization", action: "sync", targetID: serverID.uuidString, result: "verified")
        } catch {
            let message = UserFacingText.localizedError(error)
            let status: AuthorizationStatus
            let checkState: AuthenticationCheckState
            switch error as? SSHServiceError {
            case .missingPrivateKey:
                status = .missingLocalKey
                checkState = .blocked
            case .missingPassword:
                status = .needsAuthorization
                checkState = .blocked
                passwordSaveError = nil
                requestPassword(for: serverID, endpoint: endpoint)
            case .hostKeyNotConfirmed:
                status = .hostKeyPending
                checkState = .blocked
            case .hostKeyChanged:
                status = .hostKeyMismatch
                checkState = .blocked
            case .passwordAuthenticationRejected:
                status = .passwordAuthenticationFailed
                checkState = .failed
            default:
                status = .keyAuthenticationFailed
                checkState = .failed
            }
            let detail = "SSH 授权同步失败：\(message)"
            updateServer(id: serverID, status: status, detail: detail)
            updateAuthenticationCheck(id: serverID, kind: .key, state: checkState, detail: detail)
            appendSSHCheckLog(detail, serverID: serverID)
            appendAudit(category: "authorization", action: "sync", targetID: serverID.uuidString, result: "failed", level: .warning)
        }

        recordSSHConnectionEvidence(
            serverID: serverID,
            routedServer: routeServer,
            endpointOverride: endpoint,
            wasReachable: didReachEndpoint
        )
        await persist()
        let finalCheck = snapshot.servers.first(where: { $0.id == serverID })?.keyCheck
        if finalCheck?.state == .succeeded {
            retainedSSHCheckLog = nil
        }
    }

    func synchronizeMachineConfigurationSelected() async {
        guard let id = selectedServerID else { return }
        await synchronizeMachineConfiguration(serverID: id)
    }

    func synchronizeMachineConfiguration(serverID: UUID) async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy,
              let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        guard server.status == .authorized else {
            machineConfigurationSyncErrorServerID = serverID
            machineConfigurationSyncError = "请先确认 SSH 免密可用，再同步机器配置。"
            return
        }
        guard let key = key(for: server), key.isLocallyAvailable, key.privateKeyPath != nil else {
            machineConfigurationSyncErrorServerID = serverID
            machineConfigurationSyncError = "当前 Mac 没有可用于机器配置同步的本地私钥。"
            return
        }
        guard let routeServer = sshOperationServer(for: server) else {
            machineConfigurationSyncErrorServerID = serverID
            machineConfigurationSyncError = "该身份的 SSH 路由被 v6 兼容层关闭（存在待解决冲突或无可用地址）。"
            return
        }

        isBusy = true
        defer { isBusy = false }
        await synchronizeMachineConfigurationWithKey(server: routeServer, key: key)
        await persist()
    }

    func checkAll() async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy, !isInitialLoadInProgress else {
            scheduleCloudRetry(after: 5)
            return
        }
        isBusy = true
        let ids = activeServers.map(\.id)
        for id in ids {
            await check(serverID: id, kind: .password, ownsBusyState: false)
            await check(serverID: id, kind: .key, ownsBusyState: false)
        }
        isBusy = false
    }

    func confirmPendingHostKeys() async {
        guard await authorizeLegacyMutation() else { return }
        guard let serverID = pendingHostKeyServerID,
              let index = snapshot.servers.firstIndex(where: { $0.id == serverID }) else { return }
        let now = Date()
        let confirmed = pendingHostKeys.map {
            HostKeyRecord(algorithm: $0.algorithm, fingerprint: $0.fingerprint, knownHostsLine: $0.knownHostsLine, firstConfirmedAt: now, lastSeenAt: now)
        }
        let isRotation = !snapshot.servers[index].confirmedHostKeys.isEmpty
        snapshot.servers[index].confirmedHostKeys = confirmed
        snapshot.servers[index].status = key(for: snapshot.servers[index]) == nil ? .missingLocalKey : .needsAuthorization
        snapshot.servers[index].statusDetail = "已根据当前网络响应确认主机密钥。"
        snapshot.servers[index].updatedAt = now
        let checkKind = pendingHostKeyCheckKind ?? .key
        let endpoint = pendingHostKeyEndpointID.flatMap(topology.endpoint(id:))
        let resumesAuthorization = pendingHostKeyResumesAuthorization
        pendingHostKeys = []
        pendingHostKeyServerID = nil
        pendingHostKeyCheckKind = nil
        pendingHostKeyEndpointID = nil
        pendingHostKeyResumesAuthorization = false
        do {
            try await hostKeyService.persistConfirmedKeys(confirmed, allServers: snapshot.servers.filter { !$0.isDeleted })
            appendAudit(category: "host-key", action: isRotation ? "rotate" : "confirm", targetID: serverID.uuidString, result: "confirmed-\(confirmed.count)")
            await persist()
            if resumesAuthorization {
                await synchronizeSSHAuthorization(serverID: serverID, endpoint: endpoint)
            } else {
                await check(serverID: serverID, kind: checkKind, endpointOverride: endpoint)
            }
        } catch { present(error) }
    }

    func cancelPendingHostKeys() {
        pendingHostKeys = []
        pendingHostKeyServerID = nil
        pendingHostKeyCheckKind = nil
        pendingHostKeyEndpointID = nil
        pendingHostKeyResumesAuthorization = false
    }

    func authorizeSelected() async {
        await synchronizeSSHAuthorizationSelected()
    }

    func authorizeCurrentDevice(serverID: UUID) async {
        await authorizeCurrentDevice(serverID: serverID, endpoint: nil)
    }

    func authorizeCurrentDevice(serverID: UUID, endpoint: Endpoint?) async {
        guard await authorizeLegacyMutation() else { return }
        guard !isBusy else { return }
        do {
            if preferredKey == nil {
                let key = try await generateCurrentDeviceKey()
                appendAudit(category: "key", action: "generate", targetID: key.id, result: "account-authorization")
                await persist()
            }
            guard hasStoredPassword(serverID: serverID) else {
                requestPassword(for: serverID, endpoint: endpoint)
                return
            }
            await synchronizeSSHAuthorization(serverID: serverID, endpoint: endpoint)
        } catch { present(error) }
    }

    func authorizePendingServers() async {
        guard await authorizeLegacyMutation() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if preferredKey == nil {
                guard let device = currentDevice else { throw SSHServiceError.missingPrivateKey }
                let generated = try await keyService.generate(device: device)
                snapshot.keys.append(generated)
                selectedKeyID = generated.id
                selectedKeyItemID = "identity:\(generated.id)"
                for index in snapshot.servers.indices where snapshot.servers[index].status == .missingLocalKey {
                    snapshot.servers[index].status = .needsAuthorization
                    snapshot.servers[index].statusDetail = "当前 Mac 的密钥已就绪，可以启用免密。"
                }
                appendAudit(category: "key", action: "generate", targetID: generated.id, result: "new-device-ed25519")
                await persist()
            }
            try await localAuthentication.authorize(reason: "为待处理的 KeyPort 服务器启用免密")
            for server in activeServers where server.status == .needsAuthorization
                || server.status == .missingLocalKey
                || server.status == .syncPending {
                guard let serverKey = key(for: server) else { continue }
                updateServer(id: server.id, status: .syncing, detail: "正在同步 SSH 授权。")
                updateAuthenticationCheck(id: server.id, kind: .key, state: .checking, detail: "正在安装公钥并进行复检。", checkedAt: nil)
                do {
                    try await authorize(server: server, key: serverKey)
                } catch {
                    let detail = "SSH 授权同步失败：\(UserFacingText.localizedError(error))"
                    let status: AuthorizationStatus
                    let checkState: AuthenticationCheckState
                    switch error as? SSHServiceError {
                    case .hostKeyNotConfirmed:
                        status = .hostKeyPending
                        checkState = .blocked
                    case .hostKeyChanged:
                        status = .hostKeyMismatch
                        checkState = .blocked
                    case .missingPrivateKey:
                        status = .missingLocalKey
                        checkState = .blocked
                    case .missingPassword, .passwordAuthenticationRejected:
                        status = .passwordAuthenticationFailed
                        checkState = .failed
                    default:
                        status = .keyAuthenticationFailed
                        checkState = .failed
                    }
                    updateServer(id: server.id, status: status, detail: detail)
                    updateAuthenticationCheck(id: server.id, kind: .key, state: checkState, detail: detail)
                    appendAudit(category: "authorization", action: "batch-sync", targetID: server.id.uuidString, result: "failed", level: .error)
                    appendAudit(category: "authorization", action: "batch-item", targetID: server.id.uuidString, result: "failed", level: .error)
                }
            }
        } catch { present(error) }
    }

    func refreshRemoteAuthorizations(serverID: UUID) async {
        guard await authorizeLegacyMutation() else { return }
        guard let server = snapshot.servers.first(where: { $0.id == serverID }),
              let identity = key(for: server)?.privateKeyPath else { return }
        guard let routeServer = sshOperationServer(for: server) else {
            markSSHRouteUnavailable(serverID: serverID, kind: .key)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let lines = try await sshService.readAuthorizedKeys(server: routeServer, identityPath: identity)
            var discoveredKeys: [SSHKeyRecord] = []
            var existingByID: [String: Authorization] = [:]
            for authorization in snapshot.authorizations where authorization.serverID == serverID {
                existingByID[authorization.id] = authorization
            }
            let discovered = lines.filter(\.isKeyPortManaged).compactMap { line -> Authorization? in
                guard let key = line.key, let comment = key.comment else { return nil }
                let components = comment.split(separator: ":").map(String.init)
                guard components.count >= 4 else { return nil }
                let knownKey = snapshot.keys.first { $0.fingerprint == key.fingerprint }
                if knownKey == nil {
                    discoveredKeys.append(SSHKeyRecord(id: components[2], deviceID: components[3], kind: key.kind, publicKey: line.rawLine, fingerprint: key.fingerprint, privateKeyPath: nil, isInAgent: false, origin: .scanned, isLocallyAvailable: false))
                }
                let identity = Authorization(
                    serverID: serverID,
                    keyID: knownKey?.id ?? components[2],
                    fingerprint: key.fingerprint,
                    remoteComment: comment,
                    status: .authorized
                )
                let previous = existingByID[identity.id]
                return Authorization(
                    serverID: serverID,
                    keyID: knownKey?.id ?? components[2],
                    fingerprint: key.fingerprint,
                    remoteComment: comment,
                    status: .authorized,
                    authorizedAt: previous?.authorizedAt,
                    lastVerifiedAt: .now,
                    updatedAt: .now,
                    isDeleted: false,
                    version: previous.map { $0.isDeleted ? $0.version + 1 : $0.version } ?? 1
                )
            }
            var managedByID: [String: Authorization] = [:]
            for authorization in discovered { managedByID[authorization.id] = authorization }
            let managed = Array(managedByID.values)
            for key in discoveredKeys where !snapshot.keys.contains(where: { $0.fingerprint == key.fingerprint }) {
                snapshot.keys.append(key)
            }
            let managedFingerprints = Set(managed.map(\.fingerprint))
            let existing = snapshot.authorizations.filter { $0.serverID == serverID }
            snapshot.authorizations.removeAll { $0.serverID == serverID }
            snapshot.authorizations.append(contentsOf: existing.compactMap { authorization in
                guard !managedFingerprints.contains(authorization.fingerprint) else { return nil }
                guard !authorization.isDeleted else { return authorization }
                var tombstone = authorization
                tombstone.status = .needsAuthorization
                tombstone.isDeleted = true
                tombstone.updatedAt = .now
                tombstone.lastVerifiedAt = .now
                tombstone.version += 1
                return tombstone
            })
            snapshot.authorizations.append(contentsOf: managed)
            if currentAuthorizationNeedsAction(for: serverID) {
                updateServer(id: serverID, status: .needsAuthorization, detail: "远端记录中已找不到当前 Mac 的免密授权，请重新启用免密。")
            }
            appendAudit(category: "authorization", action: "read", targetID: serverID.uuidString, result: "keyport-entries-\(managed.count)")
            await persist()
        } catch { present(error) }
    }

    func revokeAuthorization(_ authorizationID: String) async {
        guard await authorizeLegacyMutation() else { return }
        guard let authorization = snapshot.authorizations.first(where: { $0.id == authorizationID }),
              let server = snapshot.servers.first(where: { $0.id == authorization.serverID }),
              let credentialKey = key(for: server),
              let identity = credentialKey.privateKeyPath,
              let targetKey = snapshot.keys.first(where: { $0.fingerprint == authorization.fingerprint }),
              let parsed = PublicKeyParser.parse(targetKey.publicKey) else { return }
        guard let routeServer = sshOperationServer(for: server) else {
            markSSHRouteUnavailable(serverID: server.id, kind: .key)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await localAuthentication.authorize(reason: "撤销所选 KeyPort 服务器授权")
            let observed = try await hostKeyService.scan(server: routeServer)
            guard HostKeyEvaluator.evaluate(observed: observed, confirmed: routeServer.confirmedHostKeys) == .confirmed else {
                throw SSHServiceError.hostKeyChanged
            }
            try await sshService.revokePublicKey(server: routeServer, fingerprint: authorization.fingerprint, publicKeyBlob: parsed.blob, identityPath: identity)
            if let index = snapshot.authorizations.firstIndex(where: { $0.id == authorizationID }) {
                snapshot.authorizations[index].status = .needsAuthorization
                snapshot.authorizations[index].isDeleted = true
                snapshot.authorizations[index].updatedAt = .now
                snapshot.authorizations[index].lastVerifiedAt = .now
                snapshot.authorizations[index].version += 1
            }
            if authorization.keyID == credentialKey.id {
                updateServer(id: server.id, status: .needsAuthorization, detail: "此 Mac 的授权已撤销。")
            }
            appendAudit(category: "authorization", action: "revoke", targetID: server.id.uuidString, result: "fingerprint-verified")
            await writeConfig()
            await persist()
        } catch { present(error) }
    }

    func synchronizeCloud(userInitiated: Bool = true) async {
        guard defaults.bool(forKey: "KeyPort.cloudSyncEnabled") else {
            cloudState = .disabled
            return
        }
        guard await authorizeLegacyMutation() else {
            cloudState = .failed(errorMessage ?? "v6 已取得元数据写权，Cloud v1 同步已停用。")
            return
        }
        guard !isBusy else { return }
        if userInitiated {
            scheduledCloudSync?.cancel()
            scheduledCloudSync = nil
        }
        isBusy = true
        cloudState = .syncing
        isSynchronizingCloud = true
        defer {
            isBusy = false
            isSynchronizingCloud = false
        }
        do {
            let previousServers = snapshot.servers
            let localMachineConfigurationRefreshAttempts = snapshot.servers.reduce(into: [UUID: Date]()) { result, server in
                if let attemptedAt = server.machineConfigurationRefreshAttemptedAt {
                    result[server.id] = attemptedAt
                }
            }
            let currentDeviceID = snapshot.devices.first(where: \.isCurrent)?.id
                ?? defaults.string(forKey: "KeyPort.deviceID")
                ?? KeyPortNaming.newDeviceID()
            topology = try await cloudSync.synchronize(topology)
            snapshot = TopologySnapshotMigration.legacyProjection(
                from: topology,
                currentDeviceID: currentDeviceID
            )
            for index in snapshot.servers.indices {
                guard let localAttempt = localMachineConfigurationRefreshAttempts[snapshot.servers[index].id] else { continue }
                let mergedAttempt = snapshot.servers[index].machineConfigurationRefreshAttemptedAt ?? .distantPast
                if localAttempt > mergedAttempt {
                    snapshot.servers[index].machineConfigurationRefreshAttemptedAt = localAttempt
                }
            }
            ensureCurrentDevice()
            if selectedDeviceItem == nil {
                selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
            }
            normalizeStatusesAfterMetadataMerge(previousServers: previousServers)
            await refreshPasswordAvailability()
            discoveredSSHConnections = await configService.discoverConnections()
            reconcileImportedServerAliases()
            await refreshMissingMachineConfigurations()
            let synchronizedAt = Date.now
            lastCloudSyncAt = synchronizedAt
            defaults.set(synchronizedAt, forKey: "KeyPort.lastCloudSyncAt")
            automaticCloudRetryAttempt = 0
            cloudState = .succeeded(synchronizedAt)
            appendAudit(category: "cloud", action: "sync", result: "success")
            await persist()
        } catch {
            let message = UserFacingText.localizedError(error)
            cloudState = cloudState(for: error, message: message)
            appendAudit(category: "cloud", action: "sync", result: "unavailable", level: .warning)
            if userInitiated, (error as? CloudSyncError) != .cancelled {
                errorMessage = message
            }
            if let retryDelay = (error as? CloudSyncError)?.automaticRetryDelay {
                scheduleCloudRetry(after: retryDelay)
            }
        }
    }

    func refreshTailscale() async {
        guard tailscaleDiscoveryState != .refreshing else { return }
        let readOnlyPresentation = isMetadataReadOnly
        tailscaleDiscoveryState = .refreshing
        do {
            let status = try await tailscaleService.status()
            tailscaleStatus = status
            if readOnlyPresentation {
                tailscaleDiscoveryState = status.isCompleteAssociationSnapshot
                    ? .available
                    : .unavailable("Tailscale 状态不完整，已保留现有节点关联。")
            } else if status.isCompleteAssociationSnapshot {
                let observerDeviceID = currentDevice?.id
                    ?? defaults.string(forKey: "KeyPort.deviceID")
                    ?? KeyPortNaming.newDeviceID()
                topology = TailscaleTopologySynchronizer.apply(
                    status: status,
                    to: topology,
                    observerDeviceID: observerDeviceID,
                    observedAt: status.observedAt
                )
                recordCurrentDeviceIdentity(from: status)
                discoverLogicalNameAssociations(using: status)
                revalidateNodeAssociations(status: status, sourceState: .complete)
                tailscaleDiscoveryState = .available
            } else {
                let observerDeviceID = currentDevice?.id
                    ?? defaults.string(forKey: "KeyPort.deviceID")
                    ?? KeyPortNaming.newDeviceID()
                topology = TailscaleTopologySynchronizer.apply(
                    status: status,
                    to: topology,
                    observerDeviceID: observerDeviceID,
                    observedAt: status.observedAt
                )
                recordCurrentDeviceIdentity(from: status)
                revalidateNodeAssociations(status: nil, sourceState: .unavailable)
                tailscaleDiscoveryState = .unavailable("Tailscale 状态不完整，已保留现有节点关联。")
            }
            if !readOnlyPresentation {
                await persist()
            }
            if selectedDeviceItem == nil {
                selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
            }
        } catch {
            tailscaleStatus = nil
            if !readOnlyPresentation {
                revalidateNodeAssociations(status: nil, sourceState: .unavailable)
            }
            if !readOnlyPresentation {
                let currentDeviceID = currentDevice?.id
                    ?? defaults.string(forKey: "KeyPort.deviceID")
                graphWorkspace.update(
                    topology: topology,
                    currentDeviceID: currentDeviceID,
                    tailscaleStatus: TailscaleStatus(
                        backendState: "Unavailable",
                        tailnetName: nil,
                        magicDNSSuffix: nil,
                        nodes: []
                    )
                )
            }
            tailscaleDiscoveryState = .unavailable(error.localizedDescription)
        }
    }

    func copySelectedAlias() {
        guard let serverID = selectedServerID else { return }
        copyAlias(serverID: serverID)
    }

    func copyAlias(serverID: UUID) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        clipboard.copy(server.alias)
        appendAudit(category: "server", action: "copy-alias", targetID: serverID.uuidString, result: "success")
    }

    func copyHost(serverID: UUID) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        clipboard.copy(server.host)
        appendAudit(category: "server", action: "copy-host", targetID: serverID.uuidString, result: "success")
    }

    func copySSHCommand(serverID: UUID) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        clipboard.copy(SSHCommandPresentation.command(server: server))
        appendAudit(category: "server", action: "copy-ssh-command", targetID: serverID.uuidString, result: "success")
    }

    func copySSHCommand(serverID: UUID, endpoint: Endpoint?) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        clipboard.copy(SSHCommandPresentation.command(server: server, endpoint: endpoint))
        appendAudit(
            category: "server",
            action: "copy-ssh-command",
            targetID: serverID.uuidString,
            result: endpoint == nil ? "alias" : "selected-route"
        )
    }

    func openTerminal(serverID: UUID, endpoint: Endpoint?) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        guard terminal.open(server: server, endpoint: endpoint) else {
            errorMessage = "无法打开系统默认的 SSH 终端。请先确认 macOS 已为 ssh:// 链接配置可用的终端应用。"
            appendAudit(
                category: "server",
                action: "open-terminal",
                targetID: serverID.uuidString,
                result: "unavailable",
                level: .warning
            )
            return
        }
        appendAudit(
            category: "server",
            action: "open-terminal",
            targetID: serverID.uuidString,
            result: endpoint == nil ? "alias" : "selected-route"
        )
    }

    func clearAuditLog() async {
        guard await authorizeLegacyMutation() else { return }
        snapshot.auditEvents.removeAll()
        await persist()
    }

    func keyDisplayName(_ key: SSHKeyRecord) -> String {
        if let path = key.privateKeyPath {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            if fileName != key.id { return fileName }
        }
        let deviceName = snapshot.devices.first(where: { $0.id == key.deviceID })?.name ?? "SSH"
        return "\(deviceName) \(key.kind.rawValue.uppercased()) Key"
    }

    func key(for connection: DiscoveredSSHConnection) -> SSHKeyRecord? {
        let configuredPaths = Set(connection.identityFiles.map(normalizedIdentityPath))
        return snapshot.keys.first { key in
            guard let path = key.privateKeyPath else { return false }
            return configuredPaths.contains(normalizedIdentityPath(path))
        }
    }

    func connection(for server: ServerConnection) -> DiscoveredSSHConnection? {
        discoveredSSHConnections.first { connection in
            connection.alias == server.alias || (
                connection.alias == server.name &&
                connection.host == server.host &&
                connection.port == server.port &&
                connection.username == server.username
            )
        }
    }

    func key(for server: ServerConnection) -> SSHKeyRecord? {
        if let authorization = snapshot.authorizations.first(where: { authorization in
            guard authorization.serverID == server.id,
                  !authorization.isDeleted,
                  authorization.status == .authorized,
                  let authorizedKey = key(for: authorization) else { return false }
            return authorizedKey.deviceID == currentDevice?.id && authorizedKey.isLocallyAvailable
        }), let authorizedKey = key(for: authorization) {
            return authorizedKey
        }
        if let connection = connection(for: server), let configuredKey = key(for: connection) {
            return configuredKey
        }
        return preferredKey
    }

    func connections(for key: SSHKeyRecord) -> [DiscoveredSSHConnection] {
        guard let path = key.privateKeyPath else { return [] }
        let normalizedPath = normalizedIdentityPath(path)
        return discoveredSSHConnections.filter { connection in
            connection.identityFiles.contains { normalizedIdentityPath($0) == normalizedPath }
        }
    }

    func server(matching connection: DiscoveredSSHConnection) -> ServerConnection? {
        snapshot.servers.first { !$0.isDeleted && $0.alias == connection.alias }
            ?? snapshot.servers.first {
                !$0.isDeleted &&
                $0.name == connection.alias &&
                $0.host == connection.host &&
                $0.port == connection.port &&
                $0.username == connection.username
        }
    }

    func addDiscoveredConnectionToServers(_ connection: DiscoveredSSHConnection) async {
        guard await authorizeLegacyMutation() else { return }
        if let existing = server(matching: connection) {
            showServer(existing.id)
            return
        }

        guard KeyPortNaming.isValidAlias(connection.alias) else {
            errorMessage = "此 SSH 别名包含 KeyPort 无法安全管理的字符。"
            return
        }

        let server = ServerConnection(
            name: connection.alias,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            alias: connection.alias,
            notes: "从 SSH Config 主机 \(connection.alias) 导入。"
        )
        snapshot.servers.append(server)
        selectedServerID = server.id
        selectedKeyItemID = "server:\(server.id.uuidString)"
        appendAudit(category: "ssh-config", action: "import-server", targetID: server.id.uuidString, result: "metadata-only")
        await persist()
        passwordSaveError = nil
        passwordPromptServerID = server.id
    }

    func hasStoredPassword(serverID: UUID) -> Bool {
        credentialOwnerIDs(forProfileID: serverID).contains {
            serverIDsWithStoredPassword.contains($0)
        }
    }

    func hasStoredPassword(accountID: UUID) -> Bool {
        credentialOwnerIDs(forAccountID: accountID).contains {
            serverIDsWithStoredPassword.contains($0)
        }
    }

    func isPasswordSynchronizable(serverID: UUID) -> Bool {
        credentialOwnerIDs(forProfileID: serverID).contains {
            serverIDsWithSynchronizablePassword.contains($0)
        }
    }

    func isPasswordSynchronizable(accountID: UUID) -> Bool {
        credentialOwnerIDs(forAccountID: accountID).contains {
            serverIDsWithSynchronizablePassword.contains($0)
        }
    }

    func requestPassword(for serverID: UUID, endpoint: Endpoint? = nil) {
        passwordSaveError = nil
        passwordPromptServerID = serverID
        passwordPromptEndpointID = endpoint?.id
    }

    func cancelPasswordPrompt() {
        passwordSaveError = nil
        passwordPromptServerID = nil
        passwordPromptEndpointID = nil
    }

    private func accountID(forProfileID profileID: UUID) -> UUID? {
        topology.connectionProfile(id: profileID)?.accountID
    }

    private func profileIDs(forAccountID accountID: UUID) -> [UUID] {
        topology.connectionProfiles(for: accountID).map(\.id)
    }

    private func credentialOwnerIDs(forAccountID accountID: UUID) -> [UUID] {
        var values = [accountID]
        values.append(contentsOf: profileIDs(forAccountID: accountID))
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    private func credentialOwnerIDs(forProfileID profileID: UUID) -> [UUID] {
        guard let accountID = accountID(forProfileID: profileID) else { return [profileID] }
        var values = credentialOwnerIDs(forAccountID: accountID)
        if !values.contains(profileID) { values.append(profileID) }
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    private func credentialOwnerID(
        forProfileID profileID: UUID,
        targetNodeID: UUID? = nil,
        username: String? = nil
    ) -> UUID {
        if let targetNodeID, let username, !username.isEmpty {
            return TopologyStableID.sshAccount(nodeID: targetNodeID, username: username)
        }
        return accountID(forProfileID: profileID) ?? profileID
    }

    private func storedCredentialOwnerID(forProfileID profileID: UUID) async -> UUID? {
        for ownerID in credentialOwnerIDs(forProfileID: profileID) {
            if await keychain.hasServerCredential(serverID: ownerID) { return ownerID }
        }
        return nil
    }

    private func storedCredentialOwnerID(forAccountID accountID: UUID) async -> UUID? {
        for ownerID in credentialOwnerIDs(forAccountID: accountID) {
            if await keychain.hasServerCredential(serverID: ownerID) { return ownerID }
        }
        return nil
    }

    private func serverCredential(forProfileID profileID: UUID) async throws -> ServerCredential {
        guard let ownerID = await storedCredentialOwnerID(forProfileID: profileID) else {
            throw SSHServiceError.missingPassword
        }
        return try await keychain.serverCredential(serverID: ownerID)
    }

    private func cacheCredentialAvailability(
        ownerID: UUID,
        profileID: UUID,
        synchronizable: Bool
    ) {
        let relatedIDs = Set(credentialOwnerIDs(forProfileID: profileID) + [ownerID, profileID])
        serverIDsWithStoredPassword.formUnion(relatedIDs)
        for id in relatedIDs {
            updatePasswordStorageCache(serverID: id, synchronizable: synchronizable)
        }
    }

    private func cacheCredentialAvailability(
        ownerID: UUID,
        accountID: UUID,
        synchronizable: Bool
    ) {
        let relatedIDs = Set(credentialOwnerIDs(forAccountID: accountID) + [ownerID, accountID])
        serverIDsWithStoredPassword.formUnion(relatedIDs)
        for id in relatedIDs {
            updatePasswordStorageCache(serverID: id, synchronizable: synchronizable)
        }
    }

    func testPromptedPassword(username: String, password: String) async -> AuthenticationCheck {
        guard let server = promptedPasswordServer, !password.isEmpty else {
            return AuthenticationCheck(state: .failed, detail: "测试前请输入用户名和密码。", checkedAt: .now)
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            return AuthenticationCheck(state: .failed, detail: "测试前请输入用户名。", checkedAt: .now)
        }
        var candidateServer: ServerConnection
        if let routed = sshOperationServer(for: server) {
            let endpoint = passwordPromptEndpointID.flatMap(topology.endpoint(id:))
            candidateServer = self.server(routed, using: endpoint)
        } else {
            return AuthenticationCheck(state: .blocked, detail: "该身份的 SSH 路由被 v6 兼容层关闭（存在待解决冲突或无可用地址）。", checkedAt: .now)
        }
        candidateServer.username = trimmedUsername

        do {
            let observed = try await hostKeyService.scan(server: candidateServer)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: candidateServer.confirmedHostKeys) {
            case .pending:
                let detail = candidateServer.confirmedHostKeys.isEmpty
                    ? "测试密码身份验证前，请先确认此服务器的主机密钥。"
                    : "端点提供了尚未确认的主机密钥算法，密码身份验证已被阻止。"
                return AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now)
            case .changed(let algorithms):
                let detail = "以下算法的主机密钥已变更：\(algorithms.joined(separator: "、"))。密码登录验证已被阻止。"
                return AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now)
            case .confirmed:
                var passwordData = Data(password.utf8)
                defer { passwordData.resetBytes(in: passwordData.indices) }
                let authenticated = try await sshService.testPassword(server: candidateServer, passwordData: passwordData)
                return AuthenticationCheck(
                    state: authenticated ? .succeeded : .failed,
                    detail: authenticated
                        ? "仅使用密码的 SSH 身份验证成功，公钥和 SSH Agent 已禁用。"
                        : "服务器在仅使用密码的 SSH 身份验证中拒绝了该密码。",
                    checkedAt: .now
                )
            }
        } catch {
            return AuthenticationCheck(state: .failed, detail: UserFacingText.localizedError(error), checkedAt: .now)
        }
    }

    func savePromptedPassword(
        username: String,
        password: String,
        synchronizable: Bool,
        authorizeAfterSave: Bool,
        validatedCheck: AuthenticationCheck
    ) async {
        guard await authorizeLegacyMutation() else { return }
        guard let server = promptedPasswordServer, !password.isEmpty, !isSavingPassword else { return }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            passwordSaveError = "请输入用户名。"
            return
        }
        guard validatedCheck.state == .succeeded, validatedCheck.checkedAt != nil else {
            passwordSaveError = "保存前，请先完成密码登录验证。"
            return
        }
        let sameAccountProfileIDs = accountID(forProfileID: server.id).map {
            Set(profileIDs(forAccountID: $0))
        } ?? [server.id]
        let duplicateAccount = snapshot.servers.contains {
            !$0.isDeleted
                && !sameAccountProfileIDs.contains($0.id)
                && $0.host == server.host
                && $0.port == server.port
                && $0.username == trimmedUsername
        }
        guard !duplicateAccount else {
            passwordSaveError = "该设备上的 SSH 用户已由 KeyPort 管理。"
            return
        }
        isSavingPassword = true
        passwordSaveError = nil
        defer { isSavingPassword = false }
        do {
            var passwordData = Data(password.utf8)
            defer { passwordData.resetBytes(in: passwordData.indices) }
            let targetNodeID = accountID(forProfileID: server.id).flatMap { accountID in
                topology.activeAccounts.first(where: { $0.id == accountID })?.nodeID
            }
            let credentialOwnerID = credentialOwnerID(
                forProfileID: server.id,
                targetNodeID: targetNodeID,
                username: trimmedUsername
            )
            try await keychain.saveServerCredential(
                username: trimmedUsername,
                passwordData: passwordData,
                serverID: credentialOwnerID,
                synchronizable: synchronizable
            )
            cacheCredentialAvailability(
                ownerID: credentialOwnerID,
                profileID: server.id,
                synchronizable: synchronizable
            )
            var usernameChanged = false
            if let index = snapshot.servers.firstIndex(where: { $0.id == server.id }) {
                usernameChanged = snapshot.servers[index].username != trimmedUsername
                snapshot.servers[index].username = trimmedUsername
                snapshot.servers[index].passwordCheck = validatedCheck
                snapshot.servers[index].lastCheckedAt = validatedCheck.checkedAt
                if usernameChanged {
                    snapshot.servers[index].keyCheck = nil
                    snapshot.servers[index].status = key(for: snapshot.servers[index]) == nil ? .missingLocalKey : .needsAuthorization
                    snapshot.servers[index].statusDetail = "连接用户已变更。密码 SSH 已验证，请重新检查密钥授权。"
                    snapshot.servers[index].updatedAt = .now
                    snapshot.servers[index].version += 1
                }
            }
            let authorizationEndpoint = passwordPromptEndpointID.flatMap(topology.endpoint(id:))
            let profileBinding = usernameChanged ? targetNodeID.map {
                SSHConnectionProfileNodeBinding(
                    profileID: server.id,
                    nodeID: $0,
                    endpointID: authorizationEndpoint?.id
                        ?? topology.connectionProfile(id: server.id)?.routePolicy.fixedEndpointID
                )
            } : nil
            passwordPromptServerID = nil
            passwordPromptEndpointID = nil
            appendAudit(category: "keychain", action: "save-credential", targetID: server.id.uuidString, result: synchronizable ? "saved-synchronizable" : "saved-local")
            if usernameChanged {
                await writeConfig()
            }
            await persist(profileBindings: profileBinding.map { [$0] } ?? [])
            if authorizeAfterSave {
                selectedServerID = server.id
                await authorizeCurrentDevice(serverID: server.id, endpoint: authorizationEndpoint)
            }
        } catch {
            passwordSaveError = UserFacingText.localizedError(error)
        }
    }

    func showServer(_ serverID: UUID) {
        destination = .servers
        selectedServerID = serverID
    }

    func showDevice(_ itemID: DevicePresence.ID) {
        destination = .devices
        selectedDeviceItemID = itemID
    }

    func showKey(_ keyID: String) {
        destination = .keys
        selectedKeyID = keyID
        selectedKeyItemID = "identity:\(keyID)"
    }

    func synchronizeKeySelection() {
        if let key = selectedKeyServerRow?.key ?? selectedDiscoveredSSHConnection.flatMap({ key(for: $0) }) ?? selectedStandaloneKey {
            selectedKeyID = key.id
        }
    }

    func exportMetadata(password: String) async {
        guard let destination = await fileSelection.selectArchiveDestination() else { return }
        do {
            try await archiveService.export(snapshot: snapshot, password: password, destination: destination)
            if !isMetadataReadOnly {
                appendAudit(category: "archive", action: "export", result: "encrypted-metadata")
                await persist()
            }
        } catch { present(error) }
    }

    func importMetadata(password: String) async {
        guard await authorizeLegacyMutation() else { return }
        guard let source = await fileSelection.selectArchiveForImport() else { return }
        do {
            let imported = try await archiveService.importArchive(from: source, password: password)
            let previousServers = snapshot.servers
            mergeImported(imported)
            normalizeStableMetadataIDs()
            ensureCurrentDevice()
            normalizeStatusesAfterMetadataMerge(previousServers: previousServers)
            await refreshPasswordAvailability()
            appendAudit(category: "archive", action: "import", result: "merged")
            await persist()
        } catch { present(error) }
    }

    private func generateCurrentDeviceKey() async throws -> SSHKeyRecord {
        guard let device = currentDevice else { throw SSHServiceError.missingPrivateKey }
        let key = try await keyService.generate(device: device)
        snapshot.keys.append(key)
        selectedKeyID = key.id
        selectedKeyItemID = "identity:\(key.id)"
        for index in snapshot.servers.indices where snapshot.servers[index].status == .missingLocalKey {
            snapshot.servers[index].status = .needsAuthorization
            snapshot.servers[index].statusDetail = "当前 Mac 的密钥已就绪，可以启用免密。"
        }
        return key
    }

    private func authorizeServer(_ serverID: UUID) async throws {
        try await requireLegacyMutation()
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else {
            throw SSHServiceError.operationFailed("找不到要启用免密的服务器。")
        }
        guard let key = privateKey(for: server) else { throw SSHServiceError.missingPrivateKey }
        try await localAuthentication.authorize(reason: "为 \(server.name) 启用免密")
        try await authorize(server: server, key: key)
    }

    private var preferredKey: SSHKeyRecord? {
        let privateKeys = currentDeviceKeys.filter { $0.privateKeyPath != nil }
        if let selectedKeyID, let selected = privateKeys.first(where: { $0.id == selectedKeyID }) { return selected }
        return privateKeys.first(where: { $0.kind == .ed25519 }) ?? privateKeys.first
    }

    private func privateKey(for server: ServerConnection) -> SSHKeyRecord? {
        if let key = key(for: server), key.privateKeyPath != nil {
            return key
        }
        return preferredKey
    }

    private func normalizedIdentityPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private func isImportedSSHConfigNote(_ note: String, alias: String? = nil) -> Bool {
        if let alias {
            return note.hasPrefix("Imported from SSH Config host \(alias).")
                || note.hasPrefix("从 SSH Config 主机 \(alias) 导入。")
        }
        return note.hasPrefix("Imported from SSH Config host ")
            || note.hasPrefix("从 SSH Config 主机 ")
    }

    private func reconcileImportedServerAliases() {
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted {
            guard let connection = discoveredSSHConnections.first(where: {
                $0.alias == snapshot.servers[index].name &&
                $0.host == snapshot.servers[index].host &&
                $0.port == snapshot.servers[index].port &&
                $0.username == snapshot.servers[index].username
            }), isImportedSSHConfigNote(snapshot.servers[index].notes, alias: connection.alias),
            snapshot.servers[index].alias != connection.alias,
            !snapshot.servers.contains(where: { $0.id != snapshot.servers[index].id && !$0.isDeleted && $0.alias == connection.alias }) else {
                continue
            }
            snapshot.servers[index].alias = connection.alias
            snapshot.servers[index].updatedAt = .now
            snapshot.servers[index].version += 1
        }
    }

    private func migrateImportedConnectionKeyStatusIfNeeded() {
        guard snapshot.schemaVersion < 2 else { return }
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted {
            guard isImportedSSHConfigNote(snapshot.servers[index].notes),
                  connection(for: snapshot.servers[index]) != nil,
                  snapshot.servers[index].status == .needsAuthorization else { continue }
            snapshot.servers[index].status = .syncPending
            snapshot.servers[index].statusDetail = "已配置的 SSH 身份密钥发生变化，请在启用免密前检查此连接。"
            snapshot.servers[index].lastCheckedAt = nil
        }
        snapshot.schemaVersion = 2
    }

    private func migrateLegacyAuthenticationChecksIfNeeded() {
        guard snapshot.schemaVersion < 3 else { return }
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted && snapshot.servers[index].keyCheck == nil {
            guard let checkedAt = snapshot.servers[index].lastCheckedAt else { continue }
            switch snapshot.servers[index].status {
            case .authorized:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .succeeded,
                    detail: snapshot.servers[index].statusDetail ?? "免密登录验证成功。",
                    checkedAt: checkedAt
                )
            case .needsAuthorization, .keyAuthenticationFailed:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .failed,
                    detail: snapshot.servers[index].statusDetail ?? "当前 Mac 尚未启用免密。",
                    checkedAt: checkedAt
                )
            case .hostKeyPending, .hostKeyMismatch:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .blocked,
                    detail: snapshot.servers[index].statusDetail ?? "需要确认主机密钥。",
                    checkedAt: checkedAt
                )
            default:
                break
            }
        }
        snapshot.schemaVersion = 3
    }

    private func migrateDeviceNetworkIdentitySchemaIfNeeded() {
        guard snapshot.schemaVersion < 4 else { return }
        snapshot.schemaVersion = 4
    }

    /// flag 感知的 SSH 路由（切片 C 适配层）：默认原样返回 legacy 对象；
    /// `KeyPort.sshCompatAdapterV6` 开启时改用 v6 只读兼容投影，投影被关闭
    /// （blocking 冲突或无可用地址）时 fail closed 返回 nil。审计只记稳定码，
    /// 不含地址、用户名或秘密。关闭 flag 即整体回退 legacy adapter。
    private func sshOperationServer(for server: ServerConnection) -> ServerConnection? {
        let provider = SSHCompatFeatureFlags.routeProvider(servers: snapshot.servers, defaults: defaults)
        if let routed = provider.sshRoute(for: server.id) { return routed }
        if let failure = provider.blockingFailure(for: server.id) {
            appendAudit(category: "ssh-auth", action: "route", targetID: server.id.uuidString, result: failure.code.rawValue, level: .error)
        }
        return nil
    }

    private func markSSHRouteUnavailable(serverID: UUID, kind: ServerCheckKind) {
        let detail = "该身份的 SSH 路由被 v6 兼容层关闭（存在待解决冲突或无可用地址）。"
        updateServer(id: serverID, status: .syncPending, detail: detail)
        updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
        appendSSHCheckLog(detail, serverID: serverID)
    }

    private func check(
        serverID: UUID,
        kind: ServerCheckKind,
        ownsBusyState: Bool = true,
        endpointOverride: Endpoint? = nil
    ) async {
        guard await authorizeLegacyMutation() else { return }
        guard let initial = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        guard let compatibleRouteServer = sshOperationServer(for: initial) else {
            markSSHRouteUnavailable(serverID: serverID, kind: kind)
            return
        }
        let routeServer = server(compatibleRouteServer, using: endpointOverride)
        if ownsBusyState { isBusy = true }
        retainedSSHCheckLog = SSHCheckLog(
            serverID: serverID,
            title: kind == .password ? "密码登录验证" : "免密检测",
            lines: ["正在连接 \(initial.username)@\(routeServer.endpoint)...", "正在扫描服务器主机密钥..."]
        )
        updateAuthenticationCheck(id: serverID, kind: kind, state: .checking, detail: kind.checkingDetail, checkedAt: nil)
        if kind == .key {
            updateServer(id: serverID, status: .checking, detail: "密钥登录检查前正在获取主机密钥。")
        }
        defer { if ownsBusyState { isBusy = false } }
        var didReachEndpoint = false
        do {
            let observed = try await hostKeyService.scan(server: routeServer)
            didReachEndpoint = true
            appendSSHCheckLog("已收到 \(observed.count) 个主机密钥指纹。", serverID: serverID)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: routeServer.confirmedHostKeys) {
            case .pending:
                let detail = "身份验证前，请核对主机密钥指纹。"
                updateServer(id: serverID, status: .hostKeyPending, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
                appendSSHCheckLog(detail, serverID: serverID)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = kind
                pendingHostKeyEndpointID = endpointOverride?.id
                pendingHostKeyResumesAuthorization = false
                appendAudit(category: "host-key", action: kind.auditAction, targetID: serverID.uuidString, result: "pending-confirmation", level: .warning)
            case .changed(let algorithms):
                let detail = "发生变更的算法：\(algorithms.joined(separator: "、"))。身份验证已被阻止。"
                updateServer(id: serverID, status: .hostKeyMismatch, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
                appendSSHCheckLog(detail, serverID: serverID)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = kind
                pendingHostKeyEndpointID = endpointOverride?.id
                pendingHostKeyResumesAuthorization = false
                appendAudit(category: "host-key", action: kind.auditAction, targetID: serverID.uuidString, result: "mismatch-blocked", level: .error)
            case .confirmed:
                switch kind {
                case .password:
                    try await checkPasswordAuthentication(server: routeServer)
                case .key:
                    try await checkKeyAuthentication(server: routeServer)
                }
            }
        } catch {
            let message = UserFacingText.localizedError(error)
            updateAuthenticationCheck(id: serverID, kind: kind, state: .failed, detail: message)
            appendSSHCheckLog(message, serverID: serverID)
            if kind == .key {
                updateServer(id: serverID, status: .unreachable, detail: message)
            }
            appendAudit(category: "ssh-auth", action: kind.auditAction, targetID: serverID.uuidString, result: "failed", level: .warning)
        }
        recordSSHConnectionEvidence(
            serverID: serverID,
            routedServer: routeServer,
            endpointOverride: endpointOverride,
            wasReachable: didReachEndpoint
        )
        await persist()
        let finalCheck = snapshot.servers.first(where: { $0.id == serverID }).flatMap {
            kind == .password ? $0.passwordCheck : $0.keyCheck
        }
        if finalCheck?.state == .succeeded {
            retainedSSHCheckLog = nil
        } else if let detail = finalCheck?.detail {
            appendSSHCheckLog(detail, serverID: serverID)
        }
    }

    private func server(_ server: ServerConnection, using endpoint: Endpoint?) -> ServerConnection {
        guard let endpoint, !endpoint.isDeleted, endpoint.protocol == .ssh else { return server }
        var routed = server
        routed.host = endpoint.address
        routed.port = Int(endpoint.port)
        return routed
    }

    private func recordSSHConnectionEvidence(
        serverID: UUID,
        routedServer: ServerConnection,
        endpointOverride: Endpoint?,
        wasReachable: Bool
    ) {
        guard let profile = topology.connectionProfile(id: serverID),
              let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }) else {
            return
        }
        let endpoint = endpointOverride
            ?? profile.routePolicy.fixedEndpointID.flatMap(topology.endpoint(id:))
            ?? topology.endpoints(for: account.nodeID, endpointProtocol: .ssh).first(where: {
                $0.address.caseInsensitiveCompare(routedServer.host) == .orderedSame
                    && Int($0.port) == routedServer.port
            })
        guard let endpoint else { return }
        let deviceID = currentDevice?.id
            ?? defaults.string(forKey: "KeyPort.deviceID")
            ?? "local"
        let observation = ReachabilityObservation(
            endpointID: endpoint.id,
            observerDeviceID: deviceID,
            networkEpoch: 0,
            observedAt: .now,
            wasReachable: wasReachable
        )
        topology.reachabilityObservations.removeAll { $0.id == observation.id }
        topology.reachabilityObservations.append(observation)

        guard let server = snapshot.servers.first(where: { $0.id == serverID }) else { return }
        let verification = AccessVerification(
            accountID: account.id,
            deviceID: deviceID,
            profileID: profile.id,
            endpointID: endpoint.id,
            transport: .direct,
            networkEpoch: 0,
            status: server.status,
            statusDetail: server.statusDetail,
            lastCheckedAt: server.lastCheckedAt,
            passwordCheck: server.passwordCheck,
            keyCheck: server.keyCheck,
            machineConfigurationRefreshAttemptedAt: server.machineConfigurationRefreshAttemptedAt
        )
        topology.accessVerifications.removeAll { $0.id == verification.id }
        topology.accessVerifications.append(verification)
    }

    private func serverUsingCredentialUsername(_ server: ServerConnection, credential: ServerCredential) -> ServerConnection {
        let username = credential.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != server.username else { return server }
        var authenticatedServer = server
        authenticatedServer.username = username
        return authenticatedServer
    }

    private func checkPasswordAuthentication(server: ServerConnection) async throws {
        guard await storedCredentialOwnerID(forProfileID: server.id) != nil else {
            let detail = "检查密码 SSH 前，请输入并测试服务器密码。"
            updateAuthenticationCheck(id: server.id, kind: .password, state: .blocked, detail: detail)
            passwordSaveError = nil
            passwordPromptServerID = server.id
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "missing-password", level: .warning)
            return
        }
        var credential = try await serverCredential(forProfileID: server.id)
        defer { credential.passwordData.resetBytes(in: credential.passwordData.indices) }
        let authenticatedServer = serverUsingCredentialUsername(server, credential: credential)
        let authenticated = try await sshService.testPassword(server: authenticatedServer, passwordData: credential.passwordData)
        let detail = authenticated ? "服务器密码身份验证成功。" : "服务器拒绝了已存储的密码。"
        updateAuthenticationCheck(id: server.id, kind: .password, state: authenticated ? .succeeded : .failed, detail: detail)
        appendSSHCheckLog(detail, serverID: server.id)
        if authenticated {
            if server.status == .passwordAuthenticationFailed {
                updateServer(
                    id: server.id,
                    status: key(for: server) == nil ? .missingLocalKey : .needsAuthorization,
                    detail: "密码 SSH 已验证，现在可以继续同步 SSH 授权。"
                )
            }
            await synchronizeMachineConfigurationWithPassword(
                server: authenticatedServer,
                passwordData: credential.passwordData
            )
        } else if server.status != .authorized {
            updateServer(id: server.id, status: .passwordAuthenticationFailed, detail: detail)
        }
        appendAudit(
            category: "ssh-auth",
            action: ServerCheckKind.password.auditAction,
            targetID: server.id.uuidString,
            result: authenticated ? "succeeded" : "rejected",
            level: authenticated ? .info : .warning
        )
    }

    private func checkKeyAuthentication(server: ServerConnection) async throws {
        guard let key = key(for: server) else {
            let detail = "此 Mac 没有可用的本地私钥。"
            updateAuthenticationCheck(id: server.id, kind: .key, state: .failed, detail: detail)
            updateServer(id: server.id, status: .missingLocalKey, detail: detail)
            appendAudit(category: "ssh-auth", action: ServerCheckKind.key.auditAction, targetID: server.id.uuidString, result: "missing-key", level: .warning)
            return
        }
        let authenticated = try await sshService.testPublicKey(server: server, key: key)
        let detail = authenticated ? "免密登录验证成功。" : "当前 Mac 尚未启用免密。"
        updateAuthenticationCheck(id: server.id, kind: .key, state: authenticated ? .succeeded : .failed, detail: detail)
        appendSSHCheckLog(detail, serverID: server.id)
        if authenticated {
            markMachineConfigurationRefreshAttempt(serverID: server.id)
            updateServer(id: server.id, status: .authorized, detail: detail)
            upsertAuthorization(serverID: server.id, key: key, authorizedAt: nil)
            await synchronizeMachineConfigurationWithKey(server: server, key: key)
            return
        }
        updateServer(id: server.id, status: .needsAuthorization, detail: detail)
        appendAudit(category: "ssh-auth", action: ServerCheckKind.key.auditAction, targetID: server.id.uuidString, result: "not-authorized", level: .warning)
    }

    private func authorize(server: ServerConnection, key: SSHKeyRecord) async throws {
        guard await storedCredentialOwnerID(forProfileID: server.id) != nil else {
            throw SSHServiceError.missingPassword
        }
        var credential = try await serverCredential(forProfileID: server.id)
        defer { credential.passwordData.resetBytes(in: credential.passwordData.indices) }
        let authenticatedServer = serverUsingCredentialUsername(server, credential: credential)
        let observed = try await hostKeyService.scan(server: server)
        switch HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) {
        case .confirmed: break
        case .pending: throw SSHServiceError.hostKeyNotConfirmed
        case .changed: throw SSHServiceError.hostKeyChanged
        }
        do {
            try await sshService.installPublicKey(server: authenticatedServer, key: key, passwordData: credential.passwordData)
            updateAuthenticationCheck(id: server.id, kind: .password, state: .succeeded, detail: "授权期间服务器密码身份验证成功。")
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "succeeded-during-authorization")
        } catch SSHServiceError.passwordAuthenticationRejected {
            updateAuthenticationCheck(id: server.id, kind: .password, state: .failed, detail: "服务器拒绝了已存储的密码。")
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "rejected-during-authorization", level: .warning)
            await persist()
            throw SSHServiceError.passwordAuthenticationRejected
        }
        guard try await sshService.testPublicKey(server: authenticatedServer, key: key) else {
            updateAuthenticationCheck(id: server.id, kind: .key, state: .failed, detail: "密钥已安装，但免密 SSH 验证失败。")
            throw SSHServiceError.operationFailed("密钥已安装，但验证失败。")
        }
        updateAuthenticationCheck(id: server.id, kind: .key, state: .succeeded, detail: "授权后免密 SSH 身份验证成功。")
        upsertAuthorization(serverID: server.id, key: key, authorizedAt: .now)
        updateServer(id: server.id, status: .authorized, detail: "公钥已安装并通过验证。")
        try await configService.write(servers: activeServers, keys: snapshot.keys, authorizations: snapshot.authorizations)
        appendAudit(category: "authorization", action: "install", targetID: server.id.uuidString, result: "verified")
        appendAudit(category: "ssh-config", action: "write", targetID: server.id.uuidString, result: "success")
        await persist()
    }

    private func writeConfig() async {
        guard await authorizeLegacyMutation() else { return }
        do {
            try await configService.write(servers: activeServers, keys: snapshot.keys, authorizations: snapshot.authorizations)
            appendAudit(category: "ssh-config", action: "write", result: "success")
        } catch { present(error) }
    }

    private func ensureAuthorizationRecordForVerifiedServer(serverID: UUID) {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }),
              server.status == .authorized,
              let key = key(for: server),
              key.isLocallyAvailable,
              key.privateKeyPath != nil,
              !snapshot.authorizations.contains(where: {
                  $0.serverID == serverID && $0.fingerprint == key.fingerprint && !$0.isDeleted && $0.status == .authorized
              }) else { return }
        upsertAuthorization(serverID: serverID, key: key, authorizedAt: nil)
    }

    private func upsertAuthorization(serverID: UUID, key: SSHKeyRecord, authorizedAt: Date?) {
        let relatedProfileIDs: [UUID]
        if let accountID = accountID(forProfileID: serverID) {
            relatedProfileIDs = profileIDs(forAccountID: accountID)
        } else {
            relatedProfileIDs = [serverID]
        }
        for profileID in Set(relatedProfileIDs + [serverID]) {
            let existing = snapshot.authorizations.first {
                $0.serverID == profileID && $0.fingerprint == key.fingerprint
            }
            let authorization = Authorization(
                serverID: profileID,
                keyID: key.id,
                fingerprint: key.fingerprint,
                remoteComment: key.publicKeyComment ?? "",
                status: .authorized,
                authorizedAt: authorizedAt ?? existing?.authorizedAt,
                lastVerifiedAt: .now,
                updatedAt: .now,
                isDeleted: false,
                version: (existing?.version ?? 0) + 1
            )
            snapshot.authorizations.removeAll {
                $0.serverID == profileID && $0.fingerprint == key.fingerprint
            }
            snapshot.authorizations.append(authorization)
            if let serverIndex = snapshot.servers.firstIndex(where: { $0.id == profileID && !$0.isDeleted }) {
                snapshot.servers[serverIndex].status = .authorized
                snapshot.servers[serverIndex].statusDetail = "同一 SSH 账户已完成公钥授权。"
                snapshot.servers[serverIndex].lastCheckedAt = .now
            }
        }
    }

    private func ensureCurrentDevice() {
        let storedID = defaults.string(forKey: "KeyPort.deviceID")
        let deviceID = storedID ?? KeyPortNaming.newDeviceID()
        if storedID == nil { defaults.set(deviceID, forKey: "KeyPort.deviceID") }
        snapshot.devices = snapshot.devices.map { device in
            var value = device
            value.isCurrent = device.id == deviceID
            return value
        }
        if !snapshot.devices.contains(where: { $0.id == deviceID }) {
            let name = Host.current().localizedName ?? "此 Mac"
            snapshot.devices.append(Device(id: deviceID, name: name, isCurrent: true))
        }
    }

    private func recordCurrentDeviceIdentity(from status: TailscaleStatus) {
        guard let node = status.nodes.first(where: \.isCurrent),
              let identity = TailscaleDeviceIdentity(node: node),
              let index = snapshot.devices.firstIndex(where: \.isCurrent) else { return }
        snapshot.devices[index].tailscaleIdentity = identity
        snapshot.devices[index].lastActiveAt = .now
    }

    private func revalidateNodeAssociations(
        status: TailscaleStatus?,
        sourceState: NodeAssociationSourceState
    ) {
        let associations = snapshot.nodeAssociations
        for association in associations {
            guard let server = snapshot.servers.first(where: { $0.id == association.serverID && !$0.isDeleted }) else {
                continue
            }
            guard let evaluation = try? NodeAssociationEngine.evaluate(
                testCaseNodeID: association.testCaseNodeID,
                serverID: association.serverID,
                route: effectiveSSHRoute(for: server),
                status: status,
                sourceState: sourceState,
                logicalNameContext: logicalNameContext(for: server),
                existing: association,
                hostKeyChanged: server.status == .hostKeyMismatch
            ) else { continue }
            nodeAssociationCandidates[evaluation.association.testCaseNodeID] = evaluation.candidates
            upsertNodeAssociation(evaluation.association)
        }
    }

    private func effectiveSSHRoute(for server: ServerConnection) -> EffectiveSSHRoute {
        guard let connection = connection(for: server) else {
            return EffectiveSSHRoute(hostname: server.host)
        }
        return EffectiveSSHRoute(
            hostname: connection.host,
            proxyJump: connection.proxyJump,
            proxyCommand: connection.proxyCommand
        )
    }

    private func logicalNameContext(for server: ServerConnection) -> LogicalNameMatchContext {
        let normalizedName = LogicalNodeName.normalize(server.name)
        let matchingServerCount = activeServers.filter {
            LogicalNodeName.normalize($0.name) == normalizedName
        }.count
        return LogicalNameMatchContext(
            serverName: server.name,
            matchingServerCount: matchingServerCount
        )
    }

    private func discoverLogicalNameAssociations(using status: TailscaleStatus) {
        let associatedServerIDs = Set(snapshot.nodeAssociations.map(\.serverID))
        for server in activeServers where !associatedServerIDs.contains(server.id) {
            let logicalID = LogicalNodeName.normalize(server.name)
            let context = logicalNameContext(for: server)
            guard !logicalID.isEmpty, context.matchingServerCount == 1 else { continue }
            guard let evaluation = try? NodeAssociationEngine.evaluate(
                testCaseNodeID: logicalID,
                serverID: server.id,
                route: effectiveSSHRoute(for: server),
                status: status,
                sourceState: .complete,
                logicalNameContext: context,
                hostKeyChanged: server.status == .hostKeyMismatch
            ), evaluation.association.state != .unlinked else { continue }
            nodeAssociationCandidates[logicalID] = evaluation.candidates
            upsertNodeAssociation(evaluation.association)
        }
    }

    private func upsertNodeAssociation(_ association: NodeAssociation) {
        snapshot.nodeAssociations.removeAll { $0.testCaseNodeID == association.testCaseNodeID }
        snapshot.nodeAssociations.append(association)
    }

    private func requireObservedRevision(
        _ association: NodeAssociation?,
        expectedRevision: Int?
    ) throws {
        if let association {
            guard let expectedRevision else {
                throw NodeAssociationMutationError.revisionConflict(expected: 0, actual: association.revision)
            }
            guard association.revision == expectedRevision else {
                throw NodeAssociationMutationError.revisionConflict(
                    expected: expectedRevision,
                    actual: association.revision
                )
            }
        } else if let expectedRevision {
            throw NodeAssociationMutationError.revisionConflict(expected: expectedRevision, actual: 0)
        }
    }

    private func normalizeStatusesAfterMetadataMerge(previousServers: [ServerConnection]) {
        let previousByID = Dictionary(uniqueKeysWithValues: previousServers.map { ($0.id, $0) })
        let hasLocalKey = !currentDeviceKeys.isEmpty
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted {
            if let previous = previousByID[snapshot.servers[index].id],
               authenticationContextMatches(previous, snapshot.servers[index]) {
                if previous.status == .authorized,
                   currentAuthorizationNeedsAction(for: snapshot.servers[index].id) {
                    snapshot.servers[index].status = .needsAuthorization
                    snapshot.servers[index].statusDetail = "同步结果显示当前 Mac 的远端免密授权已撤销，请重新启用免密。"
                    snapshot.servers[index].lastCheckedAt = nil
                    snapshot.servers[index].passwordCheck = nil
                    snapshot.servers[index].keyCheck = nil
                    continue
                }
                snapshot.servers[index].status = previous.status
                snapshot.servers[index].statusDetail = previous.statusDetail
                snapshot.servers[index].lastCheckedAt = previous.lastCheckedAt
                snapshot.servers[index].passwordCheck = previous.passwordCheck
                snapshot.servers[index].keyCheck = previous.keyCheck
                continue
            }
            if snapshot.servers[index].confirmedHostKeys.isEmpty {
                snapshot.servers[index].status = .hostKeyPending
                snapshot.servers[index].statusDetail = "身份验证前，请在当前网络上确认此端点。"
            } else if !hasLocalKey {
                snapshot.servers[index].status = .missingLocalKey
                snapshot.servers[index].statusDetail = "同步的元数据中没有此 Mac 的私钥。"
            } else {
                snapshot.servers[index].status = .syncPending
                snapshot.servers[index].statusDetail = "使用此免密授权前，请先进行本地检测。"
            }
            snapshot.servers[index].lastCheckedAt = nil
            snapshot.servers[index].passwordCheck = nil
            snapshot.servers[index].keyCheck = nil
        }
    }

    private func currentAuthorizationNeedsAction(for serverID: UUID) -> Bool {
        let localFingerprints = Set(currentDeviceKeys.map(\.fingerprint))
        guard let authorization = snapshot.authorizations.first(where: {
            $0.serverID == serverID && localFingerprints.contains($0.fingerprint)
        }) else { return false }
        return authorization.isDeleted || authorization.status != .authorized
    }

    private func authenticationContextMatches(_ lhs: ServerConnection, _ rhs: ServerConnection) -> Bool {
        guard lhs.host == rhs.host,
              lhs.port == rhs.port,
              lhs.username == rhs.username else { return false }
        let lhsHostKeys = Set(lhs.confirmedHostKeys.map { "\($0.algorithm):\($0.fingerprint)" })
        let rhsHostKeys = Set(rhs.confirmedHostKeys.map { "\($0.algorithm):\($0.fingerprint)" })
        return lhsHostKeys == rhsHostKeys
    }

    private func refreshPasswordAvailability() async {
        var available = Set<UUID>()
        var synchronizable = Set<UUID>()
        var credentialGroups = topology.activeAccounts.map {
            credentialOwnerIDs(forAccountID: $0.id)
        }
        credentialGroups.append(contentsOf: activeServers.compactMap { server in
            guard topology.connectionProfile(id: server.id) == nil else { return nil }
            return [server.id]
        })
        for relatedIDs in credentialGroups {
            for ownerID in relatedIDs {
                if let storage = await keychain.serverPasswordStorage(serverID: ownerID) {
                    available.formUnion(relatedIDs)
                    if storage.isSynchronizable {
                        synchronizable.formUnion(relatedIDs)
                    }
                    break
                }
            }
        }
        serverIDsWithStoredPassword = available
        serverIDsWithSynchronizablePassword = synchronizable
    }

    private func updatePasswordStorageCache(serverID: UUID, synchronizable: Bool) {
        if synchronizable {
            serverIDsWithSynchronizablePassword.insert(serverID)
        } else {
            serverIDsWithSynchronizablePassword.remove(serverID)
        }
    }

    private func refreshMissingMachineConfigurations() async {
        let refreshDate = Date()
        let servers = activeServers.filter {
            $0.status == .authorized && $0.shouldRefreshMachineConfiguration(at: refreshDate)
        }

        for server in servers {
            guard let routeServer = sshOperationServer(for: server),
                  let key = key(for: routeServer),
                  key.isLocallyAvailable,
                  key.privateKeyPath != nil else { continue }

            markMachineConfigurationRefreshAttempt(serverID: server.id, at: refreshDate)
            await persist()
            await synchronizeMachineConfigurationWithKey(server: routeServer, key: key)
        }
    }

    private func mergeImported(_ imported: AppSnapshot) {
        for server in imported.servers {
            if let index = snapshot.servers.firstIndex(where: { $0.id == server.id }) {
                let existing = snapshot.servers[index]
                if server.version > existing.version
                    || (server.version == existing.version && server.isDeleted && !existing.isDeleted)
                    || (server.version == existing.version
                        && server.isDeleted == existing.isDeleted
                        && server.updatedAt > existing.updatedAt) {
                    snapshot.servers[index] = server
                }
            } else {
                snapshot.servers.append(server)
            }
        }
        for device in imported.devices {
            if let index = snapshot.devices.firstIndex(where: { $0.id == device.id }) {
                let existing = snapshot.devices[index]
                if (device.isRevoked && !existing.isRevoked)
                    || (device.isRevoked == existing.isRevoked && device.lastActiveAt > existing.lastActiveAt) {
                    snapshot.devices[index] = device
                }
            } else {
                snapshot.devices.append(device)
            }
        }
        for key in imported.keys {
            if let existing = snapshot.keys.firstIndex(where: { $0.fingerprint == key.fingerprint }) {
                if snapshot.keys[existing].privateKeyPath == nil { snapshot.keys[existing] = key }
            } else {
                snapshot.keys.append(key)
            }
        }
        for authorization in imported.authorizations {
            guard let existing = snapshot.authorizations.first(where: { $0.id == authorization.id }) else {
                snapshot.authorizations.append(authorization)
                continue
            }
            let shouldReplace = authorization.version > existing.version
                || (authorization.version == existing.version
                    && authorization.isDeleted
                    && !existing.isDeleted)
                || (authorization.version == existing.version
                    && authorization.isDeleted == existing.isDeleted
                    && authorization.updatedAt > existing.updatedAt)
            if shouldReplace {
                snapshot.authorizations.removeAll { $0.id == authorization.id }
                snapshot.authorizations.append(authorization)
            }
        }
        snapshot.nodeAssociations = NodeAssociationMerger.merge(
            snapshot.nodeAssociations + imported.nodeAssociations
        )
    }

    private func normalizeStableMetadataIDs() {
        let normalized = CloudMetadataSnapshotPolicy.merge(local: snapshot, remote: AppSnapshot())
        snapshot = CloudMetadataSnapshotPolicy.restoringLocalState(in: normalized, from: snapshot)
    }

    private func serverIDsSharingEndpoint(with serverID: UUID) -> [UUID] {
        ServerConnectionGrouping.groups(activeServers)
            .first { group in group.accounts.contains { $0.id == serverID } }?
            .accounts
            .map(\.id) ?? []
    }

    private func validateEditorDraft(_ draft: ServerDraft, existingServerID: UUID?) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty else {
            throw SSHServiceError.operationFailed("名称、主机和用户均为必填项。")
        }
        guard (1...65_535).contains(draft.port) else {
            throw SSHServiceError.operationFailed("请输入 1 到 65535 之间的有效 SSH 端口。")
        }
        guard KeyPortNaming.isValidAlias(alias) else {
            throw SSHServiceError.operationFailed("SSH 别名只能包含小写字母、数字和单个连字符。")
        }
        guard !activeServers.contains(where: { $0.id != existingServerID && $0.alias == alias }) else {
            throw SSHServiceError.operationFailed("该 SSH 别名已由 KeyPort 管理。")
        }
        if let suggestion = draft.tailscaleSuggestion, !suggestion.matches(host: host) {
            throw SSHServiceError.operationFailed("Tailscale SSH 账户的主机必须属于当前设备。")
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let peerServerIDs = Set(existingServerID.map(serverIDsSharingEndpoint(with:)) ?? [])
        var movedUsernames = [username]
        movedUsernames.append(contentsOf: activeServers.lazy
            .filter { peerServerIDs.contains($0.id) && $0.id != existingServerID }
            .map(\.username))
        guard Set(movedUsernames).count == movedUsernames.count else {
            throw SSHServiceError.operationFailed("该服务器上的 SSH 用户已由 KeyPort 管理。")
        }
        let hasDuplicateAccount = activeServers.contains { server in
            guard server.id != existingServerID,
                  !peerServerIDs.contains(server.id),
                  server.port == draft.port,
                  movedUsernames.contains(server.username) else { return false }
            if let suggestion = draft.tailscaleSuggestion {
                return suggestion.matches(host: server.host)
            }
            let existingHost = server.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return existingHost == normalizedHost
        }
        guard !hasDuplicateAccount else {
            throw SSHServiceError.operationFailed("该设备上的 SSH 用户已由 KeyPort 管理。")
        }
        let existingAlias = existingServerID.flatMap { id in
            snapshot.servers.first(where: { $0.id == id })?.alias
        }
        try await configService.validateAlias(alias, excluding: existingAlias)
    }

    private func editorServer(
        draft: ServerDraft,
        existingServerID: UUID?,
        confirmedHostKeys: [HostKeyRecord]
    ) -> ServerConnection {
        let existing = existingServerID.flatMap { id in snapshot.servers.first(where: { $0.id == id }) }
        return ServerConnection(
            id: existingServerID ?? UUID(),
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: draft.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: draft.port,
            username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines),
            alias: draft.alias.trimmingCharacters(in: .whitespacesAndNewlines),
            group: draft.group.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: draft.notes,
            confirmedHostKeys: confirmedHostKeys,
            status: existing?.status ?? .hostKeyPending,
            statusDetail: existing?.statusDetail,
            lastCheckedAt: existing?.lastCheckedAt,
            passwordCheck: existing?.passwordCheck,
            keyCheck: existing?.keyCheck,
            machineConfiguration: existing?.machineConfiguration,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: existing?.updatedAt ?? .now,
            version: existing?.version ?? 1
        )
    }

    private func failedEditorValidation(
        detail: String,
        log: [String],
        confirmedHostKeys: [HostKeyRecord]
    ) -> ServerEditorValidationResult {
        ServerEditorValidationResult(
            state: .failed,
            check: AuthenticationCheck(state: .failed, detail: detail, checkedAt: .now),
            logLines: log,
            observedHostKeys: [],
            confirmedHostKeys: confirmedHostKeys,
            machineConfiguration: nil
        )
    }

    private func synchronizeMachineConfigurationWithKey(server: ServerConnection, key: SSHKeyRecord) async {
        machineConfigurationSyncingServerID = server.id
        machineConfigurationSyncError = nil
        machineConfigurationSyncErrorServerID = nil
        markMachineConfigurationRefreshAttempt(serverID: server.id)
        defer { machineConfigurationSyncingServerID = nil }

        do {
            guard let configuration = try await sshService.inspectMachineWithPublicKey(server: server, key: key) else {
                let detail = "服务器未返回可解析的机器配置。"
                machineConfigurationSyncError = detail
                machineConfigurationSyncErrorServerID = server.id
                appendSSHCheckLog(detail, serverID: server.id)
                appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "unavailable", level: .warning)
                return
            }
            updateMachineConfiguration(configuration, serverID: server.id)
            appendSSHCheckLog("机器配置同步完成。", serverID: server.id)
            appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "success")
        } catch {
            let detail = UserFacingText.localizedError(error)
            machineConfigurationSyncError = detail
            machineConfigurationSyncErrorServerID = server.id
            appendSSHCheckLog("机器配置同步失败：\(detail)", serverID: server.id)
            appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "failed", level: .warning)
        }
    }

    private func synchronizeMachineConfigurationWithPassword(server: ServerConnection, passwordData: Data) async {
        machineConfigurationSyncingServerID = server.id
        machineConfigurationSyncError = nil
        machineConfigurationSyncErrorServerID = nil
        markMachineConfigurationRefreshAttempt(serverID: server.id)
        defer { machineConfigurationSyncingServerID = nil }

        do {
            guard let configuration = try await sshService.inspectMachineWithPassword(server: server, passwordData: passwordData) else {
                let detail = "服务器未返回可解析的机器配置。"
                machineConfigurationSyncError = detail
                machineConfigurationSyncErrorServerID = server.id
                appendSSHCheckLog(detail, serverID: server.id)
                appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "unavailable", level: .warning)
                return
            }
            updateMachineConfiguration(configuration, serverID: server.id)
            appendSSHCheckLog("机器配置同步完成。", serverID: server.id)
            appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "success")
        } catch {
            let detail = UserFacingText.localizedError(error)
            machineConfigurationSyncError = detail
            machineConfigurationSyncErrorServerID = server.id
            appendSSHCheckLog("机器配置同步失败：\(detail)", serverID: server.id)
            appendAudit(category: "machine-config", action: "sync", targetID: server.id.uuidString, result: "failed", level: .warning)
        }
    }

    private func appendSSHCheckLog(_ line: String, serverID: UUID) {
        guard retainedSSHCheckLog?.serverID == serverID,
              retainedSSHCheckLog?.lines.last != line else { return }
        retainedSSHCheckLog?.lines.append(line)
    }

    private func updateMachineConfiguration(_ configuration: RemoteMachineConfiguration, serverID: UUID) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == serverID }) else { return }
        snapshot.servers[index].machineConfiguration = configuration
        snapshot.servers[index].machineConfigurationRefreshAttemptedAt = configuration.synchronizedAt
        snapshot.servers[index].updatedAt = .now
    }

    private func markMachineConfigurationRefreshAttempt(serverID: UUID, at date: Date = .now) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == serverID }) else { return }
        snapshot.servers[index].machineConfigurationRefreshAttemptedAt = date
    }

    private func updateServer(id: UUID, status: AuthorizationStatus, detail: String) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == id }) else { return }
        snapshot.servers[index].status = status
        snapshot.servers[index].statusDetail = detail
        snapshot.servers[index].lastCheckedAt = .now
        snapshot.servers[index].updatedAt = .now
        if status == .hostKeyMismatch {
            for associationIndex in snapshot.nodeAssociations.indices
                where snapshot.nodeAssociations[associationIndex].serverID == id
                    && snapshot.nodeAssociations[associationIndex].target != nil
                    && (snapshot.nodeAssociations[associationIndex].state != .reviewRequired
                        || snapshot.nodeAssociations[associationIndex].reasonCodes != [.hostKeyChanged]) {
                snapshot.nodeAssociations[associationIndex] = NodeAssociationEngine.reviewRequired(
                    snapshot.nodeAssociations[associationIndex],
                    reason: .hostKeyChanged
                )
            }
        }
    }

    private func updateAuthenticationCheck(
        id: UUID,
        kind: ServerCheckKind,
        state: AuthenticationCheckState,
        detail: String,
        checkedAt: Date? = .now
    ) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == id }) else { return }
        let check = AuthenticationCheck(state: state, detail: detail, checkedAt: checkedAt)
        switch kind {
        case .password:
            snapshot.servers[index].passwordCheck = check
        case .key:
            snapshot.servers[index].keyCheck = check
        }
    }

    private func appendAudit(category: String, action: String, targetID: String? = nil, result: String, level: AuditEvent.Level = .info) {
        snapshot.auditEvents.insert(audit.event(category: category, action: action, targetID: targetID, result: result, level: level), at: 0)
        if snapshot.auditEvents.count > 1000 { snapshot.auditEvents.removeLast(snapshot.auditEvents.count - 1000) }
    }

    private func persist(profileBindings: [SSHConnectionProfileNodeBinding] = []) async {
        do {
            if let hostV6Runtime {
                let envelope = try await hostV6Runtime.saveLegacySnapshot(snapshot, to: store)
                graphWorkspace.update(
                    envelope: envelope,
                    currentDeviceID: envelope.local.deviceStates.first(where: \.isCurrent)?.deviceID
                        ?? snapshot.devices.first(where: \.isCurrent)?.id
                )
            } else {
                let currentDeviceID = snapshot.devices.first(where: \.isCurrent)?.id
                    ?? defaults.string(forKey: "KeyPort.deviceID")
                    ?? KeyPortNaming.newDeviceID()
                let currentDeviceName = snapshot.devices.first(where: { $0.id == currentDeviceID })?.name
                    ?? Host.current().localizedName
                    ?? "此 Mac"
                topology = TopologySnapshotMigration.refreshed(
                    from: snapshot,
                    preserving: topology,
                    currentDeviceID: currentDeviceID,
                    currentDeviceName: currentDeviceName,
                    profileBindings: profileBindings
                )
                try await store.save(snapshot)
                try await topologyStore.save(topology)
                graphWorkspace.update(
                    topology: topology,
                    currentDeviceID: currentDeviceID,
                    tailscaleStatus: tailscaleStatus
                )
            }
            scheduleCloudSyncIfNeeded()
        }
        catch { present(error) }
    }

    private func authorizeLegacyMutation() async -> Bool {
        do {
            try await requireLegacyMutation()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func requireLegacyMutation() async throws {
        try await hostV6Runtime?.authorizeLegacyWrite()
    }

    private func scheduleCloudSyncIfNeeded() {
        guard defaults.bool(forKey: "KeyPort.cloudSyncEnabled"),
              !isSynchronizingCloud,
              !isInitialLoadInProgress else { return }
        automaticCloudRetryAttempt = 0
        scheduledCloudSync?.cancel()
        scheduledCloudSync = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            for _ in 0..<20 {
                guard !Task.isCancelled else { return }
                if !self.isBusy {
                    await self.synchronizeCloud(userInitiated: false)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
            self.scheduleCloudRetry(after: 5)
        }
    }

    private func scheduleCloudRetry(after minimumDelay: TimeInterval) {
        guard defaults.bool(forKey: "KeyPort.cloudSyncEnabled") else { return }
        automaticCloudRetryAttempt += 1
        let exponentialDelay = min(300, 15 * pow(2, Double(max(0, automaticCloudRetryAttempt - 1))))
        let delay = max(minimumDelay, exponentialDelay)
        scheduledCloudSync?.cancel()
        scheduledCloudSync = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.isBusy {
                self.scheduleCloudRetry(after: 5)
            } else {
                await self.synchronizeCloud(userInitiated: false)
            }
        }
    }

    private func cloudState(for error: Error, message: String) -> CloudSyncState {
        guard let error = error as? CloudSyncError else { return .failed(message) }
        switch error {
        case .adHocSignature:
            return .adHocSigned
        case .missingEntitlement:
            return .cloudKitDisabled
        case .accountUnavailable:
            return .signedOut
        default:
            return .failed(message)
        }
    }

    private func present(_ error: Error) {
        errorMessage = UserFacingText.localizedError(error)
    }
}
