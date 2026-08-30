import KeyPortCore
import SwiftUI

struct NodeWorkspaceHeader: View {
    let item: NodeWorkspaceItem
    let tags: [String]
    let accounts: [ServerConnection]
    let endpoints: [Endpoint]
    let selectedAccountID: UUID?
    let selectedEndpointID: UUID?
    let isBusy: Bool
    let isReadOnly: Bool
    let onSelectAccount: (UUID) -> Void
    let onSelectEndpoint: (UUID) -> Void
    let onTestConnection: () -> Void
    let onOpenTerminal: () -> Void
    let onAddAccount: () -> Void
    let onAddEndpoint: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: item.node.kind.systemImage)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.node.title)
                        .font(.title.weight(.semibold))
                        .lineLimit(1)
                    ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                        NodeTagChip(title: tag, index: index)
                    }
                }

                Spacer(minLength: 8)

                Menu {
                    Button(action: onAddAccount) {
                        Label("添加 SSH 账户", systemImage: "person.badge.plus")
                    }
                    .disabled(isReadOnly)
                    Button(action: onAddEndpoint) {
                        Label("添加网络路径", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(isReadOnly)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("节点操作")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { selectors }
                VStack(alignment: .leading, spacing: 10) { selectors }
            }

            HStack(spacing: 10) {
                Button(action: onTestConnection) {
                    Label("测试连接", systemImage: "waveform.path.ecg")
                }
                .disabled(selectedAccount == nil || isBusy)

                Button(action: onOpenTerminal) {
                    Label("在终端中打开", systemImage: "terminal")
                }
                .disabled(selectedAccount == nil || isBusy)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    @ViewBuilder
    private var selectors: some View {
        Menu {
            ForEach(accounts) { account in
                Button {
                    onSelectAccount(account.id)
                } label: {
                    Label(
                        "\(account.username) · \(account.alias)",
                        systemImage: account.id == selectedAccountID ? "checkmark" : "person"
                    )
                }
            }
        } label: {
            NodeWorkspacePickerLabel(
                title: selectedAccount.map { "\($0.username) · \($0.alias)" } ?? "选择账户",
                systemImage: "person"
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(accounts.isEmpty)

        Menu {
            ForEach(endpoints) { endpoint in
                Button {
                    onSelectEndpoint(endpoint.id)
                } label: {
                    Label(
                        "\(endpoint.networkScope.displayTitle) · \(endpoint.displayAddress)",
                        systemImage: endpoint.id == selectedEndpointID ? "checkmark" : endpoint.networkScope.systemImage
                    )
                }
            }
        } label: {
            NodeWorkspacePickerLabel(
                title: selectedEndpoint.map {
                    "自动 → \($0.networkScope.displayTitle)"
                } ?? "账户默认路径",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(endpoints.isEmpty)

        NodeWorkspaceStatusPill(status: item.node.status)
    }

    private var selectedAccount: ServerConnection? {
        accounts.first(where: { $0.id == selectedAccountID }) ?? accounts.first
    }

    private var selectedEndpoint: Endpoint? {
        endpoints.first(where: { $0.id == selectedEndpointID }) ?? endpoints.first
    }
}

private struct NodeWorkspacePickerLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct NodeWorkspaceStatusPill: View {
    let status: TopologyGraphStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.level.tint)
                .frame(width: 7, height: 7)
            Text(status.level.displayTitle)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .help(status.reasons.map(\.rawValue).joined(separator: "、"))
    }
}

private struct NodeTagChip: View {
    let title: String
    let index: Int

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.18), lineWidth: 1)
            }
    }

    private var tint: Color {
        let colors: [Color] = [.blue, .purple, .green]
        return colors[index % colors.count]
    }
}
