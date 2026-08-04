import KeyPortCore
import SwiftUI

struct PasswordEntryView: View {
    let server: ServerConnection
    let canAuthorize: Bool
    let canSynchronize: Bool
    let isSaving: Bool
    let errorMessage: String?
    let onTest: (String) async -> AuthenticationCheck
    let onSave: (String, Bool, Bool, AuthenticationCheck) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var synchronizable = false
    @State private var validationGate = PasswordSSHValidationGate()
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?

    private var currentPasswordPassed: Bool {
        !password.isEmpty &&
            !isTesting &&
            validationGate.canSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Password").font(.title2).fontWeight(.semibold)
                Text(verbatim: "\(server.name) · \(server.host):\(server.port)").foregroundStyle(.secondary)
            }

            Form {
                SecureField("Password", text: $password)
                    .disabled(isSaving || isTesting)

                Section("Password SSH Test") {
                    HStack(alignment: .center, spacing: 12) {
                        passwordTestStatus
                        Spacer()
                        Button {
                            testPassword()
                        } label: {
                            Label("Test Password SSH", systemImage: "lock.open")
                        }
                        .disabled(password.isEmpty || isSaving || isTesting)
                    }

                    if let testCheck = validationGate.check {
                        Text(testCheck.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Test the current password before saving it to Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Allow iCloud Keychain sync", isOn: $synchronizable)
                    .disabled(!canSynchronize || isSaving || isTesting)
                if !canSynchronize {
                    Label("iCloud Keychain sync is unavailable in this build", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving || isTesting)
                if canAuthorize {
                    Button("Save") { save(authorizeAfterSave: false) }
                        .disabled(!currentPasswordPassed || isSaving)
                    Button("Save and Authorize") { save(authorizeAfterSave: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!currentPasswordPassed || isSaving)
                } else {
                    Button("Save") { save(authorizeAfterSave: false) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!currentPasswordPassed || isSaving)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .frame(minHeight: 430)
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
            Label("Checking", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.blue)
        } else if let testCheck = validationGate.check {
            switch testCheck.state {
            case .checking:
                Label("Checking", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.blue)
            case .succeeded:
                Label("Passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .blocked:
                Label("Blocked", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Not tested", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func testPassword() {
        guard !password.isEmpty, !isSaving, !isTesting else { return }
        let revision = validationGate.beginTest()
        let candidate = password
        isTesting = true

        testTask = Task { @MainActor in
            let result = await onTest(candidate)
            guard !Task.isCancelled else { return }
            isTesting = false
            validationGate.finishTest(result, for: revision)
        }
    }

    private func save(authorizeAfterSave: Bool) {
        guard currentPasswordPassed, let testCheck = validationGate.check else { return }
        onSave(password, synchronizable, authorizeAfterSave, testCheck)
    }
}
