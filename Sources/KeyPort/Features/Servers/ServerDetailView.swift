import KeyPortCore
import SwiftUI

struct ServerDetailView: View {
    let server: ServerConnection
    let model: AppModel
    @State private var pendingRevocationID: String?

    private var localKey: SSHKeyRecord? {
        guard let key = model.key(for: server),
              key.isLocallyAvailable,
              key.privateKeyPath != nil else { return nil }
        return key
    }

    private var primaryAction: SSHAuthorizationAction {
        server.status.primaryAction(
            hasStoredPassword: model.hasStoredPassword(serverID: server.id),
            hasLocalKey: localKey != nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountHeader
                authorizationOverview
                verificationResults
                sshOperationLog
                authorizationPrerequisites
                deviceAssociation
                machineConfiguration
                connectionDetails
                remoteAuthorizations
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

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(verbatim: "\(server.username)@\(server.endpoint)")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusLabel(status: server.status)
            }
            Text("当前 SSH 账户的免密授权状态与操作")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var authorizationOverview: some View {
        GroupBox("SSH 免密授权") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    StatusLabel(status: server.status)
                    Spacer()
                    if server.status.isInFlight {
                        ProgressView()
                            .controlSize(.small)
                        Text(server.status.title)
                            .foregroundStyle(.secondary)
                    } else if primaryAction != .none {
                        Button {
                            performPrimaryAction()
                        } label: {
                            Label(primaryAction.title, systemImage: primaryAction.systemImage)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }
                }

                Text(UserFacingText.localized(server.statusDetail ?? defaultStatusDetail))
                    .fixedSize(horizontal: false, vertical: true)

                if let key = localKey {
                    LabeledContent("当前公钥指纹") {
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let checkedAt = server.lastCheckedAt {
                    LabeledContent("最近状态更新时间") {
                        Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private var verificationResults: some View {
        GroupBox("验证结果") {
            VStack(alignment: .leading, spacing: 10) {
                VerificationCheckRow(title: "公钥复检", check: server.keyCheck)
                Divider()
                VerificationCheckRow(title: "密码前置验证", check: server.passwordCheck)
                Divider()
                Text("只有同一 \(server.username)@\(server.endpoint) 的公钥复检成功后，状态才会显示“免密可用”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var sshOperationLog: some View {
        if let log = model.retainedSSHCheckLog, log.serverID == server.id {
            GroupBox(log.title) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        server.status.isInFlight ? "正在执行" : "最近一次操作未完成",
                        systemImage: server.status.isInFlight
                            ? "arrow.trianglehead.2.clockwise.rotate.90"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(server.status.isInFlight ? .blue : .orange)
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
    }

    private var authorizationPrerequisites: some View {
        GroupBox("授权阻断与前置条件") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        server.confirmedHostKeys.isEmpty ? "主机身份待确认" : "主机身份已确认",
                        systemImage: server.confirmedHostKeys.isEmpty ? "exclamationmark.shield" : "checkmark.shield.fill"
                    )
                    .foregroundStyle(server.confirmedHostKeys.isEmpty ? .orange : .green)
                    Spacer()
                    if server.status == .hostKeyPending || server.status == .hostKeyMismatch || server.confirmedHostKeys.isEmpty {
                        Button("确认主机身份") {
                            Task { await model.checkKey(serverID: server.id) }
                        }
                        .disabled(model.isBusy)
                    }
                }
                if !server.confirmedHostKeys.isEmpty {
                    ForEach(server.confirmedHostKeys) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key.algorithm)
                                .font(.callout)
                                .fontWeight(.medium)
                            Text(key.fingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    if model.hasStoredPassword(serverID: server.id) {
                        Label("Keychain 已保存当前账户密码", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Keychain 中没有当前账户密码", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(model.hasStoredPassword(serverID: server.id) ? "更新并验证密码" : "添加并验证密码") {
                        model.requestPassword(for: server.id)
                    }
                    .disabled(model.isBusy)
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    if let key = localKey {
                        Label(model.keyDisplayName(key), systemImage: "key.fill")
                    } else {
                        Label("没有可用的本地私钥", systemImage: "key.slash")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if localKey == nil {
                        Button("生成本地密钥") {
                            Task { await model.generateKey() }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private var deviceAssociation: some View {
        GroupBox("设备与已管理 SSH 账户") {
            if let item = model.devicePresence(for: server) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(item.name, systemImage: item.isCurrent ? "laptopcomputer" : "desktopcomputer")
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            model.showDevice(item.id)
                        } label: {
                            Label("查看设备", systemImage: "arrow.right.circle")
                        }
                    }

                    LabeledContent("关联依据") {
                        Text(item.addressMatch(for: server.host)?.title ?? "Tailscale 地址精确匹配")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("账户边界") {
                        Text(verbatim: "SSH \(server.username)@\(server.endpoint)")
                            .font(.caption.monospaced())
                    }

                    if let addresses = associatedAddresses(for: item), !addresses.isEmpty {
                        LabeledContent("已知 Tailscale 地址") {
                            Text(addresses.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Text("这是设备网络身份与已管理 SSH 账户的地址关联，不代表在设备内发现了 SSH 或 Telnet 服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    let accounts = model.servers(for: item)
                    if !accounts.isEmpty {
                        Divider()
                        Text("同一设备下的已管理 SSH 账户")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(accounts) { account in
                            HStack {
                                Label(account.username, systemImage: "person.crop.circle")
                                Text(verbatim: "\(account.host):\(account.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if account.id == server.id {
                                    Text("当前")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        model.showServer(account.id)
                                    } label: {
                                        Image(systemName: "arrow.right.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("查看 \(account.username) SSH 账户")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("未匹配设备地址", systemImage: "link.badge.plus")
                        .foregroundStyle(.secondary)
                    Text("当前只按 Tailscale MagicDNS 或 Tailscale IP 精确匹配。Telnet、公网 IPv4、反向 DNS、相似主机名和网段都不会自动推断为 SSH 服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
        }
    }

    private var machineConfiguration: some View {
        GroupBox("机器配置同步") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if model.machineConfigurationSyncingServerID == server.id {
                        Label("正在同步机器配置", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                        ProgressView()
                            .controlSize(.small)
                    } else if server.machineConfiguration != nil {
                        Label("已同步", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("尚未同步", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("同步机器配置") {
                        Task { await model.synchronizeMachineConfiguration(serverID: server.id) }
                    }
                    .disabled(server.status != .authorized || model.isBusy)
                }

                if let configuration = server.machineConfiguration {
                    VStack(alignment: .leading, spacing: 8) {
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
                } else {
                    Text("免密可用后可以独立同步机器配置；配置读取失败不会覆盖 SSH 免密状态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.machineConfigurationSyncError,
                   model.machineConfigurationSyncErrorServerID == server.id,
                   model.machineConfigurationSyncingServerID == nil {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private var connectionDetails: some View {
        GroupBox("SSH 账户资料") {
            VStack(alignment: .leading, spacing: 10) {
                LeftAlignedDetailRow("SSH 别名") {
                    HStack(spacing: 6) {
                        Text(server.alias).monospaced()
                        Button { model.copyAlias(serverID: server.id) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制 SSH 别名")
                    }
                }
                LeftAlignedDetailRow("主机") {
                    HStack(spacing: 6) {
                        Text(server.host).monospaced()
                        Button { model.copyHost(serverID: server.id) } label: {
                            Image(systemName: "doc.on.doc")
                        }
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
    }

    private var remoteAuthorizations: some View {
        GroupBox("远端公钥授权") {
            let authorizations = model.snapshot.authorizations.filter { $0.serverID == server.id }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(authorizations.isEmpty ? "尚未读取到 KeyPort 授权。" : "共 \(authorizations.count) 项 KeyPort 授权")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") {
                        Task { await model.refreshRemoteAuthorizations(serverID: server.id) }
                    }
                    .disabled(server.status != .authorized || model.isBusy)
                }
                ForEach(authorizations) { authorization in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            if let key = model.key(for: authorization) {
                                let deviceName = model.devicePresence(for: key)?.name ?? "未知设备"
                                Text(deviceName)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(model.keyDisplayName(key))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(authorization.remoteComment)
                                    .font(.callout)
                                    .lineLimit(1)
                            }
                            Text(authorization.fingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let key = model.key(for: authorization) {
                            Button { model.showKey(key.id) } label: {
                                Image(systemName: "key.horizontal")
                            }
                            .buttonStyle(.borderless)
                            .help("查看密钥")
                        }
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

    private var defaultStatusDetail: String {
        switch server.status {
        case .authorized: "最近一次公钥复检成功。"
        case .needsAuthorization, .syncPending: "当前 Mac 的公钥尚未完成 SSH 授权。"
        case .missingLocalKey: "需要生成或导入本地私钥。"
        case .hostKeyPending, .hostKeyMismatch: "主机身份未确认，授权已阻止。"
        case .checking: "正在检查 SSH 连接和主机身份。"
        case .syncing: "正在同步 SSH 授权。"
        default: "最近一次 SSH 身份验证没有成功完成。"
        }
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .synchronizeAuthorization:
            Task { await model.synchronizeSSHAuthorization(serverID: server.id) }
        case .recheck, .confirmHostKey, .retry:
            Task { await model.checkKey(serverID: server.id) }
        case .addAndVerifyPassword:
            model.requestPassword(for: server.id)
        case .generateLocalKey:
            Task { await model.generateKey() }
        case .none:
            break
        }
    }

    private func associatedAddresses(for item: DevicePresence) -> [String]? {
        item.tailscaleNode?.addresses ?? item.registeredDevice?.tailscaleIdentity?.addresses
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

private struct VerificationCheckRow: View {
    let title: String
    let check: AuthenticationCheck?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
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
                } else {
                    Text("尚未执行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            AuthenticationCheckLabel(check: check)
        }
    }
}
