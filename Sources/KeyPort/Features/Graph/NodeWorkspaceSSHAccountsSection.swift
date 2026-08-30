import KeyPortCore
import SwiftUI

struct NodeWorkspaceSSHAccountsSection: View {
    let accounts: [SSHAccount]
    let isBusy: Bool
    let isReadOnly: Bool
    let hasStoredPassword: (UUID) -> Bool
    let connectionProfileCount: (UUID) -> Int
    let onAdd: () -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH 用户")
                        .font(.title3.weight(.semibold))
                    Text("用户身份和凭据独立于网络路径与 SSH 别名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAdd) {
                    Label("添加用户", systemImage: "plus")
                }
                .disabled(isReadOnly || isBusy)
            }

            if accounts.isEmpty {
                ContentUnavailableView(
                    "还没有 SSH 用户",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("先添加用户名；之后再选择网络路径并创建连接配置。")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(accounts.indices, id: \.self) { index in
                        if index > accounts.startIndex {
                            Divider().padding(.leading, 62)
                        }
                        accountRow(accounts[index])
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

    private func accountRow(_ account: SSHAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(account.label.isEmpty ? account.username : account.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !account.label.isEmpty {
                    Text(account.username)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    Label(
                        hasStoredPassword(account.id) ? "已存密码" : "按需输入密码",
                        systemImage: hasStoredPassword(account.id) ? "key.fill" : "key.slash"
                    )
                    Text("\(connectionProfileCount(account.id)) 个连接配置")
                }
                Label(
                    hasStoredPassword(account.id) ? "已存密码" : "按需输入密码",
                    systemImage: hasStoredPassword(account.id) ? "key.fill" : "key.slash"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                onEdit(account.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑 SSH 用户")
            .disabled(isReadOnly || isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
