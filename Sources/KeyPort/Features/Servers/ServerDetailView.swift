import KeyPortCore
import SwiftUI

struct ServerDetailView: View {
    let server: ServerConnection
    let model: AppModel
    @State private var pendingRevocationID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.title2).fontWeight(.semibold)
                        Text("\(server.username)@\(server.endpoint)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("密钥授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        StatusLabel(status: server.status)
                    }
                }

                GroupBox("连接") {
                    VStack(alignment: .leading, spacing: 10) {
                        LeftAlignedDetailRow("SSH 别名") {
                            HStack(spacing: 6) {
                                Text(server.alias).monospaced()
                                Button { model.copySelectedAlias() } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("复制 SSH 别名")
                            }
                        }
                        LeftAlignedDetailRow("主机") {
                            HStack(spacing: 6) {
                                Text(server.host).monospaced()
                                Button { model.copyHost(serverID: server.id) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("复制主机地址")
                            }
                        }
                        LeftAlignedDetailRow("端口") { Text(String(server.port)) }
                        LeftAlignedDetailRow("用户") { Text(server.username) }
                        LeftAlignedDetailRow("分组") { Text(server.group.isEmpty ? "无" : server.group) }
                        if let connection = model.connection(for: server) {
                            LeftAlignedDetailRow("生效的 SSH 配置") {
                                Label("已同步", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            if !connection.identityFiles.isEmpty {
                                LeftAlignedDetailRow("身份密钥文件") {
                                    Text(connection.identityFiles.joined(separator: "\n"))
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }

                if let log = model.retainedSSHCheckLog, log.serverID == server.id {
                    GroupBox(log.title) {
                        VStack(alignment: .leading, spacing: 8) {
                            if server.passwordCheck?.state == .checking || server.keyCheck?.state == .checking {
                                Label("正在检查", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                                    .foregroundStyle(.blue)
                            } else {
                                Label("最近一次检查未成功完成。", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(log.lines.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }

                GroupBox("机器配置") {
                    if let configuration = server.machineConfiguration {
                        VStack(alignment: .leading, spacing: 10) {
                            LeftAlignedDetailRow("主机名") { Text(configuration.hostname) }
                            LeftAlignedDetailRow("操作系统") { Text(configuration.operatingSystem) }
                            LeftAlignedDetailRow("内核") { Text(configuration.kernel) }
                            LeftAlignedDetailRow("架构") { Text(configuration.architecture) }
                            if let processorCount = configuration.processorCount {
                                LeftAlignedDetailRow("处理器") { Text(String(processorCount)) }
                            }
                            if let memoryBytes = configuration.memoryBytes {
                                LeftAlignedDetailRow("内存") {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory))
                                }
                            }
                            LeftAlignedDetailRow("同步时间") {
                                Text(configuration.synchronizedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    } else {
                        Label("成功完成一次 SSH 检查后即可同步此机器的配置。", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    }
                }

                GroupBox("用户密码") {
                    HStack {
                        if model.hasStoredPassword(serverID: server.id) {
                            Label("已存储在 Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button("更新密码") { model.requestPassword(for: server.id) }
                        } else {
                            Label("Keychain 中缺少密码", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Spacer()
                            Button("添加密码") { model.requestPassword(for: server.id) }
                        }
                    }
                    .padding(.vertical, 5)
                }

                GroupBox("身份验证检查") {
                    VStack(spacing: 12) {
                        AuthenticationCheckRow(
                            title: "密码 SSH",
                            check: server.passwordCheck,
                            buttonTitle: "检查密码 SSH",
                            systemImage: "lock",
                            isDisabled: model.isBusy
                        ) {
                            Task { await model.checkPasswordSelected() }
                        }
                        Divider()
                        AuthenticationCheckRow(
                            title: "密钥 SSH",
                            check: server.keyCheck,
                            buttonTitle: "检查密钥 SSH",
                            systemImage: "key.horizontal",
                            isDisabled: model.isBusy
                        ) {
                            Task { await model.checkKeySelected() }
                        }
                    }
                    .padding(.vertical, 5)
                }

                GroupBox("主机身份") {
                    if server.confirmedHostKeys.isEmpty {
                        Label("尚未确认主机密钥", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(server.confirmedHostKeys) { key in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key.algorithm).font(.callout).fontWeight(.medium)
                                    Text(key.fingerprint).font(.caption).monospaced().textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }

                GroupBox("当前 Mac") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let key = model.key(for: server) {
                            LeftAlignedDetailRow("密钥") { Text(model.keyDisplayName(key)) }
                            LeftAlignedDetailRow("指纹") {
                                Text(key.fingerprint).font(.caption).monospaced().textSelection(.enabled)
                            }
                        } else {
                            Text("没有可用的本地私钥。").foregroundStyle(.secondary)
                            Button("生成 Ed25519 密钥") { Task { await model.generateKey() } }
                        }

                        if let detail = server.statusDetail {
                            Divider()
                            Text(UserFacingText.localized(detail)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }

                GroupBox("设备授权") {
                    let authorizations = model.snapshot.authorizations.filter { $0.serverID == server.id }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(authorizations.isEmpty ? "尚未读取到 KeyPort 授权。" : "共 \(authorizations.count) 项 KeyPort 授权")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("刷新") { Task { await model.refreshRemoteAuthorizations(serverID: server.id) } }
                                .disabled(server.status != .authorized || model.isBusy)
                        }
                        ForEach(authorizations) { authorization in
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(authorization.remoteComment).font(.callout).lineLimit(1)
                                    Text(authorization.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    pendingRevocationID = authorization.id
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("撤销与此公钥指纹完全匹配的授权")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(server.name)
        .confirmationDialog("要从服务器撤销此设备密钥吗？", isPresented: Binding(
            get: { pendingRevocationID != nil },
            set: { if !$0 { pendingRevocationID = nil } }
        )) {
            Button("撤销授权", role: .destructive) {
                guard let id = pendingRevocationID else { return }
                pendingRevocationID = nil
                Task { await model.revokeAuthorization(id) }
            }
            Button("取消", role: .cancel) { pendingRevocationID = nil }
        } message: {
            Text("KeyPort 只会移除公钥指纹完全匹配的记录，其他未知密钥将保留。")
        }
    }
}

private struct LeftAlignedDetailRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 124, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AuthenticationCheckRow: View {
    let title: String
    let check: AuthenticationCheck?
    let buttonTitle: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                AuthenticationCheckLabel(check: check)
                Button(action: action) {
                    Label(buttonTitle, systemImage: systemImage)
                }
                .labelStyle(.iconOnly)
                .help(buttonTitle)
                .disabled(isDisabled)
            }
            if let check {
                Text(UserFacingText.localized(check.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let checkedAt = check.checkedAt {
                    Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
