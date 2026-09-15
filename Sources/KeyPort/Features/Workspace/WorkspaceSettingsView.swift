import SwiftUI
import KeyPortInterface

struct WorkspaceSettingsView: View {
    let store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var archive: WorkspaceArchiveFlow?
    @State private var selectingFile = false
    @State private var notice: String?

    private var syncBusy: Bool { store.syncState == .syncing || store.checkingSyncAvailability }
    private var unavailable: Bool { store.syncUnavailable != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置").font(.system(size: 20, weight: .medium))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(selectingFile)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsGroup {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("iCloud 同步").font(.system(size: 14, weight: .medium))
                                syncStatus.font(.system(size: 12)).foregroundStyle(unavailable ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            if syncBusy { ProgressView().controlSize(.small) }
                            Button("立即同步") { Task { await store.synchronize(); await store.checkSyncAvailability() } }
                                .disabled(unavailable || syncBusy)
                        }
                        Divider()
                        HStack {
                            Text("自动同步")
                            Spacer()
                            Toggle("自动同步", isOn: Binding(get: { store.syncEnabled }, set: { store.setSyncEnabled($0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(unavailable || syncBusy)
                        }
                        Text("统一连接策略使用新版同步记录；首次同步读取旧资料。请将其他 Mac 一并升级，旧版本后续修改不会直接覆盖新版策略。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(syncExplanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let issue = store.syncUnavailable, issue != .adHocSignature && issue != .missingEntitlement {
                            Button("重新检查 iCloud") { Task { await store.checkSyncAvailability() } }.disabled(syncBusy)
                        }
                        if case .failed(let message) = store.syncState, !unavailable {
                            Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    settingsGroup {
                        Text("备份与恢复").font(.system(size: 14, weight: .medium))
                        backupRow("导出加密备份", detail: "保存服务器、账户、地址和公钥授权记录。", action: "导出备份…") {
                            notice = nil; archive = WorkspaceArchiveFlow(store: store)
                        }
                        Divider()
                        backupRow("从备份导入", detail: "将备份内容合并到当前工作区。", action: "导入备份…") {
                            selectingFile = true; notice = nil
                            Task { @MainActor in
                                defer { selectingFile = false }
                                if let source = await FileSelectionService().selectArchiveForImport() {
                                    archive = WorkspaceArchiveFlow(store: store, source: source)
                                }
                            }
                        }
                    }.disabled(selectingFile)
                    Text("私钥、登录密码和本机检测结果不会同步或导出。\n导入的授权记录需要在此 Mac 重新验证。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .font(.system(size: 13)).controlSize(.regular).tint(InterfaceStyle.blue)
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(width: 640, height: 560, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(selectingFile)
        .task { await store.checkSyncAvailability() }
        .sheet(item: $archive) { flow in
            WorkspaceArchiveView(flow: flow) { result in notice = result; archive = nil }
        }
    }
    @ViewBuilder private var syncStatus: some View {
        if store.checkingSyncAvailability { Text("正在检查 iCloud…") }
        else if let issue = store.syncUnavailable {
            Text(issue == .adHocSignature || issue == .missingEntitlement ? "此版本无法使用 iCloud" : "iCloud 暂不可用")
        } else if case .succeeded(let date) = store.syncState {
            Text("已同步 · \(date.formatted(date: .omitted, time: .shortened))")
        } else { Text(store.syncState == .disabled ? (store.syncEnabled ? "等待同步" : "自动同步已关闭") : store.syncState.title) }
    }
    private var syncExplanation: String {
        if let issue = store.syncUnavailable {
            if issue == .adHocSignature || issue == .missingEntitlement { return "当前为本地构建，请使用支持 iCloud 的签名版本。" }
            return issue.localizedDescription
        }
        return "在使用同一 Apple 账户的 Mac 之间保持管理信息一致。"
    }
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.45)))
    }
    private func backupRow(_ title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
        }
    }
}

private struct WorkspaceArchiveView: View {
    @Bindable var flow: WorkspaceArchiveFlow
    let close: (String?) -> Void
    @FocusState private var passwordFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch flow.step {
            case .export:
                title("导出加密备份")
                detail("为备份设置独立密码。导入时需要此密码，KeyPort 不会保存它。")
                passwordField("备份密码", text: $flow.password).focused($passwordFocused)
                passwordField("再次输入密码", text: $flow.confirmation)
                if flow.passwordMismatch { Text("两次输入的密码不一致。").font(.caption).foregroundStyle(.red) }
                detail("包含管理信息，不包含私钥、登录密码和检测结果。")
            case .password(let source):
                title("导入备份")
                Text("已选择 \(source.lastPathComponent)").lineLimit(2).help(source.lastPathComponent)
                detail("输入导出时设置的密码以读取备份。")
                passwordField("备份密码", text: $flow.password).focused($passwordFocused)
                detail("读取后先确认合并，当前工作区暂不改变。")
            case .confirm(let source, _):
                title("将备份合并到此工作区？")
                detail("\(source.lastPathComponent) 已成功读取")
                Text("合并服务器、账户、地址和公钥授权记录。\n同一记录按现有合并规则处理，不替换整个工作区。")
                detail("私钥和本机检测结果保持本地管理。\n导入的授权记录需要在此 Mac 重新验证。")
            case .finished: EmptyView()
            }
            if let error = flow.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 12) {
                if flow.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { flow.cancel(); close(nil) }.keyboardShortcut(.cancelAction).disabled(flow.working)
                Button(actionTitle, action: advance).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!flow.canContinue)
            }
        }
        .font(.system(size: 13)).tint(InterfaceStyle.blue)
        .padding(28).frame(width: 440, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(flow.working)
        .onAppear { passwordFocused = true }
        .onDisappear { flow.cancel() }
    }
    private var actionTitle: String {
        switch flow.step {
        case .export: "选择保存位置…"
        case .password: "读取备份"
        case .confirm: "合并到工作区"
        case .finished: "完成"
        }
    }
    private func advance() {
        Task { @MainActor in
            switch flow.step {
            case .export:
                if await flow.export(selectDestination: { await FileSelectionService().selectArchiveDestination() }) { close("加密备份已导出。") }
            case .password: await flow.readImport()
            case .confirm:
                if flow.confirmImport() { close("备份已合并；导入的授权记录需要在此 Mac 重新验证。") }
            case .finished: break
            }
        }
    }
    private func title(_ text: String) -> some View { Text(text).font(.system(size: 19, weight: .medium)) }
    private func detail(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            SecureField(title, text: text).textFieldStyle(.roundedBorder).labelsHidden().disabled(flow.working)
        }
    }
}
