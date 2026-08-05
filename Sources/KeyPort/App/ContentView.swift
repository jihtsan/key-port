import KeyPortCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var showsAddServer = false
    @State private var showsEditServer = false
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
                title: "添加服务器",
                canSynchronize: model.canSynchronizePasswords,
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
        .sheet(item: $tailscaleAccountEditorRequest) { request in
            let suggestion = request.suggestion
            let existingServer = request.serverID.flatMap { serverID in
                model.activeServers.first { $0.id == serverID }
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
                    title: "编辑服务器",
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
        .alert("KeyPort could not complete the action", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch model.destination {
        case .servers:
            ServerListView(model: model) { serverID in
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
                ContentUnavailableView("No Server Selected", systemImage: "server.rack", description: Text("Select or add a server connection."))
            }
        case .keys:
            if let row = model.selectedKeyServerRow {
                KeyServerDetailView(row: row, model: model)
            } else if let connection = model.selectedDiscoveredSSHConnection {
                SSHConfigConnectionDetailView(connection: connection, model: model)
            } else if let key = model.selectedStandaloneKey {
                KeyDetailView(key: key, model: model)
            } else {
                ContentUnavailableView("No Server Key Selected", systemImage: "key", description: Text("Select a server connection or local identity."))
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
                    Label("Add Server", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    Task { await model.checkPasswordSelected() }
                } label: {
                    Label("Check Password SSH", systemImage: "lock")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    Task { await model.checkKeySelected() }
                } label: {
                    Label("Check Key SSH", systemImage: "key.horizontal")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    showsEditServer = true
                } label: {
                    Label("Edit Server", systemImage: "pencil")
                }
                .disabled(model.selectedServerID == nil || model.isBusy)

                Button {
                    Task { await model.authorizeSelected() }
                } label: {
                    Label("Authorize This Mac", systemImage: "key.horizontal")
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
                    Label("Sync Metadata", systemImage: "icloud.and.arrow.up")
                }
                .help("Synchronize non-secret metadata with iCloud")
            }
        }
    }
}

struct KeyPortCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Server") {
            Button("Check Password SSH") { Task { await model.checkPasswordSelected() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil)
            Button("Check Key SSH") { Task { await model.checkKeySelected() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedServerID == nil)
            Button("Copy SSH Alias") { model.copySelectedAlias() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selectedServerID == nil)
            Divider()
            Button("Authorize This Mac") { Task { await model.authorizeSelected() } }
                .disabled(model.selectedServer?.status != .needsAuthorization)
        }
    }
}
