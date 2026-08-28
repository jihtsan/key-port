import KeyPortCore
import SwiftUI

struct ServerListView: View {
    let model: AppModel
    let onAddAccount: (UUID) -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedServerID) {
            ForEach(model.activeServerGroups) { group in
                if group.accounts.count == 1, let account = group.accounts.first {
                    ServerAccountRow(
                        account: account,
                        group: group,
                        onEdit: onEdit,
                        onAddAccount: onAddAccount,
                        onCopyAlias: { model.copyAlias(serverID: $0) },
                        onDelete: { serverID in Task { await model.deleteServer(serverID) } }
                    )
                    .tag(account.id)
                } else {
                    Section {
                        ForEach(group.accounts) { account in
                            ServerAccountRow(
                                account: account,
                                group: nil,
                                onEdit: onEdit,
                                onAddAccount: onAddAccount,
                                onCopyAlias: { model.copyAlias(serverID: $0) },
                                onDelete: { serverID in Task { await model.deleteServer(serverID) } }
                            )
                            .tag(account.id)
                        }
                    } header: {
                        ServerGroupHeader(
                            group: group,
                            onSelect: { model.selectedServerID = group.representative.id },
                            onEdit: onEdit,
                            onAddAccount: { onAddAccount(group.representative.id) }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "名称、地址、用户、分组")
        .navigationTitle("服务器")
        .overlay {
            if model.activeServerGroups.isEmpty {
                if model.searchText.isEmpty {
                    ContentUnavailableView("暂无服务器", systemImage: "server.rack", description: Text("请添加服务器和首个 SSH 用户。"))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
    }
}

private struct ServerGroupHeader: View {
    let group: ServerConnectionGroup
    let onSelect: () -> Void
    let onEdit: (UUID) -> Void
    let onAddAccount: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.representative.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text("\(group.host):\(group.port)")
                                .monospaced()
                            Text("\(group.accounts.count) 个用户")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let capacity = group.representative.machineConfiguration?.capacitySummary {
                        Text(capacity)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("选择此服务器端点")
            .contextMenu {
                Button {
                    onEdit(group.representative.id)
                } label: {
                    Label("编辑服务器和用户", systemImage: "pencil")
                }
            }
            Button {
                onEdit(group.representative.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑服务器和用户")
            Button(action: onAddAccount) {
                Image(systemName: "person.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("为此服务器添加 SSH 用户")
        }
        .textCase(nil)
        .padding(.top, 4)
    }
}

private struct ServerAccountRow: View {
    let account: ServerConnection
    let group: ServerConnectionGroup?
    let onEdit: (UUID) -> Void
    let onAddAccount: (UUID) -> Void
    let onCopyAlias: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group == nil ? "person.crop.circle" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if let group {
                    Text(group.representative.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(group.host):\(group.port) · \(account.username) · \(account.alias)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(account.username)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(account.alias)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let group, let capacity = group.representative.machineConfiguration?.capacitySummary {
                Text(capacity)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StatusLabel(status: account.status)
        }
        .padding(.vertical, group == nil ? 3 : 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit(account.id)
            } label: {
                Label("编辑用户", systemImage: "pencil")
            }
            Button {
                onAddAccount(account.id)
            } label: {
                Label("添加用户", systemImage: "person.badge.plus")
            }
            Button {
                onCopyAlias(account.id)
            } label: {
                Label("复制 SSH 别名", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete(account.id)
            } label: {
                Label("删除用户", systemImage: "trash")
            }
        }
    }
}

struct AuthenticationCheckLabel: View {
    let check: AuthenticationCheck?

    var body: some View {
        if let check {
            Label(check.state.title, systemImage: check.state.systemImage)
                .foregroundStyle(check.state.color)
                .lineLimit(1)
        } else {
            Label("未检查", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct StatusLabel: View {
    let status: AuthorizationStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .foregroundStyle(status.color)
            .lineLimit(1)
    }
}

private extension AuthorizationStatus {
    var systemImage: String {
        switch self {
        case .authorized: "checkmark.circle.fill"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .syncing: "arrow.triangle.2.circlepath"
        case .hostKeyMismatch, .authorizationConflict: "exclamationmark.shield.fill"
        case .hostKeyPending: "questionmark.diamond.fill"
        case .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: "xmark.circle.fill"
        case .missingLocalKey: "key.slash"
        case .syncPending: "arrow.triangle.2.circlepath"
        case .needsAuthorization: "key.horizontal"
        }
    }

    var color: Color {
        switch self {
        case .authorized: .green
        case .checking, .syncing, .syncPending: .blue
        case .hostKeyPending, .needsAuthorization, .missingLocalKey: .orange
        case .hostKeyMismatch, .authorizationConflict, .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: .red
        }
    }
}

private extension AuthenticationCheckState {
    var systemImage: String {
        switch self {
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking: .blue
        case .succeeded: .green
        case .failed: .red
        case .blocked: .orange
        }
    }
}
