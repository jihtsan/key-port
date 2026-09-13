import KeyPortCore
import SwiftUI

enum ServerAccessFormPhase: Equatable {
    case idle
    case checking
    case hostKeyConfirmation
    case authorizing
    case succeeded
    case failed

    var isRunning: Bool {
        self == .checking || self == .authorizing
    }
}

/// The single first-access form. It validates the password and host identity,
/// then immediately persists the profile and verifies this Mac's key without a
/// second save button or an artificial delay.
struct ServerAccessFormView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let canSynchronize: Bool
    let onCheck: (ServerDraft, String, [HostKeyRecord]) async -> ServerEditorValidationResult
    let onSave: (ServerEditorSubmission) async throws -> UUID
    let onOpenTerminal: (UUID) -> Bool
    let onCopyCommand: (UUID) -> Bool

    @State private var draft: ServerDraft
    @State private var portText: String
    @State private var password = ""
    @State private var savePassword = false
    @State private var synchronizable = false
    @State private var trustedHostKeys: [HostKeyRecord]
    @State private var validation: ServerEditorValidationResult?
    @State private var logLines: [String] = []
    @State private var phase: ServerAccessFormPhase = .idle
    @State private var errorMessage: String?
    @State private var savedServerID: UUID?
    @State private var copyMessage: String?
    @State private var terminalMessage: String?
    @State private var operationTask: Task<Void, Never>?

    init(
        title: String,
        initialDraft: ServerDraft = ServerDraft(),
        canSynchronize: Bool,
        onCheck: @escaping (ServerDraft, String, [HostKeyRecord]) async -> ServerEditorValidationResult,
        onSave: @escaping (ServerEditorSubmission) async throws -> UUID,
        onOpenTerminal: @escaping (UUID) -> Bool,
        onCopyCommand: @escaping (UUID) -> Bool
    ) {
        self.title = title
        self.canSynchronize = canSynchronize
        self.onCheck = onCheck
        self.onSave = onSave
        self.onOpenTerminal = onOpenTerminal
        self.onCopyCommand = onCopyCommand
        _draft = State(initialValue: initialDraft)
        _portText = State(initialValue: String(initialDraft.port))
        _trustedHostKeys = State(initialValue: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            if let savedServerID, phase == .succeeded {
                successView(serverID: savedServerID)
            } else {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.top, .horizontal])

                Form {
                    Section("服务器") {
                        TextField("名称", text: $draft.name)
                            .onChange(of: draft.name) { _, _ in
                                draft.updateSuggestedAlias()
                                invalidateValidation()
                            }

                        HStack {
                            TextField("地址或主机名", text: $draft.host)
                                .onChange(of: draft.host) { _, _ in
                                    invalidateValidation(resetHostKeys: true)
                                }
                            TextField("端口", text: $portText)
                                .frame(width: 92)
                                .onChange(of: portText) { _, value in
                                    updatePort(from: value)
                                }
                        }
                    }

                    Section("SSH 账户") {
                        TextField("登录账户", text: $draft.username)
                            .onChange(of: draft.username) { _, _ in
                                draft.updateSuggestedAlias()
                                invalidateValidation()
                            }

                        SecureField("首次授权密码", text: $password)
                            .disabled(phase.isRunning)
                            .onChange(of: password) { _, _ in
                                invalidateValidation()
                            }
                        Text("密码只用于本次验证；默认不会保存到 Keychain。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("保存密码供以后使用", isOn: $savePassword)
                            .onChange(of: savePassword) { _, enabled in
                                if !enabled { synchronizable = false }
                            }
                        if savePassword {
                            if canSynchronize {
                                Toggle("使用 iCloud Keychain 同步", isOn: $synchronizable)
                            } else {
                                Label("当前签名不支持 iCloud Keychain，将仅保存到此 Mac。", systemImage: "lock.laptopcomputer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        DisclosureGroup("高级选项") {
                            TextField("SSH 别名", text: $draft.alias)
                                .textContentType(.URL)
                                .onChange(of: draft.alias) { _, _ in
                                    draft.noteAliasEdit()
                                    invalidateValidation()
                                }
                            TextField("分组", text: $draft.group)
                                .onChange(of: draft.group) { _, _ in
                                    draft.updateSuggestedAlias()
                                    invalidateValidation()
                                }
                            TextField("备注", text: $draft.notes, axis: .vertical)
                                .lineLimit(2...4)
                                .onChange(of: draft.notes) { _, _ in invalidateValidation() }
                        }
                    }

                    Section("连接与授权") {
                        progressPanel

                        if phase == .hostKeyConfirmation {
                            hostKeyConfirmation
                        }

                        if !logLines.isEmpty {
                            checkLog
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(phase.isRunning)

                Divider()
                HStack {
                    if phase.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("取消", role: .cancel) {
                        cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase.isRunning)

                    Button(primaryActionTitle) {
                        if phase == .hostKeyConfirmation {
                            trustHostKeysAndContinue()
                        } else {
                            beginCheck()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canBeginCheck || phase.isRunning)
                }
                .padding()
            }
        }
        .frame(width: 640)
        .frame(minHeight: 700)
        .interactiveDismissDisabled(phase.isRunning)
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
            password = ""
        }
    }

    private var canBeginCheck: Bool {
        isValidDraft && !password.isEmpty
    }

    private var isValidDraft: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(draft.port)
            && KeyPortNaming.isValidAlias(draft.alias)
    }

    private var primaryActionTitle: String {
        switch phase {
        case .hostKeyConfirmation:
            "确认身份并继续"
        case .failed:
            "重新连接并授权"
        default:
            "连接并启用免密"
        }
    }

    @ViewBuilder
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("一次完成首次访问", systemImage: "lock.shield")
                    .font(.headline)
                Spacer()
                if phase.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            progressRow("验证地址、端口和密码", state: passwordStepState)
            progressRow("确认服务器主机身份", state: hostKeyStepState)
            progressRow("安装并复检当前 Mac 公钥", state: authorizationStepState)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func progressRow(_ title: String, state: ProgressRowState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .foregroundStyle(state.tint)
                .frame(width: 18)
            Text(title)
                .font(.callout)
            if state == .active {
                Spacer()
                Text("进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passwordStepState: ProgressRowState {
        switch phase {
        case .idle: .pending
        case .checking: .active
        case .hostKeyConfirmation, .authorizing, .succeeded: .complete
        case .failed: .failed
        }
    }

    private var hostKeyStepState: ProgressRowState {
        switch phase {
        case .idle, .checking: .pending
        case .hostKeyConfirmation: .active
        case .authorizing, .succeeded: .complete
        case .failed: validation?.state == .confirmationRequired ? .failed : .pending
        }
    }

    private var authorizationStepState: ProgressRowState {
        switch phase {
        case .idle, .checking, .hostKeyConfirmation: .pending
        case .authorizing: .active
        case .succeeded: .complete
        case .failed: .failed
        }
    }

    private var hostKeyConfirmation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("核对服务器身份")
                .font(.callout.weight(.medium))
            Text("请将下面的指纹与可信来源核对。确认后会继续密码验证和公钥授权。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(validation?.observedHostKeys ?? []) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.algorithm)
                        .font(.caption.weight(.medium))
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 6)
    }

    private var checkLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("操作记录", systemImage: "list.bullet.rectangle")
                .font(.callout.weight(.medium))
            ScrollView {
                Text(logLines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(minHeight: 74, maxHeight: 150)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func successView(serverID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("服务器已连接并启用免密", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Text("密码登录、主机身份确认和当前 Mac 的公钥复检均已完成。")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    terminalMessage = onOpenTerminal(serverID)
                        ? "已请求系统默认终端打开 SSH 连接。"
                        : "无法打开系统默认终端。请确认 macOS 已配置 ssh:// 链接处理程序。"
                } label: {
                    Label("在终端中打开", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    copyMessage = onCopyCommand(serverID)
                        ? "SSH 命令已复制到剪贴板。"
                        : "复制失败，剪贴板没有接受这条命令。"
                } label: {
                    Label("复制 SSH 命令", systemImage: "doc.on.doc")
                }
            }

            if let terminalMessage {
                Label(terminalMessage, systemImage: terminalMessage.hasPrefix("已") ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(terminalMessage.hasPrefix("已") ? Color.green : Color.red)
            }
            if let copyMessage {
                Label(copyMessage, systemImage: copyMessage.hasPrefix("SSH") ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(copyMessage.hasPrefix("SSH") ? Color.green : Color.red)
            }

            Spacer(minLength: 12)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func beginCheck() {
        guard canBeginCheck, !phase.isRunning else { return }
        operationTask?.cancel()
        validation = nil
        errorMessage = nil
        copyMessage = nil
        terminalMessage = nil
        logLines = ["正在开始 SSH 检查..."]
        phase = .checking

        let candidateDraft = draft
        let candidatePassword = password
        let candidateHostKeys = trustedHostKeys
        operationTask = Task { @MainActor in
            let result = await onCheck(candidateDraft, candidatePassword, candidateHostKeys)
            guard !Task.isCancelled else { return }
            validation = result
            trustedHostKeys = result.confirmedHostKeys
            logLines = result.logLines

            switch result.state {
            case .confirmationRequired:
                phase = .hostKeyConfirmation
            case .failed:
                phase = .failed
                errorMessage = result.check.detail
                password = ""
            case .succeeded:
                phase = .authorizing
                await save(result: result, password: candidatePassword)
            }
        }
    }

    private func trustHostKeysAndContinue() {
        guard let observed = validation?.observedHostKeys, !observed.isEmpty else { return }
        let now = Date()
        trustedHostKeys = observed.map { key in
            HostKeyRecord(
                algorithm: key.algorithm,
                fingerprint: key.fingerprint,
                knownHostsLine: key.knownHostsLine,
                firstConfirmedAt: key.firstConfirmedAt ?? now,
                lastSeenAt: now
            )
        }
        beginCheck()
    }

    private func save(result: ServerEditorValidationResult, password passwordValue: String) async {
        let submission = ServerEditorSubmission(
            draft: draft,
            password: passwordValue,
            synchronizable: savePassword && canSynchronize && synchronizable,
            savePassword: savePassword,
            confirmedHostKeys: trustedHostKeys,
            passwordCheck: result.check,
            machineConfiguration: result.machineConfiguration
        )
        do {
            let serverID = try await onSave(submission)
            guard !Task.isCancelled else { return }
            savedServerID = serverID
            self.password = ""
            phase = .succeeded
        } catch is CancellationError {
            self.password = ""
        } catch {
            guard !Task.isCancelled else { return }
            let message = UserFacingText.localizedError(error)
            errorMessage = message
            logLines.append("授权失败：\(message)")
            self.password = ""
            phase = .failed
        }
    }

    private func updatePort(from value: String) {
        let digits = value.filter(\.isNumber)
        if digits != value { portText = digits }
        draft.port = Int(digits) ?? 0
        invalidateValidation(resetHostKeys: true)
    }

    private func invalidateValidation(resetHostKeys: Bool = false) {
        guard !phase.isRunning else { return }
        validation = nil
        errorMessage = nil
        logLines = []
        phase = .idle
        if resetHostKeys { trustedHostKeys = [] }
    }

    private func cancel() {
        guard !phase.isRunning else { return }
        operationTask?.cancel()
        operationTask = nil
        password = ""
        dismiss()
    }
}

private enum ProgressRowState: Equatable {
    case pending
    case active
    case complete
    case failed

    var systemImage: String {
        switch self {
        case .pending: "circle"
        case .active: "arrow.trianglehead.2.clockwise.rotate.90"
        case .complete: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .active: .blue
        case .complete: .green
        case .failed: .red
        }
    }
}
