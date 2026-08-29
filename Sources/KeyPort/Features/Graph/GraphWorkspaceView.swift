import KeyPortCore
import SwiftUI

struct GraphWorkspaceView: View {
    let model: AppModel

    var body: some View {
        @Bindable var workspace = model.graphWorkspace

        VStack(spacing: 0) {
            GraphFilterBar(workspace: workspace)
            Divider()
            GraphAuthorityBanner(workspace: workspace)

            if !workspace.isAvailable {
                GraphUnavailableView(message: workspace.unavailableMessage)
            } else if workspace.snapshot.nodes.isEmpty {
                ContentUnavailableView(
                    "没有匹配的节点",
                    systemImage: "magnifyingglass",
                    description: Text("调整搜索或筛选条件后重试。")
                )
            } else {
                GraphCanvasView(
                    snapshot: workspace.snapshot,
                    selection: $workspace.selectedNodeID
                )
            }
        }
        .navigationTitle("Graph")
        .searchable(
            text: $workspace.searchText,
            placement: .toolbar,
            prompt: "搜索节点、地址、账户或服务"
        )
    }
}

private struct GraphUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Graph 还没有数据", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(message)
        } actions: {
            Text("Graph 读取统一拓扑快照；SSH 管理继续通过兼容适配器工作。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
