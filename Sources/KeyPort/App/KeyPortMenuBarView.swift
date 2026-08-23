import AppKit
import KeyPortCore
import SwiftUI

struct KeyPortMenuBarView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @State private var copiedServerID: UUID?

    var body: some View {
        authorizedServiceSections

        Divider()

        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("打开 KeyPort", systemImage: "macwindow")
        }

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("退出 KeyPort", systemImage: "power")
        }
    }

    @ViewBuilder
    private var authorizedServiceSections: some View {
        if !model.isLoaded {
            Section("免密已验证") {
                Text("正在加载...")
            }
        } else if serviceGroups.isEmpty {
            Section("免密已验证") {
                Text("暂无免密已验证的服务")
            }
        } else {
            ForEach(serviceGroups) { group in
                authorizedServiceSection(group)
            }
        }
    }

    private var authorizedAccounts: [ServerConnection] {
        model.authorizedSSHAccounts
    }

    private var serviceGroups: [AuthorizedServiceGroup] {
        authorizedServiceGroups(from: authorizedAccounts)
    }

    @ViewBuilder
    private func authorizedServiceSection(_ group: AuthorizedServiceGroup) -> some View {
        if let title = group.title {
            Section(title) {
                serviceRows(group.accounts)
            }
        } else {
            Section {
                serviceRows(group.accounts)
            }
        }
    }

    @ViewBuilder
    private func serviceRows(_ accounts: [ServerConnection]) -> some View {
        ForEach(accounts) { server in
            serviceRow(server)
        }
    }

    private func serviceRow(_ server: ServerConnection) -> some View {
        Button {
            copyAlias(for: server)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: server.alias)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 140, alignment: .leading)

                Text(verbatim: endpoint(for: server))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 120, alignment: .leading)

                Image(systemName: copiedServerID == server.id ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, alignment: .leading)
        }
        .help("复制 SSH 别名 \(server.alias)")
    }

    private func endpoint(for server: ServerConnection) -> String {
        server.port == 22 ? server.host : "\(server.host):\(server.port)"
    }

    private func copyAlias(for server: ServerConnection) {
        model.copyAlias(serverID: server.id)
        copiedServerID = server.id

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard copiedServerID == server.id else { return }
            copiedServerID = nil
        }
    }
}

struct AuthorizedServiceGroup: Identifiable {
    let id: String
    let title: String?
    let accounts: [ServerConnection]
}

func authorizedServiceGroups(from accounts: [ServerConnection]) -> [AuthorizedServiceGroup] {
    let grouped = Dictionary(
        grouping: accounts,
        by: { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) }
    )

    return grouped
        .map {
            AuthorizedServiceGroup(
                id: $0.key,
                title: $0.key.isEmpty ? nil : $0.key,
                accounts: sortedAccounts($0.value)
            )
        }
        .sorted {
            ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
        }
}

private func sortedAccounts(_ accounts: [ServerConnection]) -> [ServerConnection] {
    accounts.sorted {
        let aliasOrder = $0.alias.localizedCaseInsensitiveCompare($1.alias)
        if aliasOrder != .orderedSame {
            return aliasOrder == .orderedAscending
        }
        return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
    }
}
