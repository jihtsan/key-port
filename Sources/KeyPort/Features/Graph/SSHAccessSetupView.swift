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

                    Picker("路径策略", selection: $draft.routeMode) {
                        ForEach(SSHAccessRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .onChange(of: draft.routeMode) { _, _ in routeModeChanged() }

                    if draft.routeMode == .fixed {
                        Picker("固定访问路径", selection: $draft.endpointID) {
                            ForEach(endpoints) { endpoint in
                                Text("\(endpoint.networkScope.displayTitle) · \(endpoint.displayAddress)")
                                    .tag(endpoint.id)
                            }
                        }
                        .onChange(of: draft.endpointID) { _, _ in selectionChanged() }
                    } else {
                        Picker("网络范围", selection: networkScopeSelection) {
                            Text("不限").tag(Self.anyNetworkScope)
                            ForEach(NetworkScope.allCases, id: \.self) { scope in
                                Text(scope.displayTitle).tag(scope.rawValue)
                            }
                        }
                        .onChange(of: draft.automaticNetworkScope) { _, _ in networkScopeChanged() }

                        Toggle("限制为有序候选路径", isOn: explicitCandidateSelection)

                        if draft.candidateEndpointIDs.isEmpty {
                            Text("自动路径会在连接前按当前网络证据和路径优先级选择所有符合条件的地址。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("转为有序候选路径") {
                                materializeCandidates()
                            }
                        } else {
                            candidatePathEditor
                        }

                        Picker("预览 / 授权路径", selection: $draft.endpointID) {
                            ForEach(previewEndpoints) { endpoint in
                                Text("\(endpoint.networkScope.displayTitle) · \(endpoint.displayAddress)")
                                    .tag(endpoint.id)
                            }
                        }
                        .onChange(of: draft.endpointID) { _, _ in selectionChanged() }
                    }

                    if let routeError {
                        Label(routeError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let endpoint = selectedEndpoint {
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
        .frame(minWidth: 640, minHeight: draft.routeMode == .automatic ? 620 : 460)
        .navigationTitle(draft.profileID == nil ? "配置 SSH 访问" : "编辑 SSH 连接配置")
    }

    private static let anyNetworkScope = "any"

    private var accounts: [SSHAccount] {
        model.sshAccounts(forNodeID: draft.nodeID)
    }

    private var endpoints: [Endpoint] {
        model.topology.endpoints(for: draft.nodeID, endpointProtocol: .ssh)
    }

    private var selectedEndpoint: Endpoint? {
        endpoints.first { $0.id == draft.endpointID }
    }

    private var scopedEndpoints: [Endpoint] {
        guard draft.routeMode == .automatic,
              let scope = draft.automaticNetworkScope else {
            return endpoints
        }
        return endpoints.filter { $0.networkScope == scope }
    }

    private var previewEndpoints: [Endpoint] {
        if !draft.candidateEndpointIDs.isEmpty {
            return draft.candidateEndpointIDs.compactMap { candidateID in
                endpoints.first { $0.id == candidateID }
            }
        }
        return scopedEndpoints
    }

    private var orderedCandidateEndpoints: [Endpoint] {
        draft.candidateEndpointIDs.compactMap { candidateID in
            endpoints.first { $0.id == candidateID }
        }
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

    private var networkScopeSelection: Binding<String> {
        Binding(
            get: { draft.automaticNetworkScope?.rawValue ?? Self.anyNetworkScope },
            set: { rawValue in
                draft.automaticNetworkScope = rawValue == Self.anyNetworkScope
                    ? nil
                    : NetworkScope(rawValue: rawValue)
            }
        )
    }

    private var explicitCandidateSelection: Binding<Bool> {
        Binding(
            get: { !draft.candidateEndpointIDs.isEmpty },
            set: { enabled in
                if enabled {
                    materializeCandidates()
                } else {
                    draft.candidateEndpointIDs = []
                    normalizePreviewEndpoint()
                }
                selectionChanged()
            }
        )
    }

    private var canSave: Bool {
        accounts.contains { $0.id == draft.accountID }
            && previewEndpoints.contains { $0.id == draft.endpointID }
            && routeError == nil
            && aliasError == nil
    }

    private var routeError: String? {
        guard draft.routeMode == .automatic else { return nil }
        if let scope = draft.automaticNetworkScope,
           let endpoint = selectedEndpoint,
           endpoint.networkScope != scope {
            return "预览路径不符合当前网络范围要求。"
        }
        let endpointIDs = Set(endpoints.map(\.id))
        if draft.candidateEndpointIDs.contains(where: { !endpointIDs.contains($0) }) {
            return "候选路径中包含已删除或不属于当前节点的地址，请重新选择。"
        }
        if !draft.candidateEndpointIDs.isEmpty
            && !draft.candidateEndpointIDs.contains(draft.endpointID) {
            return "预览路径必须包含在候选顺序中。"
        }
        return nil
    }

    @ViewBuilder
    private var candidatePathEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("候选路径顺序")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(orderedCandidateEndpoints.enumerated()), id: \.element.id) { index, endpoint in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.label)
                            .lineLimit(1)
                        Text(endpoint.displayAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        moveCandidate(endpoint.id, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    Button {
                        moveCandidate(endpoint.id, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == orderedCandidateEndpoints.count - 1)
                    Button {
                        removeCandidate(endpoint.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("移出候选路径")
                }
            }

            Divider()

            Text("可加入的 SSH 路径")
                .font(.subheadline.weight(.semibold))
            ForEach(scopedEndpoints) { endpoint in
                Toggle(isOn: candidateBinding(for: endpoint.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.label)
                            .lineLimit(1)
                        Text(endpoint.displayAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 4)
    }

    private func accountTitle(_ account: SSHAccount) -> String {
        account.label.isEmpty ? account.username : "\(account.label) · \(account.username)"
    }

    private func candidateBinding(for endpointID: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.candidateEndpointIDs.contains(endpointID) },
            set: { enabled in
                if enabled {
                    if !draft.candidateEndpointIDs.contains(endpointID) {
                        draft.candidateEndpointIDs.append(endpointID)
                    }
                } else {
                    draft.candidateEndpointIDs.removeAll { $0 == endpointID }
                    normalizePreviewEndpoint()
                }
                selectionChanged()
            }
        )
    }

    private func materializeCandidates() {
        let current = Set(draft.candidateEndpointIDs)
        let additions = scopedEndpoints
            .filter { !current.contains($0.id) }
            .map(\.id)
        draft.candidateEndpointIDs.append(contentsOf: additions)
        normalizePreviewEndpoint()
    }

    private func removeCandidate(_ endpointID: UUID) {
        draft.candidateEndpointIDs.removeAll { $0 == endpointID }
        normalizePreviewEndpoint()
        selectionChanged()
    }

    private func moveCandidate(_ endpointID: UUID, offset: Int) {
        guard let index = draft.candidateEndpointIDs.firstIndex(of: endpointID) else { return }
        let target = index + offset
        guard draft.candidateEndpointIDs.indices.contains(target) else { return }
        draft.candidateEndpointIDs.swapAt(index, target)
        draft.endpointID = endpointID
        selectionChanged()
    }

    private func normalizePreviewEndpoint() {
        if !previewEndpoints.contains(where: { $0.id == draft.endpointID }) {
            draft.endpointID = previewEndpoints.first?.id ?? endpoints.first?.id ?? draft.endpointID
        }
    }

    private func routeModeChanged() {
        if draft.routeMode == .fixed {
            draft.candidateEndpointIDs = []
            draft.automaticNetworkScope = nil
            if !endpoints.contains(where: { $0.id == draft.endpointID }) {
                draft.endpointID = endpoints.first?.id ?? draft.endpointID
            }
        } else {
            normalizePreviewEndpoint()
        }
        selectionChanged()
    }

    private func networkScopeChanged() {
        if draft.routeMode == .automatic, !draft.candidateEndpointIDs.isEmpty {
            let scope = draft.automaticNetworkScope
            draft.candidateEndpointIDs = draft.candidateEndpointIDs.filter { candidateID in
                guard let scope else { return true }
                return endpoints.contains {
                    $0.id == candidateID && $0.networkScope == scope
                }
            }
        }
        normalizePreviewEndpoint()
        selectionChanged()
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
