import KeyPortCore
import SwiftUI

struct GraphNodesView: View {
    let model: AppModel

    var body: some View {
        @Bindable var workspace = model.graphWorkspace

        VStack(spacing: 0) {
            GraphFilterBar(workspace: workspace)
            Divider()
            if !workspace.isAvailable {
                ContentUnavailableView(
                    "节点列表还没有数据",
                    systemImage: "circle.grid.3x3",
                    description: Text(workspace.unavailableMessage)
                )
            } else {
                List(selection: $workspace.selectedNodeID) {
                    ForEach(workspace.snapshot.nodes) { node in
                        GraphNodeRow(node: node)
                            .tag(node.id)
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
    let node: TopologyGraphNode

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(node.status.level.tint)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(node.kind.displayTitle)
                    if let subtitle = node.subtitle {
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
                .fill(node.status.level.tint)
                .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title)，\(node.kind.displayTitle)，\(node.status.level.displayTitle)")
    }
}
