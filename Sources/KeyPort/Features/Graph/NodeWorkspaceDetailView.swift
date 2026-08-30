import KeyPortCore
import SwiftUI

struct NodeWorkspaceDetailView: View {
    let model: AppModel
    let onAddAccount: (UUID, UUID?) -> Void
    let onAddEndpoint: (UUID) -> Void
    let onEditAccount: (UUID) -> Void
    let onConfigureAccess: (UUID, UUID?, UUID?) -> Void

    @State private var selectedEndpointID: UUID?
    @State private var showsAccountInspector = true
    @State private var pendingDeletion: ServerConnection?

    var body: some View {
        let item = NodeWorkspacePresentation.item(
            for: model.graphWorkspace.selectedNodeID,
            model: model,
            workspace: model.graphWorkspace
        )

        Group {
            if !model.graphWorkspace.isAvailable {
                ContentUnavailableView(
                    "节点工作区还没有数据",
                    systemImage: "server.rack",
                    description: Text(model.graphWorkspace.unavailableMessage)
                )
            } else if let item {
                NodeWorkspaceContentView(
                    item: item,
                    tags: tags(for: item),
                    accountRows: accountRows(for: item),
                    selectedAccountID: model.selectedServerID,
                    selectedEndpointID: selectedEndpointID,
                    isBusy: model.isBusy,
                    isReadOnly: model.isMetadataReadOnly,
                    onSelectAccount: selectAccount,
                    onSelectEndpoint: { selectedEndpointID = $0 },
                    onTestConnection: { testConnection(in: item) },
                    onOpenTerminal: { openTerminal(in: item) },
                    onConfigureAccess: { configureAccess(in: item) },
                    onAddAccount: {
                        guard let nodeID = item.node.id.topologyUUID else { return }
                        onAddAccount(nodeID, selectedEndpoint(in: item)?.id)
                    },
                    onAddEndpoint: {
                        guard let nodeID = item.node.id.topologyUUID else { return }
                        onAddEndpoint(nodeID)
                    },
                    onEditAccount: onEditAccount,
                    onCopyCommand: { account in
                        model.copySSHCommand(
                            serverID: account.id,
                            endpoint: selectedEndpoint(in: item)
                        )
                    }
                )
                .onAppear { synchronizeSelection(for: item) }
                .onChange(of: item.id) { _, _ in
                    synchronizeSelection(for: item, resetsRoute: true)
                }
                .onChange(of: model.selectedServerID) { _, _ in
                    synchronizeSelection(for: item)
                }
            } else {
                ContentUnavailableView(
                    "未选择节点",
                    systemImage: "cursorarrow.click",
                    description: Text("从左侧列表选择一个节点。")
                )
            }
        }
        .navigationTitle(item?.node.title ?? "节点")
        .inspector(isPresented: $showsAccountInspector) {
            NodeAccountInspectorView(
                account: item.flatMap(selectedAccount(in:)),
                endpoint: item.flatMap(selectedEndpoint(in:)),
                isDefaultAccount: item.flatMap { selectedItem in
                    guard let account = selectedAccount(in: selectedItem) else { return nil }
                    return selectedItem.accounts.first?.id == account.id
                } ?? false,
                hasStoredPassword: item
                    .flatMap(selectedAccount(in:))
                    .map { model.hasStoredPassword(serverID: $0.id) } ?? false,
                isBusy: model.isBusy,
                isReadOnly: model.isMetadataReadOnly,
                onTestConnection: {
                    guard let item else { return }
                    testConnection(in: item)
                },
                onOpenTerminal: {
                    guard let item else { return }
                    openTerminal(in: item)
                },
                onCopyCommand: {
                    guard let item, let account = selectedAccount(in: item) else { return }
                    model.copySSHCommand(
                        serverID: account.id,
                        endpoint: selectedEndpoint(in: item)
                    )
                },
                onEdit: { account in onEditAccount(account.id) },
                onDelete: { account in pendingDeletion = account }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 340)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showsAccountInspector.toggle()
                } label: {
                    Label(
                        showsAccountInspector ? "隐藏连接配置检查器" : "显示连接配置检查器",
                        systemImage: "sidebar.right"
                    )
                }
                .help(showsAccountInspector ? "隐藏连接配置检查器" : "显示连接配置检查器")
            }
        }
        .confirmationDialog(
            "要删除这个 SSH 连接配置吗？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("删除连接配置", role: .destructive) {
                guard let account = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await model.deleteServer(account.id) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("这个别名和网络路径会从 KeyPort 及生成的 SSH 配置中移除；共享的 SSH 账户与其他连接配置不会受影响。")
        }
    }

    private func accountRows(for item: NodeWorkspaceItem) -> [NodeWorkspaceAccountDisplay] {
        item.accounts.map { account in
            NodeWorkspaceAccountDisplay(
                account: account,
                authenticationTitle: model.hasStoredPassword(serverID: account.id)
                    ? "SSH 密钥 · 已存密码"
                    : "SSH 密钥"
            )
        }
    }

    private func tags(for item: NodeWorkspaceItem) -> [String] {
        var values: [String] = []
        if let nodeID = item.node.id.topologyUUID,
           let group = model.topology.nodes.first(where: { $0.id == nodeID })?.group,
           !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(group)
        }
        values.append(contentsOf: item.accounts.map(\.group).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        if item.node.isWorkspaceDevice {
            values.append(item.id == model.graphWorkspace.sourceSnapshot.primaryNodeID ? "当前设备" : "工作区设备")
        }
        return values.reduce(into: []) { result, value in
            guard !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
            result.append(value)
        }
        .prefix(3)
        .map { $0 }
    }

    private func selectAccount(_ accountID: UUID) {
        model.selectedServerID = accountID
    }

    private func selectedAccount(in item: NodeWorkspaceItem) -> ServerConnection? {
        if let selectedServerID = model.selectedServerID,
           let account = item.accounts.first(where: { $0.id == selectedServerID }) {
            return account
        }
        return item.accounts.first
    }

    private func selectedEndpoint(in item: NodeWorkspaceItem) -> Endpoint? {
        let routes = sshEndpoints(in: item)
        if let selectedEndpointID,
           let endpoint = routes.first(where: { $0.id == selectedEndpointID }) {
            return endpoint
        }
        return defaultEndpoint(in: item)
    }

    private func synchronizeSelection(for item: NodeWorkspaceItem, resetsRoute: Bool = false) {
        let account = selectedAccount(in: item)
        if model.selectedServerID != account?.id {
            model.selectedServerID = account?.id
        }

        let routes = sshEndpoints(in: item)
        if resetsRoute || !routes.contains(where: { $0.id == selectedEndpointID }) {
            selectedEndpointID = defaultEndpoint(in: item)?.id
        }
    }

    private func defaultEndpoint(in item: NodeWorkspaceItem) -> Endpoint? {
        let routes = sshEndpoints(in: item)
        if let account = selectedAccount(in: item),
           let exact = routes.first(where: {
               $0.address.caseInsensitiveCompare(account.host) == .orderedSame
                   && Int($0.port) == account.port
           }) {
            return exact
        }
        return routes.first
    }

    private func sshEndpoints(in item: NodeWorkspaceItem) -> [Endpoint] {
        item.endpoints
            .filter { !$0.isDeleted && $0.protocol == .ssh }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }

    private func testConnection(in item: NodeWorkspaceItem) {
        guard let account = selectedAccount(in: item) else { return }
        Task {
            await model.checkKey(
                serverID: account.id,
                endpoint: selectedEndpoint(in: item)
            )
        }
    }

    private func openTerminal(in item: NodeWorkspaceItem) {
        guard let account = selectedAccount(in: item) else { return }
        model.openTerminal(
            serverID: account.id,
            endpoint: selectedEndpoint(in: item)
        )
    }

    private func configureAccess(in item: NodeWorkspaceItem) {
        guard let nodeID = item.node.id.topologyUUID else { return }
        onConfigureAccess(
            nodeID,
            selectedAccount(in: item)?.id,
            selectedEndpoint(in: item)?.id
        )
    }
}

