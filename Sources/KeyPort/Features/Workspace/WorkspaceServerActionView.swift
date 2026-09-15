import SwiftUI

struct WorkspaceServerActionView: View {
    let store: WorkspaceStore
    let serverID: String
    let serverName: String
    let disconnect: Bool
    let complete: (String) -> Void
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(disconnect ? "一键解除" : "撤销授权").font(.title2)
            Text(serverName)
            Text("将撤销以下工作区公钥在远端账户中的授权（包括其他设备的公钥）。")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.serverAuthorizations(serverID)) { authorization in
                        VStack(alignment: .leading) {
                            Text(store.topology.sshAccounts.first { $0.id == authorization.accountID }?.username ?? "账户")
                            Text(authorization.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(authorization.remoteState == .revoked ? "已撤销" : "待撤销").font(.caption)
                        }
                    }
                    if store.serverAuthorizations(serverID).isEmpty { Text("没有已记录的工作区公钥授权。") }
                }
            }.frame(maxHeight: 220)
            Text(disconnect ? "全部撤销成功后，将删除服务器、路径、账户、服务和终端别名。失败时保留服务器记录。" : "撤销后保留服务器与连接路径，使用这些公钥将无法继续登录。")
            if disconnect && store.topology.profiles.contains(where: { $0.nodeID.uuidString == serverID }) {
                Text("这台机器也是工作区设备：将移除 SSH 服务器角色，保留设备档案和本机密钥。").font(.callout)
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small); Text("正在撤销…") }
                Button("取消") { complete("") }.disabled(working)
                Button(disconnect ? "撤销并解除" : "撤销授权", role: .destructive) {
                    working = true
                    Task { @MainActor in
                        do {
                            try await store.revokeServer(serverID, disconnect: disconnect)
                            complete(disconnect ? "远端授权已撤销，服务器记录和终端别名已清理。" : "远端授权已撤销，服务器和路径已保留。")
                        } catch { complete(error.localizedDescription) }
                        working = false
                    }
                }.disabled(working)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(working)
    }
}
