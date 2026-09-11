import KeyPortCore
import SwiftUI

enum ServerWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "列表"
        case .graph: "图谱"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct ServerWorkspaceView: View {
    let model: AppModel
    let onAddServer: () -> Void
    let onAddDiscoveredServer: (TailscaleSSHServerSuggestion) -> Void
    let onAddDiscoveredConnection: (DiscoveredSSHConnection) -> Void
    let onAddAccount: (UUID) -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("服务器", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Picker("显示", selection: $model.serverWorkspaceMode) {
                    ForEach(ServerWorkspaceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Button(action: onAddServer) {
                    Label("添加服务器", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(model.isMetadataReadOnly || model.isBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch model.serverWorkspaceMode {
                case .list:
                    ServerListView(
                        model: model,
                        onAddAccount: onAddAccount,
                        onEdit: onEdit,
                        onAddDiscoveredServer: onAddDiscoveredServer,
                        onAddDiscoveredConnection: onAddDiscoveredConnection
                    )
                case .graph:
                    GraphWorkspaceView(model: model)
                }
            }
        }
        .navigationTitle("服务器")
        .onAppear { synchronizeWorkspace() }
        .task { await model.refreshTailscale() }
        .onChange(of: model.serverWorkspaceMode) { _, mode in
            if mode == .graph {
                model.graphWorkspace.viewMode = .allDevices
                model.graphWorkspace.searchText = model.searchText
                synchronizeGraphSelection()
            } else {
                model.searchText = model.graphWorkspace.searchText
                synchronizeServerSelection()
            }
        }
        .onChange(of: model.selectedServerID) { _, _ in
            guard model.serverWorkspaceMode == .graph else { return }
            synchronizeGraphSelection()
        }
        .onChange(of: model.graphWorkspace.selectedNodeID) { _, _ in
            guard model.serverWorkspaceMode == .graph else { return }
            synchronizeServerSelection()
        }
        .onChange(of: model.searchText) { _, value in
            guard model.serverWorkspaceMode == .list,
                  model.graphWorkspace.searchText != value else { return }
            model.graphWorkspace.searchText = value
        }
        .onChange(of: model.graphWorkspace.searchText) { _, value in
            guard model.serverWorkspaceMode == .graph,
                  model.searchText != value else { return }
            model.searchText = value
        }
    }

    private func synchronizeWorkspace() {
        if model.serverWorkspaceMode == .graph {
            model.graphWorkspace.viewMode = .allDevices
            model.graphWorkspace.searchText = model.searchText
            synchronizeGraphSelection()
        } else {
            synchronizeServerSelection()
        }
    }

    private func synchronizeGraphSelection() {
        guard let selectedServerID = model.selectedServerID else { return }
        let items = NodeWorkspacePresentation.items(
            model: model,
            workspace: model.graphWorkspace
        )
        if let item = items.first(where: { item in
            item.accounts.contains { $0.id == selectedServerID }
        }) {
            if model.graphWorkspace.selectedNodeID != item.id {
                model.graphWorkspace.selectedNodeID = item.id
            }
            return
        }

        guard let profile = model.topology.connectionProfile(id: selectedServerID),
              let account = model.topology.activeAccounts.first(where: { $0.id == profile.accountID }) else {
            return
        }
        let nodeID = TopologyGraphNodeID.node(account.nodeID)
        if model.graphWorkspace.selectedNodeID != nodeID {
            model.graphWorkspace.selectedNodeID = nodeID
        }
    }

    private func synchronizeServerSelection() {
        guard let item = NodeWorkspacePresentation.item(
            for: model.graphWorkspace.selectedNodeID,
            model: model,
            workspace: model.graphWorkspace
        ) else { return }
        guard let account = item.accounts.first else { return }
        if model.selectedServerID != account.id {
            model.selectedServerID = account.id
        }
    }
}
