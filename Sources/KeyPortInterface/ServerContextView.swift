import SwiftUI

struct ServerContextView: View {
    @ObservedObject var workspace: AccessWorkspace
    var compact: Bool
    let onAction: () -> Void
    let onAdd: () -> Void
    let onConfigure: (AccessFormDraft) -> Void
    var onPathAction: ((ConfiguredAccessPath, Bool) -> Void)? = nil
    private var path: ConfiguredAccessPath? { workspace.selectedPath ?? workspace.selectedServer.flatMap { server in
        let paths = workspace.paths(for: server.id); return paths.count == 1 ? paths.first : nil
    } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 18 : 20) {
                if workspace.selectionIsFilteredOut {
                    Text("选中对象不在当前搜索结果中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let server = workspace.selectedServer {
                    if compact { Text(workspace.selectedPath == nil ? "服务器详情" : "路径详情").foregroundStyle(.secondary) }
                    identity(server)
                    if let path {
                        accountAndAuthorization(path, server: server)
                        if !compact { actions(path) }
                        Text(workspace.selectedPath == nil ? "访问路径" : "选中的直连路径").font(.system(size: 13, weight: .medium))
                        pathDetails(path, server: server)
                        if compact { actions(path) }
                        if workspace.paths(for: server.id).count > 1 { pathChoices(server) }
                    } else if workspace.paths(for: server.id).count > 1 {
                        Text("访问路径").font(.system(size: 13, weight: .medium))
                        Text(workspace.paths(for: server.id).verificationSummary).foregroundStyle(.secondary)
                        Text("选择路径查看账户、地址与检测时间").font(.system(size: 12)).foregroundStyle(.secondary)
                        pathChoices(server)
                    } else {
                        Text("暂无配置的访问路径").foregroundStyle(.secondary)
                        Text("服务器保留为独立节点；没有推断账户、授权或连线。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("配置免密") {
                            var draft = AccessFormDraft(); draft.editingEntryID = server.id
                            draft.alias = server.alias; draft.description = server.description
                            onConfigure(draft)
                        }.buttonStyle(InterfaceButtonStyle(primary: true))
                    }
                    Button("连接设置") { if let path, let draft = workspace.accessDraft(for: path) { onConfigure(draft) } else { onAction() } }.buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue)
                    if !compact {
                        Text("最近活动").font(.system(size: 13, weight: .medium))
                        Text(path.map { "\($0.verification.rawValue) · \($0.checkedLabel)" } ?? (workspace.paths(for: server.id).isEmpty ? "尚无路径检测记录" : "选择具体路径查看检测记录")).foregroundStyle(.secondary)
                    }
                } else if case .device = workspace.selection {
                    Text("访问来源").foregroundStyle(.secondary)
                    Label("此 Mac", systemImage: "laptopcomputer").font(.system(size: 19, weight: .medium))
                    Text("\(workspace.graph.paths.count) 条已配置直连路径").foregroundStyle(.secondary)
                    Text("授权绑定此设备与服务器账户，多个地址共用同一账户授权。").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("未选择对象").font(.system(size: 19, weight: .medium))
                    Text("点选节点查看服务器；点选连线或路径标签查看路径。").foregroundStyle(.secondary)
                }
                Text(workspace.isSimulation ? "示例数据 · 非实时状态" : "最近一次检测结果 · 非实时状态").font(.system(size: 10)).foregroundStyle(InterfaceStyle.color(0x9AA4B3))
                if workspace.selection != nil {
                    Button("清除选择") { workspace.select(nil) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                }
            }.padding(compact ? 24 : 32).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
    }
    private func identity(_ server: ServerNaming) -> some View {
        HStack(spacing: 16) {
            if !compact {
                Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(InterfaceStyle.blue)
                    .frame(width: 56, height: 56).background(InterfaceStyle.color(0xEEF3FC), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(server.alias).font(InterfaceStyle.technical(compact ? 19 : 25, medium: true)).lineLimit(2).help(server.alias)
                if let description = server.visibleDescription { Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).help(description) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func accountAndAuthorization(_ path: ConfiguredAccessPath, server: ServerNaming) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("登录账户").font(.system(size: 11)).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Text(path.account).font(InterfaceStyle.technical(14, medium: true))
            }
            Text(authorizationText(path)).font(.system(size: 12)).foregroundStyle(authorizationColor(path))
            if !compact { Text(path.reachability.rawValue + " · " + path.verification.rawValue).font(.system(size: 12)).foregroundStyle(path.verification.color) }
        }.padding(compact ? 0 : 18).frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? .clear : InterfaceStyle.color(0xF7F8FA), in: RoundedRectangle(cornerRadius: 9))
    }
    private func pathDetails(_ path: ConfiguredAccessPath, server: ServerNaming) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此 Mac → " + server.alias).font(.system(size: 12)).lineLimit(2).help("此 Mac → " + server.alias)
            Text(path.account + "@" + path.endpoint).font(InterfaceStyle.technical(12)).textSelection(.enabled).lineLimit(3)
            Text(path.verification.rawValue).foregroundStyle(path.verification.color)
            Text(path.reachability.rawValue).foregroundStyle(.secondary)
            if let isDefault = path.isDefaultConnection {
                Text(isDefault ? "默认连接 · 普通终端使用服务器别名" : "指定路径 · 命令固定此地址，不切换默认连接").font(.system(size: 11)).foregroundStyle(.secondary)
                if let command = path.terminalCommand { Text(command).font(InterfaceStyle.technical(11)).textSelection(.enabled).help(command) }
            }
            Text("检测：" + path.checkedLabel).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(compact ? 0 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? .clear : InterfaceStyle.color(0xF8F9FB), in: RoundedRectangle(cornerRadius: 8))
    }
    private func primaryAction(_ path: ConfiguredAccessPath) -> some View {
        let action = workspace.primaryAction(for: path)
        return Button {
            if action == .openTerminal { if let onPathAction { onPathAction(path, false) } else { onAction() } }
            else if let draft = workspace.accessDraft(for: path) { onConfigure(draft) }
        } label: {
            Label(action.title, systemImage: action.symbol).frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
        }.buttonStyle(InterfaceButtonStyle(primary: true))
    }
    @ViewBuilder private func actions(_ path: ConfiguredAccessPath) -> some View {
        if compact {
            primaryAction(path)
            Button("测试路径") { if let onPathAction { onPathAction(path, true) } else { onAction() } }.buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue)
        } else {
            HStack(spacing: 10) {
                primaryAction(path)
                Button("测试路径") { if let onPathAction { onPathAction(path, true) } else { onAction() } }.buttonStyle(InterfaceButtonStyle())
                Button("管理免密授权") { if let draft = workspace.accessDraft(for: path) { onConfigure(draft) } }.buttonStyle(InterfaceButtonStyle())
            }
        }
    }
    private func pathChoices(_ server: ServerNaming) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("该服务器的全部路径").font(.system(size: 12, weight: .medium))
            ForEach(workspace.paths(for: server.id)) { item in
                Button { workspace.select(.path(item.id)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.account + " · " + item.endpoint).font(InterfaceStyle.technical(10)).lineLimit(2)
                        Text(item.verification.rawValue).font(.system(size: 10)).foregroundStyle(item.verification.color)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(workspace.selectedPath?.id == item.id ? InterfaceStyle.color(0xEFF5FF) : InterfaceStyle.color(0xF7F8FA), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityLabel("选择路径 " + item.account + " " + item.endpoint)
            }
        }
    }
    private func authorizationText(_ path: ConfiguredAccessPath) -> String {
        switch workspace.snapshot.authorization(for: path) {
        case .installed: return "本机公钥已授权" + (workspace.isSimulation ? " · 示例" : "")
        case .absent: return "此账户尚未授权" + (workspace.isSimulation ? " · 示例" : "")
        case .unknown: return "账户授权状态待核对" + (workspace.isSimulation ? " · 示例" : "")
        }
    }
    private func authorizationColor(_ path: ConfiguredAccessPath) -> Color {
        workspace.snapshot.authorization(for: path) == .installed ? InterfaceStyle.color(0x288459) : InterfaceStyle.color(0xA57634)
    }
}

extension PathVerification {
    var color: Color {
        switch self { case .verified: return InterfaceStyle.color(0x3D73B9); case .pending: return InterfaceStyle.color(0xA57634); case .failed: return InterfaceStyle.color(0xB44D2B) }
    }
}
