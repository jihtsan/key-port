import Foundation
import KeyPortCore
import Observation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case servers, keys, devices, logs
    var id: String { rawValue }
    var title: String {
        switch self { case .servers: "Servers"; case .keys: "Keys"; case .devices: "Devices"; case .logs: "Audit Log" }
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
        return KeyPortNaming.alias(group: group, name: name)
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
}

struct ServerEditorSubmission: Sendable {
    let draft: ServerDraft
    let password: String
    let synchronizable: Bool
    let confirmedHostKeys: [HostKeyRecord]
    let passwordCheck: AuthenticationCheck
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
    var alias: String { connection?.alias ?? serverRow?.server.alias ?? "Unknown" }
    var host: String { connection?.host ?? serverRow?.server.host ?? "" }
    var port: Int { connection?.port ?? serverRow?.server.port ?? 22 }
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
        case .password: "Checking server password authentication..."
        case .key: "Checking passwordless SSH authentication..."
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
        snapshot.servers.filter { !$0.isDeleted }.filter { server in
            guard !searchText.isEmpty else { return true }
            let needle = searchText.localizedLowercase
            return [server.name, server.host, server.username, server.group, server.alias]
                .contains { $0.localizedLowercase.contains(needle) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            !$0.isDeleted && $0.port == suggestion.port && suggestion.matches(host: $0.host)
        }.sorted {
            let usernameOrder = $0.username.localizedCaseInsensitiveCompare($1.username)
            return usernameOrder == .orderedSame ? $0.alias < $1.alias : usernameOrder == .orderedAscending
        }
    }

