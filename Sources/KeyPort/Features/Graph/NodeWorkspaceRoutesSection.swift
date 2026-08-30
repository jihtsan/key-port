import KeyPortCore
import SwiftUI

struct NodeWorkspaceRoutesSection: View {
    let endpoints: [Endpoint]
    let selectedEndpointID: UUID?
    let nodeStatus: TopologyGraphStatus
    let tailscaleIdentities: [TopologyGraphTailscaleIdentity]
    let isReadOnly: Bool
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("网络路径")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onAdd) {
                    Label("添加网络路径", systemImage: "plus")
                }
                .disabled(isReadOnly)
            }

            if endpoints.isEmpty {
                ContentUnavailableView(
                    "还没有网络路径",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("添加局域网、Tailscale、VPN 或公网 SSH 地址。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ViewThatFits(in: .horizontal) {
                    fullTable
                        .frame(minWidth: 520)
                    compactTable
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }
        }
    }

    private var fullTable: some View {
        VStack(spacing: 0) {
            NodeRouteTableHeader()
            Divider()
            ForEach(endpoints.indices, id: \.self) { index in
                if index > endpoints.startIndex { Divider() }
                let endpoint = endpoints[index]
                NodeRouteTableRow(
                    endpoint: endpoint,
                    status: status(for: endpoint),
                    isSelected: endpoint.id == selectedEndpointID,
                    onSelect: { onSelect(endpoint.id) }
                )
            }
        }
    }

    private var compactTable: some View {
        VStack(spacing: 0) {
            ForEach(endpoints.indices, id: \.self) { index in
                if index > endpoints.startIndex { Divider() }
                let endpoint = endpoints[index]
                NodeCompactRouteRow(
                    endpoint: endpoint,
                    status: status(for: endpoint),
                    isSelected: endpoint.id == selectedEndpointID,
                    onSelect: { onSelect(endpoint.id) }
                )
            }
        }
    }

    private func status(for endpoint: Endpoint) -> NodeRouteDisplayStatus {
        if endpoint.networkScope == .tailnet {
            if tailscaleIdentities.contains(where: { $0.observationState == .online }) {
                return .available
            }
            if tailscaleIdentities.contains(where: { $0.observationState == .offline }) {
                return .unavailable
            }
            return .requires("需要 Tailscale")
        }
        if nodeStatus.route == .conflict { return .conflict }
        if nodeStatus.reachability == .unreachable { return .unavailable }
        if nodeStatus.route == .available || nodeStatus.reachability == .reachable {
            return .available
        }
        switch endpoint.networkScope {
        case .lan: return .requires("需要同一局域网")
        case .vpn: return .requires("需要 VPN")
        case .publicNetwork: return .unknown
        case .unknown: return .unknown
        case .tailnet: return .requires("需要 Tailscale")
        }
    }
}

private struct NodeRouteTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("类型").frame(maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: 118, alignment: .leading)
            Text("来源").frame(width: 92, alignment: .leading)
            Text("优先级").frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct NodeRouteTableRow: View {
    let endpoint: Endpoint
    let status: NodeRouteDisplayStatus
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: endpoint.networkScope.systemImage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(endpoint.networkScope.displayTitle)
                            .font(.callout.weight(.medium))
                        Text(endpoint.displayAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Label(status.title, systemImage: status.systemImage)
                    .font(.caption)
                    .foregroundStyle(status.tint)
                    .frame(width: 118, alignment: .leading)
                    .lineLimit(1)

                Text(endpoint.source.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                    .lineLimit(1)

                Text(String(endpoint.priority))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(isSelected ? Color.primary.opacity(0.025) : Color.clear)
    }
}

private struct NodeCompactRouteRow: View {
    let endpoint: Endpoint
    let status: NodeRouteDisplayStatus
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                Image(systemName: endpoint.networkScope.systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(endpoint.networkScope.displayTitle)
                        .font(.callout.weight(.medium))
                    Text("\(endpoint.displayAddress) · \(endpoint.source.displayTitle)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Label(status.title, systemImage: status.systemImage)
                    .font(.caption)
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(isSelected ? Color.primary.opacity(0.025) : Color.clear)
    }
}

private enum NodeRouteDisplayStatus {
    case available
    case unavailable
    case conflict
    case requires(String)
    case unknown

    var title: String {
        switch self {
        case .available: "可用"
        case .unavailable: "当前不可用"
        case .conflict: "路径冲突"
        case .requires(let title): title
        case .unknown: "未检测"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "circle.fill"
        case .unavailable, .conflict: "circle.fill"
        case .requires: "circle.fill"
        case .unknown: "circle"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .unavailable, .conflict: .red
        case .requires: .orange
        case .unknown: .secondary
        }
    }
}
