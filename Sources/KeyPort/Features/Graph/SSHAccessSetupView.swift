import KeyPortCore
import SwiftUI

/// Creates or edits one connection profile, then runs passwordless setup with
/// the exact account and endpoint selected in this sheet.
struct SSHAccessSetupView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SSHAccessSetupDraft
    @State private var usesSuggestedAlias: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveAliasError: String?

    init(model: AppModel, initialDraft: SSHAccessSetupDraft) {
        self.model = model
        _draft = State(initialValue: initialDraft)
        _usesSuggestedAlias = State(initialValue: initialDraft.profileID == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("账户与网络") {
                    Picker("SSH 用户", selection: $draft.accountID) {
                        ForEach(accounts) { account in
                            Text(accountTitle(account)).tag(account.id)
                        }
                    }
                    .onChange(of: draft.accountID) { _, _ in selectionChanged() }

                    Picker("访问路径", selection: $draft.endpointID) {
                        ForEach(endpoints) { endpoint in
                            Text("\(endpoint.networkScope.displayTitle) · \(endpoint.displayAddress)")
                                .tag(endpoint.id)
                        }
                    }
                    .onChange(of: draft.endpointID) { _, _ in selectionChanged() }

                    if let endpoint = selectedEndpoint {
                        LabeledContent("网络要求", value: endpoint.networkScope.requirementTitle)
                        LabeledContent("实际目标", value: endpoint.displayAddress)
                    }
                }

                Section {
                    TextField("例如 mac-studio-tailnet-sw-jooder", text: $draft.sshAlias)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft.sshAlias) { _, newValue in
                            let suggested = suggestedAlias
                            usesSuggestedAlias = newValue.isEmpty || newValue == suggested
                            saveAliasError = nil
                            errorMessage = nil
                        }

                    HStack {
                        Button("使用建议别名") {
                            usesSuggestedAlias = true
                            draft.sshAlias = suggestedAlias
                        }
                        Spacer()
                        Text("保存时检查 KeyPort 与 ~/.ssh/config")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let aliasError {
                        Label(aliasError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("SSH 别名")
                } footer: {
                    Text("启用免密后，可直接使用 ssh \(draft.sshAlias.isEmpty ? "<别名>" : draft.sshAlias)。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button("仅保存配置") { save(authorizes: false) }
                    .disabled(!canSave || isSaving)
                Button("保存并启用免密") { save(authorizes: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(minWidth: 600, minHeight: 460)
        .navigationTitle(draft.profileID == nil ? "配置 SSH 访问" : "编辑 SSH 连接配置")
    }

    private var accounts: [SSHAccount] {
        model.sshAccounts(forNodeID: draft.nodeID)
    }

    private var endpoints: [Endpoint] {
        model.topology.endpoints(for: draft.nodeID, endpointProtocol: .ssh)
    }

    private var selectedEndpoint: Endpoint? {
        endpoints.first { $0.id == draft.endpointID }
    }

    private var suggestedAlias: String {
        model.suggestedSSHAlias(
            nodeID: draft.nodeID,
            accountID: draft.accountID,
            endpointID: draft.endpointID,
            excludingProfileID: draft.profileID
        )
    }

    private var aliasError: String? {
        model.sshAliasValidationMessage(
            draft.sshAlias,
            excludingProfileID: draft.profileID
        ) ?? saveAliasError
    }

    private var canSave: Bool {
        accounts.contains { $0.id == draft.accountID }
            && endpoints.contains { $0.id == draft.endpointID }
            && aliasError == nil
    }

    private func accountTitle(_ account: SSHAccount) -> String {
        account.label.isEmpty ? account.username : "\(account.label) · \(account.username)"
    }

    private func selectionChanged() {
        if usesSuggestedAlias {
            draft.sshAlias = suggestedAlias
        }
        saveAliasError = nil
        errorMessage = nil
    }

    private func save(authorizes: Bool) {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let profileID = try await model.saveSSHConnectionProfile(draft)
                draft.recordPersistedProfile(profileID)
                let endpoint = model.topology.endpoint(id: draft.endpointID)
                if authorizes {
                    await model.performPasswordlessPrimaryAction(
                        serverID: profileID,
                        endpoint: endpoint
                    )
                }
                dismiss()
            } catch {
                if let configError = error as? SSHConfigError,
                   case .aliasConflict = configError {
                    saveAliasError = UserFacingText.localizedError(configError)
                    errorMessage = nil
                } else {
                    errorMessage = UserFacingText.localizedError(error)
                }
                isSaving = false
            }
        }
    }
}
