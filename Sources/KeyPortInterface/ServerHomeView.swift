import SwiftUI

public struct ServerHomeView: View {
    @ObservedObject private var workspace: AccessWorkspace
    @State private var formSession: AccessFormSession?
    @State private var retainedDraft: AccessFormDraft?
    @State private var notice: String?
    private let onPathAction: ((ConfiguredAccessPath, Bool) -> Void)?
    private let accessFlow: (AccessFormDraft, @escaping (AccessFormDraft) -> Void) -> AnyView
    private let previewControls: () -> AnyView
    public init(workspace: AccessWorkspace, onPathAction: ((ConfiguredAccessPath, Bool) -> Void)? = nil, previewControls: @escaping () -> AnyView = { AnyView(EmptyView()) },
                accessFlow: @escaping (AccessFormDraft, @escaping (AccessFormDraft) -> Void) -> AnyView) {
        self.onPathAction = onPathAction; self.workspace = workspace; self.previewControls = previewControls; self.accessFlow = accessFlow
    }
    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            if workspace.presentation == .graph {
                AccessGraphView(workspace: workspace, previewControls: previewControls, onAdd: { beginAdd() }, onAction: previewNotice, onConfigure: configure, onPathAction: onPathAction)
            } else {
                serverList.frame(width: 320)
                VStack(spacing: 0) {
                    HStack {
                        Text("服务器详情").foregroundStyle(.secondary); Spacer(); previewControls()
                    }.padding(.horizontal, 24).frame(height: 56).background(InterfaceStyle.color(0xF5F5F7))
                    ServerContextView(workspace: workspace, compact: false, onAction: previewNotice, onAdd: { beginAdd() }, onConfigure: configure, onPathAction: onPathAction)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.white).foregroundStyle(InterfaceStyle.ink).font(.system(size: 12))
        .sheet(item: $formSession) { session in accessFlow(session.draft, { if $0.editingEntryID == nil { retainedDraft = $0 }; formSession = nil }) }
        .alert(workspace.isSimulation ? "隔离预览" : "真实连接验收", isPresented: Binding(get: { notice != nil && formSession == nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
    }
    private var exampleDraft: AccessFormDraft {
        var draft = AccessFormDraft(); draft.description = "家里的主路由器"; draft.address = "192.168.8.1"
        draft.account = "root"; draft.password = "demo-only"; return draft
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 56)
            HStack(spacing: 10) { Image(systemName: "key").font(.system(size: 24)).foregroundStyle(InterfaceStyle.blue); Text("KeyPort").font(.system(size: 21, weight: .medium)) }.padding(18).frame(height: 68)
            Text("工作空间").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 18).frame(height: 17)
            VStack(spacing: 6) {
                navigation("服务器", "server.rack", selected: true)
                navigation("我的设备", "laptopcomputer")
                navigation("活动记录", "waveform.path.ecg")
            }.padding(12).frame(height: 160, alignment: .top)
            Text("标签").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 18).frame(height: 17)
            Text(workspace.isSimulation ? "家庭网络" : "暂无标签").foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 38)
            Spacer()
            Label(workspace.isSimulation ? "管理信息已同步" : "仅存于此 Mac", systemImage: workspace.isSimulation ? "icloud" : "internaldrive").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 36).help("当前入口未连接 iCloud")
            Button { previewNotice() } label: { Label("设置", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 38)
            Color.clear.frame(height: 60)
        }.frame(maxHeight: .infinity).background(InterfaceStyle.color(0xEDF0F2))
    }
    private func navigation(_ name: String, _ symbol: String, selected: Bool = false) -> some View {
        Button { if !selected { previewNotice() } } label: {
            Label(name, systemImage: symbol).font(.system(size: 13, weight: selected ? .medium : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(10).frame(height: 38)
                .foregroundStyle(selected ? InterfaceStyle.color(0x155ABB) : InterfaceStyle.color(0x373B43))
                .background(selected ? InterfaceStyle.color(0xDCE7F8) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
    private var serverList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("服务器").font(.system(size: 15, weight: .medium)); Text("\(workspace.graph.servers.count)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { beginAdd() } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("添加服务器").keyboardShortcut("n", modifiers: .command)
                WorkspaceViewSwitch(workspace: workspace, compact: true)
            }.padding(.horizontal, 18).frame(height: 56).background(InterfaceStyle.color(0xF5F5F7))
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceSearch(workspace: workspace)
                Text(workspace.isSimulation ? "已添加 · 示例状态" : "已保存 · 最近检测结果").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 17)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(workspace.visibleGraph.servers) { server in
                            Button { workspace.select(.server(server.id)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack").font(.system(size: 22)).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.alias).font(InterfaceStyle.technical(15, medium: true)).lineLimit(1).help(server.alias)
                                        if let description = server.visibleDescription { Text(description).font(.system(size: 12)).lineLimit(1).help(description) }
                                        Text(workspace.paths(for: server.id).isEmpty ? "暂无配置路径" : workspace.paths(for: server.id).verificationSummary)
                                            .font(.system(size: 10)).opacity(0.75)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(12).frame(height: workspace.selectedServer?.id == server.id ? 84 : 74)
                                    .foregroundStyle(workspace.selectedServer?.id == server.id ? .white : InterfaceStyle.ink)
                                    .background(workspace.selectedServer?.id == server.id ? InterfaceStyle.blue : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel("服务器 " + server.alias + (server.visibleDescription.map { "，" + $0 } ?? ""))
                        }
                        if workspace.visibleGraph.servers.isEmpty {
                            Text(workspace.graph.servers.isEmpty ? "还没有服务器" : "没有匹配的服务器").foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(12)
            Button { beginAdd() } label: { Label("添加或导入服务器", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 54) }
                .buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue).background(InterfaceStyle.color(0xF5F5F7))
        }.background(InterfaceStyle.color(0xFBFBFC))
    }
    private func beginAdd() { formSession = AccessFormSession(draft: retainedDraft ?? (workspace.isSimulation ? exampleDraft : AccessFormDraft())) }
    private func configure(_ draft: AccessFormDraft) { formSession = AccessFormSession(draft: draft) }
    private func previewNotice() { notice = workspace.isSimulation ? "隔离示例：未连接真实服务器，也不会打开终端或更改本机配置。" : "此入口先验收服务器访问流程；此功能尚未接入。" }
}

struct WorkspaceViewSwitch: View {
    @ObservedObject var workspace: AccessWorkspace
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Button("列表") { workspace.presentation = .list }.keyboardShortcut("1", modifiers: .command)
                .frame(maxWidth: .infinity).frame(height: compact ? 22 : 24).background(workspace.presentation == .list ? .white : .clear, in: RoundedRectangle(cornerRadius: 4))
            Button("拓扑") { workspace.presentation = .graph }.keyboardShortcut("2", modifiers: .command)
                .frame(maxWidth: .infinity).frame(height: compact ? 22 : 24).background(workspace.presentation == .graph ? .white : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).font(.system(size: compact ? 11 : 12)).padding(3).frame(width: compact ? 116 : 152)
            .background(InterfaceStyle.color(0xE7EAF0), in: RoundedRectangle(cornerRadius: 6))
    }
}
struct WorkspaceSearch: View {
    @ObservedObject var workspace: AccessWorkspace
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            TextField("搜索别名或描述", text: $workspace.query).textFieldStyle(.plain).accessibilityLabel("搜索别名或描述")
                .onSubmit { workspace.selectSearchResult() }
        }.foregroundStyle(.secondary).padding(8).frame(height: 32)
            .background(InterfaceStyle.color(0xECEEF1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AccessFormSession: Identifiable {
    let id = UUID()
    let draft: AccessFormDraft
}
