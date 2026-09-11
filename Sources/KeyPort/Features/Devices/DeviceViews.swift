import KeyPortCore
import SwiftUI

struct DeviceListView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDeviceItemID) {
            Section("我的设备") {
                if model.registeredDeviceListItems.isEmpty {
                    Label("尚未登记其他 KeyPort 设备", systemImage: "laptopcomputer.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.registeredDeviceListItems) { item in
                        DeviceListRow(item: item)
                            .tag(item.id)
                    }
                }
            }

            Section("服务器发现") {
                switch model.tailscaleDiscoveryState {
                case .idle, .available:
                    Label("Tailscale 发现的服务器在服务器工作区中管理。", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        }
        .listStyle(.sidebar)
        .navigationTitle("我的设备")
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
    let onStartBatch: ([UUID]) -> Void
    let onShowBatch: () -> Void

    var body: some View {
        if model.selectedKeyID != nil, let key = model.selectedStandaloneKey {
            KeyDetailView(key: key, model: model)
        } else if let item = model.selectedDeviceItem {
            DeviceDetailView(
                item: item,
                model: model,
                onStartBatch: onStartBatch,
                onShowBatch: onShowBatch
            )
        } else {
            ContentUnavailableView("未选择设备", systemImage: "laptopcomputer", description: Text("请选择一台设备。"))
        }
    }
}

private struct DeviceDetailView: View {
    let item: DevicePresence
    let model: AppModel
    let onStartBatch: ([UUID]) -> Void
    let onShowBatch: () -> Void
    @State private var showsAuthorizationTargetSelection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.title2).fontWeight(.semibold)
                    if item.isCurrent { LocalDeviceTag() }
                }

                if let device = item.registeredDevice {
                    GroupBox("工作区设备") {
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
                    GroupBox("发现信息 · Tailscale") {
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

                if item.registeredDevice != nil {
                    deviceKeyAccess
                }

                if item.isCurrent {
                    GroupBox("本机授权") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("本地密钥", value: String(model.currentDeviceKeys.count))
                            LabeledContent(
                                "待启用免密的服务器",
                                value: String(pendingPasswordlessServerCount)
                            )
                            Button("选择服务器并启用免密") {
                                showsAuthorizationTargetSelection = true
                            }
                                .disabled(model.isBusy || pendingPasswordlessServerCount == 0)
                            if model.authorizationBatchPlan != nil {
                                Button("查看批量授权结果") {
                                    onShowBatch()
                                }
                                .disabled(model.isBusy && model.authorizationBatchPlan?.phase != .authorizing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .sheet(isPresented: $showsAuthorizationTargetSelection) {
            SSHAuthorizationTargetSelectionView(model: model, onStart: onStartBatch)
        }
    }

    private var deviceKeyAccess: some View {
        let keys = model.keys(for: item)
        let authorizedServers = model.authorizedServers(for: item)
        return GroupBox("密钥与访问") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.isCurrent ? "本机身份密钥" : "设备身份密钥")
                        .fontWeight(.medium)
                    Spacer()
                    if item.isCurrent {
                        Menu {
                            Button("生成 Ed25519 密钥") {
                                Task { await model.generateKey() }
                            }
                            Button("导入本机密钥") {
                                Task { await model.importKey() }
                            }
                            Button("扫描密钥") {
                                Task { try? await model.refreshKeys() }
                            }
                        } label: {
                            Label("管理密钥", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

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

    private var pendingPasswordlessServerCount: Int {
        model.pendingAuthorizationServers.count
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
