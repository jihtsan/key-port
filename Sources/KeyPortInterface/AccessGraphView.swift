import SwiftUI

/// Geometry is a view projection of stable server IDs, never of accounts or addresses.
struct DirectGraphLayout {
    let projection: DirectAccessProjection
    let width: CGFloat = 824
    var expandedServerIDs: Set<String> = []
    func paths(for id: String) -> [ConfiguredAccessPath] {
        projection.paths.filter { $0.serverID == id }.sorted { $0.id < $1.id }
    }
    func isCollapsed(_ id: String) -> Bool { paths(for: id).count > 3 && !expandedServerIDs.contains(id) }
    func blockHeight(_ id: String) -> CGFloat { isCollapsed(id) ? 210 : max(210, CGFloat(paths(for: id).count) * 80 - 30) }
    var height: CGFloat { max(764, projection.servers.reduce(CGFloat(134)) { $0 + blockHeight($1.id) }) }
    var deviceCenter: CGPoint { CGPoint(x: 145, y: 360) }
    func serverCenter(_ id: String) -> CGPoint {
        let preceding = projection.servers.prefix { $0.id != id }
        let top = preceding.reduce(CGFloat(134)) { $0 + blockHeight($1.id) }
        return CGPoint(x: 642, y: top + blockHeight(id) / 2)
    }
    func laneCenter(_ path: ConfiguredAccessPath) -> CGPoint {
        let siblings = paths(for: path.serverID)
        let index = siblings.firstIndex { $0.id == path.id } ?? 0
        return CGPoint(x: 382, y: serverCenter(path.serverID).y + (CGFloat(index) - CGFloat(siblings.count - 1) / 2) * 80)
    }
    func endpoint(_ path: ConfiguredAccessPath) -> CGPoint {
        let siblings = paths(for: path.serverID)
        let index = siblings.firstIndex { $0.id == path.id } ?? 0
        let step = min(20, 64 / CGFloat(max(1, siblings.count - 1)))
        return CGPoint(x: 526, y: serverCenter(path.serverID).y + (CGFloat(index) - CGFloat(siblings.count - 1) / 2) * step)
    }
    func curve(_ path: ConfiguredAccessPath) -> Path {
        let start = CGPoint(x: 248, y: deviceCenter.y), middle = laneCenter(path), end = endpoint(path)
        var line = Path(); line.move(to: start)
        line.addCurve(to: middle, control1: CGPoint(x: 290, y: start.y), control2: CGPoint(x: 310, y: middle.y))
        line.addCurve(to: end, control1: CGPoint(x: 445, y: middle.y), control2: CGPoint(x: 476, y: end.y))
        return line
    }
    func fittedScale(in size: CGSize) -> CGFloat { min(1, max(0.01, min(size.width / width, max(1, size.height - 180) / height))) }
}

