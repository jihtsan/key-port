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
                Text("\(item.endpointCount) 条路径 · \(item.accountCount) 个 SSH 账户")
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
