import AppKit
import KeyPortCore
import SwiftUI

struct ServerDetailView: View {
    let server: ServerConnection
    let model: AppModel
    @State private var pendingRevocationID: String?
    @State private var associationEditorSelection: AssociationEditorSelection?
    @State private var securityDetailsExpanded = false
    @State private var copiedValue: CopiedSSHValue?

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
                accessSummary
                sshOperationLog
                validationAndSecurityDetails
                deviceAssociation
                testCaseNodeAssociation
                machineConfiguration
                connectionDetails
                remoteAuthorizations
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(server.name)
        .onAppear { expandSecurityDetailsForHostRisk() }
        .onChange(of: server.status) { _, _ in expandSecurityDetailsForHostRisk() }
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
        .sheet(item: $associationEditorSelection) { selection in
            NodeAssociationEditorView(
                server: server,
                model: model,
                existingAssociation: selection.testCaseNodeID.flatMap(model.nodeAssociation(testCaseNodeID:))
            )
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
            }
        }
    }

    private var accessSummary: some View {
        GroupBox("SSH 访问") {
            VStack(alignment: .leading, spacing: 14) {
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

                if let lastSuccessAt = server.lastKeySuccessAt {
                    Label(
                        "最近免密成功：\(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        Task { await model.checkKey(serverID: server.id) }
                    } label: {
                        authenticationButtonLabel(
                            title: "测试免密 SSH",
                            systemImage: "key.horizontal",
                            isChecking: server.keyCheck?.state == .checking
                        )
                    }
                    .help("只使用本地公钥测试 SSH，不读取密码或写入远端")
                    .accessibilityLabel("测试免密 SSH")
                    .accessibilityValue(authenticationAccessibilityValue(server.keyCheck))

                    Button {
                        Task { await model.checkPassword(serverID: server.id) }
                    } label: {
                        authenticationButtonLabel(
                            title: "测试密码 SSH",
                            systemImage: "lock.open",
                            isChecking: server.passwordCheck?.state == .checking
                        )
                    }
                    .help("使用已存密码测试 SSH；没有密码时打开安全凭据窗口")
                    .accessibilityLabel("测试密码 SSH")
                    .accessibilityValue(authenticationAccessibilityValue(server.passwordCheck))
                }
                .disabled(model.isBusy)

                Divider()

                HStack(spacing: 10) {
                    Text(server.alias)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    copyButton(.alias)
                    copyButton(.command)
                }
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

    private var validationAndSecurityDetails: some View {
        DisclosureGroup("验证与安全详情", isExpanded: $securityDetailsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                VerificationCheckRow(title: "免密 SSH", check: server.keyCheck)
                Divider()
                VerificationCheckRow(title: "密码 SSH", check: server.passwordCheck)
                Divider()
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

                if let observedKeys = server.lastObservedHostKeys, !observedKeys.isEmpty,
                   server.status == .hostKeyPending || server.status == .hostKeyMismatch {
                    Divider()
                    Label("本次观察到的主机密钥", systemImage: "exclamationmark.shield.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    ForEach(observedKeys) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key.algorithm)
                                .font(.callout)
                            Text(key.fingerprint)
                                .font(.caption.monospaced())
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

                if let key = localKey {
                    Divider()
                    LeftAlignedDetailRow("当前公钥指纹") {
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let checkedAt = server.lastCheckedAt {
                    LeftAlignedDetailRow("最近状态更新时间") {
                        Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
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

    private var testCaseNodeAssociation: some View {
        GroupBox("Test Case 节点关联") {
            VStack(alignment: .leading, spacing: 10) {
                let associations = model.nodeAssociations(for: server.id)
                if !associations.isEmpty {
                    HStack {
                        Text("已配置 \(associations.count) 个逻辑节点")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("添加关联") { associationEditorSelection = AssociationEditorSelection() }
                    }
                    ForEach(associations) { association in
                        Divider()
                        nodeAssociationRow(association)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("尚未配置", systemImage: "link.badge.plus")
                                .foregroundStyle(.secondary)
                            Text("默认使用标准化后的 Server 名称；唯一同名 Tailscale HostName 可自动关联，歧义时需人工确认。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("配置关联") { associationEditorSelection = AssociationEditorSelection() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func nodeAssociationRow(_ association: NodeAssociation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(association.state.displayTitle, systemImage: association.state.systemImage)
                    .foregroundStyle(association.state.tint)
                Text(association.testCaseNodeID).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button("管理") {
                    associationEditorSelection = AssociationEditorSelection(testCaseNodeID: association.testCaseNodeID)
                }
            }
            if let target = association.target {
                LeftAlignedDetailRow("稳定目标") {
                    Text(target.id).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            LeftAlignedDetailRow("关联方式") {
                Text(association.method == .automatic ? "唯一强证据自动关联" : association.method == .manual ? "人工确认" : "未关联")
            }
            if !association.evidenceKinds.isEmpty {
                LeftAlignedDetailRow("匹配证据") {
                    Text(association.evidenceKinds.map(\.displayTitle).joined(separator: "、"))
                }
            }
            if !association.reasonCodes.isEmpty {
                LeftAlignedDetailRow("状态原因") {
                    Text(association.reasonCodes.map(\.displayTitle).joined(separator: "、"))
                        .foregroundStyle(.secondary)
                }
            }
            if let verifiedAt = association.lastVerifiedAt {
                LeftAlignedDetailRow("最后验证") {
                    Text(verifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
            Label(
                model.canExecuteTestCaseNode(association.testCaseNodeID)
                    ? "允许关联驱动的 Test Case 执行"
                    : "已阻止关联驱动的 Test Case 执行",
                systemImage: model.canExecuteTestCaseNode(association.testCaseNodeID)
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill"
            )
            .foregroundStyle(model.canExecuteTestCaseNode(association.testCaseNodeID) ? .green : .orange)
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

    @ViewBuilder
    private func authenticationButtonLabel(title: String, systemImage: String, isChecking: Bool) -> some View {
        HStack(spacing: 7) {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: systemImage)
                    .frame(width: 16, height: 16)
            }
            Text(title)
        }
        .frame(minWidth: 132)
    }

    private func authenticationAccessibilityValue(_ check: AuthenticationCheck?) -> String {
        guard let check else { return "尚未测试" }
        return "\(check.state.title)，\(UserFacingText.localized(check.detail))"
    }

    private func copyButton(_ value: CopiedSSHValue) -> some View {
        Button {
            switch value {
            case .alias:
                model.copyAlias(serverID: server.id)
            case .command:
                model.copySSHCommand(serverID: server.id)
            }
            copiedValue = value
            AccessibilityNotification.Announcement(value.successAnnouncement).post()
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                if copiedValue == value { copiedValue = nil }
            }
        } label: {
            Label(
                value.title,
                systemImage: copiedValue == value ? "checkmark" : value.systemImage
            )
            .frame(minWidth: value.minimumWidth)
        }
        .help(value.title)
        .accessibilityLabel(value.title)
        .accessibilityValue(copiedValue == value ? "已复制" : "")
    }

    private func expandSecurityDetailsForHostRisk() {
        if server.status == .hostKeyPending || server.status == .hostKeyMismatch {
            securityDetailsExpanded = true
        }
    }

    private func associatedAddresses(for item: DevicePresence) -> [String]? {
        item.tailscaleNode?.addresses ?? item.registeredDevice?.tailscaleIdentity?.addresses
    }
}

private enum CopiedSSHValue: Equatable {
    case alias
    case command

    var title: String { self == .alias ? "复制 SSH 别名" : "复制 SSH 命令" }
    var systemImage: String { self == .alias ? "doc.on.doc" : "terminal" }
    var minimumWidth: CGFloat { self == .alias ? 124 : 128 }
    var successAnnouncement: String { self == .alias ? "SSH 别名已复制" : "SSH 命令已复制" }
}

private struct AssociationEditorSelection: Identifiable {
    let id = UUID()
    var testCaseNodeID: String?
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

private extension NodeAssociationState {
    var displayTitle: String {
        switch self {
        case .unlinked: "未关联"
        case .pendingConfirmation: "待确认"
        case .linked: "已关联"
        case .reviewRequired: "需要复核"
        case .invalidated: "已解除"
        }
    }

    var systemImage: String {
        switch self {
        case .linked: "link.circle.fill"
        case .pendingConfirmation: "questionmark.circle"
        case .reviewRequired: "exclamationmark.triangle.fill"
        case .invalidated: "link.badge.minus"
        case .unlinked: "link.badge.plus"
        }
    }

    var tint: Color {
        switch self {
        case .linked: .green
        case .pendingConfirmation, .reviewRequired: .orange
        case .unlinked, .invalidated: .secondary
        }
    }
}

private extension NodeAssociationEvidence {
    var displayTitle: String {
        switch self {
        case .exactLogicalName: "逻辑节点名称精确一致"
        case .exactMagicDNS: "MagicDNS 精确一致"
        case .exactTailscaleIP: "Tailscale IP 精确一致"
        }
    }
}

private extension NodeAssociationReason {
    var displayTitle: String {
        switch self {
        case .noMatch: "无强证据匹配"
        case .multipleStrongMatches: "存在多个强匹配候选"
        case .weakEvidenceOnly: "仅有弱证据"
        case .proxiedRoute: "SSH 使用跳板或代理"
        case .sourceUnavailable: "Tailscale 数据源不可用"
        case .unstableTargetIdentity: "目标缺少稳定 nodeId"
        case .nodeMissing: "原节点已消失"
        case .nodeIdentityChanged: "nodeId 已变化"
        case .hostKeyChanged: "Host Key 已变化"
        case .endpointConflict: "有效 SSH 主机与目标冲突"
        case .logicalNameChanged: "逻辑节点名称已变化或出现重名"
        case .manuallyUnlinked: "用户已解除并暂停自动匹配"
        }
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
