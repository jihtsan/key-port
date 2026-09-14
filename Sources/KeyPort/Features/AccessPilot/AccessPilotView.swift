import SwiftUI
import KeyPortInterface

@MainActor enum AccessPilotRuntime {
    static var enabled: Bool { Bundle.main.bundleIdentifier == "com.jihtsan.KeyPort.AccessPilot" }
}

struct AccessPilotRoot: View {
    @State private var store: AccessPilotStore?
    @State private var error: String?
    var body: some View {
        Group {
            if let store { AccessPilotHome(store: store) }
            else {
                VStack(spacing: 16) {
                    Text("KeyPort · 真实连接验收").font(.title2)
                    Text(error ?? "正在读取本地验收工作区…")
                }.padding(40)
            }
        }.task {
            guard store == nil && error == nil else { return }
            InterfaceStyle.registerFonts()
            do { store = try AccessPilotStore() }
            catch AccessPilotError.alreadyOpen { error = "验收工作区已在另一个窗口或进程中打开，请先关闭它。" }
            catch { self.error = "无法读取本地验收工作区；为保护已有配置，未创建空白替代数据。" }
        }
    }
}

private struct AccessPilotHome: View {
    let store: AccessPilotStore
    @State private var notice: String?
    @State private var checking = false
    @State private var pathTask: Task<Void, Never>?
    var body: some View {
        ServerHomeView(workspace: store.workspace, onPathAction: act, previewControls: {
            AnyView(Text(checking ? "正在测试路径…" : "真实连接验收 · 仅此 Mac").font(.system(size: 11)).foregroundStyle(.secondary))
        }) { draft, close in AnyView(AccessPilotFlowView(store: store, draft: draft, close: close)) }
        .alert("连接结果", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
        .onDisappear { pathTask?.cancel() }
    }
    private func act(_ path: ConfiguredAccessPath, test: Bool) {
        guard !checking, let connection = store.state.connections.first(where: { $0.id == path.id }),
              let draft = store.workspace.accessDraft(for: path) else { return }
        checking = true
        pathTask = Task { @MainActor in
            defer { checking = false }
            let adapter = OpenSSHFirstAccessAdapter(store: store, expectedServerID: path.serverID)
            defer { adapter.cancel() }
            do {
                if test {
                    let identity = try await adapter.inspectHost(address: path.address, port: String(path.port))
                    guard !identity.needsConfirmation else { throw AccessFlowFailure.identityMismatch }
                    var input = draft; input.existingKey = true
                    input.privateKeyPath = store.state.keys.first(where: { $0.id == connection.keyID })?.privateKeyPath ?? ""
                    try await adapter.login(draft: input, identity: identity)
                    let key = path.authorizationKey
                    _ = try await adapter.authorizationStatus(for: key)
                    try await adapter.verify(key, address: path.address, port: String(path.port))
                    notice = "当前路径已通过主机身份与免密登录验证。"
                } else {
                    let command = try store.command(for: connection)
                    try await OpenSSHFirstAccessAdapter.handoff(command, directory: store.paths.applicationSupport)
                    notice = "已请求打开终端；SSH 会话结果请在终端查看。"
                }
            } catch {
                if test { try? store.checked(path.id, success: false, unreachable: (error as? AccessFlowFailure) == .unreachable) }
                notice = test ? "路径验证未通过。请打开连接设置检查；身份不匹配时不会自动继续。" : "终端交接失败，请在配置成功页复制命令。"
            }
        }
    }
}

private struct AccessPilotFlowView: View {
    let store: AccessPilotStore
    let draft: AccessFormDraft
    let close: (AccessFormDraft) -> Void
    @State private var adapter: OpenSSHFirstAccessAdapter
    @StateObject private var flow: FirstAccessFlow
    @State private var storageError = false
    init(store: AccessPilotStore, draft: AccessFormDraft, close: @escaping (AccessFormDraft) -> Void) {
        self.store = store; self.draft = draft; self.close = close
        let adapter = OpenSSHFirstAccessAdapter(store: store, expectedServerID: draft.editingEntryID)
        _adapter = State(initialValue: adapter)
        _flow = StateObject(wrappedValue: FirstAccessFlow(draft: draft, adapter: adapter, aliasDirectory: store.aliases))
    }
    var body: some View {
        FirstAccessView(flow: flow, initialDraft: draft, onClose: { close(flow.state == .success ? AccessFormDraft() : $0) }) { EmptyView() }
            .onChange(of: flow.state) { _, state in
                if case .failed(let failure) = state {
                    do { try adapter.recordFailure(failure) } catch { storageError = true }
                }
            }
            .alert("检测结果未保存", isPresented: $storageError) { Button("好") {} }
                message: { Text("本次操作失败，且本地存储未能更新。已有记录不代表本次检测成功。") }
    }
}