struct AccessGraphView: View {
    @ObservedObject var workspace: AccessWorkspace
    let previewControls: () -> AnyView
    let onAdd: () -> Void
    let onAction: () -> Void
    let onConfigure: (AccessFormDraft) -> Void
    @State private var zoom: CGFloat = 1
    @State private var showsPlanning = false
    @State private var focusRequest = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("服务器").font(.system(size: 14, weight: .medium))
                WorkspaceViewSwitch(workspace: workspace)
                Spacer(minLength: 12)
                WorkspaceSearch(workspace: workspace).frame(width: 240)
                Button(action: onAdd) { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("添加服务器").keyboardShortcut("n", modifiers: .command)
                previewControls()
            }.padding(.horizontal, 20).frame(height: 56).background(InterfaceStyle.color(0xF5F5F7))
            HStack(spacing: 0) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                ServerContextView(workspace: workspace, compact: true, onAction: onAction, onAdd: onAdd, onConfigure: onConfigure).frame(width: 296)
            }
        }
        .sheet(isPresented: $showsPlanning) {
            VStack(alignment: .leading, spacing: 18) {
                Text("经跳板机访问 · 未来规划").font(.system(size: 21, weight: .medium))
                Text("此 Mac → 跳板机 → 目标服务器").font(InterfaceStyle.technical(14))
                Text("未来按段区分网络到达、主机身份和账户认证。跳板可达不代表目标能够登录。")
                Text("当前图谱仅显示已配置的直连路径；没有多跳路径、ProxyJump 或连接操作。")
                    .foregroundStyle(.secondary)
                Button("返回直连图") { showsPlanning = false }.keyboardShortcut(.cancelAction)
            }.padding(32).frame(width: 600).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            let graph = workspace.visibleGraph
            let layout = DirectGraphLayout(projection: graph, expandedServerIDs: workspace.expandedGraphServerIDs)
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    if workspace.graph.servers.isEmpty {
                        emptyState("还没有服务器", detail: "添加服务器后，已配置的直连路径将在这里显示。", add: true)
                    } else if graph.servers.isEmpty {
                        emptyState("没有匹配的服务器", detail: "搜索别名或中文描述；清空搜索可恢复所有节点。", add: false)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            graphContent(layout).frame(width: layout.width, height: layout.height)
                                .scaleEffect(zoom, anchor: .topLeading)
                                .frame(width: layout.width * zoom, height: layout.height * zoom, alignment: .topLeading)
                        }.scrollIndicators(.visible)
                            .frame(height: max(1, geometry.size.height - 180))
                            .padding(.top, 90)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("访问拓扑").font(.system(size: 20, weight: .medium))
                                Text("已配置的直连路径 · 示例状态").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("跳板机规划") { showsPlanning = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(28).frame(maxWidth: .infinity).background(InterfaceStyle.color(0xFAFBFD))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("实线：已验证   虚线：待验证或失败 · 示例时间 CST").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("−") { zoom = max(0.25, zoom - 0.15) }.accessibilityLabel("缩小画布")
                            Text("\(Int((zoom * 100).rounded()))%").font(InterfaceStyle.technical(11)).frame(width: 42)
                            Button("+") { zoom = min(2, zoom + 0.15) }.accessibilityLabel("放大画布")
                            Button("适应画布") { zoom = layout.fittedScale(in: geometry.size) }
                            Button("定位结果") { workspace.selectSearchResult(); focusRequest += 1 }
                                .disabled(graph.servers.isEmpty)
                            Button("下一个对象") { workspace.advanceSelection(); focusRequest += 1 }.keyboardShortcut("]", modifiers: .command)
                        }.buttonStyle(.borderless).font(.system(size: 11))
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(true)
                }.background(InterfaceStyle.color(0xFAFBFD))
                .onAppear { zoom = layout.fittedScale(in: geometry.size) }
                .onChange(of: geometry.size) { _, size in zoom = layout.fittedScale(in: size) }
                .onChange(of: workspace.query) { _, _ in
                    zoom = layout.fittedScale(in: geometry.size)
                    if let id = workspace.searchTargetID { proxy.scrollTo("server-" + id, anchor: .center) }
                }
                .onChange(of: workspace.graph.servers) { _, _ in zoom = layout.fittedScale(in: geometry.size) }
                .onChange(of: focusRequest) { _, _ in
                    if let server = workspace.selectedServer { proxy.scrollTo("server-" + server.id, anchor: .center) }
                    else { proxy.scrollTo("device", anchor: .center) }
                }
            }
        }
    }
    private func graphContent(_ layout: DirectGraphLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.projection.paths.filter { !layout.isCollapsed($0.serverID) }) { path in
                GraphPathView(path: path, layout: layout, selected: workspace.selectedPath?.id == path.id,
                              serverAlias: workspace.graph.servers.first { $0.id == path.serverID }?.alias ?? path.serverID) {
                    workspace.select(.path(path.id))
                }
            }
            ForEach(layout.projection.servers.filter { layout.paths(for: $0.id).count > 3 }) { server in
                GraphPathGroupView(server: server, paths: layout.paths(for: server.id),
                                   layout: layout, collapsed: layout.isCollapsed(server.id)) {
                    if workspace.selectedServer?.id != server.id { workspace.select(.server(server.id)) }
                    if workspace.expandedGraphServerIDs.contains(server.id) { workspace.expandedGraphServerIDs.remove(server.id) }
                    else { workspace.expandedGraphServerIDs.insert(server.id) }
                }
            }
            Button { workspace.select(.device(workspace.snapshot.deviceID)) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "laptopcomputer").font(.system(size: 22))
                    Text("此 Mac").font(.system(size: 14, weight: .medium))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).frame(width: 206, height: 104)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(workspace.selection == .device(workspace.snapshot.deviceID) ? InterfaceStyle.blue : InterfaceStyle.color(0xDBE2EC)))
            }.buttonStyle(.plain).id("device").position(layout.deviceCenter).accessibilityLabel("节点 此 Mac，访问来源")
            ForEach(layout.projection.servers) { server in
                GraphServerView(server: server, paths: workspace.paths(for: server.id), selected: workspace.selectedServer?.id == server.id) {
                    workspace.select(.server(server.id))
                }.id("server-" + server.id).position(layout.serverCenter(server.id))
            }
        }
    }
    private func emptyState(_ title: String, detail: String, add: Bool) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 20, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if add { Button("添加服务器", action: onAdd) }
            else { Button("清空搜索") { workspace.query = "" } }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
