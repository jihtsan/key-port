import KeyPortCore
import SwiftUI

struct GraphWorkspaceView: View {
    let model: AppModel

    var body: some View {
        @Bindable var workspace = model.graphWorkspace
        let nodeItems = NodeWorkspacePresentation.items(model: model, workspace: workspace)

        VStack(spacing: 0) {
            GraphFilterBar(workspace: workspace)
            Divider()
            GraphAuthorityBanner(workspace: workspace)

            if !workspace.isAvailable {
                GraphUnavailableView(message: workspace.unavailableMessage)
            } else {
                let visibleSnapshot = NodeWorkspacePresentation.snapshot(model: model, workspace: workspace)
                if visibleSnapshot.nodes.isEmpty {
                    ContentUnavailableView(
                        "没有匹配的服务器",
                        systemImage: "magnifyingglass",
                        description: Text("调整搜索或筛选条件后重试。")
                    )
                } else {
                    GraphCanvasView(
                        snapshot: visibleSnapshot,
                        nodeItems: nodeItems,
                        selection: $workspace.selectedNodeID
                    )
                }
            }
        }
        .navigationTitle("服务器")
        .searchable(
            text: $workspace.searchText,
            placement: .toolbar,
            prompt: "搜索服务器、地址、账户或服务"
        )
    }
}

private struct GraphUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("服务器图谱还没有数据", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(message)
        } actions: {
            Text("图谱读取统一拓扑快照；账户、路径和授权请在服务器详情中管理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
