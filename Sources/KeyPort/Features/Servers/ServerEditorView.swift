import KeyPortCore
import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let existingServerID: UUID?
    let hasStoredPassword: Bool
    let storedPasswordSynchronizable: Bool
    let canSynchronize: Bool
    let primaryActionTitle: String
    let offersPasswordlessSetup: Bool
    let showsNotes: Bool
    let locksServerFields: Bool
    let onCheck: (ServerDraft, String, [HostKeyRecord]) async -> ServerEditorValidationResult
    let onSave: (ServerEditorSubmission, Bool) async throws -> Void

    private let initialDraft: ServerDraft
    private let initialHostKeys: [HostKeyRecord]
    @State private var draft: ServerDraft
    @State private var password = ""
    @State private var synchronizable = false
    @State private var trustedHostKeys: [HostKeyRecord]
    @State private var validation: ServerEditorValidationResult?
    @State private var logLines: [String] = []
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var checkTask: Task<Void, Never>?

    init(
        title: String,
        existingServerID: UUID? = nil,
        initialDraft: ServerDraft = ServerDraft(),
        initialHostKeys: [HostKeyRecord] = [],
        hasStoredPassword: Bool = false,
        storedPasswordSynchronizable: Bool = false,
        canSynchronize: Bool,
        primaryActionTitle: String = "保存",
        offersPasswordlessSetup: Bool = true,
        showsNotes: Bool = true,
        locksServerFields: Bool = false,
        onCheck: @escaping (ServerDraft, String, [HostKeyRecord]) async -> ServerEditorValidationResult,
        onSave: @escaping (ServerEditorSubmission, Bool) async throws -> Void
    ) {
        self.title = title
        self.existingServerID = existingServerID
        self.hasStoredPassword = hasStoredPassword
        self.storedPasswordSynchronizable = storedPasswordSynchronizable
        self.canSynchronize = canSynchronize
        self.primaryActionTitle = primaryActionTitle
        self.offersPasswordlessSetup = offersPasswordlessSetup
        self.showsNotes = showsNotes
        self.locksServerFields = locksServerFields
        self.onCheck = onCheck
        self.onSave = onSave
        self.initialDraft = initialDraft
        self.initialHostKeys = initialHostKeys
        _draft = State(initialValue: initialDraft)
        _trustedHostKeys = State(initialValue: initialHostKeys)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal])

            Form {
                Section("服务器") {
                    TextField("名称", text: $draft.name)
                        .onChange(of: draft.name) { _, _ in
                            draft.updateSuggestedAlias()
                        }
                    TextField("主机或 IP", text: $draft.host)
                        .onChange(of: draft.host) { _, _ in invalidateValidation(resetHostKeys: true) }
                    TextField("分组", text: $draft.group)
                        .onChange(of: draft.group) { _, _ in
                            draft.updateSuggestedAlias()
                        }
                    Stepper("端口：\(draft.port)", value: $draft.port, in: 1...65_535)
                        .onChange(of: draft.port) { _, _ in invalidateValidation(resetHostKeys: true) }
                }
                .disabled(locksServerFields)

                Section("SSH 用户") {
                    TextField("用户名", text: $draft.username)
                        .onChange(of: draft.username) { _, _ in
                            draft.updateSuggestedAlias()
                            invalidateValidation()
                        }
                    TextField("SSH 别名", text: $draft.alias)
                        .textContentType(.URL)
                        .onChange(of: draft.alias) { _, _ in
                            draft.noteAliasEdit()
                        }
                }

                Section("凭据") {
                    SecureField(hasStoredPassword ? "新密码（留空则保留当前密码）" : "密码", text: $password)
                        .disabled(isChecking || isSaving)
                        .onChange(of: password) { _, _ in invalidateValidation() }

                    if hasStoredPassword && password.isEmpty {
                        Label("此次检查将使用 Keychain 中已存储的密码。", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("允许通过 iCloud Keychain 同步", isOn: $synchronizable)
                        .disabled(!canSynchronize || (!hasStoredPassword && password.isEmpty) || isChecking || isSaving)
                    if !canSynchronize {
                        Label("此版本无法使用 iCloud Keychain 同步", systemImage: "icloud.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if hasStoredPassword && password.isEmpty {
                        Label(
                            synchronizable
                                ? "保存后，当前密码将允许通过 iCloud Keychain 同步。"
                                : "保存后，当前密码将仅保存在此 Mac。",
                            systemImage: synchronizable ? "checkmark.icloud" : "macbook"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("连接测试") {
                    HStack(spacing: 12) {
                        checkStatus
                        Spacer()
                        Button {
                            checkConnection()
                        } label: {
                            Label("测试连接", systemImage: "checkmark.shield")
                        }
                        .disabled(!canCheck || isChecking || isSaving)
                    }

                    if validation?.state == .confirmationRequired {
                        hostKeyConfirmation
                    }

                    if shouldShowLog {
                        checkLog
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if showsNotes {
                    Section("备注") {
                        TextField("可选备注", text: $draft.notes, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isChecking || isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isChecking || isSaving)
                if offersPasswordlessSetup {
                    Button("仅保存") { save(enablesPasswordless: false) }
                        .disabled(!validationPassed || isChecking || isSaving)
                }
                Button(offersPasswordlessSetup ? "保存并启用免密" : primaryActionTitle) {
                    save(enablesPasswordless: offersPasswordlessSetup)
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!validationPassed || isChecking || isSaving)
            }
            .padding()
        }
        .frame(width: 620)
        .frame(minHeight: 650)
        .onAppear {
            if hasStoredPassword {
                synchronizable = storedPasswordSynchronizable
            } else if canSynchronize {
                synchronizable = UserDefaults.standard.bool(forKey: "KeyPort.defaultPasswordSync")
            }
        }
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
        }
    }

    @ViewBuilder
    private var checkStatus: some View {
        if isChecking {
            Label("正在测试连接", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.blue)
        } else if validation?.state == .succeeded {
            Label("连接测试已通过", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if validation?.state == .confirmationRequired {
            Label("需要确认主机身份", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        } else if validation?.state == .failed {
            Label("SSH 检查失败", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if metadataOnlySaveAllowed {
            Label("可直接保存资料修改", systemImage: "pencil.circle.fill")
                .foregroundStyle(.blue)
        } else {
            Label("未检查", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var hostKeyConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(trustedHostKeys.isEmpty ? "确认服务器身份" : "确认主机密钥变更")
                .fontWeight(.medium)
            Text("继续前，请将这些指纹与可信来源进行核对。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(validation?.observedHostKeys ?? []) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.algorithm).font(.caption).fontWeight(.medium)
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Button {
                trustHostKeysAndContinue()
            } label: {
                Label("信任并继续", systemImage: "checkmark.shield")
            }
            .disabled(isChecking || isSaving)
        }
    }

    private var checkLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("检查日志", systemImage: "terminal")
                .fontWeight(.medium)
            ScrollView {
                Text(logLines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 86, maxHeight: 150)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var canCheck: Bool {
        isValidDraft && (!password.isEmpty || hasStoredPassword)
    }

    private var validationPassed: Bool {
        (validation?.state == .succeeded && validation?.check.state == .succeeded)
            || metadataOnlySaveAllowed
    }

    private var metadataOnlySaveAllowed: Bool {
        existingServerID != nil
            && !isChecking
            && password.isEmpty
            && !authenticationContextChanged
            && trustedHostKeys == initialHostKeys
            && isValidDraft
    }

    private var authenticationContextChanged: Bool {
        draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            || draft.port != initialDraft.port
            || draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowLog: Bool {
        isChecking || validation?.state == .confirmationRequired || validation?.state == .failed
    }

    private var isValidDraft: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
            && KeyPortNaming.isValidAlias(draft.alias)
    }

    private func checkConnection() {
        guard canCheck, !isChecking, !isSaving else { return }
        checkTask?.cancel()
        isChecking = true
        saveError = nil
        validation = nil
        logLines = ["正在开始 SSH 检查..."]
        let candidateDraft = draft
        let candidatePassword = password
        let candidateHostKeys = trustedHostKeys

        checkTask = Task { @MainActor in
            let result = await onCheck(candidateDraft, candidatePassword, candidateHostKeys)
            guard !Task.isCancelled else { return }
            isChecking = false
            validation = result
            trustedHostKeys = result.confirmedHostKeys
            logLines = result.state == .succeeded ? [] : result.logLines
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
        checkConnection()
    }

    private func save(enablesPasswordless: Bool) {
        guard validationPassed, !isSaving else { return }
        isSaving = true
        saveError = nil
        let submission = ServerEditorSubmission(
            draft: draft,
            password: password,
            synchronizable: synchronizable,
            confirmedHostKeys: trustedHostKeys,
            passwordCheck: validation?.check,
            machineConfiguration: validation?.machineConfiguration
        )
        Task { @MainActor in
            do {
                try await onSave(submission, enablesPasswordless)
                dismiss()
            } catch {
                isSaving = false
                let message = UserFacingText.localizedError(error)
                saveError = message
                logLines.append("保存失败：\(message)")
            }
        }
    }

    private func invalidateValidation(resetHostKeys: Bool = false) {
        guard !isChecking, !isSaving else { return }
        validation = nil
        logLines = []
        saveError = nil
        if resetHostKeys { trustedHostKeys = [] }
    }
}
