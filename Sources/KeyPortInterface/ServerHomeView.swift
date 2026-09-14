import SwiftUI

public enum ServerPreviewStatus: String, CaseIterable { case ready = "免密就绪", unconfigured = "未配置", unreachable = "不可达" }

public struct ServerHomeView: View {
    @State private var search = ""
    @State private var selected = "home-router"
    @State private var status = ServerPreviewStatus.ready
    @State private var showsForm = false
    @State private var retainedDraft: AccessFormDraft?
    @State private var notice: String?
    @State private var longDescription = false
    private let accessFlow: (AccessFormDraft, @escaping (AccessFormDraft) -> Void) -> AnyView
    public init(accessFlow: @escaping (AccessFormDraft, @escaping (AccessFormDraft) -> Void) -> AnyView) { self.accessFlow = accessFlow }
    private let servers = [
        ServerNaming(id: "router", alias: "home-router", description: "家里的主路由器"),
        ServerNaming(id: "studio", alias: "mac-studio"),
        ServerNaming(id: "cloud", alias: "tencent-cloud")
    ]
    private var selectedServer: ServerNaming { displayServer(servers.first { $0.alias == selected } ?? servers[0]) }
    private func displayServer(_ server: ServerNaming) -> ServerNaming {
        var value = server
        if longDescription && value.id == "router" { value.description = String(repeating: "家里的主路由器，负责客厅与书房的网络连接；", count: 8) }
        return value
    }
    private var account: String { selected == "mac-studio" ? "jooder" : "root" }
    private var address: String { selected == "mac-studio" ? "192.0.2.2:22" : selected == "tencent-cloud" ? "cloud.example:22" : "192.168.8.1:22" }
    private var displayStatus: ServerPreviewStatus { selected == "mac-studio" ? .ready : selected == "tencent-cloud" ? .unconfigured : status }
    private var stateText: String {
        if selected == "tencent-cloud" { return "尚未添加登录账户" }
        switch displayStatus {
        case .ready: return "本机免密已就绪 · 最近登录测试成功"
        case .unconfigured: return "此 Mac 尚未配置免密 · 连接地址可到达"
        case .unreachable: return "本机免密已配置 · 当前连接地址无法到达"
        }
    }
    private var stateColor: Color { InterfaceStyle.color(displayStatus == .ready ? 0x258456 : displayStatus == .unconfigured ? 0x9B661E : 0xB44D2B) }
    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            serverList.frame(width: 320)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(.white).foregroundStyle(InterfaceStyle.ink).font(.system(size: 12))
        .sheet(isPresented: $showsForm) {
            accessFlow(retainedDraft ?? exampleDraft, { retainedDraft = $0; showsForm = false })
        }
        .alert("隔离预览", isPresented: Binding(get: { notice != nil && !showsForm }, set: { if !$0 { notice = nil } })) { Button("好") { notice = nil } } message: { Text(notice ?? "") }
    }
    private var exampleDraft: AccessFormDraft {
        var draft = AccessFormDraft(); draft.description = "家里的主路由器"; draft.address = "192.168.8.1"; draft.account = "root"; draft.password = "demo-only"; return draft
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
            Text("家庭网络").foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 38)
            Spacer()
            Label("管理信息已同步", systemImage: "icloud").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 36).help("设计示例，未连接 iCloud")
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
                Text("服务器").font(.system(size: 15, weight: .medium)); Text("3").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { showsForm = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).accessibilityLabel("添加服务器").keyboardShortcut("n", modifiers: .command)
                HStack(spacing: 6) { Text("列表").padding(.horizontal, 14).frame(height: 22).background(.white, in: RoundedRectangle(cornerRadius: 4)); Button("拓扑") { previewNotice() }.buttonStyle(.plain).foregroundStyle(.secondary) }.font(.system(size: 11)).padding(3).frame(width: 116, height: 28).background(InterfaceStyle.color(0xE7EAF0), in: RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 18).frame(height: 56).background(InterfaceStyle.color(0xF5F5F7))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { Image(systemName: "magnifyingglass"); TextField("搜索别名或描述", text: $search).textFieldStyle(.plain).accessibilityLabel("搜索别名或描述") }.foregroundStyle(.secondary).padding(8).frame(height: 32).background(InterfaceStyle.color(0xECEEF1), in: RoundedRectangle(cornerRadius: 6))
                Text("已添加").font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 17)
                ForEach(servers.map(displayServer).filter { $0.matches(search) }) { server in
                    let name = server.alias
                    Button { selected = name } label: {
                        HStack(spacing: 12) {
                            Image(systemName: name == "mac-studio" ? "laptopcomputer" : "server.rack").font(.system(size: 22)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(InterfaceStyle.technical(15, medium: true)).lineLimit(1).help(name)
                                if let description = server.visibleDescription {
                                    Text(description).font(.system(size: 12)).lineLimit(1).help(description)
                                }
                                Text(name == "tencent-cloud" ? "待添加登录账户" : "\(name == "mac-studio" ? "jooder" : "root") · \(name == "mac-studio" || status == .ready ? "免密已就绪" : status == .unconfigured ? "待配置免密" : "地址不可达")").font(.system(size: 10)).opacity(0.75)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).frame(height: name == selected ? 84 : 74).foregroundStyle(name == selected ? .white : InterfaceStyle.ink).background(name == selected ? InterfaceStyle.blue : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(12)
            Button { showsForm = true } label: { Label("添加或导入服务器", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(height: 54) }.buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue).background(InterfaceStyle.color(0xF5F5F7))
        }.background(InterfaceStyle.color(0xFBFBFC))
    }
    private var detail: some View {
        VStack(spacing: 0) {
            HStack { Text("服务器详情").font(.system(size: 13)).foregroundStyle(.secondary); Spacer(); Menu { Toggle("预览：长中文描述", isOn: $longDescription); ForEach(ServerPreviewStatus.allCases, id: \.self) { value in Button("预览：" + value.rawValue) { status = value } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("预览状态") }.padding(.horizontal, 24).frame(height: 56).background(InterfaceStyle.color(0xF5F5F7))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(InterfaceStyle.blue).frame(width: 56, height: 56).background(InterfaceStyle.color(0xEEF3FC), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) { Text(selectedServer.alias).font(InterfaceStyle.technical(25, medium: true)).lineLimit(1).help(selectedServer.alias)
                            if let description = selectedServer.visibleDescription {
                                Text(description + (selected == "home-router" ? "   ·   家庭网络" : ""))
                                    .foregroundStyle(.secondary).lineLimit(1).help(description)
                            } }
                        Spacer(minLength: 0)
                    }.frame(height: 68)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) { Text("登录账户").foregroundStyle(.secondary); Menu {
                            Button(selected == "tencent-cloud" ? "添加登录账户" : account) { if selected == "tencent-cloud" { showsForm = true } }
                        } label: {
                            HStack { Text(selected == "tencent-cloud" ? "待添加登录账户" : account).font(InterfaceStyle.technical(13, medium: true)); Spacer(minLength: 0); Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
                                .padding(.horizontal, 8).frame(width: 142, height: 30)
                                .background(.white, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(InterfaceStyle.color(0xD7DCE3)))
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("登录账户") }
                        Label(stateText, systemImage: displayStatus == .ready ? "checkmark" : "exclamationmark.circle").foregroundStyle(stateColor).frame(height: 27)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).frame(height: 116).background(InterfaceStyle.color(0xF7F8FA), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(InterfaceStyle.color(0xE2E5EA)))
                    HStack(spacing: 10) {
                        Button { if displayStatus == .unconfigured { showsForm = true } else { previewNotice() } } label: { Label(displayStatus == .ready ? "在终端打开" : displayStatus == .unconfigured ? "配置免密" : "检查地址", systemImage: displayStatus == .ready ? "terminal" : displayStatus == .unconfigured ? "key" : "slider.horizontal.3").frame(width: 118) }.buttonStyle(InterfaceButtonStyle(primary: true))
                        Button("测试连接") { previewNotice() }.buttonStyle(InterfaceButtonStyle(width: 110))
                        Button { previewNotice() } label: { Label(displayStatus == .unconfigured ? "账户设置" : "管理免密授权", systemImage: "key") }.buttonStyle(InterfaceButtonStyle(width: 142))
                    }.frame(height: 34)
                    HStack { Text("连接地址").font(.system(size: 13, weight: .medium)); Spacer(); Button("管理地址") { previewNotice() }.buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue) }.frame(height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) { Image(systemName: "wifi").font(.system(size: 20)); Text(selected == "tencent-cloud" ? "公网" : "局域网"); Text(address).font(InterfaceStyle.technical(13)); Text(displayStatus == .unreachable ? "无法到达" : "可到达 · 当前使用").font(.system(size: 11)).foregroundStyle(stateColor) }.padding(.horizontal, 16).frame(height: 56)
                        Text(displayStatus == .unreachable ? "连接超时。请检查局域网连接，或在“管理地址”中切换地址。" : "当前使用固定地址").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 54).background(InterfaceStyle.color(0xF8F9FB))
                    }.clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(InterfaceStyle.color(0xE1E5EB)))
                    Button { previewNotice() } label: { HStack(spacing: 12) { Image(systemName: "slider.horizontal.3"); Text("连接设置").fontWeight(.medium); Text("描述、地址选择策略").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Image(systemName: "chevron.right") }.padding(14).frame(height: 50).background(InterfaceStyle.color(0xF7F8FA), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                    Text("最近活动").font(.system(size: 13, weight: .medium)).frame(height: 20)
                    HStack(spacing: 10) { Image(systemName: displayStatus == .ready ? "checkmark" : "exclamationmark.circle").foregroundStyle(stateColor); Text(displayStatus == .ready ? "登录测试成功" : displayStatus == .unconfigured ? "尚未测试登录" : "连接超时 · 尚未验证 SSH 身份"); Text(selected == "tencent-cloud" ? "" : account).font(InterfaceStyle.technical(11)); Text(displayStatus == .unconfigured ? "等待配置" : "今天 22:00").font(.system(size: 11)).foregroundStyle(.secondary) }.frame(height: 34)
                    Text("设计示例 · 状态非实时").font(.system(size: 10)).foregroundStyle(InterfaceStyle.color(0x9AA1AC)).frame(height: 15)
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func previewNotice() { notice = "此操作属于后续验收阶段；预览不会连接真实服务器或更改本机配置。" }
}
