import SwiftUI

/// Edits only the identity and local credential of an SSH account. Endpoints,
/// route selection and aliases are intentionally owned by SSHAccessSetupView.
struct SSHAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let nodeName: String
    let hasStoredPassword: Bool
    let canSynchronize: Bool
    let onSave: (SSHAccountEditorSubmission) async throws -> Void

    @State private var draft: SSHAccountDraft
    @State private var password = ""
    @State private var synchronizable: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        nodeName: String,
        initialDraft: SSHAccountDraft,
        hasStoredPassword: Bool,
        storedPasswordSynchronizable: Bool,
        canSynchronize: Bool,
        onSave: @escaping (SSHAccountEditorSubmission) async throws -> Void
    ) {
        self.nodeName = nodeName
        self.hasStoredPassword = hasStoredPassword
        self.canSynchronize = canSynchronize
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
        _synchronizable = State(initialValue: storedPasswordSynchronizable)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.accountID == nil ? "添加 SSH 用户" : "编辑 SSH 用户")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal])

            Form {
                Section("SSH 账户") {
                    LabeledContent("所属节点", value: nodeName)
                    TextField("账户标签（可选）", text: $draft.label)
                    TextField("SSH 用户名", text: $draft.username)
                        .textContentType(.username)
                }

                Section {
                    SecureField(passwordPrompt, text: $password)
                        .textContentType(.password)

                    if canSynchronize {
                        Toggle("通过 iCloud Keychain 同步密码", isOn: $synchronizable)
                            .disabled(password.isEmpty && !hasStoredPassword)
                    } else {
                        Label("密码仅保存在此 Mac 的 Keychain。", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if hasStoredPassword && password.isEmpty {
                        Label("留空会保留当前保存的密码。", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("账户凭据")
                } footer: {
                    Text("密码是账户级凭据；选择网络路径并启用免密时才会连接服务器进行验证。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(draft.accountID == nil ? "添加账户" : "保存账户") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(width: 520)
        .frame(minHeight: 390)
    }

    private var passwordPrompt: String {
        hasStoredPassword ? "新密码（可选）" : "密码（可选）"
    }

    private var canSave: Bool {
        !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let submission = SSHAccountEditorSubmission(
            draft: draft,
            password: password,
            synchronizable: credentialSynchronizable
        )
        Task { @MainActor in
            do {
                try await onSave(submission)
                dismiss()
            } catch {
                errorMessage = UserFacingText.localizedError(error)
                isSaving = false
            }
        }
    }

    private var credentialSynchronizable: Bool {
        if canSynchronize { return synchronizable }
        return hasStoredPassword && password.isEmpty ? synchronizable : false
    }
}
