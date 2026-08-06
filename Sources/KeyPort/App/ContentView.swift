import KeyPortCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var showsAddServer = false
    @State private var showsEditServer = false
    @State private var accountSourceServerID: UUID?
    @State private var tailscaleAccountEditorRequest: TailscaleAccountEditorRequest?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $model.destination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .listStyle(.sidebar)
            .navigationTitle("KeyPort")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 390, max: 520)
        } detail: {
            detailColumn
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showsAddServer) {
            ServerEditorView(
                title: "添加服务器和用户",
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
                onSave: { submission in
                    _ = try await model.saveServerEditor(submission, existingServerID: nil)
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { accountSourceServerID != nil },
            set: { if !$0 { accountSourceServerID = nil } }
        )) {
            if let sourceServerID = accountSourceServerID,
               let sourceServer = model.snapshot.servers.first(where: { $0.id == sourceServerID && !$0.isDeleted }),
               let draft = model.newAccountDraft(for: sourceServerID) {
                ServerEditorView(
                    title: "为 \(sourceServer.name) 添加用户",
                    initialDraft: draft,
                    initialHostKeys: sourceServer.confirmedHostKeys,
                    hasStoredPassword: false,
                    canSynchronize: model.canSynchronizePasswords,
                    primaryActionTitle: "保存用户",
                    showsNotes: false,
                    locksServerFields: true,
                    onCheck: { draft, password, hostKeys in
                        await model.validateServerEditor(
                            draft: draft,
                            password: password,
                            existingServerID: nil,
                            trustedHostKeys: hostKeys
                        )
                    },
                    onSave: { submission in
                        _ = try await model.saveServerEditor(submission, existingServerID: nil)
                    }
                )
            }
        }
        .sheet(item: $tailscaleAccountEditorRequest) { request in
            let suggestion = request.suggestion
            let existingServer = request.serverID.flatMap { serverID in
                model.snapshot.servers.first { $0.id == serverID && !$0.isDeleted }
            }
            ServerEditorView(
                title: request.authorizesAfterSave
                    ? "授权本机账户"
                    : (existingServer == nil ? "添加 SSH 账户" : "编辑 SSH 账户"),
                existingServerID: existingServer?.id,
                initialDraft: model.tailscaleServerDraft(
                    for: suggestion,
                    existingServer: existingServer
                ),
                initialHostKeys: existingServer?.confirmedHostKeys ?? [],
                hasStoredPassword: existingServer.map { model.hasStoredPassword(serverID: $0.id) } ?? false,
                canSynchronize: model.canSynchronizePasswords,
                primaryActionTitle: request.authorizesAfterSave ? "保存并授权本机" : "保存账户",
                showsNotes: false,
                onCheck: { draft, password, hostKeys in
                    let existingServerID = request.serverID
                        ?? model.existingTailscaleServerID(for: suggestion, draft: draft)
                    return await model.validateServerEditor(
                        draft: draft,
                        password: password,
                        existingServerID: existingServerID,
                        trustedHostKeys: hostKeys
                    )
                },
                onSave: { submission in
                    let existingServerID = request.serverID
                        ?? model.existingTailscaleServerID(for: suggestion, draft: submission.draft)
                    if request.authorizesAfterSave {
                        _ = try await model.saveAndAuthorizeTailscaleServer(
                            submission,
                            suggestion: suggestion,
                            existingServerID: existingServerID
                        )
                    } else {
                        _ = try await model.saveServerEditor(submission, existingServerID: existingServerID)
                    }
                }
            )
        }
        .sheet(isPresented: $showsEditServer) {
            if let server = model.selectedServer {
                ServerEditorView(
                    title: "编辑服务器和用户",
                    existingServerID: server.id,
                    initialDraft: ServerDraft(server: server),
                    initialHostKeys: server.confirmedHostKeys,
                    hasStoredPassword: model.hasStoredPassword(serverID: server.id),
                    canSynchronize: model.canSynchronizePasswords,
                    onCheck: { draft, password, hostKeys in
                        await model.validateServerEditor(
                            draft: draft,
                            password: password,
                            existingServerID: server.id,
                            trustedHostKeys: hostKeys
                        )
                    },
                    onSave: { submission in
                        _ = try await model.saveServerEditor(submission, existingServerID: server.id)
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
                    onTest: { password in
                        await model.testPromptedPassword(password)
                    },
                    onSave: { password, synchronizable, authorizeAfterSave, validatedCheck in
                        Task {
                            await model.savePromptedPassword(
                                password,
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
        case .servers:
            ServerListView(model: model) { serverID in
                model.selectedServerID = serverID
                accountSourceServerID = serverID
            } onEdit: { serverID in
                model.selectedServerID = serverID
                showsEditServer = true
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
            DeviceOverviewView(model: model) { request in
                tailscaleAccountEditorRequest = request
            }
        case .logs:
            AuditOverviewView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.destination == .servers {
            ToolbarItemGroup {
                Button {
                    showsAddServer = true
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    accountSourceServerID = model.selectedServerID
                } label: {
                    Label("添加用户", systemImage: "person.badge.plus")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    Task { await model.checkPasswordSelected() }
                } label: {
                    Label("检查密码 SSH", systemImage: "lock")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    Task { await model.checkKeySelected() }
                } label: {
                    Label("检查密钥 SSH", systemImage: "key.horizontal")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    showsEditServer = true
                } label: {
                    Label("编辑用户", systemImage: "pencil")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    Task { await model.authorizeSelected() }
                } label: {
                    Label("授权此 Mac", systemImage: "key.horizontal")
                }
                .disabled(model.selectedServer?.status != .needsAuthorization || model.isBusy)
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
                    Label("同步元数据", systemImage: "icloud.and.arrow.up")
                }
                .help("通过 iCloud 同步非敏感元数据")
            }
        }
    }
}

struct KeyPortCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("服务器") {
            Button("检查密码 SSH") { Task { await model.checkPasswordSelected() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil)
            Button("检查密钥 SSH") { Task { await model.checkKeySelected() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil)
            Button("复制 SSH 别名") { model.copySelectedAlias() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selectedServerID == nil)
            Divider()
            Button("授权此 Mac") { Task { await model.authorizeSelected() } }
                .disabled(model.selectedServer?.status != .needsAuthorization)
        }
    }
}
