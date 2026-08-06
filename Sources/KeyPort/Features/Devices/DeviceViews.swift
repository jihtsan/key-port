import KeyPortCore
import SwiftUI

struct DeviceListView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDeviceItemID) {
            ForEach(model.deviceListItems) { item in
                DeviceListRow(item: item)
                    .tag(item.id)
            }

            switch model.tailscaleDiscoveryState {
            case .idle, .available:
                EmptyView()
            case .refreshing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在刷新 Tailscale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let message):
                Label(message, systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("设备")
        .task { await model.refreshTailscale() }
    }
}

private struct DeviceListRow: View {
    let item: DevicePresence

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isCurrent ? "laptopcomputer.and.arrow.down" : "desktopcomputer")
                .foregroundStyle(item.isRevoked ? .red : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    if item.isCurrent { LocalDeviceTag() }
                }
                HStack(spacing: 6) {
                    if let node = item.tailscaleNode {
                        Circle()
                            .fill(node.isOnline ? Color.green : Color.secondary.opacity(0.55))
                            .frame(width: 6, height: 6)
                        let source = item.registeredDevice == nil ? "Tailscale 节点" : "Tailscale"
                        Text("\(source) · \(node.isOnline ? "在线" : "离线")")
                    } else if let device = item.registeredDevice {
                        Text(device.id)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LocalDeviceTag: View {
    var body: some View {
        Text("本机")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
    }
}

struct DeviceOverviewView: View {
    let model: AppModel
    let onManageAccount: (TailscaleAccountEditorRequest) -> Void

    var body: some View {
        if let item = model.selectedDeviceItem {
            DeviceDetailView(item: item, model: model, onManageAccount: onManageAccount)
        } else {
            ContentUnavailableView("未选择设备", systemImage: "laptopcomputer", description: Text("请选择一台设备。"))
        }
    }
}

private struct DeviceDetailView: View {
    let item: DevicePresence
    let model: AppModel
    let onManageAccount: (TailscaleAccountEditorRequest) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.title2).fontWeight(.semibold)
                    if item.isCurrent { LocalDeviceTag() }
                }

                if let device = item.registeredDevice {
                    GroupBox("KeyPort") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("设备 ID", value: device.id)
                            LabeledContent("登记时间", value: device.registeredAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("最近活跃", value: device.lastActiveAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("授权状态", value: device.isRevoked ? "已撤销" : "有效")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }

                if let node = item.tailscaleNode {
                    GroupBox("Tailscale") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("状态") {
                                Label(node.isOnline ? "在线" : "离线", systemImage: node.isOnline ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(node.isOnline ? .green : .secondary)
                            }
                            if let tailnetName = model.tailscaleStatus?.tailnetName {
                                LabeledContent("Tailnet", value: tailnetName)
                            }
                            if let dnsName = node.dnsName {
                                LabeledContent("MagicDNS", value: dnsName)
                            }
                            if !node.addresses.isEmpty {
                                LabeledContent("Tailscale IP") {
                                    Text(node.addresses.joined(separator: "\n"))
                                        .monospaced()
                                        .textSelection(.enabled)
                                }
                            }
                            if let operatingSystem = node.operatingSystem {
                                LabeledContent("系统", value: operatingSystem)
                            }
                            if let relay = node.relay {
                                LabeledContent("DERP", value: relay.uppercased())
                            }
                            if !node.isOnline, let lastSeen = node.lastSeen {
                                LabeledContent("最近在线", value: lastSeen.formatted(date: .abbreviated, time: .shortened))
                            }
                            if node.isExitNode || node.isExitNodeOption {
                                LabeledContent("出口节点", value: node.isExitNode ? "正在使用" : "可用")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                } else if item.isCurrent {
                    tailscaleUnavailableContent
                }

                if let node = item.tailscaleNode,
                   let suggestion = TailscaleSSHServerSuggestion(node: node) {
                    tailscaleSSHManagement(node: node, suggestion: suggestion)
                }

                if item.registeredDevice != nil {
                    deviceKeyAccess
                }

                if item.isCurrent {
                    GroupBox("设备授权") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("本地密钥", value: String(model.currentDeviceKeys.count))
                            LabeledContent(
                                "等待授权的服务器",
                                value: String(model.activeServers.filter { $0.status == .needsAuthorization || $0.status == .syncPending }.count)
                            )
                            Button("授权待处理服务器") { Task { await model.authorizePendingServers() } }
                                .disabled(model.isBusy || model.activeServers.isEmpty)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var deviceKeyAccess: some View {
        let keys = model.keys(for: item)
        let authorizedServers = model.authorizedServers(for: item)
        return GroupBox("密钥与访问") {
            VStack(alignment: .leading, spacing: 10) {
                if keys.isEmpty {
                    Label("这台设备还没有同步的 SSH 密钥", systemImage: "key.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                        if index > 0 { Divider() }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.keyDisplayName(key)).fontWeight(.medium)
                                Text("已授权到 \(model.authorizedServers(for: key).count) 个 SSH 账户")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.showKey(key.id)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("查看密钥")
                        }
                    }
                }

                if !authorizedServers.isEmpty {
                    Divider()
                    Text("可访问的 SSH 账户")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(authorizedServers) { server in
                        HStack {
                            Label(server.username, systemImage: "person.crop.circle")
                            Text(server.name)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.showServer(server.id)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("在服务器中查看")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func tailscaleSSHManagement(
        node: TailscaleNode,
        suggestion: TailscaleSSHServerSuggestion
    ) -> some View {
        let servers = model.managedServers(for: suggestion)
        let unmanagedConnections = model.unmanagedSSHConnections(for: item)
        return GroupBox("SSH 管理") {
            VStack(alignment: .leading, spacing: 10) {
                if servers.isEmpty && unmanagedConnections.isEmpty {
                    Label("尚未添加 SSH 账户", systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider() }
                        tailscaleAccountRow(server, node: node, suggestion: suggestion)
                    }
                    ForEach(Array(unmanagedConnections.enumerated()), id: \.element.alias) { index, connection in
                        if !servers.isEmpty || index > 0 { Divider() }
                        discoveredAccountRow(connection)
                    }
                }

                Divider()
                Button {
                    onManageAccount(TailscaleAccountEditorRequest(suggestion: suggestion))
                } label: {
                    Label("添加 SSH 账户", systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!node.isOnline || model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func discoveredAccountRow(_ connection: DiscoveredSSHConnection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(connection.username, systemImage: "person.crop.circle")
                    .fontWeight(.medium)
                Spacer()
                Label("SSH Config", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(connection.alias) · \(connection.host):\(connection.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Button {
                Task { await model.addDiscoveredConnectionToServers(connection) }
            } label: {
                Label("添加到服务器", systemImage: "plus.circle")
            }
            .disabled(model.isBusy)
        }
    }

    private func tailscaleAccountRow(
        _ server: ServerConnection,
        node: TailscaleNode,
        suggestion: TailscaleSSHServerSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(server.username, systemImage: "person.crop.circle")
                    .fontWeight(.medium)
                Spacer()
                Label(
                    server.status == .authorized ? "本机已授权" : "本机未授权",
                    systemImage: server.status == .authorized ? "checkmark.circle.fill" : "key.slash"
                )
                .font(.caption)
                .foregroundStyle(server.status == .authorized ? .green : .secondary)
            }

            HStack(spacing: 14) {
                Text(server.alias)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label(
                    model.hasStoredPassword(serverID: server.id) ? "本机密码可用" : "本机需要密码",
                    systemImage: model.hasStoredPassword(serverID: server.id) ? "key.fill" : "key.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    model.showServer(server.id)
                } label: {
                    Label("查看", systemImage: "arrow.right.circle")
                }
                Button {
                    onManageAccount(TailscaleAccountEditorRequest(suggestion: suggestion, serverID: server.id))
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .disabled(!node.isOnline || model.isBusy)

                if server.status != .authorized {
                    if model.hasStoredPassword(serverID: server.id) {
                        Button {
                            Task { await model.authorizeCurrentDevice(serverID: server.id) }
                        } label: {
                            Label("授权本机", systemImage: "key.horizontal")
                        }
                        .disabled(!node.isOnline || model.isBusy)
                    } else {
                        Button {
                            onManageAccount(
                                TailscaleAccountEditorRequest(
                                    suggestion: suggestion,
                                    serverID: server.id,
                                    authorizesAfterSave: true
                                )
                            )
                        } label: {
                            Label("输入密码并授权", systemImage: "key.viewfinder")
                        }
                        .disabled(!node.isOnline || model.isBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tailscaleUnavailableContent: some View {
        switch model.tailscaleDiscoveryState {
        case .refreshing:
            GroupBox("Tailscale") {
                ProgressView("正在读取设备状态")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            }
        case .unavailable(let message):
            GroupBox("Tailscale") {
                Label(message, systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            }
        case .available:
            GroupBox("Tailscale") {
                Label("未发现本机 Tailscale 节点（\(model.tailscaleStatus?.backendState ?? "未知状态")）", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            }
        case .idle:
            EmptyView()
        }
    }
}

struct TailscaleAccountEditorRequest: Identifiable {
    let suggestion: TailscaleSSHServerSuggestion
    let serverID: UUID?
    let authorizesAfterSave: Bool

    init(
        suggestion: TailscaleSSHServerSuggestion,
        serverID: UUID? = nil,
        authorizesAfterSave: Bool = false
    ) {
        self.suggestion = suggestion
        self.serverID = serverID
        self.authorizesAfterSave = authorizesAfterSave
    }

    var id: String {
        "\(suggestion.nodeID):\(serverID?.uuidString ?? "new"):\(authorizesAfterSave)"
    }
}
