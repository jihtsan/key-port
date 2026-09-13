import KeyPortCore
import SwiftUI

struct AppSidebarView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        let destinationSelection = Binding<SidebarDestination>(
            get: { model.destination },
            set: { destination in
                model.destination = destination
                model.selectedKeyID = nil
            }
        )

        VStack(spacing: 0) {
            List(selection: destinationSelection) {
                Section {
                    AppSidebarDestinationRow(
                        title: "服务器",
                        systemImage: "server.rack"
                    )
                    .tag(SidebarDestination.servers)
                }

                Section {
                    Button(action: showAllNodes) {
                        AppSidebarCountRow(
                            title: "全部服务器",
                            systemImage: "square.grid.2x2",
                            count: serverCount
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
                        title: "我的设备",
                        systemImage: "laptopcomputer"
                    )
                    .tag(SidebarDestination.devices)
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

    private var serverCount: Int {
        NodeWorkspacePresentation.serverItems(
            model: model,
            workspace: model.graphWorkspace
        ).filter { !$0.accounts.isEmpty }.count
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
        model.destination = .servers
        model.selectedKeyID = nil
        model.serverWorkspaceMode = .list
        model.graphWorkspace.viewMode = .allDevices
        model.graphWorkspace.onlyIssues = false
        model.graphWorkspace.searchText = ""
        model.searchText = ""
    }

    private func showTag(_ tag: String) {
        model.destination = .servers
        model.selectedKeyID = nil
        model.serverWorkspaceMode = .list
        model.graphWorkspace.viewMode = .allDevices
        model.graphWorkspace.onlyIssues = false
        model.graphWorkspace.searchText = tag
        model.searchText = tag
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
