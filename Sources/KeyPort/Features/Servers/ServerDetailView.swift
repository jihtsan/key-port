import KeyPortCore
import SwiftUI

struct ServerDetailView: View {
    let server: ServerConnection
    let model: AppModel

    @State private var credentialsAndSecurityExpanded = false
    @State private var deviceAuthorizationsExpanded = false
    @State private var pendingRevocationID: String?
    @State private var associationEditorSelection: AssociationEditorSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountHeader
                quickConnection
                machineConfiguration
                credentialsAndSecurity
                testCaseNodeAssociation
                deviceAuthorizations
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(server.name)
        .onAppear { expandRequiredSections() }
        .onChange(of: server.id) { _, _ in expandRequiredSections() }
        .onChange(of: server.status) { _, _ in expandRequiredSections() }
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
        let action = model.passwordlessPrimaryAction(for: server)
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(server.username)@\(server.endpoint)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                PasswordlessStatusLabel(status: server.status)
                Button {
                    Task { await model.performPasswordlessPrimaryAction(serverID: server.id) }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .help(action.help)
                .disabled(model.isBusy || action == .checking)
            }
        }
    }

    private var quickConnection: some View {
        GroupBox("快速连接") {
            VStack(alignment: .leading, spacing: 10) {
                LeftAlignedDetailRow("SSH 别名") {
                    CopyableValue(value: server.alias, help: "复制 SSH 别名") {
                        model.copyAlias(serverID: server.id)
                    }
                }
                LeftAlignedDetailRow("SSH 命令") {
                    CopyableValue(value: "ssh \(server.alias)", help: "复制 SSH 命令") {
                        model.copySSHCommand(serverID: server.id)
                    }
                }
                LeftAlignedDetailRow("IP / 域名") {
                    CopyableValue(value: server.host, help: "复制主机地址") {
                        model.copyHost(serverID: server.id)
                    }
                }
                LeftAlignedDetailRow("端口") { Text(String(server.port)) }
                LeftAlignedDetailRow("SSH 用户") { Text(server.username) }
                if !server.group.isEmpty {
                    LeftAlignedDetailRow("分组") { Text(server.group) }
                }
                if !server.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LeftAlignedDetailRow("备注") {
                        Text(server.notes)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let connection = model.connection(for: server) {
                    LeftAlignedDetailRow("SSH 配置") {
                        Label("已同步", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if !connection.identityFiles.isEmpty {
                        LeftAlignedDetailRow("身份密钥") {
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

    private var machineConfiguration: some View {
        GroupBox("机器配置") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.machineConfigurationSyncingServerID == server.id {
                        Label("正在同步", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.blue)
                        ProgressView().controlSize(.small)
                    } else if server.machineConfiguration != nil {
                        Label("已同步", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("尚未同步", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.synchronizeMachineConfiguration(serverID: server.id) }
                    } label: {
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(server.status != .authorized || model.isBusy)
                }

                if let configuration = server.machineConfiguration {
                    Divider()
                    LeftAlignedDetailRow("主机名") { Text(configuration.hostname) }
                    LeftAlignedDetailRow("操作系统") { Text(configuration.operatingSystem) }
                    LeftAlignedDetailRow("内核") { Text(configuration.kernel) }
                    LeftAlignedDetailRow("架构") { Text(configuration.architecture) }
                    if let processorCount = configuration.processorCount {
                        LeftAlignedDetailRow("处理器") { Text("\(processorCount) 核") }
                    }
                    if let memoryBytes = configuration.memoryBytes {
                        LeftAlignedDetailRow("内存") {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory))
                        }
                    }
                    LeftAlignedDetailRow("更新时间") {
                        Text(configuration.synchronizedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("成功完成一次 SSH 登录后即可读取机器配置。")
                        .foregroundStyle(.secondary)
                }

                if model.machineConfigurationSyncErrorServerID == server.id,
                   let error = model.machineConfigurationSyncError,
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

    private var credentialsAndSecurity: some View {
        GroupBox {
            DisclosureGroup(isExpanded: credentialsExpansion) {
                VStack(alignment: .leading, spacing: 14) {
                    passwordCredential
                    Divider()
                    passwordlessEvidence
                    Divider()
                    hostIdentity
                    if let log = model.retainedSSHCheckLog, log.serverID == server.id {
                        Divider()
                        sshCheckLog(log)
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack {
                    Label("凭据与安全", systemImage: "lock.shield")
                        .fontWeight(.medium)
                    Spacer()
                    Text(hostKeyRequiresAttention ? "需要核对" : credentialSummary)
                        .font(.caption)
                        .foregroundStyle(hostKeyRequiresAttention ? .orange : .secondary)
                }
            }
            .padding(.vertical, 5)
        }
    }

    private var passwordCredential: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("密码登录")
                    .fontWeight(.medium)
                Spacer()
                if model.hasStoredPassword(serverID: server.id) {
                    Label(
                        model.isPasswordSynchronizable(serverID: server.id) ? "iCloud Keychain" : "本机 Keychain",
                        systemImage: model.isPasswordSynchronizable(serverID: server.id) ? "checkmark.icloud" : "macbook"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label("未保存", systemImage: "key.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(model.hasStoredPassword(serverID: server.id) ? "更新" : "添加") {
                    model.requestPassword(for: server.id)
                }
            }
            AuthenticationCheckRow(
                title: "最近验证",
                check: server.passwordCheck,
                buttonTitle: "验证密码",
                systemImage: "lock.open",
                isDisabled: model.isBusy
            ) {
                Task { await model.checkPassword(serverID: server.id) }
            }
        }
    }

    private var passwordlessEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前 Mac 密钥")
                    .fontWeight(.medium)
                Spacer()
                AuthenticationCheckLabel(check: server.keyCheck)
            }
            if let key = model.key(for: server), key.privateKeyPath != nil {
                LeftAlignedDetailRow("密钥") { Text(model.keyDisplayName(key)) }
                LeftAlignedDetailRow("指纹") {
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Text("此 Mac 没有可用于 KeyPort 免密登录的本地私钥。")
                    .foregroundStyle(.secondary)
            }
            if let detail = server.keyCheck?.detail ?? server.statusDetail {
                Text(UserFacingText.localized(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let checkedAt = server.keyCheck?.checkedAt {
                Text("最近检测：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hostIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("主机身份")
                    .fontWeight(.medium)
                Spacer()
                if hostKeyRequiresAttention {
                    Label("需要核对", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("已确认", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            }
            if server.confirmedHostKeys.isEmpty {
                Text("尚未确认 Host Key。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.confirmedHostKeys) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(key.algorithm)
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            if let firstConfirmedAt = key.firstConfirmedAt {
                                Text("确认于 \(firstConfirmedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func sshCheckLog(_ log: SSHCheckLog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(log.title, systemImage: "terminal")
                .fontWeight(.medium)
            Text(log.lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
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
                Text(association.testCaseNodeID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("管理") {
                    associationEditorSelection = AssociationEditorSelection(testCaseNodeID: association.testCaseNodeID)
                }
            }
            if let target = association.target {
                LeftAlignedDetailRow("稳定目标") {
                    Text(target.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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

    private var deviceAuthorizations: some View {
        let authorizations = activeAuthorizations
        return GroupBox {
            DisclosureGroup(isExpanded: deviceExpansion) {
                VStack(alignment: .leading, spacing: 12) {
                    if let item = model.devicePresence(for: server) {
                        deviceConnection(item)
                        Divider()
                    }

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
                        authorizationRow(authorization)
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack {
                    Label("设备授权", systemImage: "laptopcomputer.and.arrow.down")
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(authorizations.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
        }
    }

    private func deviceConnection(_ item: DevicePresence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.name, systemImage: item.isCurrent ? "laptopcomputer" : "desktopcomputer")
                    .fontWeight(.medium)
                Spacer()
                Button {
                    model.showDevice(item.id)
                } label: {
                    Label("在设备中显示", systemImage: "arrow.right.circle")
                }
            }
            if let node = item.tailscaleNode, !node.addresses.isEmpty {
                Text(node.addresses.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(model.servers(for: item)) { account in
                HStack {
                    Label(account.username, systemImage: "person.crop.circle")
                    Text(verbatim: ":\(account.port)")
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
                        .help("在服务器中显示 \(account.username)")
                    }
                }
            }
        }
    }

    private func authorizationRow(_ authorization: Authorization) -> some View {
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
                Button {
                    model.showKey(key.id)
                } label: {
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

    private var activeAuthorizations: [Authorization] {
        model.snapshot.authorizations.filter {
            $0.serverID == server.id && !$0.isDeleted && $0.status == .authorized
        }
    }

    private var credentialSummary: String {
        model.hasStoredPassword(serverID: server.id) ? "凭据已保存" : "未保存密码"
    }

    private var hostKeyRequiresAttention: Bool {
        server.confirmedHostKeys.isEmpty
            || server.status == .hostKeyPending
            || server.status == .hostKeyMismatch
    }

    private var authorizationRequiresAttention: Bool {
        server.status == .authorizationConflict
    }

    private var credentialsExpansion: Binding<Bool> {
        Binding(
            get: { hostKeyRequiresAttention || credentialsAndSecurityExpanded },
            set: { credentialsAndSecurityExpanded = hostKeyRequiresAttention ? true : $0 }
        )
    }

    private var deviceExpansion: Binding<Bool> {
        Binding(
            get: { authorizationRequiresAttention || deviceAuthorizationsExpanded },
            set: { deviceAuthorizationsExpanded = authorizationRequiresAttention ? true : $0 }
        )
    }

    private func expandRequiredSections() {
        if hostKeyRequiresAttention {
            credentialsAndSecurityExpanded = true
        }
        if authorizationRequiresAttention {
            deviceAuthorizationsExpanded = true
        }
    }
}

private struct AssociationEditorSelection: Identifiable {
    let id = UUID()
    var testCaseNodeID: String?
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

private struct PasswordlessStatusLabel: View {
    let status: AuthorizationStatus

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var title: String {
        switch status {
        case .authorized: "免密可用"
        case .needsAuthorization: "待启用免密"
        case .missingLocalKey: "缺少本机密钥"
        case .hostKeyPending: "主机身份待确认"
        case .hostKeyMismatch: "主机身份异常"
        case .unreachable: "无法连接"
        case .passwordAuthenticationFailed: "密码验证失败"
        case .keyAuthenticationFailed: "免密验证失败"
        case .authorizationConflict: "授权冲突"
        case .syncPending: "免密待验证"
        case .checking: "正在检测免密"
        case .syncing: "正在同步免密"
        }
    }

    private var systemImage: String {
        switch status {
        case .authorized: "checkmark.shield.fill"
        case .checking, .syncing: "arrow.trianglehead.2.clockwise.rotate.90"
        case .hostKeyMismatch, .authorizationConflict: "exclamationmark.shield.fill"
        case .hostKeyPending: "questionmark.diamond.fill"
        case .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: "xmark.circle.fill"
        case .missingLocalKey: "key.slash"
        case .syncPending: "icloud"
        case .needsAuthorization: "key.horizontal"
        }
    }

    private var color: Color {
        switch status {
        case .authorized: .green
        case .checking, .syncing, .syncPending: .blue
        case .hostKeyPending, .needsAuthorization, .missingLocalKey: .orange
        case .hostKeyMismatch, .authorizationConflict, .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: .red
        }
    }
}

private struct CopyableValue: View {
    let value: String
    let help: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .monospaced()
                .textSelection(.enabled)
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(help)
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
                Text(title)
                Spacer()
                AuthenticationCheckLabel(check: check)
                Button(action: action) {
                    Label(buttonTitle, systemImage: systemImage)
                }
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
