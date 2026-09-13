import KeyPortCore
import SwiftUI

struct NodeWorkspaceDetailView: View {
    let model: AppModel
    let onAddAccount: (UUID) -> Void
    let onAddEndpoint: (UUID) -> Void
    let onEditEndpoint: (UUID, UUID) -> Void
    let onDeleteEndpoint: (UUID, UUID) -> Void
    let onEditAccount: (UUID) -> Void
    let onConfigureAccess: (UUID, UUID?, UUID?) -> Void

    @State private var selectedEndpointID: UUID?
    @State private var pendingDeletion: ServerConnection?
    @State private var pendingEndpointDeletion: Endpoint?

    var body: some View {
        let item = NodeWorkspacePresentation.item(
            for: model.graphWorkspace.selectedNodeID,
            model: model,
            workspace: model.graphWorkspace
        )

        Group {
            if !model.graphWorkspace.isAvailable {
                ContentUnavailableView(
                    "服务器工作区还没有数据",
                    systemImage: "server.rack",
                    description: Text(model.graphWorkspace.unavailableMessage)
                )
            } else if let item {
                let selectedAccount = selectedAccount(in: item)
                NodeWorkspaceContentView(
                    model: model,
                    item: item,
                    tags: tags(for: item),
                    sshAccounts: item.node.id.topologyUUID.map {
                        model.sshAccounts(forNodeID: $0)
                    } ?? [],
                    connectionProfiles: item.node.id.topologyUUID.map {
                        model.topology.connectionProfiles(forNodeID: $0)
                    } ?? [],
                    accountRows: accountRows(for: item),
                    selectedAccount: selectedAccount,
                    deviceAuthorizationSummaries: selectedAccount.map {
                        model.deviceAuthorizationSummaries(for: $0)
                    } ?? [],
                    deviceNames: Dictionary(
                        uniqueKeysWithValues: model.snapshot.devices.map { ($0.id, $0.name) }
                    ),
                    hostKeyTrusts: hostKeyTrusts(for: item),
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
                        onAddAccount(nodeID)
                    },
                    onAddEndpoint: {
                        guard let nodeID = item.node.id.topologyUUID else { return }
                        onAddEndpoint(nodeID)
                    },
                    onEditEndpoint: { endpoint in
                        onEditEndpoint(endpoint.nodeID, endpoint.id)
                    },
                    onDeleteEndpoint: { endpoint in
                        pendingEndpointDeletion = endpoint
                    },
                    onVerifyEndpoint: { endpoint in
                        verifyEndpoint(endpoint, in: item)
                    },
                    hasStoredPasswordForAccount: { accountID in
                        model.hasStoredPassword(accountID: accountID)
                    },
                    connectionProfileCount: { accountID in
                        model.topology.connectionProfiles(for: accountID).count
                    },
                    onEditSSHAccount: onEditAccount,
                    onEditConnectionProfile: { profileID in
                        configureAccess(profileID: profileID, in: item)
                    },
                    onDeleteConnectionProfile: { account in
                        pendingDeletion = account
                    },
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
                    "未选择服务器",
                    systemImage: "cursorarrow.click",
                    description: Text("从左侧列表选择一个服务器。")
                )
            }
        }
        .navigationTitle(item?.node.title ?? "服务器")
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
        .confirmationDialog(
            "要删除这个网络路径吗？",
            isPresented: Binding(
                get: { pendingEndpointDeletion != nil },
                set: { if !$0 { pendingEndpointDeletion = nil } }
            )
        ) {
            Button("删除网络路径", role: .destructive) {
                guard let endpoint = pendingEndpointDeletion else { return }
                pendingEndpointDeletion = nil
                Task {
                    do {
                        try await model.deleteNodeEndpoint(endpoint.id, forNodeID: endpoint.nodeID)
                    } catch {
                        model.errorMessage = UserFacingText.localizedError(error)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingEndpointDeletion = nil }
        } message: {
            Text("删除只会移除这条地址及其本机检测证据，不会撤销 SSH 账户上的远端设备授权；仍被连接配置使用的地址需先调整路径。")
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

    private func configureAccess(profileID: UUID, in item: NodeWorkspaceItem) {
        guard let nodeID = item.node.id.topologyUUID else { return }
        let endpointID = model.topology.connectionProfile(id: profileID)?
            .routePolicy.fixedEndpointID
        onConfigureAccess(nodeID, profileID, endpointID)
    }

    private func hostKeyTrusts(for item: NodeWorkspaceItem) -> [SSHHostKeyTrust] {
        guard let nodeID = item.topologyNodeID else { return [] }
        let endpointIDs = Set(item.endpoints.filter { $0.nodeID == nodeID }.map(\.id))
        return model.topology.hostKeyTrusts.filter { endpointIDs.contains($0.endpointID) }
    }

    private func verifyEndpoint(_ endpoint: Endpoint, in item: NodeWorkspaceItem) {
        guard let account = selectedAccount(in: item) else {
            model.errorMessage = "请先添加 SSH 连接配置，再核验主机身份。"
            return
        }
        Task {
            await model.checkKey(serverID: account.id, endpoint: endpoint)
        }
    }
}

private struct NodeWorkspaceContentView: View {
    let model: AppModel
    let item: NodeWorkspaceItem
    let tags: [String]
    let sshAccounts: [SSHAccount]
    let connectionProfiles: [SSHConnectionProfile]
    let accountRows: [NodeWorkspaceAccountDisplay]
    let selectedAccount: ServerConnection?
    let deviceAuthorizationSummaries: [SSHDeviceAuthorizationSummary]
    let deviceNames: [String: String]
    let hostKeyTrusts: [SSHHostKeyTrust]
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
    let onEditEndpoint: (Endpoint) -> Void
    let onDeleteEndpoint: (Endpoint) -> Void
    let onVerifyEndpoint: (Endpoint) -> Void
    let hasStoredPasswordForAccount: (UUID) -> Bool
    let connectionProfileCount: (UUID) -> Int
    let onEditSSHAccount: (UUID) -> Void
    let onEditConnectionProfile: (UUID) -> Void
    let onDeleteConnectionProfile: (ServerConnection) -> Void
    let onCopyCommand: (ServerConnection) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NodeWorkspaceHeader(
                    item: item,
                    tags: tags,
                    accounts: accountRows.map(\.account),
                    connectionProfiles: connectionProfiles,
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
                    if let selectedAccount {
                        SSHFirstAccessProgressView(
                            state: model.firstAccessState(for: selectedAccount),
                            onPrimaryAction: {
                                Task {
                                    await model.performPasswordlessPrimaryAction(serverID: selectedAccount.id)
                                }
                            }
                        )
                    }

                    NodeWorkspaceSSHAccountsSection(
                        accounts: sshAccounts,
                        isBusy: isBusy,
                        isReadOnly: isReadOnly,
                        hasStoredPassword: hasStoredPasswordForAccount,
                        connectionProfileCount: connectionProfileCount,
                        onAdd: onAddAccount,
                        onEdit: onEditSSHAccount
                    )

                    NodeWorkspaceAccountsSection(
                        rows: accountRows,
                        selectedAccountID: selectedAccountID,
                        isBusy: isBusy,
                        isReadOnly: isReadOnly,
                        onSelect: onSelectAccount,
                        onAdd: onConfigureAccess,
                        onEdit: onEditConnectionProfile,
                        onTest: { account in
                            onSelectAccount(account.id)
                            onTestConnection()
                        },
                        onCopyCommand: onCopyCommand,
                        onDelete: onDeleteConnectionProfile
                    )

                    if let selectedAccount {
                        NodeWorkspaceAuthorizationSection(
                            model: model,
                            account: selectedAccount,
                            summaries: deviceAuthorizationSummaries,
                            deviceNames: deviceNames,
                            isBusy: isBusy
                        )
                    }

                    NodeWorkspaceRoutesSection(
                        endpoints: endpoints,
                        selectedEndpointID: selectedEndpointID,
                        nodeStatus: item.node.status,
                        tailscaleIdentities: item.node.tailscaleIdentities,
                        hostKeyTrusts: hostKeyTrusts,
                        isReadOnly: isReadOnly,
                        canVerify: selectedAccount != nil,
                        onSelect: onSelectEndpoint,
                        onAdd: onAddEndpoint,
                        onVerify: onVerifyEndpoint,
                        onEdit: onEditEndpoint,
                        onDelete: onDeleteEndpoint
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

struct NodeWorkspaceAuthorizationSection: View {
    let model: AppModel
    let account: ServerConnection
    let summaries: [SSHDeviceAuthorizationSummary]
    let deviceNames: [String: String]
    let isBusy: Bool

    @State private var detailsExpanded = false
    @State private var pendingRevocationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设备授权")
                        .font(.title3.weight(.semibold))
                    Text("授权属于 SSH 账户；删除连接配置或网络路径不会撤销远端公钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(detailsExpanded ? "收起详情" : "查看与撤销") {
                    detailsExpanded.toggle()
                }
                .disabled(isBusy)
            }

            if summaries.isEmpty {
                Label("尚未读取到其他设备的授权状态。", systemImage: "laptopcomputer.and.arrow.down")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 { Divider().padding(.leading, 34) }
                        HStack(spacing: 10) {
                            Image(systemName: summary.status.systemImage)
                                .foregroundStyle(color(for: summary.status))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deviceTitle(for: summary))
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if let verifiedAt = summary.lastVerifiedAt {
                                    Text("最近验证：\(verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(summary.status.title)
                                .font(.caption)
                                .foregroundStyle(color(for: summary.status))
                        }
                        .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 11)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if detailsExpanded {
                authorizationDetails
            }
        }
        .confirmationDialog(
            "要从服务器撤销此设备密钥吗？",
            isPresented: Binding(
                get: { pendingRevocationID != nil },
                set: { if !$0 { pendingRevocationID = nil } }
            )
        ) {
            Button("撤销授权", role: .destructive) {
                guard let id = pendingRevocationID else { return }
                pendingRevocationID = nil
                Task { await model.revokeAuthorization(id) }
            }
            Button("取消", role: .cancel) { pendingRevocationID = nil }
        } message: {
            Text("KeyPort 只会移除公钥指纹完全匹配的记录，其他未知密钥将保留。")
        }
    }

    private var authorizationDetails: some View {
        GroupBox("账户级远端授权") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("这些公钥属于当前 SSH 账户，而不是某一条网络路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await model.refreshRemoteAuthorizations(serverID: account.id) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                }

                if authorizations.isEmpty {
                    Label("当前没有可撤销的 KeyPort 设备授权。", systemImage: "key.slash")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(authorizations.enumerated()), id: \.element.id) { index, authorization in
                            if index > 0 { Divider() }
                            authorizationRow(authorization)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authorizations: [Authorization] {
        model.snapshot.authorizations
            .filter { $0.serverID == account.id && !$0.isDeleted }
            .sorted {
                if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
                return $0.fingerprint < $1.fingerprint
            }
    }

    private func authorizationRow(_ authorization: Authorization) -> some View {
        let key = model.key(for: authorization)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: authorization.status == .authorized ? "checkmark.shield.fill" : "questionmark.shield")
                .foregroundStyle(authorization.status == .authorized ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(authorizationDeviceTitle(for: key))
                    .font(.callout.weight(.medium))
                if let key {
                    Text(model.keyDisplayName(key))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(authorization.fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(authorization.status.title)
                    .font(.caption)
                    .foregroundStyle(authorization.status == .authorized ? .green : .orange)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                pendingRevocationID = authorization.id
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("撤销与此公钥指纹完全匹配的授权")
            .disabled(isBusy || authorization.status != .authorized)
        }
        .padding(.vertical, 8)
    }

    private func deviceTitle(for summary: SSHDeviceAuthorizationSummary) -> String {
        deviceNames[summary.deviceID].flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? summary.deviceID
    }

    private func authorizationDeviceTitle(for key: SSHKeyRecord?) -> String {
        guard let deviceID = key?.deviceID else { return "未知设备" }
        return deviceNames[deviceID].flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? deviceID
    }

    private func color(for status: SSHDeviceAuthorizationStatus) -> Color {
        switch status {
        case .authorized, .remotelyAuthorized: .green
        case .checking: .blue
        case .needsAuthorization, .missingLocalKey, .remoteUnknown, .staleVerification: .orange
        case .deviceRevoked, .failed: .red
        }
    }
}

private extension TopologyGraphNodeID {
    var topologyUUID: UUID? {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(rawValue[rawValue.index(after: separator)...]))
    }
}
