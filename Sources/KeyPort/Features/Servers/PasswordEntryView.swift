import KeyPortCore
import SwiftUI

enum PasswordEntryPrimaryAction: Equatable, Sendable {
    case verifyPassword
    case save
    case saveAndAuthorize
}

func passwordEntryPrimaryAction(
    canAuthorize: Bool,
    validationPassed: Bool
) -> PasswordEntryPrimaryAction {
    guard validationPassed else { return .verifyPassword }
    return canAuthorize ? .saveAndAuthorize : .save
}

struct PasswordEntryView: View {
    let server: ServerConnection
    let canAuthorize: Bool
    let canSynchronize: Bool
    let isSaving: Bool
    let errorMessage: String?
    let onTest: (String, String) async -> AuthenticationCheck
    let onSave: (String, String, Bool, Bool, AuthenticationCheck) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var validationGate = PasswordSSHValidationGate()
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var pendingSave: PendingPasswordSave?

    private var currentPasswordPassed: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !isTesting &&
            validationGate.canSave
    }

    private var canTestPassword: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty
    }

    private var currentPrimaryAction: PasswordEntryPrimaryAction {
        passwordEntryPrimaryAction(
            canAuthorize: canAuthorize,
            validationPassed: currentPasswordPassed
        )
    }

    private var primaryButtonTitle: String {
        switch currentPrimaryAction {
        case .verifyPassword:
            "验证密码"
        case .save:
            "保存"
        case .saveAndAuthorize:
            "保存并授权"
        }
    }

    private var primaryButtonDisabled: Bool {
        guard !isSaving, !isTesting, pendingSave == nil else { return true }
        switch currentPrimaryAction {
        case .verifyPassword:
            return !canTestPassword
        case .save, .saveAndAuthorize:
            return false
        }
    }

    init(
        server: ServerConnection,
        canAuthorize: Bool,
        canSynchronize: Bool,
        isSaving: Bool,
        errorMessage: String?,
        onTest: @escaping (String, String) async -> AuthenticationCheck,
        onSave: @escaping (String, String, Bool, Bool, AuthenticationCheck) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.server = server
        self.canAuthorize = canAuthorize
        self.canSynchronize = canSynchronize
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onTest = onTest
        self.onSave = onSave
        self.onCancel = onCancel
        _username = State(initialValue: server.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH 用户凭据").font(.title2).fontWeight(.semibold)
                Text(verbatim: "\(server.name) · \(server.host):\(server.port)").foregroundStyle(.secondary)
            }

            Form {
                Section("凭据") {
                    TextField("用户", text: $username)
                        .textContentType(.username)
                        .disabled(isSaving || isTesting)

                    SecureField("密码", text: $password)
                        .disabled(isSaving || isTesting)
                }

                Section("密码登录验证") {
                    HStack(alignment: .center, spacing: 12) {
                        passwordTestStatus
                        Spacer()
                    }

                    if let testCheck = validationGate.check {
                        Text(testCheck.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("保存到 Keychain 前，请先验证当前用户和密码。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving || isTesting || pendingSave != nil)
                if canAuthorize {
                    Button("保存") { requestSave(authorizeAfterSave: false) }
                        .disabled(!currentPasswordPassed || isSaving || pendingSave != nil)
                }
                Button(primaryButtonTitle) {
                    performPrimaryAction()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(primaryButtonDisabled)
            }
        }
        .padding(24)
        .frame(width: 500)
        .frame(minHeight: 430)
        .sheet(item: $pendingSave) { request in
            PasswordSyncConfirmationView(
                initialSynchronizable: request.initialSynchronizable,
                onConfirm: { synchronizable in
                    pendingSave = nil
                    save(
                        authorizeAfterSave: request.authorizeAfterSave,
                        synchronizable: synchronizable
                    )
                },
                onCancel: { pendingSave = nil }
            )
        }
        .onChange(of: username) { _, _ in
            validationGate.inputChanged()
        }
        .onChange(of: password) { _, _ in
            validationGate.inputChanged()
        }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
    }

    @ViewBuilder
    private var passwordTestStatus: some View {
        if isTesting {
            Label("检查中", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.blue)
        } else if let testCheck = validationGate.check {
            switch testCheck.state {
            case .checking:
                Label("检查中", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.blue)
            case .succeeded:
                Label("已通过", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("失败", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .blocked:
                Label("已阻止", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Label("未测试", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func testPassword() {
        guard canTestPassword,
              !isSaving,
              !isTesting else { return }
        let revision = validationGate.beginTest()
        let candidateUsername = username
        let candidate = password
        isTesting = true

        testTask = Task { @MainActor in
            let result = await onTest(candidateUsername, candidate)
            guard !Task.isCancelled else { return }
            isTesting = false
            validationGate.finishTest(result, for: revision)
        }
    }

    private func performPrimaryAction() {
        switch currentPrimaryAction {
        case .verifyPassword:
            testPassword()
        case .save:
            requestSave(authorizeAfterSave: false)
        case .saveAndAuthorize:
            requestSave(authorizeAfterSave: true)
        }
    }

    private var initialSynchronizableChoice: Bool {
        UserDefaults.standard.bool(forKey: "KeyPort.defaultPasswordSync")
    }

    private func requestSave(authorizeAfterSave: Bool) {
        guard currentPasswordPassed, !isSaving, pendingSave == nil else { return }
        if canSynchronize {
            pendingSave = PendingPasswordSave(
                authorizeAfterSave: authorizeAfterSave,
                initialSynchronizable: initialSynchronizableChoice
            )
        } else {
            save(authorizeAfterSave: authorizeAfterSave, synchronizable: false)
        }
    }

    private func save(authorizeAfterSave: Bool, synchronizable: Bool) {
        guard currentPasswordPassed, let testCheck = validationGate.check else { return }
        onSave(username, password, synchronizable, authorizeAfterSave, testCheck)
    }
}

private struct PendingPasswordSave: Identifiable {
    let id = UUID()
    let authorizeAfterSave: Bool
    let initialSynchronizable: Bool
}
