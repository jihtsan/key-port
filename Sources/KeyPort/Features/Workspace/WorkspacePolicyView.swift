import SwiftUI
import KeyPortCore
import KeyPortInterface

struct WorkspacePolicyView: View {
    let store: WorkspaceStore
    let connection: WorkspaceStore.Connection
    @Environment(\.dismiss) private var dismiss
    @State private var endpoints: [UUID] = []
    @State private var automatic = false
    @State private var notice: String?
    @State private var verifying = false
    @State private var verificationTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("连接策略 · " + connection.alias).font(.title2); Spacer(); Button("完成") { dismiss() }.disabled(verifying) }
            Text("ssh " + connection.alias).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            Picker("连接方式", selection: $automatic) {
                Text("固定第一条地址").tag(false)
                Text("按顺序自动回退").tag(true)
            }.pickerStyle(.segmented)
            Text("仅在 DNS 或 TCP 连接失败时尝试下一条。主机身份、SSH 登录失败时停止；已建立的会话不切换。")
                .foregroundStyle(.secondary)
            List(Array(endpoints.enumerated()), id: \.element) { index, id in
                if let endpoint = store.topology.activeEndpoints.first(where: { $0.id == id }) {
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(endpoint.address + ":" + String(endpoint.port)).font(.system(.body, design: .monospaced))
                            Text(store.state.connections.first { $0.endpointID == id && $0.account == connection.account && $0.alias == connection.alias }?.verification == "verified" ? "本机已验证" : "待验证 · 暂不参与连接").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("上移") { endpoints.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("下移") { endpoints.swapAt(index, index + 1) }.disabled(index + 1 == endpoints.count)
                    }.padding(.vertical, 4)
                }
            }
            if let notice { Text(notice).textSelection(.enabled).foregroundStyle(.secondary) }
            HStack {
                Button(verifying ? "正在验证…" : "保存并验证全部地址") { verifyAll() }
                Spacer()
                Button("保存策略") {
                    do { try save(); dismiss() } catch { notice = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 760, height: 520).disabled(verifying)
        .onAppear {
            if let id = connection.profileID {
                endpoints = store.policyEndpoints(id)
                automatic = store.topology.activeConnectionProfiles.first { $0.id == id }?.routePolicy.fixedEndpointID == nil
            }
        }
        .onDisappear { verificationTask?.cancel() }
    }
    private func save() throws {
        guard let id = connection.profileID else { throw WorkspaceError.configuration }
        // Resolve the canonical profile after a previous save merged legacy profiles.
        let account = store.topology.activeAccounts.first { $0.nodeID.uuidString == connection.serverID && $0.username == connection.account }
        let current = store.topology.activeConnectionProfiles.first { $0.id == id || ($0.sshAlias == connection.alias && $0.accountID == account?.id) }
        guard let profile = current else { throw WorkspaceError.configuration }
        try store.updatePolicy(profileID: profile.id, endpoints: endpoints, automatic: automatic)
    }
    private func verifyAll() {
        verificationTask = Task { @MainActor in
            verifying = true; defer { verifying = false }
            do {
                try save()
                var passed = 0, failed = 0
                for id in endpoints {
                    try Task.checkCancellation()
                    guard let c = store.state.connections.first(where: { $0.endpointID == id && $0.account == connection.account && $0.alias == connection.alias }),
                          let path = store.workspace.graph.paths.first(where: { $0.id == c.id }), var draft = store.workspace.accessDraft(for: path),
                          let key = store.state.keys.first(where: { $0.id == c.keyID }), let privatePath = key.privateKeyPath else { failed += 1; continue }
                    let adapter = OpenSSHFirstAccessAdapter(store: store, expectedServerID: c.serverID)
                    defer { adapter.cancel() }
                    do {
                        let trustedPins = Set(store.state.trusts.filter { $0.serverID == c.serverID }.map(\.key.fingerprint))
                        let identity = try await adapter.inspectHost(address: c.address, port: String(c.port))
                        if identity.needsConfirmation {
                            guard trustedPins == [identity.fingerprint] else { throw AccessFlowFailure.identityMismatch }
                            try await adapter.confirmHost(identity)
                        }
                        draft.existingKey = true; draft.privateKeyPath = privatePath
                        try await adapter.login(draft: draft, identity: identity)
                        _ = try await adapter.authorizationStatus(for: path.authorizationKey)
                        try await adapter.verify(path.authorizationKey, address: c.address, port: String(c.port))
                        passed += 1
                    } catch {
                        failed += 1
                        let mismatch = (error as? AccessFlowFailure) == .identityMismatch
                        try store.checked(c.id, success: false, unreachable: (error as? AccessFlowFailure) == .unreachable, identityMismatch: mismatch)
                        if mismatch { throw error }
                    }
                }
                notice = "验证完成：\(passed) 个通过，\(failed) 个未通过。"
            } catch { notice = "操作停止：" + error.localizedDescription }
        }
    }
}
