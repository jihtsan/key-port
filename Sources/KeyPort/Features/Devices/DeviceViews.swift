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
    let onAddServer: (TailscaleSSHServerSuggestion) -> Void

    var body: some View {
        if let item = model.selectedDeviceItem {
            DeviceDetailView(item: item, model: model, onAddServer: onAddServer)
        } else {
            ContentUnavailableView("未选择设备", systemImage: "laptopcomputer", description: Text("请选择一台设备。"))
        }
    }
}

private struct DeviceDetailView: View {
    let item: DevicePresence
    let model: AppModel
    let onAddServer: (TailscaleSSHServerSuggestion) -> Void

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

    private func tailscaleSSHManagement(
        node: TailscaleNode,
        suggestion: TailscaleSSHServerSuggestion
    ) -> some View {
        GroupBox("SSH 管理") {
            VStack(alignment: .leading, spacing: 10) {
                if let server = model.managedServer(for: suggestion) {
                    Label("已作为 \(server.username) 加入服务器", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Button {
                            model.showServer(server.id)
                        } label: {
                            Label("查看服务器", systemImage: "arrow.right.circle")
                        }
                        Button {
                            onAddServer(suggestion)
                        } label: {
                            Label("添加其他用户", systemImage: "person.badge.plus")
                        }
                        .disabled(!node.isOnline || model.isBusy)
                    }
                } else {
                    Button {
                        onAddServer(suggestion)
                    } label: {
                        Label("添加并授权", systemImage: "key.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!node.isOnline || model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
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
