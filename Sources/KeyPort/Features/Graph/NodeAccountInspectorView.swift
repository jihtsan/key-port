import KeyPortCore
import SwiftUI

struct NodeAccountInspectorView: View {
    let account: ServerConnection?
    let endpoint: Endpoint?
    let isDefaultAccount: Bool
    let hasStoredPassword: Bool
    let isBusy: Bool
    let isReadOnly: Bool
    let onTestConnection: () -> Void
    let onOpenTerminal: () -> Void
    let onCopyCommand: () -> Void
    let onEdit: (ServerConnection) -> Void
    let onDelete: (ServerConnection) -> Void

    var body: some View {
        if let account {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountHeader(account)
                    accountSettings(account)
                    Divider()
                    quickActions(account)
                    Divider()
                    details(account)
                    Divider()
                    moreOptions(account)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("连接配置")
        } else {
            ContentUnavailableView(
                "未选择连接配置",
                systemImage: "arrow.triangle.branch",
                description: Text("从节点工作区选择一个 SSH 连接配置。")
            )
            .navigationTitle("连接配置")
        }
    }

    private func accountHeader(_ account: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.quaternary, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(account.username) · \(account.alias)")
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if isDefaultAccount {
                        Text("默认连接配置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            StatusLabel(status: account.status)
                .font(.callout)
        }
    }

    private func accountSettings(_ account: ServerConnection) -> some View {
        HStack(spacing: 10) {
            Button {
                onEdit(account)
            } label: {
                HStack {
                    Text("连接配置")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isReadOnly || isBusy)

            Menu {
                Button(action: onCopyCommand) {
                    Label("复制 SSH 命令", systemImage: "doc.on.doc")
                }
                Button {
                    onEdit(account)
                } label: {
                    Label("编辑连接配置", systemImage: "pencil")
                }
                .disabled(isReadOnly)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func quickActions(_ account: ServerConnection) -> some View {
        InspectorSection(title: "快速操作") {
            InspectorActionSurface {
                Button(action: onTestConnection) {
                    InspectorActionRow(title: "测试连接", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Divider()

                Button(action: onOpenTerminal) {
                    InspectorActionRow(title: "在终端中打开", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Divider()

                Button(action: onCopyCommand) {
                    InspectorActionRow(title: "复制 SSH 命令", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)

                Divider()

                ShareLink(item: SSHCommandPresentation.command(server: account, endpoint: endpoint)) {
                    InspectorActionRow(title: "分享连接", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func details(_ account: ServerConnection) -> some View {
        InspectorSection(title: "详细信息") {
            VStack(alignment: .leading, spacing: 12) {
                InspectorDetailRow(
                    title: "认证方式",
                    value: hasStoredPassword ? "SSH 密钥 / 密码" : "SSH 密钥"
                )
                InspectorDetailRow(title: "当前路径", value: endpoint?.displayAddress ?? account.endpoint)
                InspectorDetailRow(title: "SSH 别名", value: account.alias)
                InspectorDetailRow(
                    title: "最后检测",
                    value: account.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
                )
            }
        }
    }

    private func moreOptions(_ account: ServerConnection) -> some View {
        InspectorSection(title: "更多选项") {
            InspectorActionSurface {
                Button {
                    onEdit(account)
                } label: {
                    InspectorActionRow(title: "编辑连接配置", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .disabled(isReadOnly || isBusy)

                Divider()

                Button(role: .destructive) {
                    onDelete(account)
                } label: {
                    InspectorActionRow(
                        title: "删除连接配置",
                        systemImage: "trash",
                        tint: .red,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(isReadOnly || isBusy)
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorActionSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct InspectorActionRow: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var showsChevron = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(tint)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .contentShape(Rectangle())
    }
}

private struct InspectorDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
