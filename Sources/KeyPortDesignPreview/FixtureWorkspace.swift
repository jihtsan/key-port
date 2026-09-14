import SwiftUI
import KeyPortInterface

/// The only fixture factory for the workspace. Both presentations receive its same snapshot.
enum FixtureWorkspaceScenario: String, CaseIterable {
    case dual = "同服务器双路径", dense = "六条路径", direct = "当前直连", multiple = "多账户与多地址", unreachable = "地址不可达", unconfigured = "账户未授权"
    case isolated = "孤立节点", empty = "空数据", longText = "长别名与中文描述"
    func snapshot() -> AccessWorkspaceSnapshot {
        let device = "fixture-this-mac"
        var servers = [ServerNaming(id: "router", alias: "home-router", description: "家里的主路由器"),
                       ServerNaming(id: "studio", alias: "mac-studio"), ServerNaming(id: "cloud", alias: "tencent-cloud")]
        let date = Date(timeIntervalSince1970: 1789315200)
        var paths = [ConfiguredAccessPath(id: "router-lan-root", deviceID: device, serverID: "router", account: "root", address: "192.168.8.1", verification: .verified, reachability: .reachable, checkedAt: date),
                     ConfiguredAccessPath(id: "studio-lan", deviceID: device, serverID: "studio", account: "jooder", address: "192.0.2.2", verification: .pending, reachability: .unknown)]
        if self == .multiple {
            paths.insert(.init(id: "router-ipv6-root", deviceID: device, serverID: "router", account: "root", address: "2001:db8::1", verification: .pending, reachability: .reachable, checkedAt: date), at: 1)
            paths.insert(.init(id: "router-lan-deploy", deviceID: device, serverID: "router", account: "deploy", address: "192.168.8.1", verification: .failed, reachability: .reachable, checkedAt: date), at: 2)
        }
        if self == .dual {
            paths = [paths[0], .init(id: "router-ipv6-root", deviceID: device, serverID: "router", account: "root", address: "2001:db8::1", verification: .pending, reachability: .reachable, checkedAt: date)]
        }
        if self == .dense {
            paths = (0..<6).map { i in .init(id: "router-path-\(i)", deviceID: device, serverID: "router", account: i < 3 ? "root" : "deploy", address: "192.0.2.\(i + 1)", verification: i == 0 ? .verified : i == 5 ? .failed : .pending, reachability: .unknown, checkedAt: date) }
        }
        if self == .unreachable { paths[0].reachability = .unreachable; paths[0].verification = .failed }
        if self == .unconfigured { paths[0].verification = .pending }
        if self == .isolated { paths = [] }
        if self == .empty { paths = []; servers = [] }
        if self == .longText {
            servers[0].alias = "home-router-long-alias-for-network-acceptance"
            servers[0].description = String(repeating: "家里的主路由器，负责客厅与书房的网络连接；", count: 6)
        }
        var authorizations: [AccessAuthorizationKey: AccessAuthorizationStatus] = [:]
        for path in paths where path.account != "deploy" { authorizations[path.authorizationKey] = .installed }
        if self == .unconfigured { authorizations[paths[0].authorizationKey] = .absent }
        return .init(deviceID: device, servers: servers, configuredPaths: paths, authorizations: authorizations)
    }
}

struct FixtureWorkspacePreview: View {
    @StateObject private var workspace = AccessWorkspace(snapshot: FixtureWorkspaceScenario.direct.snapshot(), selection: .server("router"))
    @State private var scenario = FixtureWorkspaceScenario.direct
    var body: some View {
        ServerHomeView(workspace: workspace, previewControls: {
            AnyView(Menu("示例场景") {
                ForEach(FixtureWorkspaceScenario.allCases, id: \.self) { item in
                    Button(item.rawValue) { scenario = item; workspace.replaceSnapshot(item.snapshot()) }
                }
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("工作区示例场景").help("当前示例：" + scenario.rawValue))
        }) { draft, close in AnyView(FixtureAccessPreview(draft: draft, aliasDirectory: AliasDirectory(entries:
            [.init(alias: "home-router", source: .sshConfiguration, ownerID: "router")] + workspace.graph.servers.map {
                .init(alias: $0.alias, source: .managed, ownerID: $0.id)
            }), onClose: close)) }
    }
}
