import KeyPortCore
import SwiftUI

struct GraphNodesView: View {
    let model: AppModel
    let onAddNode: () -> Void

    var body: some View {
        @Bindable var workspace = model.graphWorkspace
        let items = NodeWorkspacePresentation.items(model: model, workspace: workspace)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索节点", text: $workspace.searchText)
                    .textFieldStyle(.plain)
                if !workspace.searchText.isEmpty {
                    Button {
                        workspace.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
                Button(action: onAddNode) {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .help("添加节点")
                .disabled(model.isMetadataReadOnly || model.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if !workspace.isAvailable {
                ContentUnavailableView(
                    "节点列表还没有数据",
                    systemImage: "circle.grid.3x3",
                    description: Text(workspace.unavailableMessage)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    workspace.searchText.isEmpty ? "暂无节点" : "没有匹配的节点",
                    systemImage: workspace.searchText.isEmpty ? "server.rack" : "magnifyingglass",
                    description: Text(
                        workspace.searchText.isEmpty
                            ? "添加一个节点后，它的端点和 SSH 用户会集中显示在这里。"
                            : "调整搜索或筛选条件后重试。"
                    )
                )
            } else {
                List(selection: $workspace.selectedNodeID) {
                    ForEach(items) { item in
                        GraphNodeRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("节点")
        .navigationSplitViewColumnWidth(min: 310, ideal: 340, max: 390)
        .onAppear {
            if workspace.viewMode != .allDevices {
                workspace.viewMode = .allDevices
            }
            selectPreferredNodeIfNeeded(workspace: workspace)
        }
        .onChange(of: workspace.isAvailable) { _, isAvailable in
            guard isAvailable else { return }
            selectPreferredNodeIfNeeded(workspace: workspace)
        }
        .task(id: model.isLoaded) {
            guard model.isLoaded else { return }
            selectPreferredNodeIfNeeded(workspace: workspace)
        }
    }

    private func selectPreferredNodeIfNeeded(workspace: GraphWorkspaceModel) {
        let items = NodeWorkspacePresentation.items(model: model, workspace: workspace)
        if let selectedNodeID = workspace.selectedNodeID,
           let selected = items.first(where: { $0.id == selectedNodeID }),
           selected.isHostNode,
           selected.accountCount > 0 {
            return
        }
        workspace.selectedNodeID = items.first(where: { $0.isHostNode && $0.accountCount > 0 })?.id
            ?? items.first(where: \.isHostNode)?.id
            ?? items.first?.id
    }
}

private struct GraphNodeRow: View {
    let item: NodeWorkspaceItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.node.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.node.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(item.routeSummary) · \(item.accountCount) 个账户")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(item.node.status.level.tint)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.node.title)，\(item.endpointCount) 条路径，\(item.accountCount) 个 SSH 账户，\(item.node.status.level.displayTitle)"
        )
    }
}

private extension NodeWorkspaceItem {
    var routeSummary: String {
        guard let endpoint = endpoints
            .filter({ !$0.isDeleted && $0.protocol == .ssh })
            .sorted(by: { $0.priority == $1.priority
                ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                : $0.priority < $1.priority
            })
            .first
        else {
            return endpointCount == 0 ? "暂无网络路径" : "\(endpointCount) 条网络路径"
        }

        switch endpoint.networkScope {
        case .lan: return "局域网"
        case .publicNetwork: return "公网"
        case .tailnet: return "Tailscale"
        case .vpn: return "VPN"
        case .unknown: return endpoint.label
        }
    }
}