    func tailscaleServerDraft(
        for suggestion: TailscaleSSHServerSuggestion,
        existingServer: ServerConnection? = nil
    ) -> ServerDraft {
        guard let existingServer else {
            return ServerDraft(
                tailscaleSuggestion: suggestion,
                aliasesToAvoid: Set(activeServers.map(\.alias))
            )
        }

        var draft = ServerDraft(server: existingServer)
        draft.tailscaleSuggestion = suggestion
        draft.aliasesToAvoid = Set(activeServers.lazy.filter { $0.id != existingServer.id }.map(\.alias))
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
            appendAudit(category: "app", action: "load", result: "success")
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
                    confirmedHostKeys: trustedHostKeys
                )
            case .changed(let algorithms):
                let detail = "以下算法的主机密钥已变更：\(algorithms.joined(separator: "、"))。请确认替换后的指纹以继续。"
                log.append(detail)
                return ServerEditorValidationResult(
                    state: .confirmationRequired,
                    check: AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now),
                    logLines: log,
                    observedHostKeys: observed,
                    confirmedHostKeys: trustedHostKeys
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
            } else if let existingServerID, await keychain.hasServerPassword(serverID: existingServerID) {
                passwordData = try await keychain.serverPasswordData(serverID: existingServerID)
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
                confirmedHostKeys: trustedHostKeys
            )
        } catch {
            let message = error.localizedDescription
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

        let serverID = existingServerID ?? UUID()
        if !submission.password.isEmpty {
            try await keychain.saveServerPassword(
                submission.password,
                serverID: serverID,
                synchronizable: submission.synchronizable
            )
            serverIDsWithStoredPassword.insert(serverID)
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

        if let existingServerID,
           let index = snapshot.servers.firstIndex(where: { $0.id == existingServerID }) {
            let authenticationContextChanged = snapshot.servers[index].host != trimmedHost
                || snapshot.servers[index].port != submission.draft.port
                || snapshot.servers[index].username != trimmedUsername
            snapshot.servers[index].name = trimmedName
            snapshot.servers[index].host = trimmedHost
            snapshot.servers[index].port = submission.draft.port
            snapshot.servers[index].username = trimmedUsername
            snapshot.servers[index].alias = trimmedAlias
            snapshot.servers[index].group = trimmedGroup
            snapshot.servers[index].notes = submission.draft.notes
            snapshot.servers[index].confirmedHostKeys = confirmedKeys
            snapshot.servers[index].passwordCheck = submission.passwordCheck
            if authenticationContextChanged {
                snapshot.servers[index].keyCheck = nil
                snapshot.servers[index].status = key(for: snapshot.servers[index]) == nil ? .missingLocalKey : .needsAuthorization
                snapshot.servers[index].statusDetail = "连接信息已变更。密码 SSH 已验证，请重新检查密钥授权。"
            }
            snapshot.servers[index].lastCheckedAt = submission.passwordCheck.checkedAt
            snapshot.servers[index].updatedAt = now
            snapshot.servers[index].version += 1
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
                passwordCheck: submission.passwordCheck
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
        try? await keychain.deleteServerPassword(serverID: id)
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
                errorMessage = "That public key fingerprint is already known to KeyPort."
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
        snapshot.servers[index].statusDetail = "Host key confirmed from the current network response."
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
        guard let serverID = selectedServerID else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await authorizeServer(serverID)
        } catch { present(error) }
    }

    func authorizeCurrentDevice(serverID: UUID) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if preferredKey == nil {
                let key = try await generateCurrentDeviceKey()
                appendAudit(category: "key", action: "generate", targetID: key.id, result: "account-authorization")
                await persist()
            }
            try await authorizeServer(serverID)
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
                    snapshot.servers[index].statusDetail = "This Mac key is ready for authorization."
                }
                appendAudit(category: "key", action: "generate", targetID: generated.id, result: "new-device-ed25519")
                await persist()
            }
            try await localAuthentication.authorize(reason: "Authorize this Mac on pending KeyPort servers")
            for server in activeServers where server.status == .needsAuthorization || server.status == .syncPending {
                guard let serverKey = key(for: server) else { continue }
                do { try await authorize(server: server, key: serverKey) }
                catch {
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
            try await localAuthentication.authorize(reason: "Revoke the selected KeyPort server authorization")
            let observed = try await hostKeyService.scan(server: server)
            guard HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) == .confirmed else {
                throw SSHServiceError.hostKeyChanged
            }
            try await sshService.revokePublicKey(server: server, fingerprint: authorization.fingerprint, publicKeyBlob: parsed.blob, identityPath: identity)
            snapshot.authorizations.removeAll { $0.id == authorizationID }
            if authorization.keyID == credentialKey.id {
                updateServer(id: server.id, status: .needsAuthorization, detail: "This Mac authorization was revoked.")
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
            snapshot = try await cloudSync.synchronize(snapshot)
            ensureCurrentDevice()
            if selectedDeviceItem == nil {
                selectedDeviceItemID = deviceListItems.first(where: \.isCurrent)?.id ?? deviceListItems.first?.id
            }
            normalizeStatusesAfterMetadataMerge(previousServers: previousServers)
            await refreshPasswordAvailability()
            cloudState = .available(.now)
            appendAudit(category: "cloud", action: "sync", result: "success")
            await persist()
        } catch {
            cloudState = .unavailable(error.localizedDescription)
            appendAudit(category: "cloud", action: "sync", result: "unavailable", level: .warning)
            errorMessage = error.localizedDescription
        }
    }

    func refreshTailscale() async {
        guard tailscaleDiscoveryState != .refreshing else { return }
        tailscaleDiscoveryState = .refreshing
        do {
            tailscaleStatus = try await tailscaleService.status()
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
            errorMessage = "This SSH alias contains characters that KeyPort cannot safely manage."
            return
        }

        let server = ServerConnection(
            name: connection.alias,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            alias: connection.alias,
            notes: "Imported from SSH Config host \(connection.alias)."
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

    func testPromptedPassword(_ password: String) async -> AuthenticationCheck {
        guard let server = promptedPasswordServer, !password.isEmpty else {
            return AuthenticationCheck(state: .failed, detail: "Enter a password before testing.", checkedAt: .now)
        }

        do {
            let observed = try await hostKeyService.scan(server: server)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) {
            case .pending:
                let detail = server.confirmedHostKeys.isEmpty
                    ? "Confirm this server's host key before testing password authentication."
                    : "The endpoint presented an unconfirmed host key algorithm. Password authentication was blocked."
                return AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now)
            case .changed(let algorithms):
                let detail = "Host key changed for \(algorithms.joined(separator: ", ")). Password authentication was blocked."
                return AuthenticationCheck(state: .blocked, detail: detail, checkedAt: .now)
            case .confirmed:
                var passwordData = Data(password.utf8)
                defer { passwordData.resetBytes(in: passwordData.indices) }
                let authenticated = try await sshService.testPassword(server: server, passwordData: passwordData)
                return AuthenticationCheck(
                    state: authenticated ? .succeeded : .failed,
                    detail: authenticated
                        ? "Password-only SSH authentication succeeded. Public keys and SSH Agent were disabled."
                        : "The server rejected this password using password-only SSH authentication.",
                    checkedAt: .now
                )
            }
        } catch {
            return AuthenticationCheck(state: .failed, detail: error.localizedDescription, checkedAt: .now)
        }
    }

    func savePromptedPassword(
        _ password: String,
        synchronizable: Bool,
        authorizeAfterSave: Bool,
        validatedCheck: AuthenticationCheck
    ) async {
        guard let server = promptedPasswordServer, !password.isEmpty, !isSavingPassword else { return }
        guard validatedCheck.state == .succeeded, validatedCheck.checkedAt != nil else {
            passwordSaveError = "Test the current password with Password SSH before saving."
            return
        }
        isSavingPassword = true
        passwordSaveError = nil
        defer { isSavingPassword = false }
        do {
            try await keychain.saveServerPassword(password, serverID: server.id, synchronizable: synchronizable)
            serverIDsWithStoredPassword.insert(server.id)
            if let index = snapshot.servers.firstIndex(where: { $0.id == server.id }) {
                snapshot.servers[index].passwordCheck = validatedCheck
            }
            passwordPromptServerID = nil
            appendAudit(category: "keychain", action: "save-password", targetID: server.id.uuidString, result: synchronizable ? "saved-synchronizable" : "saved-local")
            await persist()
            if authorizeAfterSave {
                selectedServerID = server.id
                await authorizeSelected()
            }
        } catch {
            passwordSaveError = error.localizedDescription
        }
    }

    func showServer(_ serverID: UUID) {
        destination = .servers
        selectedServerID = serverID
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

    private func reconcileImportedServerAliases() {
        for index in snapshot.servers.indices where !snapshot.servers[index].isDeleted {
            guard let connection = discoveredSSHConnections.first(where: {
                $0.alias == snapshot.servers[index].name &&
                $0.host == snapshot.servers[index].host &&
                $0.port == snapshot.servers[index].port &&
                $0.username == snapshot.servers[index].username
            }), snapshot.servers[index].notes.hasPrefix("Imported from SSH Config host \(connection.alias)."),
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
            guard snapshot.servers[index].notes.hasPrefix("Imported from SSH Config host "),
                  connection(for: snapshot.servers[index]) != nil,
                  snapshot.servers[index].status == .needsAuthorization else { continue }
            snapshot.servers[index].status = .syncPending
            snapshot.servers[index].statusDetail = "The configured SSH identity changed. Check this connection before authorizing it."
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
                    detail: snapshot.servers[index].statusDetail ?? "Passwordless SSH authentication succeeded.",
                    checkedAt: checkedAt
                )
            case .needsAuthorization, .keyAuthenticationFailed:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .failed,
                    detail: snapshot.servers[index].statusDetail ?? "The current Mac key is not authorized.",
                    checkedAt: checkedAt
                )
            case .hostKeyPending, .hostKeyMismatch:
                snapshot.servers[index].keyCheck = AuthenticationCheck(
                    state: .blocked,
                    detail: snapshot.servers[index].statusDetail ?? "Host key confirmation is required.",
                    checkedAt: checkedAt
                )
            default:
                break
            }
        }
        snapshot.schemaVersion = 3
    }

    private func check(serverID: UUID, kind: ServerCheckKind, ownsBusyState: Bool = true) async {
        guard let initial = snapshot.servers.first(where: { $0.id == serverID && !$0.isDeleted }) else { return }
        if ownsBusyState { isBusy = true }
        updateAuthenticationCheck(id: serverID, kind: kind, state: .checking, detail: kind.checkingDetail, checkedAt: nil)
        if kind == .key {
            updateServer(id: serverID, status: .checking, detail: "Fetching host keys before the key login check.")
        }
        defer { if ownsBusyState { isBusy = false } }
        do {
            let observed = try await hostKeyService.scan(server: initial)
            switch HostKeyEvaluator.evaluate(observed: observed, confirmed: initial.confirmedHostKeys) {
            case .pending:
                let detail = "Review the host key fingerprints before authentication."
                updateServer(id: serverID, status: .hostKeyPending, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
                pendingHostKeys = observed
                pendingHostKeyServerID = serverID
                pendingHostKeyCheckKind = kind
                appendAudit(category: "host-key", action: kind.auditAction, targetID: serverID.uuidString, result: "pending-confirmation", level: .warning)
            case .changed(let algorithms):
                let detail = "Changed algorithms: \(algorithms.joined(separator: ", ")). Authentication was blocked."
                updateServer(id: serverID, status: .hostKeyMismatch, detail: detail)
                updateAuthenticationCheck(id: serverID, kind: kind, state: .blocked, detail: detail)
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
            updateAuthenticationCheck(id: serverID, kind: kind, state: .failed, detail: error.localizedDescription)
            if kind == .key {
                updateServer(id: serverID, status: .unreachable, detail: error.localizedDescription)
            }
            appendAudit(category: "ssh-auth", action: kind.auditAction, targetID: serverID.uuidString, result: "failed", level: .warning)
        }
        await persist()
    }

    private func checkPasswordAuthentication(server: ServerConnection) async throws {
        guard await keychain.hasServerPassword(serverID: server.id) else {
            let detail = "Enter and test a server password before checking Password SSH."
            updateAuthenticationCheck(id: server.id, kind: .password, state: .blocked, detail: detail)
            passwordSaveError = nil
            passwordPromptServerID = server.id
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "missing-password", level: .warning)
            return
        }
        var passwordData = try await keychain.serverPasswordData(serverID: server.id)
        defer { passwordData.resetBytes(in: passwordData.indices) }
        let authenticated = try await sshService.testPassword(server: server, passwordData: passwordData)
        let detail = authenticated ? "Server password authentication succeeded." : "The stored server password was rejected."
        updateAuthenticationCheck(id: server.id, kind: .password, state: authenticated ? .succeeded : .failed, detail: detail)
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
            let detail = "No local private key is available for this Mac."
            updateAuthenticationCheck(id: server.id, kind: .key, state: .failed, detail: detail)
            updateServer(id: server.id, status: .missingLocalKey, detail: detail)
            appendAudit(category: "ssh-auth", action: ServerCheckKind.key.auditAction, targetID: server.id.uuidString, result: "missing-key", level: .warning)
            return
        }
        let authenticated = try await sshService.testPublicKey(server: server, key: key)
        let detail = authenticated ? "Passwordless SSH authentication succeeded." : "The current Mac key is not authorized."
        updateAuthenticationCheck(id: server.id, kind: .key, state: authenticated ? .succeeded : .failed, detail: detail)
        updateServer(id: server.id, status: authenticated ? .authorized : .needsAuthorization, detail: detail)
        appendAudit(
            category: "ssh-auth",
            action: ServerCheckKind.key.auditAction,
            targetID: server.id.uuidString,
            result: authenticated ? "succeeded" : "not-authorized",
            level: authenticated ? .info : .warning
        )
    }

    private func authorize(server: ServerConnection, key: SSHKeyRecord) async throws {
        guard await keychain.hasServerPassword(serverID: server.id) else { throw SSHServiceError.missingPassword }
        var passwordData = try await keychain.serverPasswordData(serverID: server.id)
        defer { passwordData.resetBytes(in: passwordData.indices) }
        let observed = try await hostKeyService.scan(server: server)
        switch HostKeyEvaluator.evaluate(observed: observed, confirmed: server.confirmedHostKeys) {
        case .confirmed: break
        case .pending: throw SSHServiceError.hostKeyNotConfirmed
        case .changed: throw SSHServiceError.hostKeyChanged
        }
        do {
            try await sshService.installPublicKey(server: server, key: key, passwordData: passwordData)
            updateAuthenticationCheck(id: server.id, kind: .password, state: .succeeded, detail: "Server password authentication succeeded during authorization.")
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "succeeded-during-authorization")
        } catch SSHServiceError.passwordAuthenticationRejected {
            updateAuthenticationCheck(id: server.id, kind: .password, state: .failed, detail: "The stored server password was rejected.")
            appendAudit(category: "ssh-auth", action: ServerCheckKind.password.auditAction, targetID: server.id.uuidString, result: "rejected-during-authorization", level: .warning)
            await persist()
            throw SSHServiceError.passwordAuthenticationRejected
        }
        guard try await sshService.testPublicKey(server: server, key: key) else {
            updateAuthenticationCheck(id: server.id, kind: .key, state: .failed, detail: "The key was installed, but passwordless SSH verification failed.")
            throw SSHServiceError.operationFailed("The key was installed but verification failed.")
        }
        updateAuthenticationCheck(id: server.id, kind: .key, state: .succeeded, detail: "Passwordless SSH authentication succeeded after authorization.")
        let authorization = Authorization(serverID: server.id, keyID: key.id, fingerprint: key.fingerprint, remoteComment: key.publicKeyComment ?? "", status: .authorized, authorizedAt: .now, lastVerifiedAt: .now)
        snapshot.authorizations.removeAll { $0.serverID == server.id && $0.keyID == key.id }
        snapshot.authorizations.append(authorization)
        updateServer(id: server.id, status: .authorized, detail: "Public key installed and verified.")
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
            let name = Host.current().localizedName ?? "This Mac"
            snapshot.devices.append(Device(id: deviceID, name: name, isCurrent: true))
        }
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
                snapshot.servers[index].statusDetail = "Confirm this endpoint on the current network before authentication."
            } else if !hasLocalKey {
                snapshot.servers[index].status = .missingLocalKey
                snapshot.servers[index].statusDetail = "Synced metadata has no private key for this Mac."
            } else {
                snapshot.servers[index].status = .syncPending
                snapshot.servers[index].statusDetail = "Run a local check before relying on this authorization."
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
            if await keychain.hasServerPassword(serverID: server.id) {
                available.insert(server.id)
            }
        }
        serverIDsWithStoredPassword = available
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
        let hasDuplicateAccount = activeServers.contains { server in
            guard server.id != existingServerID,
                  server.port == draft.port,
                  server.username == username else { return false }
            if let suggestion = draft.tailscaleSuggestion {
                return suggestion.matchesAccount(
                    host: host,
                    port: draft.port,
                    username: username,
                    server: server
                )
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
            confirmedHostKeys: confirmedHostKeys
        )
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
        errorMessage = error.localizedDescription
    }
}
