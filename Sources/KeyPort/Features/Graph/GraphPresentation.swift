import KeyPortCore
import SwiftUI

extension TopologyGraphNodeKind {
    var displayTitle: String {
        switch self {
        case .node: "节点"
        case .device: "KeyPort 设备"
        case .host: "主机"
        case .sshAccount: "SSH 账户"
        case .service: "服务"
        case .actualNode: "实际节点"
        }
    }

    var systemImage: String {
        switch self {
        case .node: "server.rack"
        case .device: "laptopcomputer"
        case .host: "server.rack"
        case .sshAccount: "person.crop.circle"
        case .service: "shippingbox"
        case .actualNode: "point.3.connected.trianglepath.dotted"
        }
    }
}

extension TopologyGraphStatusLevel {
    var displayTitle: String {
        switch self {
        case .healthy: "可用"
        case .pending: "待处理"
        case .unavailable: "暂不可用"
        case .blocked: "已阻断"
        case .unknown: "未知"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .pending: .orange
        case .unavailable: .yellow
        case .blocked: .red
        case .unknown: .secondary
        }
    }
}

extension TopologyGraphReachability {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .reachable: "可达"
        case .unreachable: "不可达"
        }
    }
}

extension TopologyGraphHostTrust {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .trusted: "已信任"
        case .pending: "待确认"
        case .mismatch: "不匹配"
        }
    }
}

extension TopologyGraphRouteStatus {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .available: "可用"
        case .unavailable: "不可用"
        case .conflict: "冲突"
        }
    }
}

extension TopologyGraphLocalKeyStatus {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .available: "本机可用"
        case .agentOnly: "仅 Agent"
        case .missing: "缺少本机密钥"
        case .revoked: "已撤销"
        }
    }
}

extension TopologyGraphRemoteAuthorization {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .authorized: "远端已授权"
        case .revoked: "远端已撤销"
        case .detached: "已脱离"
        }
    }
}

extension TopologyGraphVerificationStatus {
    var displayTitle: String {
        switch self {
        case .unknown: "未检查"
        case .succeeded: "复验成功"
        case .failed: "复验失败"
        case .checking: "检查中"
        }
    }
}

extension TopologyGraphSyncStatus {
    var displayTitle: String {
        switch self {
        case .clean: "V6 权威"
        case .conflict: "同步冲突"
        case .canary: "Canary 只读"
        case .readOnly: "只读"
        case .compatibilityRollback: "兼容回滚"
        }
    }
}

extension TopologyGraphQuery.ViewMode {
    var displayTitle: String {
        switch self {
        case .currentDevice: "当前设备"
        case .allDevices: "全部设备"
        case .services: "服务"
        }
    }
}

extension HostV6.AuthorityMode {
    var displayTitle: String {
        switch self {
        case .legacyAuthoritative: "兼容写入"
        case .v6Canary: "V6 Canary 只读"
        case .v6Authoritative: "V6 权威"
        case .compatibilityRollback: "兼容回滚"
        }
    }
}

struct GraphStatusBadge: View {
    let status: TopologyGraphStatus

    var body: some View {
        Label(status.level.displayTitle, systemImage: status.level == .healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(status.level.tint)
    }
}

struct GraphFilterBar: View {
    @Bindable var workspace: GraphWorkspaceModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("视图", selection: $workspace.viewMode) {
                ForEach(TopologyGraphQuery.ViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 270)

            Toggle("仅异常", isOn: $workspace.onlyIssues)
            Toggle("关系细节", isOn: $workspace.includesSupportingNodes)
            Toggle("实际节点", isOn: $workspace.includesActualNodes)
                .disabled(!workspace.includesSupportingNodes)
            Toggle("服务", isOn: $workspace.showsServices)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct GraphAuthorityBanner: View {
    let workspace: GraphWorkspaceModel

    var body: some View {
        if workspace.isAvailable {
            HStack(spacing: 8) {
                if workspace.usesUnifiedTopology {
                    Image(systemName: "checkmark.shield")
                    Text("Graph · 统一拓扑")
                } else {
                    let mode = workspace.authorityMode
                    Image(systemName: mode == .v6Authoritative ? "checkmark.shield" : "lock.shield")
                    Text("Graph · \(mode?.displayTitle ?? "V6 Shadow 只读")")
                }
                Spacer()
                Text("图仅展示已记录事实；拖动节点不会产生授权")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(workspace.usesUnifiedTopology || workspace.authorityMode == .v6Authoritative ? .green : .orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.thinMaterial)
        }
    }
}
