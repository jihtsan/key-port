import KeyPortCore
import SwiftUI

struct ServerListView: View {
    let model: AppModel
    let onAddAccount: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onAddAccountForNode: (UUID) -> Void

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedServerID) {
            ForEach(managedServerItems) { item in
                if item.accounts.count == 1, let account = item.accounts.first {
                    ServerWorkspaceAccountRow(
                        account: account,
                        item: item,
                        showsServerSummary: true,
                        onEdit: onEdit,
                        onAddAccount: { addAccountForNode(item) },
                        onCopyAlias: { model.copyAlias(serverID: $0) },
                        onDelete: { serverID in Task { await model.deleteServer(serverID) } }
                    )
                    .tag(account.id)
                } else if !item.accounts.isEmpty {
                    Section {
                        ForEach(item.accounts) { account in
                            ServerWorkspaceAccountRow(
                                account: account,
                                item: item,
                                showsServerSummary: false,
                                onEdit: onEdit,
                                onAddAccount: { addAccountForNode(item) },
                                onCopyAlias: { model.copyAlias(serverID: $0) },
                                onDelete: { serverID in Task { await model.deleteServer(serverID) } }
                            )
                            .tag(account.id)
                        }
                    } header: {
                        ServerWorkspaceGroupHeader(
                            item: item,
                            onSelect: { model.selectedServerID = item.accounts.first?.id },
                            onEdit: onEdit,
                            onAddAccount: { addAccountForNode(item) }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "名称、地址、用户、分组")
        .navigationTitle("服务器")
        .overlay {
            if managedServerItems.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("暂无托管服务器", systemImage: "server.rack", description: Text("请添加服务器和首个 SSH 用户，或打开发现与导入。"))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
    }

    private var managedServerItems: [NodeWorkspaceItem] {
        NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        ).filter { !$0.accounts.isEmpty }
    }

    private func addAccountForNode(_ item: NodeWorkspaceItem) {
        guard let nodeID = item.topologyNodeID else { return }
        onAddAccountForNode(nodeID)
    }

}

struct ServerDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let onAddDiscoveredServer: (TailscaleSSHServerSuggestion) -> Void
    let onAddDiscoveredConnection: (DiscoveredSSHConnection) -> Void

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if !discoveredServers.isEmpty {
                    Section("Tailscale 服务器") {
                        ForEach(discoveredServers) { suggestion in
                            TailscaleDiscoveryRow(
                                suggestion: suggestion,
                                managedServers: model.managedServers(for: suggestion),
                                onShowServer: { serverID in
                                    model.showServer(serverID)
                                    dismiss()
                                },
                                onAddAccount: { serverID in
                                    model.showServer(serverID)
                                    dismiss()
                                },
                                onAddServer: { suggestion in
                                    onAddDiscoveredServer(suggestion)
                                    dismiss()
                                }
                            )
                        }
                    }
                }

                if !discoveredConnections.isEmpty {
                    Section("本机 SSH 配置") {
                        ForEach(discoveredConnections) { connection in
                            DiscoveredSSHConfigRow(
                                connection: connection,
                                managedServer: model.server(matching: connection),
                                onShowServer: { serverID in
                                    model.showServer(serverID)
                                    dismiss()
                                },
                                onAdd: { connection in
                                    onAddDiscoveredConnection(connection)
                                    dismiss()
                                }
                            )
                        }
                    }
                }
            }
            .overlay {
                if discoveredServers.isEmpty && discoveredConnections.isEmpty {
                    ContentUnavailableView(
                        "没有新的发现结果",
                        systemImage: "magnifyingglass",
                        description: Text("可刷新 Tailscale 或重新读取本机 SSH 配置。")
                    )
                }
            }
            .searchable(text: $searchText, prompt: "名称、地址、用户、别名")
            .navigationTitle("发现与导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await model.refreshTailscale()
                            try? await model.refreshKeys(recordAudit: false)
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 480)
    }

    private var discoveredServers: [TailscaleSSHServerSuggestion] {
        (model.tailscaleStatus?.nodes ?? [])
            .compactMap(TailscaleSSHServerSuggestion.init(node:))
            .filter { suggestion in
                matchesSearch([
                    suggestion.name,
                    suggestion.host,
                    suggestion.nodeID,
                    suggestion.group,
                    suggestion.alias
                ])
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var discoveredConnections: [DiscoveredSSHConnection] {
        model.discoveredSSHConnections
            .filter { connection in
                matchesSearch([
                    connection.alias,
                    connection.host,
                    connection.username,
                    String(connection.port),
                    connection.proxyJump ?? "",
                    connection.hostKeyAlias ?? ""
                ])
            }
            .sorted {
                $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
            }
    }

    private func matchesSearch(_ values: [String]) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return true }
        return values.contains { $0.localizedLowercase.contains(needle) }
    }
}

