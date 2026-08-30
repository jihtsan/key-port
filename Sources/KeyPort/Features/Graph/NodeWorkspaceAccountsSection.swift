import KeyPortCore
import SwiftUI

struct NodeWorkspaceAccountsSection: View {
    let rows: [NodeWorkspaceAccountDisplay]
    let selectedAccountID: UUID?
    let isBusy: Bool
    let isReadOnly: Bool
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onEdit: (UUID) -> Void
    let onTest: (ServerConnection) -> Void
    let onCopyCommand: (ServerConnection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH 连接配置")
                        .font(.title3.weight(.semibold))
                    Text("每个配置绑定一个账户、网络路径和唯一别名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAdd) {
                    Label("账户", systemImage: "plus")
                }
                .disabled(isReadOnly || isBusy)
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "还没有 SSH 连接配置",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("选择账户和网络路径后，即可保存一个 SSH 使用入口。")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > rows.startIndex {
                            Divider().padding(.leading, 62)
                        }
                        let row = rows[index]
                        NodeWorkspaceAccountRow(
                            display: row,
                            isSelected: row.id == selectedAccountID,
                            isBusy: isBusy,
                            onSelect: { onSelect(row.id) },
                            onEdit: { onEdit(row.id) },
                            onTest: { onTest(row.account) },
                            onCopyCommand: { onCopyCommand(row.account) }
                        )
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }
        }
    }
}

struct NodeWorkspaceAccountDisplay: Identifiable {
    let account: ServerConnection
    let authenticationTitle: String

    var id: UUID { account.id }
}

private struct NodeWorkspaceAccountRow: View {
    let display: NodeWorkspaceAccountDisplay
    let isSelected: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onTest: () -> Void
    let onCopyCommand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.account.username)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(display.account.alias)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 88, alignment: .leading)
                    .layoutPriority(2)

                    Spacer(minLength: 8)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            Text(display.authenticationTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            StatusLabel(status: display.account.status)
                                .font(.caption)
                                .fixedSize()
                        }
                        StatusLabel(status: display.account.status)
                            .font(.caption)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onTest) {
                    Label("测试连接", systemImage: "waveform.path.ecg")
                }
                .disabled(isBusy)
                Button(action: onCopyCommand) {
                    Label("复制 SSH 命令", systemImage: "doc.on.doc")
                }
                Button(action: onEdit) {
                    Label("编辑连接配置", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear)
    }
}