private struct NodeWorkspaceContentView: View {
    let item: NodeWorkspaceItem
    let tags: [String]
    let accountRows: [NodeWorkspaceAccountDisplay]
    let selectedAccountID: UUID?
    let selectedEndpointID: UUID?
    let isBusy: Bool
    let isReadOnly: Bool
    let onSelectAccount: (UUID) -> Void
    let onSelectEndpoint: (UUID) -> Void
    let onTestConnection: () -> Void
    let onOpenTerminal: () -> Void
    let onConfigureAccess: () -> Void
    let onAddAccount: () -> Void
    let onAddEndpoint: () -> Void
    let onEditAccount: (UUID) -> Void
    let onCopyCommand: (ServerConnection) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NodeWorkspaceHeader(
                    item: item,
                    tags: tags,
                    accounts: accountRows.map(\.account),
                    endpoints: endpoints,
                    selectedAccountID: selectedAccountID,
                    selectedEndpointID: selectedEndpointID,
                    isBusy: isBusy,
                    isReadOnly: isReadOnly,
                    onSelectAccount: onSelectAccount,
                    onSelectEndpoint: onSelectEndpoint,
                    onTestConnection: onTestConnection,
                    onOpenTerminal: onOpenTerminal,
                    onConfigureAccess: onConfigureAccess,
                    onAddAccount: onAddAccount,
                    onAddEndpoint: onAddEndpoint
                )

                Divider()

                VStack(alignment: .leading, spacing: 32) {
                    NodeWorkspaceAccountsSection(
                        rows: accountRows,
                        selectedAccountID: selectedAccountID,
                        isBusy: isBusy,
                        isReadOnly: isReadOnly,
                        onSelect: onSelectAccount,
                        onAdd: onAddAccount,
                        onEdit: onEditAccount,
                        onTest: { account in
                            onSelectAccount(account.id)
                            onTestConnection()
                        },
                        onCopyCommand: onCopyCommand
                    )

                    NodeWorkspaceRoutesSection(
                        endpoints: endpoints,
                        selectedEndpointID: selectedEndpointID,
                        nodeStatus: item.node.status,
                        tailscaleIdentities: item.node.tailscaleIdentities,
                        isReadOnly: isReadOnly,
                        onSelect: onSelectEndpoint,
                        onAdd: onAddEndpoint
                    )
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var endpoints: [Endpoint] {
        item.endpoints
            .filter { !$0.isDeleted && $0.protocol == .ssh }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }
}

private extension TopologyGraphNodeID {
    var topologyUUID: UUID? {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(rawValue[rawValue.index(after: separator)...]))
    }
}