private struct TailscaleDiscoveryRow: View {
    let suggestion: TailscaleSSHServerSuggestion
    let managedServers: [ServerConnection]
    let onShowServer: (UUID) -> Void
    let onAddAccount: (UUID) -> Void
    let onAddServer: (TailscaleSSHServerSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(verbatim: "\(suggestion.host):\(suggestion.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if managedServers.isEmpty {
                    Label("未添加", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("已添加", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            HStack {
                if let server = managedServers.first {
                    Button {
                        onShowServer(server.id)
                    } label: {
                        Label("查看服务器", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        onAddAccount(server.id)
                    } label: {
                        Label("添加账户", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        onAddServer(suggestion)
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct DiscoveredSSHConfigRow: View {
    let connection: DiscoveredSSHConnection
    let managedServer: ServerConnection?
    let onShowServer: (UUID) -> Void
    let onAdd: (DiscoveredSSHConnection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.alias)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(verbatim: "\(connection.username)@\(connection.host):\(connection.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label(
                    managedServer == nil ? "未添加" : "已添加",
                    systemImage: managedServer == nil ? "plus.circle" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(managedServer == nil ? Color.secondary : Color.green)
            }

            HStack {
                if let managedServer {
                    Button {
                        onShowServer(managedServer.id)
                    } label: {
                        Label("查看服务器", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        onAdd(connection)
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct ServerWorkspaceGroupHeader: View {
    let item: NodeWorkspaceItem
    let onSelect: () -> Void
    let onEdit: (UUID) -> Void
    let onAddAccount: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.node.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(item.endpointSummary)
                                .monospaced()
                            Text("\(item.connectionProfileCount) 个连接配置")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let capacity = item.machineConfiguration?.capacitySummary {
                        Text(capacity)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GraphStatusBadge(status: item.node.status)
                }
            }
            .buttonStyle(.plain)
            .disabled(item.accounts.isEmpty)
            .help("选择此服务器")
            .contextMenu {
                if let account = item.accounts.first {
                    Button {
                        onEdit(account.id)
                    } label: {
                        Label("编辑连接配置", systemImage: "pencil")
                    }
                }
            }
            if let account = item.accounts.first {
                Button {
                    onEdit(account.id)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑连接配置")
            }
            Button(action: onAddAccount) {
                Image(systemName: "person.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("为此服务器添加 SSH 用户")
        }
        .textCase(nil)
        .padding(.top, 4)
    }
}

private struct ServerWorkspaceAccountRow: View {
    let account: ServerConnection
    let item: NodeWorkspaceItem
    let showsServerSummary: Bool
    let onEdit: (UUID) -> Void
    let onAddAccount: () -> Void
    let onCopyAlias: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: showsServerSummary ? "server.rack" : "person.crop.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if showsServerSummary {
                    Text(item.node.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(account.host):\(account.port) · \(account.username) · \(account.alias)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(account.username)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(account.alias)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if showsServerSummary,
               let capacity = item.machineConfiguration?.capacitySummary {
                Text(capacity)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StatusLabel(status: account.status)
        }
        .padding(.vertical, showsServerSummary ? 5 : 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit(account.id)
            } label: {
                Label("编辑连接配置", systemImage: "pencil")
            }
            Button(action: onAddAccount) {
                Label("添加用户", systemImage: "person.badge.plus")
            }
            Button {
                onCopyAlias(account.id)
            } label: {
                Label("复制 SSH 别名", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete(account.id)
            } label: {
                Label("删除连接配置", systemImage: "trash")
            }
        }
    }
}

private extension NodeWorkspaceItem {
    var endpointSummary: String {
        let sshEndpoints = endpoints.filter { !$0.isDeleted && $0.protocol == .ssh }
        if sshEndpoints.count == 1, let endpoint = sshEndpoints.first {
            return endpoint.displayAddress
        }
        if sshEndpoints.isEmpty {
            return endpointCount == 0 ? "暂无网络路径" : "\(endpointCount) 条网络路径"
        }
        return "\(sshEndpoints.count) 条 SSH 路径"
    }

}

struct AuthenticationCheckLabel: View {
    let check: AuthenticationCheck?

    var body: some View {
        if let check {
            Label(check.state.title, systemImage: check.state.systemImage)
                .foregroundStyle(check.state.color)
                .lineLimit(1)
        } else {
            Label("未检查", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct StatusLabel: View {
    let status: AuthorizationStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .foregroundStyle(status.color)
            .lineLimit(1)
    }
}

private extension AuthorizationStatus {
    var systemImage: String {
        switch self {
        case .authorized: "checkmark.circle.fill"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .syncing: "arrow.triangle.2.circlepath"
        case .hostKeyMismatch, .authorizationConflict, .authorizationWrittenAwaitingVerification: "exclamationmark.shield.fill"
        case .hostKeyPending: "questionmark.diamond.fill"
        case .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: "xmark.circle.fill"
        case .missingLocalKey: "key.slash"
        case .syncPending: "arrow.triangle.2.circlepath"
        case .needsAuthorization: "key.horizontal"
        }
    }

    var color: Color {
        switch self {
        case .authorized: .green
        case .checking, .syncing, .syncPending: .blue
        case .hostKeyPending, .needsAuthorization, .missingLocalKey: .orange
        case .hostKeyMismatch, .authorizationConflict, .authorizationWrittenAwaitingVerification, .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: .red
        }
    }
}

private extension AuthenticationCheckState {
    var systemImage: String {
        switch self {
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking: .blue
        case .succeeded: .green
        case .failed: .red
        case .blocked: .orange
        }
    }
}
