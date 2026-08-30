import KeyPortCore
import SwiftUI

struct AppSidebarView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            List(selection: $model.destination) {
                Section {
                    AppSidebarDestinationRow(
                        title: "节点",
                        systemImage: "server.rack"
                    )
                    .tag(SidebarDestination.nodes)

                    AppSidebarDestinationRow(
                        title: "拓扑",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    .tag(SidebarDestination.graph)
                }

                Section {
                    Button(action: showAllNodes) {
                        AppSidebarCountRow(
                            title: "全部节点",
                            systemImage: "square.grid.2x2",
                            count: nodeCount
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !tags.isEmpty {
                    Section("标签") {
                        ForEach(tags.indices, id: \.self) { index in
                            let tag = tags[index]
                            Button {
                                showTag(tag.title)
                            } label: {
                                AppSidebarTagRow(
                                    title: tag.title,
                                    count: tag.count,
                                    tint: tagTint(at: index)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    AppSidebarDestinationRow(
                        title: "活动",
                        systemImage: "clock"
                    )
                    .tag(SidebarDestination.activity)

                    AppSidebarDestinationRow(
                        title: "SSH 账户",
                        systemImage: "person.2"
                    )
                    .tag(SidebarDestination.servers)

                    AppSidebarDestinationRow(
                        title: "密钥",
                        systemImage: "key"
                    )
                    .tag(SidebarDestination.keys)

                    AppSidebarDestinationRow(
                        title: "设备",
                        systemImage: "laptopcomputer"
                    )
                    .tag(SidebarDestination.devices)

                    AppSidebarDestinationRow(
                        title: "审计日志",
                        systemImage: "checklist"
                    )
                    .tag(SidebarDestination.logs)
                }
            }
            .listStyle(.sidebar)

            Divider()

            SettingsLink {
                Label("偏好设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("KeyPort")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
    }

    private var nodeCount: Int {
        let unifiedCount = model.topology.nodes.filter { !$0.isDeleted }.count
        if unifiedCount > 0 { return unifiedCount }
        return NodeWorkspacePresentation.items(
            model: model,
            workspace: model.graphWorkspace
        ).count
    }

    private var tags: [AppSidebarTag] {
        let groups = Dictionary(grouping: model.activeServers) { server in
            server.group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return groups
            .filter { !$0.key.isEmpty }
            .map { AppSidebarTag(title: $0.key, count: Set($0.value.map(\.name)).count) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func showAllNodes() {
        model.destination = .nodes
        model.graphWorkspace.viewMode = .allDevices
        model.graphWorkspace.onlyIssues = false
        model.graphWorkspace.searchText = ""
    }

    private func showTag(_ tag: String) {
        model.destination = .nodes
        model.graphWorkspace.viewMode = .allDevices
        model.graphWorkspace.onlyIssues = false
        model.graphWorkspace.searchText = tag
    }

    private func tagTint(at index: Int) -> Color {
        let palette: [Color] = [.purple, .blue, .green, .orange, .pink]
        return palette[index % palette.count]
    }
}

private struct AppSidebarTag: Hashable {
    let title: String
    let count: Int
}

private struct AppSidebarDestinationRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
    }
}

private struct AppSidebarCountRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
            Text(count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .contentShape(Rectangle())
    }
}

private struct AppSidebarTagRow: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
            Spacer()
            Text(count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
