import Foundation
import KeyPortCore
import Observation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case servers, keys, devices, logs
    var id: String { rawValue }
    var title: String {
        switch self { case .servers: "服务器"; case .keys: "密钥"; case .devices: "设备"; case .logs: "审计日志" }
    }
    var systemImage: String {
        switch self { case .servers: "server.rack"; case .keys: "key"; case .devices: "laptopcomputer"; case .logs: "list.bullet.rectangle" }
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
    let passwordCheck: AuthenticationCheck
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
        case .password: "正在检查服务器密码身份验证..."
        case .key: "正在检查免密 SSH 身份验证..."
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
    var snapshot = AppSnapshot()
    var destination: SidebarDestination = .servers
    var selectedServerID: UUID?
    var selectedKeyID: String?
    var selectedKeyItemID: String?
    var selectedDeviceItemID: DevicePresence.ID?
    var searchText = ""
    var isLoaded = false
    var isBusy = false
    var errorMessage: String?
    var pendingHostKeys: [HostKeyRecord] = []
    var pendingHostKeyServerID: UUID?
    private var pendingHostKeyCheckKind: ServerCheckKind?
    var cloudState: CloudSyncState = .idle
    var serverIDsWithStoredPassword = Set<UUID>()
    var passwordPromptServerID: UUID?
    var passwordSaveError: String?
    var isSavingPassword = false
    var discoveredSSHConnections: [DiscoveredSSHConnection] = []
    var retainedSSHCheckLog: SSHCheckLog?
    var machineConfigurationSyncingServerID: UUID?
    var machineConfigurationSyncError: String?
    var machineConfigurationSyncErrorServerID: UUID?
    var tailscaleStatus: TailscaleStatus?
    var tailscaleDiscoveryState: TailscaleDiscoveryState = .idle
    let canSynchronizePasswords = KeychainService.synchronizableItemsAvailable

    private let store: SnapshotStore
    private let keychain: KeychainService
    private let keyService: SSHKeyService
    private let hostKeyService: HostKeyService
    private let sshService: OpenSSHService
    private let configService: SSHConfigService
    private let tailscaleService: TailscaleService
    private let localAuthentication: LocalAuthenticationService
    private let cloudSync: any CloudSyncing
    private let archiveService = MetadataArchiveService()
    private let audit = AuditLogService()
    private let clipboard = ClipboardService()
    private let fileSelection = FileSelectionService()

    init(cloudSync: any CloudSyncing = CloudKitSyncService()) {
        let runner = ProcessRunner()
        let paths = KeyPortPaths()
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyPortAskPass").path
        let siblingHelper = executableDirectory?.appendingPathComponent("KeyPortAskPass").path ?? bundledHelper
        let helper = FileManager.default.isExecutableFile(atPath: bundledHelper) ? bundledHelper : siblingHelper

        self.store = SnapshotStore(paths: paths)
        self.keychain = KeychainService()
        self.keyService = SSHKeyService(runner: runner, paths: paths)
        self.hostKeyService = HostKeyService(runner: runner, paths: paths)
        self.sshService = OpenSSHService(runner: runner, paths: paths, askPassPath: helper)
        self.configService = SSHConfigService(runner: runner, paths: paths)
        self.tailscaleService = TailscaleService(runner: runner)
        self.localAuthentication = LocalAuthenticationService()
        self.cloudSync = cloudSync
    }

    var activeServers: [ServerConnection] {
        snapshot.servers
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        let serverIDs = Set(snapshot.authorizations.lazy.filter { keyIDs.contains($0.keyID) }.map(\.serverID))
        return activeServers.filter { serverIDs.contains($0.id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func key(for authorization: Authorization) -> SSHKeyRecord? {
        snapshot.keys.first { $0.id == authorization.keyID }
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
        return ServerDraft(newAccountFor: server, aliasesToAvoid: managedAliases)
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
                      let key = snapshot.keys.first(where: { $0.id == authorization.keyID }) else { return false }
                return key.deviceID == currentDevice?.id
            }
            let key = key(for: server)
            return KeyServerRow(server: server, key: key, authorization: authorization)
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
        do {
            snapshot = try await store.load()
            ensureCurrentDevice()
            try await refreshKeys(recordAudit: false)
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
        } catch {
            isLoaded = true
            present(error)
        }
    }

    func validateServerEditor(
        draft: ServerDraft,
        password: String,
        existingServerID: UUID?,
        trustedHostKeys: [HostKeyRecord]
    ) async -> ServerEditorValidationResult {
        var log = ["正在解析 \(draft.username)@\(draft.host):\(draft.port)", "正在扫描服务器主机密钥..."]
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
            } else if let existingServerID, await keychain.hasServerCredential(serverID: existingServerID) {
                var credential = try await keychain.serverCredential(serverID: existingServerID)
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

            log.append("密码 SSH 身份验证成功。")
            let machineConfiguration = try await sshService.inspectMachineWithPassword(server: server, passwordData: passwordData)
            if machineConfiguration != nil {
                log.append("远程机器配置已同步。")
            } else {
                log.append("身份验证已通过，但无法获取机器配置。")
            }
            let check = AuthenticationCheck(
                state: .succeeded,
                detail: "密码 SSH 身份验证成功。",
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
        try await validateEditorDraft(submission.draft, existingServerID: existingServerID)
        guard submission.passwordCheck.state == .succeeded else {
            throw SSHServiceError.operationFailed("请先成功完成 SSH 检查再保存。")
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
            var credential = try await keychain.serverCredential(serverID: existingServerID)
            passwordData = credential.passwordData
            credential.passwordData.resetBytes(in: credential.passwordData.indices)
        } else {
            throw SSHServiceError.missingPassword
        }
        defer { passwordData.resetBytes(in: passwordData.indices) }
        try await keychain.saveServerCredential(
            username: trimmedUsername,
            passwordData: passwordData,
            serverID: serverID,
            synchronizable: hasNewPassword ? submission.synchronizable : nil
        )
        serverIDsWithStoredPassword.insert(serverID)

        let peerServerIDs = existingServerID.map(serverIDsSharingEndpoint(with:)) ?? []
        let sharedFields = SharedServerFields(
            name: trimmedName,
            host: trimmedHost,
            port: submission.draft.port,
            group: trimmedGroup,
            notes: submission.draft.notes,
            confirmedHostKeys: confirmedKeys,
            machineConfiguration: submission.machineConfiguration,
            machineConfigurationRefreshAttemptedAt: submission.machineConfiguration?.synchronizedAt ?? now
        )

        if let existingServerID,
           let index = snapshot.servers.firstIndex(where: { $0.id == existingServerID }) {
            let authenticationContextChanged = snapshot.servers[index].host != trimmedHost
                || snapshot.servers[index].port != submission.draft.port
                || snapshot.servers[index].username != trimmedUsername
            sharedFields.apply(to: &snapshot.servers[index])
            snapshot.servers[index].username = trimmedUsername
            snapshot.servers[index].alias = trimmedAlias
            snapshot.servers[index].passwordCheck = submission.passwordCheck
            if authenticationContextChanged {
                snapshot.servers[index].keyCheck = nil
                snapshot.servers[index].status = key(for: snapshot.servers[index]) == nil ? .missingLocalKey : .needsAuthorization
                snapshot.servers[index].statusDetail = "连接信息已变更。密码 SSH 已验证，请重新检查密钥授权。"
            }
            snapshot.servers[index].lastCheckedAt = submission.passwordCheck.checkedAt
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
                    snapshot.servers[peerIndex].statusDetail = "服务器端点已变更，请重新检查此用户的 SSH 授权。"
                    snapshot.servers[peerIndex].lastCheckedAt = nil
                }
                snapshot.servers[peerIndex].updatedAt = now
                snapshot.servers[peerIndex].version += 1
            }
            appendAudit(category: "server", action: "update", targetID: existingServerID.uuidString, result: "password-verified")
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
                statusDetail: "密码 SSH 已验证，现在可以授权此 Mac 的密钥。",
                lastCheckedAt: submission.passwordCheck.checkedAt,
                passwordCheck: submission.passwordCheck,
                machineConfiguration: submission.machineConfiguration,
                machineConfigurationRefreshAttemptedAt: submission.machineConfiguration?.synchronizedAt ?? now
            )
            snapshot.servers.append(server)
            appendAudit(category: "server", action: "create", targetID: serverID.uuidString, result: "password-verified")
        }

        selectedServerID = serverID
        try await hostKeyService.persistConfirmedKeys(confirmedKeys, allServers: snapshot.servers.filter { !$0.isDeleted })
        try await configService.write(servers: activeServers, keys: snapshot.keys, authorizations: snapshot.authorizations)
        appendAudit(category: "ssh-config", action: "write", targetID: serverID.uuidString, result: "success")
        await persist()
        return serverID
    }

    func saveAndAuthorizeTailscaleServer(
        _ submission: ServerEditorSubmission,
        suggestion: TailscaleSSHServerSuggestion,
        existingServerID: UUID? = nil
    ) async throws -> UUID {
        guard !isBusy else {
            throw SSHServiceError.operationFailed("KeyPort 正在执行其他操作，请稍后重试。")
        }
        isBusy = true
        defer { isBusy = false }

        let matchedServerID = existingServerID
            ?? existingTailscaleServerID(for: suggestion, draft: submission.draft)
        let serverID = try await saveServerEditor(submission, existingServerID: matchedServerID)
        if preferredKey == nil {
            let key = try await generateCurrentDeviceKey()
            appendAudit(category: "key", action: "generate", targetID: key.id, result: "tailscale-enrollment")
            await persist()
        }
        try await authorizeServer(serverID)
        return serverID
    }

    func deleteSelectedServer() async {
        guard let id = selectedServerID else { return }
        await deleteServer(id)
    }

    func deleteServer(_ id: UUID) async {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == id }) else { return }
        snapshot.servers[index].isDeleted = true
        snapshot.servers[index].updatedAt = .now
        snapshot.servers[index].version += 1
        try? await keychain.deleteServerCredential(serverID: id)
        serverIDsWithStoredPassword.remove(id)
        appendAudit(category: "server", action: "delete", targetID: id.uuidString, result: "tombstoned")
        if selectedServerID == id { selectedServerID = activeServers.first?.id }
        await persist()
        await writeConfig()
    }

    func refreshKeys(recordAudit: Bool = true) async throws {
        ensureCurrentDevice()
        guard let device = currentDevice else { return }
        let scanned = try await keyService.scan(deviceID: device.id)
        discoveredSSHConnections = await configService.discoverConnections()
        reconcileImportedServerAliases()
        migrateImportedConnectionKeyStatusIfNeeded()
        migrateLegacyAuthenticationChecksIfNeeded()
        migrateDeviceNetworkIdentitySchemaIfNeeded()
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
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try await generateCurrentDeviceKey()
            appendAudit(category: "key", action: "generate", targetID: key.id, result: "ed25519-success")
            await persist()
        } catch { present(error) }
    }

    func importKey() async {
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

    func synchronizeSSHAuthorizationSelected() async {
        guard let id = selectedServerID else { return }
        await synchronizeSSHAuthorization(serverID: id)
    }

    func synchronizeSSHAuthorization(serverID: UUID) async {
        guard !isBusy,
              let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }

        isBusy = true
        retainedSSHCheckLog = SSHCheckLog(
            serverID: serverID,
            title: "SSH 授权同步",
            lines: ["正在同步 \(server.username)@\(server.endpoint)...", "正在扫描服务器主机密钥..."]
        )
        updateAuthenticationCheck(id: serverID, kind: .key, state: .checking, detail: "正在检查主机身份并准备 SSH 授权。", checkedAt: nil)
        updateServer(id: serverID, status: .syncing, detail: "正在同步 SSH 授权，完成公钥复检后才会显示免密可用。")
        defer { isBusy = false }

        do {
            let observed = try await hostKeyService.scan(server: server)
            appendSSHCheckLog("已收到 \(observed.count) 个主机密钥指纹。", serverID: serverID)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) {
            case .pending:
                let detail = "同步 SSH 授权前，请核对主机密钥指纹。"
                updateServer(id: serverID, status: .hostKeyPending, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = .key
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "host-key", action: "authorization-sync", targetID: serverID.uuidString, result: "pending-confirmation", level: .warning)
                await persist()
                return
            case .changed(let algorithms):
                let detail = "发生变更的算法：\(algorithms.joined(separator: "、"))。同步 SSH 授权已被阻止。"
                updateServer(id: serverID, status: .hostKeyMismatch, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = .key
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "host-key", action: "authorization-sync", targetID: serverID.uuidString, result: "mismatch-blocked", level: .error)
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
                await persist()
                return
            }

            guard await keychain.hasServerCredential(serverID: serverID) else {
                let detail = "同步 SSH 授权前，请添加并验证当前 SSH 账户的密码。"
                updateServer(id: serverID, status: .needsAuthorization, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: .key, state: .blocked, detail: detail)
                passwordSaveError = nil
                passwordPromptServerID = serverID
                appendSSHCheckLog(detail, serverID: serverID)
                appendAudit(category: "authorization", action: "sync", targetID: serverID.uuidString, result: "missing-password", level: .warning)
                await persist()
                return
            }

            updateAuthenticationCheck(id: serverID, kind: .key, state: .checking, detail: "正在使用 Keychain 密码安装公钥并进行复检。", checkedAt: nil)
            appendSSHCheckLog("正在安装当前 Mac 公钥并执行强制公钥复检...", serverID: serverID)
            try await localAuthentication.authorize(reason: "在 \(server.name) 上同步此 Mac 的 SSH 授权")
            try await authorize(server: server, key: key)
            await synchronizeMachineConfigurationWithKey(server: server, key: key)
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
                passwordPromptServerID = serverID
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

        isBusy = true
        defer { isBusy = false }
        await synchronizeMachineConfigurationWithKey(server: server, key: key)
        await persist()
    }

    func checkAll() async {
        guard !isBusy else { return }
        isBusy = true
        let ids = activeServers.map(\.id)
        for id in ids {
            await check(serverID: id, kind: .password, ownsBusyState: false)
            await check(serverID: id, kind: .key, ownsBusyState: false)
        }
        isBusy = false
    }

    func confirmPendingHostKeys() async {
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
        pendingHostKeys = []
        pendingHostKeyServerID = nil
        pendingHostKeyCheckKind = nil
        do {
            try await hostKeyService.persistConfirmedKeys(confirmed, allServers: snapshot.servers.filter { !$0.isDeleted })
            appendAudit(category: "host-key", action: isRotation ? "rotate" : "confirm", targetID: serverID.uuidString, result: "confirmed-\(confirmed.count)")
            await persist()
            await check(serverID: serverID, kind: checkKind)
        } catch { present(error) }
    }

    func cancelPendingHostKeys() {
        pendingHostKeys = []
        pendingHostKeyServerID = nil
        pendingHostKeyCheckKind = nil
    }

    func authorizeSelected() async {
        await synchronizeSSHAuthorizationSelected()
    }

    func authorizeCurrentDevice(serverID: UUID) async {
        guard !isBusy else { return }
        do {
            if preferredKey == nil {
                let key = try await generateCurrentDeviceKey()
                appendAudit(category: "key", action: "generate", targetID: key.id, result: "account-authorization")
                await persist()
            }
            await synchronizeSSHAuthorization(serverID: serverID)
        } catch { present(error) }
    }

    func authorizePendingServers() async {
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
                    snapshot.servers[index].statusDetail = "此 Mac 的密钥已准备好授权。"
                }
                appendAudit(category: "key", action: "generate", targetID: generated.id, result: "new-device-ed25519")
                await persist()
            }
            try await localAuthentication.authorize(reason: "在待处理的 KeyPort 服务器上授权此 Mac")
            for server in activeServers where server.status == .needsAuthorization || server.status == .syncPending {
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
        guard let server = snapshot.servers.first(where: { $0.id == serverID }),
              let identity = key(for: server)?.privateKeyPath else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let lines = try await sshService.readAuthorizedKeys(server: server, identityPath: identity)
            var discoveredKeys: [SSHKeyRecord] = []
            let managed = lines.filter(\.isKeyPortManaged).compactMap { line -> Authorization? in
                guard let key = line.key, let comment = key.comment else { return nil }
                let components = comment.split(separator: ":").map(String.init)
                guard components.count >= 4 else { return nil }
                let knownKey = snapshot.keys.first { $0.fingerprint == key.fingerprint }
                if knownKey == nil {
                    discoveredKeys.append(SSHKeyRecord(id: components[2], deviceID: components[3], kind: key.kind, publicKey: line.rawLine, fingerprint: key.fingerprint, privateKeyPath: nil, isInAgent: false, origin: .scanned, isLocallyAvailable: false))
                }
                return Authorization(serverID: serverID, keyID: knownKey?.id ?? components[2], fingerprint: key.fingerprint, remoteComment: comment, status: .authorized, lastVerifiedAt: .now)
            }
            for key in discoveredKeys where !snapshot.keys.contains(where: { $0.fingerprint == key.fingerprint }) {
                snapshot.keys.append(key)
            }
            snapshot.authorizations.removeAll { $0.serverID == serverID }
            snapshot.authorizations.append(contentsOf: managed)
            appendAudit(category: "authorization", action: "read", targetID: serverID.uuidString, result: "keyport-entries-\(managed.count)")
            await persist()
        } catch { present(error) }
    }

    func revokeAuthorization(_ authorizationID: String) async {
        guard let authorization = snapshot.authorizations.first(where: { $0.id == authorizationID }),
              let server = snapshot.servers.first(where: { $0.id == authorization.serverID }),
              let credentialKey = key(for: server),
              let identity = credentialKey.privateKeyPath,
              let targetKey = snapshot.keys.first(where: { $0.fingerprint == authorization.fingerprint }),
              let parsed = PublicKeyParser.parse(targetKey.publicKey) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await localAuthentication.authorize(reason: "撤销所选 KeyPort 服务器授权")
            let observed = try await hostKeyService.scan(server: server)
            guard HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) == .confirmed else {
                throw SSHServiceError.hostKeyChanged
            }
            try await sshService.revokePublicKey(server: server, fingerprint: authorization.fingerprint, publicKeyBlob: parsed.blob, identityPath: identity)
            snapshot.authorizations.removeAll { $0.id == authorizationID }
            if authorization.keyID == credentialKey.id {
                updateServer(id: server.id, status: .needsAuthorization, detail: "此 Mac 的授权已撤销。")
            }
            appendAudit(category: "authorization", action: "revoke", targetID: server.id.uuidString, result: "fingerprint-verified")
            await writeConfig()
            await persist()
        } catch { present(error) }
    }

    func synchronizeCloud() async {
        guard !isBusy else { return }
        isBusy = true
        cloudState = .syncing
        defer { isBusy = false }
        do {
            let previousServers = snapshot.servers
            let localMachineConfigurationRefreshAttempts = snapshot.servers.reduce(into: [UUID: Date]()) { result, server in
                if let attemptedAt = server.machineConfigurationRefreshAttemptedAt {
                    result[server.id] = attemptedAt
                }
            }
            snapshot = try await cloudSync.synchronize(snapshot)
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
            cloudState = .available(.now)
            appendAudit(category: "cloud", action: "sync", result: "success")
            await persist()
        } catch {
            let message = UserFacingText.localizedError(error)
            cloudState = .unavailable(message)
            appendAudit(category: "cloud", action: "sync", result: "unavailable", level: .warning)
            errorMessage = message
        }
    }

    func refreshTailscale() async {
        guard tailscaleDiscoveryState != .refreshing else { return }
        tailscaleDiscoveryState = .refreshing
        do {
            let status = try await tailscaleService.status()
            tailscaleStatus = status
            await recordCurrentDeviceIdentity(from: status)
            tailscaleDiscoveryState = .available
            if selectedDeviceItem == nil {
                selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
            }
        } catch {
            tailscaleStatus = nil
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

    func clearAuditLog() async {
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
                  let authorizedKey = snapshot.keys.first(where: { $0.id == authorization.keyID }) else { return false }
            return authorizedKey.deviceID == currentDevice?.id && authorizedKey.isLocallyAvailable
        }), let authorizedKey = snapshot.keys.first(where: { $0.id == authorization.keyID }) {
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
        serverIDsWithStoredPassword.contains(serverID)
    }

    func requestPassword(for serverID: UUID) {
        passwordSaveError = nil
        passwordPromptServerID = serverID
    }

    func cancelPasswordPrompt() {
        passwordSaveError = nil
        passwordPromptServerID = nil
    }

    func testPromptedPassword(username: String, password: String) async -> AuthenticationCheck {
        guard let server = promptedPasswordServer, !password.isEmpty else {
            return AuthenticationCheck(state: .failed, detail: "测试前请输入用户名和密码。", checkedAt: .now)
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            return AuthenticationCheck(state: .failed, detail: "测试前请输入用户名。", checkedAt: .now)
        }
        var candidateServer = server
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
                let detail = "以下算法的主机密钥已变更：\(algorithms.joined(separator: "、"))。密码身份验证已被阻止。"
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
        guard let server = promptedPasswordServer, !password.isEmpty, !isSavingPassword else { return }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            passwordSaveError = "请输入用户名。"
            return
        }
        guard validatedCheck.state == .succeeded, validatedCheck.checkedAt != nil else {
            passwordSaveError = "保存前，请使用密码 SSH 测试当前密码。"
            return
        }
        let duplicateAccount = snapshot.servers.contains {
            !$0.isDeleted
                && $0.id != server.id
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
            try await keychain.saveServerCredential(
                username: trimmedUsername,
                passwordData: passwordData,
                serverID: server.id,
                synchronizable: synchronizable
            )
            serverIDsWithStoredPassword.insert(server.id)
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
            passwordPromptServerID = nil
            appendAudit(category: "keychain", action: "save-credential", targetID: server.id.uuidString, result: synchronizable ? "saved-synchronizable" : "saved-local")
            if usernameChanged {
                await writeConfig()
            }
            await persist()
            if authorizeAfterSave {
                selectedServerID = server.id
                await authorizeSelected()
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
            appendAudit(category: "archive", action: "export", result: "encrypted-metadata")
            await persist()
        } catch { present(error) }
    }

    func importMetadata(password: String) async {
        guard let source = await fileSelection.selectArchiveForImport() else { return }
        do {
            let imported = try await archiveService.importArchive(from: source, password: password)
            let previousServers = snapshot.servers
            mergeImported(imported)
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
            snapshot.servers[index].statusDetail = "此 Mac 的密钥已准备好授权。"
        }
        return key
    }

    private func authorizeServer(_ serverID: UUID) async throws {
        guard let server = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else {
            throw SSHServiceError.operationFailed("找不到要授权的服务器。")
        }
        guard let key = key(for: server) else { throw SSHServiceError.missingPrivateKey }
        try await localAuthentication.authorize(reason: "在 \(server.name) 上授权此 Mac")
        try await authorize(server: server, key: key)
    }

    private var preferredKey: SSHKeyRecord? {
        if let selectedKeyID, let selected = currentDeviceKeys.first(where: { $0.id == selectedKeyID }) { return selected }
        return currentDeviceKeys.first(where: { $0.kind == .ed25519 && $0.privateKeyPath != nil }) ?? currentDeviceKeys.first
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
            snapshot.servers[index].statusDetail = "已配置的 SSH 身份密钥发生变化，请在授权前检查此连接。"
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
                    detail: snapshot.servers[index].statusDetail ?? "免密 SSH 身份验证成功。",
                    checkedAt: checkedAt
                )
            case .needsAuthorization, .keyAuthenticationFailed:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .failed,
                    detail: snapshot.servers[index].statusDetail ?? "当前 Mac 的密钥尚未授权。",
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

    private func check(serverID: UUID, kind: ServerCheckKind, ownsBusyState: Bool = true) async {
        guard let initial = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        if ownsBusyState { isBusy = true }
        retainedSSHCheckLog = SSHCheckLog(
            serverID: serverID,
            title: kind == .password ? "密码 SSH 检查" : "密钥 SSH 检查",
            lines: ["正在连接 \(initial.username)@\(initial.endpoint)...", "正在扫描服务器主机密钥..."]
        )
        updateAuthenticationCheck(id: serverID, kind: kind, state: .checking, detail: kind.checkingDetail, checkedAt: nil)
        if kind == .key {
            updateServer(id: serverID, status: .checking, detail: "密钥登录检查前正在获取主机密钥。")
        }
        defer { if ownsBusyState { isBusy = false } }
        do {
            let observed = try await hostKeyService.scan(server: initial)
            appendSSHCheckLog("已收到 \(observed.count) 个主机密钥指纹。", serverID: serverID)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: initial.confirmedHostKeys) {
            case .pending:
                let detail = "身份验证前，请核对主机密钥指纹。"
                updateServer(id: serverID, status: .hostKeyPending, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
                appendSSHCheckLog(detail, serverID: serverID)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = kind
                appendAudit(category: "host-key", action: kind.auditAction, targetID: serverID.uuidString, result: "pending-confirmation", level: .warning)
            case .changed(let algorithms):
                let detail = "发生变更的算法：\(algorithms.joined(separator: "、"))。身份验证已被阻止。"
                updateServer(id: serverID, status: .hostKeyMismatch, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
                appendSSHCheckLog(detail, serverID: serverID)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = kind
                appendAudit(category: "host-key", action: kind.auditAction, targetID: serverID.uuidString, result: "mismatch-blocked", level: .error)
            case .confirmed:
                switch kind {
                case .password:
                    try await checkPasswordAuthentication(server: initial)
                case .key:
                    try await checkKeyAuthentication(server: initial)
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

    private func serverUsingCredentialUsername(_ server: ServerConnection, credential: ServerCredential) -> ServerConnection {
        let username = credential.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != server.username else { return server }
        var authenticatedServer = server
        authenticatedServer.username = username
        return authenticatedServer
    }

    private func checkPasswordAuthentication(server: ServerConnection) async throws {
        guard await keychain.hasServerCredential(serverID: server.id) else {
            let detail = "检查密码 SSH 前，请输入并测试服务器密码。"
            updateAuthenticationCheck(id: server.id, kind: .password, state: .blocked, detail: detail)
            passwordSaveError = nil
            passwordPromptServerID = server.id
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "missing-password", level: .warning)
            return
        }
        var credential = try await keychain.serverCredential(serverID: server.id)
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
        let detail = authenticated ? "免密 SSH 身份验证成功。" : "当前 Mac 的密钥尚未授权。"
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
        guard await keychain.hasServerCredential(serverID: server.id) else { throw SSHServiceError.missingPassword }
        var credential = try await keychain.serverCredential(serverID: server.id)
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
        do {
            try await configService.write(servers: activeServers, keys: snapshot.keys, authorizations: snapshot.authorizations)
            appendAudit(category: "ssh-config", action: "write", result: "success")
        } catch { present(error) }
    }

    private func ensureCurrentDevice() {
        let defaults = UserDefaults.standard
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

    private func recordCurrentDeviceIdentity(from status: TailscaleStatus) async {
        guard let node = status.nodes.first(where: \.isCurrent),
              let index = snapshot.devices.firstIndex(where: \.isCurrent) else { return }
        snapshot.devices[index].tailscaleIdentity = TailscaleDeviceIdentity(node: node)
        snapshot.devices[index].lastActiveAt = .now
        await persist()
    }

    private func normalizeStatusesAfterMetadataMerge(previousServers: [ServerConnection]) {
        let previousByID = Dictionary(uniqueKeysWithValues: previousServers.map { ($0.id, $0) })
        let hasLocalKey = !currentDeviceKeys.isEmpty
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted {
            if let previous = previousByID[snapshot.servers[index].id],
               authenticationContextMatches(previous, snapshot.servers[index]) {
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
                snapshot.servers[index].statusDetail = "依赖此授权前，请先运行本地检查。"
            }
            snapshot.servers[index].lastCheckedAt = nil
            snapshot.servers[index].passwordCheck = nil
            snapshot.servers[index].keyCheck = nil
        }
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
        for server in activeServers {
            if await keychain.hasServerCredential(serverID: server.id) {
                available.insert(server.id)
            }
        }
        serverIDsWithStoredPassword = available
    }

    private func refreshMissingMachineConfigurations() async {
        let refreshDate = Date()
        let servers = activeServers.filter {
            $0.status == .authorized && $0.shouldRefreshMachineConfiguration(at: refreshDate)
        }

        for server in servers {
            guard let key = key(for: server),
                  key.isLocallyAvailable,
                  key.privateKeyPath != nil else { continue }

            markMachineConfigurationRefreshAttempt(serverID: server.id, at: refreshDate)
            await persist()
            await synchronizeMachineConfigurationWithKey(server: server, key: key)
        }
    }

    private func mergeImported(_ imported: AppSnapshot) {
        for server in imported.servers {
            if let index = snapshot.servers.firstIndex(where: { $0.id == server.id }) {
                if server.updatedAt > snapshot.servers[index].updatedAt { snapshot.servers[index] = server }
            } else {
                snapshot.servers.append(server)
            }
        }
        for device in imported.devices where !snapshot.devices.contains(where: { $0.id == device.id }) {
            snapshot.devices.append(device)
        }
        for key in imported.keys {
            if let existing = snapshot.keys.firstIndex(where: { $0.fingerprint == key.fingerprint }) {
                if snapshot.keys[existing].privateKeyPath == nil { snapshot.keys[existing] = key }
            } else {
                snapshot.keys.append(key)
            }
        }
        for authorization in imported.authorizations {
            snapshot.authorizations.removeAll { $0.id == authorization.id && ($0.lastVerifiedAt ?? .distantPast) < (authorization.lastVerifiedAt ?? .distantPast) }
            if !snapshot.authorizations.contains(where: { $0.id == authorization.id }) { snapshot.authorizations.append(authorization) }
        }
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

    private func upsertAuthorization(serverID: UUID, key: SSHKeyRecord, authorizedAt: Date?) {
        let existing = snapshot.authorizations.first {
            $0.serverID == serverID && $0.keyID == key.id
        }
        let authorization = Authorization(
            serverID: serverID,
            keyID: key.id,
            fingerprint: key.fingerprint,
            remoteComment: key.publicKeyComment ?? "",
            status: .authorized,
            authorizedAt: authorizedAt ?? existing?.authorizedAt,
            lastVerifiedAt: .now
        )
        snapshot.authorizations.removeAll { $0.serverID == serverID && $0.keyID == key.id }
        snapshot.authorizations.append(authorization)
    }

    private func updateServer(id: UUID, status: AuthorizationStatus, detail: String) {
        guard let index = snapshot.servers.firstIndex(where: { $0.id == id }) else { return }
        snapshot.servers[index].status = status
        snapshot.servers[index].statusDetail = detail
        snapshot.servers[index].lastCheckedAt = .now
        snapshot.servers[index].updatedAt = .now
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

    private func persist() async {
        do { try await store.save(snapshot) }
        catch { present(error) }
    }

    private func present(_ error: Error) {
        errorMessage = UserFacingText.localizedError(error)
    }
}
