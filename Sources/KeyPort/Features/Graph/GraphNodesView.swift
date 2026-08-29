import KeyPortCore
import SwiftUI

struct GraphNodesView: View {
    let model: AppModel

    var body: some View {
        @Bindable var workspace = model.graphWorkspace
        let items = NodeWorkspacePresentation.items(model: model, workspace: workspace)

        VStack(spacing: 0) {
            GraphFilterBar(workspace: workspace)
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
                NodeListSummary(items: items)
                Divider()
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
        .searchable(
            text: $workspace.searchText,
            placement: .toolbar,
            prompt: "搜索节点、地址、账户或服务"
        )
    }
}

private struct NodeListSummary: View {
    let items: [NodeWorkspaceItem]

    var body: some View {
        HStack(spacing: 8) {
            Label("节点", systemImage: "server.rack")
                .font(.callout.weight(.medium))
            Text("\(items.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if issueCount > 0 {
                Label("\(issueCount) 个需处理", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else {
                Label("状态正常", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var issueCount: Int {
        items.filter { $0.node.status.level != .healthy && $0.node.status.level != .unknown }.count
    }
}

private struct GraphNodeRow: View {
    let item: NodeWorkspaceItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.node.kind.systemImage)
                .foregroundStyle(item.node.status.level.tint)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.node.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.node.kind.displayTitle)
                    if item.isHostNode {
                        Text("·")
                        Text(item.accountCount == 1 ? "1 个 SSH 用户" : "\(item.accountCount) 个 SSH 用户")
                    }
                    if let subtitle = item.node.subtitle {
                        Text("·")
                        Text(subtitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(item.node.status.level.tint)
                .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.node.title)，\(item.node.kind.displayTitle)，\(item.accountCount) 个 SSH 用户，\(item.node.status.level.displayTitle)")
    }
}
