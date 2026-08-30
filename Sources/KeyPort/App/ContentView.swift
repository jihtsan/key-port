import KeyPortCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var showsAddServer = false
    @State private var sshAccountEditorRequest: SSHAccountEditorRequest?
    @State private var endpointNodeID: UUID?
    @State private var sshAccessSetupRequest: SSHAccessSetupRequest?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            AppSidebarView(model: model)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 390, max: 520)
        } detail: {
            detailColumn
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showsAddServer) {
            ServerEditorView(
                title: "添加节点和首个 SSH 账户",
                initialDraft: model.newServerDraft(),
                canSynchronize: model.canSynchronizePasswords,
                onCheck: { draft, password, hostKeys in
                    return await model.validateServerEditor(
                        draft: draft,
                        password: password,
                        existingServerID: nil,
                        trustedHostKeys: hostKeys
                    )
                },
                onSave: { submission, enablesPasswordless in
                    try await saveServer(
                        submission,
                        existingServerID: nil,
                        enablesPasswordless: enablesPasswordless
                    )
                }
            )
        }
        .sheet(item: $sshAccountEditorRequest) { request in
            if let node = model.topology.node(id: request.nodeID),
               let draft = model.sshAccountDraft(
                   forNodeID: request.nodeID,
                   accountID: request.accountID
               ) {
                SSHAccountEditorView(
                    nodeName: node.name,
                    initialDraft: draft,
                    hasStoredPassword: request.accountID.map {
                        model.hasStoredPassword(accountID: $0)
                    } ?? false,
                    storedPasswordSynchronizable: request.accountID.map {
                        model.isPasswordSynchronizable(accountID: $0)
                    } ?? false,
                    canSynchronize: model.canSynchronizePasswords,
                    onSave: { submission in
                        try await model.saveSSHAccount(submission)
                    }
                )
            } else {
                ContentUnavailableView(
                    "无法编辑 SSH 账户",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("目标节点或账户已经不存在。")
                )
                .frame(minWidth: 480, minHeight: 280)
            }
        }
        .sheet(item: $sshAccessSetupRequest) { request in
            NavigationStack {
                if let draft = model.sshAccessSetupDraft(
                    forNodeID: request.nodeID,
                    profileID: request.profileID,
                    endpointID: request.endpointID
                ) {
                    SSHAccessSetupView(model: model, initialDraft: draft)
                } else {
                    ContentUnavailableView(
                        "无法配置 SSH 访问",
                        systemImage: "exclamationmark.triangle",
                        description: Text("请先为节点添加至少一个 SSH 账户和网络路径。")
                    )
                    .frame(minWidth: 480, minHeight: 300)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { endpointNodeID != nil },
            set: { if !$0 { endpointNodeID = nil } }
        )) {
            if let nodeID = endpointNodeID,
               let node = model.topology.node(id: nodeID),
               let draft = model.newEndpointDraft(forNodeID: nodeID) {
                NodeEndpointEditorView(
                    nodeName: node.name,
                    initialDraft: draft,
                    onSave: { draft in
                        try await model.saveNodeEndpoint(draft, forNodeID: nodeID)
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pendingHostKeyServerID != nil },
            set: { if !$0 { model.cancelPendingHostKeys() } }
        )) {
            HostKeyConfirmationView(keys: model.pendingHostKeys, previousKeys: model.pendingPreviousHostKeys) {
                Task { await model.confirmPendingHostKeys() }
            } onCancel: {
                model.cancelPendingHostKeys()
            }
        }
        .sheet(isPresented: Binding(
            get: { model.passwordPromptServerID != nil },
            set: { if !$0 { model.cancelPasswordPrompt() } }
        )) {
            if let server = model.promptedPasswordServer {
                PasswordEntryView(
                    server: server,
                    canAuthorize: !server.confirmedHostKeys.isEmpty && model.key(for: server) != nil && server.status != .authorized,
                    canSynchronize: model.canSynchronizePasswords,
                    isSaving: model.isSavingPassword,
                    errorMessage: model.passwordSaveError,
                    onTest: { username, password in
                        await model.testPromptedPassword(username: username, password: password)
                    },
                    onSave: { username, password, synchronizable, authorizeAfterSave, validatedCheck in
                        Task {
                            await model.savePromptedPassword(
                                username: username,
                                password: password,
                                synchronizable: synchronizable,
                                authorizeAfterSave: authorizeAfterSave,
                                validatedCheck: validatedCheck
                            )
                        }
                    },
                    onCancel: { model.cancelPasswordPrompt() }
                )
            }
        }
        .alert("KeyPort 无法完成此操作", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch model.destination {
        case .graph:
            GraphWorkspaceView(model: model)
        case .nodes:
            GraphNodesView(model: model) {
                showsAddServer = true
            }
        case .activity:
            GraphActivityListView(model: model)
        case .servers:
            ServerListView(model: model) { serverID in
                model.selectedServerID = serverID
                addAccount(forConnectionProfileID: serverID)
            } onEdit: { serverID in
                model.selectedServerID = serverID
                configureAccess(connectionProfileID: serverID)
            }
        case .keys:
            KeyListView(model: model)
        case .devices:
            DeviceListView(model: model)
        case .logs:
            AuditLogListView(model: model)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch model.destination {
        case .graph:
            GraphInspectorView(
                workspace: model.graphWorkspace,
                model: model,
                onAddAccount: { nodeID in
                    addAccount(nodeID: nodeID)
                },
                onAddEndpoint: { nodeID in
                    addEndpoint(nodeID: nodeID)
                },
                onEditAccount: { accountID in
                    editAccount(accountID: accountID)
                },
                onConfigureAccess: { nodeID, profileID, endpointID in
                    configureAccess(
                        nodeID: nodeID,
                        profileID: profileID,
                        endpointID: endpointID
                    )
                }
            )
        case .nodes:
            NodeWorkspaceDetailView(
                model: model,
                onAddAccount: { nodeID in
                    addAccount(nodeID: nodeID)
                },
                onAddEndpoint: { nodeID in
                    addEndpoint(nodeID: nodeID)
                },
                onEditAccount: { accountID in
                    editAccount(accountID: accountID)
                },
                onConfigureAccess: { nodeID, profileID, endpointID in
                    configureAccess(
                        nodeID: nodeID,
                        profileID: profileID,
                        endpointID: endpointID
                    )
                }
            )
        case .activity:
            AuditOverviewView(model: model)
        case .servers:
            if let server = model.selectedServer {
                ServerDetailView(server: server, model: model)
            } else {
                ContentUnavailableView("未选择用户", systemImage: "person.crop.circle", description: Text("请在服务器下选择一个 SSH 用户。"))
            }
        case .keys:
            if let row = model.selectedKeyServerRow {
                KeyServerDetailView(row: row, model: model)
            } else if let connection = model.selectedDiscoveredSSHConnection {
                SSHConfigConnectionDetailView(connection: connection, model: model)
            } else if let key = model.selectedStandaloneKey {
                KeyDetailView(key: key, model: model)
            } else {
                ContentUnavailableView("未选择服务器密钥", systemImage: "key", description: Text("请选择服务器连接或本地身份密钥。"))
            }
        case .devices:
            DeviceOverviewView(
                model: model,
                onManageAccount: manageTailscaleAccount,
                onConfigureAccess: { profileID in
                    configureAccess(connectionProfileID: profileID)
                }
            )
        case .logs:
            AuditOverviewView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.destination == .graph || model.destination == .nodes {
            ToolbarItem {
                Button {
                    showsAddServer = true
                } label: {
                    Label("添加节点", systemImage: "plus")
                }
                .help("添加节点和首个 SSH 账户；V6 权威模式下不可用")
                .disabled(model.isMetadataReadOnly || model.isBusy)
            }
        }

        if model.destination == .servers {
            ToolbarItemGroup {
                Button {
                    showsAddServer = true
                } label: {
                    Label("添加节点", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    guard let profileID = model.selectedServerID else { return }
                    addAccount(forConnectionProfileID: profileID)
                } label: {
                    Label("添加 SSH 账户", systemImage: "person.badge.plus")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    guard let serverID = model.selectedServerID else { return }
                    Task { await model.performPasswordlessPrimaryAction(serverID: serverID) }
                } label: {
                    Label(selectedPasswordlessAction.title, systemImage: selectedPasswordlessAction.systemImage)
                }
                .help(selectedPasswordlessAction.help)
                .disabled(model.selectedServerID == nil || model.isBusy || selectedPasswordlessAction == .checking)

                Button {
                    Task { await model.synchronizeSSHAuthorizationSelected() }
                } label: {
                    Label("同步 SSH 授权", systemImage: "key.horizontal.fill")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    guard let profileID = model.selectedServerID else { return }
                    configureAccess(connectionProfileID: profileID)
                } label: {
                    Label("编辑连接配置", systemImage: "pencil")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

            }
        }

        if model.destination == .devices {
            ToolbarItem {
                Button {
                    Task { await model.refreshTailscale() }
                } label: {
                    Label("刷新 Tailscale", systemImage: "arrow.clockwise")
                }
                .help("刷新 Tailscale 设备状态")
                .disabled(model.tailscaleDiscoveryState == .refreshing)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.synchronizeCloud() }
                } label: {
                    Label("同步工作区", systemImage: "icloud.and.arrow.up")
                }
                .help("同步非敏感工作区元数据；不会同步服务器密码或私钥")
            }
        }
    }

    private func addAccount(nodeID: UUID) {
        guard !model.isBusy, !model.isMetadataReadOnly else { return }
        guard model.sshAccountDraft(forNodeID: nodeID) != nil else {
            model.errorMessage = "目标节点不存在或已被删除。"
            return
        }
        sshAccountEditorRequest = SSHAccountEditorRequest(nodeID: nodeID)
    }

    private func addAccount(forConnectionProfileID profileID: UUID) {
        guard let accountID = model.sshAccountID(forConnectionProfileID: profileID),
              let account = model.sshAccount(id: accountID) else {
            model.errorMessage = "无法确定这个连接配置所属的节点。"
            return
        }
        addAccount(nodeID: account.nodeID)
    }

    private func addEndpoint(nodeID: UUID) {
        guard !model.isBusy, !model.isMetadataReadOnly else { return }
        guard model.newEndpointDraft(forNodeID: nodeID) != nil else {
            model.errorMessage = "目标节点不存在或已被删除。"
            return
        }
        endpointNodeID = nodeID
    }

    private func editAccount(accountID: UUID) {
        guard !model.isBusy, !model.isMetadataReadOnly else { return }
        guard let account = model.sshAccount(id: accountID) else {
            model.errorMessage = "目标 SSH 账户不存在或已被删除。"
            return
        }
        sshAccountEditorRequest = SSHAccountEditorRequest(
            nodeID: account.nodeID,
            accountID: account.id
        )
    }

    private func configureAccess(connectionProfileID profileID: UUID) {
        guard let profile = model.topology.connectionProfile(id: profileID),
              let account = model.sshAccount(id: profile.accountID) else {
            model.errorMessage = "目标 SSH 连接配置不存在或已被删除。"
            return
        }
        configureAccess(
            nodeID: account.nodeID,
            profileID: profile.id,
            endpointID: profile.routePolicy.fixedEndpointID
        )
    }

    private func manageTailscaleAccount(_ request: TailscaleAccountEditorRequest) {
        if let accountID = request.accountID {
            editAccount(accountID: accountID)
            return
        }
        guard let nodeID = model.keyPortNodeID(for: request.suggestion) else {
            model.errorMessage = "尚未找到这个 Tailscale 设备对应的 KeyPort 节点，请先刷新 Tailscale。"
            return
        }
        addAccount(nodeID: nodeID)
    }

    private func configureAccess(nodeID: UUID, profileID: UUID?, endpointID: UUID?) {
        guard !model.isBusy, !model.isMetadataReadOnly else { return }
        guard model.sshAccessSetupDraft(
            forNodeID: nodeID,
            profileID: profileID,
            endpointID: endpointID
        ) != nil else {
            model.errorMessage = "请先为节点添加至少一个 SSH 账户和网络路径。"
            return
        }
        sshAccessSetupRequest = SSHAccessSetupRequest(
            nodeID: nodeID,
            profileID: profileID,
            endpointID: endpointID
        )
    }

    private var selectedPasswordlessAction: PasswordlessPrimaryAction {
        guard let server = model.selectedServer else { return .enable }
        return model.passwordlessPrimaryAction(for: server)
    }

    private func saveServer(
        _ submission: ServerEditorSubmission,
        existingServerID: UUID?,
        enablesPasswordless: Bool
    ) async throws {
        let serverID = try await model.saveServerEditor(submission, existingServerID: existingServerID)
        if enablesPasswordless {
            await model.authorizeCurrentDevice(serverID: serverID)
        }
    }
}

private struct SSHAccountEditorRequest: Identifiable {
    let nodeID: UUID
    let accountID: UUID?

    init(nodeID: UUID, accountID: UUID? = nil) {
        self.nodeID = nodeID
        self.accountID = accountID
    }

    var id: String {
        "\(nodeID.uuidString.lowercased()):\(accountID?.uuidString.lowercased() ?? "new")"
    }
}

private struct SSHAccessSetupRequest: Identifiable {
    let nodeID: UUID
    let profileID: UUID?
    let endpointID: UUID?

    var id: String {
        [
            nodeID.uuidString.lowercased(),
            profileID?.uuidString.lowercased() ?? "new",
            endpointID?.uuidString.lowercased() ?? "automatic",
        ].joined(separator: ":")
    }
}

struct KeyPortCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("服务器") {
            Button(passwordlessAction.title) {
                guard let serverID = model.selectedServerID else { return }
                Task { await model.performPasswordlessPrimaryAction(serverID: serverID) }
            }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil || passwordlessAction == .checking)
            Button("检查密码 SSH") { Task { await model.checkPasswordSelected() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil)
            Button("同步 SSH 授权") { Task { await model.synchronizeSSHAuthorizationSelected() } }
                .disabled(model.selectedServerID == nil || model.isBusy)
            Button("复制 SSH 别名") { model.copySelectedAlias() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selectedServerID == nil)
        }
    }

    private var passwordlessAction: PasswordlessPrimaryAction {
        guard let server = model.selectedServer else { return .enable }
        return model.passwordlessPrimaryAction(for: server)
    }
}
