import SwiftUI
import KeyPortCore

struct WorkspaceManagementView: View {
    let store: WorkspaceStore
    let section: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notice: String?
    @State private var selectedAuthorization: SSHAuthorization?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(section).font(.title2); Spacer(); Button("完成") { dismiss() } }
            if section == "活动记录" {
                List(store.topology.accessVerifications.filter { $0.deviceID == store.state.deviceID }.sorted { ($0.lastCheckedAt ?? .distantPast) > ($1.lastCheckedAt ?? .distantPast) }) { v in
                    VStack(alignment: .leading) {
                        Text(store.topology.sshAccounts.first { $0.id == v.accountID }?.username ?? "账户")
                        Text(v.status.title)
                        if let date = v.lastCheckedAt { Text(date, style: .date).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Form {
                    Section("当前设备") {
                        TextField("设备名称", text: $name)
                        Button("保存名称") { perform { try store.renameDevice(store.state.deviceID, name: name) } }
                    }
                    Section("工作区设备与公钥") {
                        ForEach(store.topology.profiles) { device in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(device.name + (device.id == store.state.deviceID ? "（此 Mac）" : ""))
                                ForEach(store.topology.sshKeys.filter { $0.deviceID == device.id }) { key in
                                    Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Section("账户授权") {
                        ForEach(store.topology.authorizations.filter { !$0.isDeleted }) { authorization in
                            VStack(alignment: .leading, spacing: 6) {
                                if let account = store.topology.activeAccounts.first(where: { $0.id == authorization.accountID }) {
                                    Text((store.topology.nodes.first { $0.id == account.nodeID }?.name ?? "服务器") + " · " + account.username)
                                }
                                Text(authorization.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text(authorization.remoteState == .authorized ? "已记录授权" : authorization.remoteState == .revoked ? "已撤销" : "状态待核对")
                                HStack {
                                    Button("核对远端授权") { run(authorization, revoke: false) }
                                    Button("撤销此公钥", role: .destructive) { selectedAuthorization = authorization }.disabled(authorization.remoteState != .authorized)
                                }.disabled(working)
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24).frame(width: 680, height: 640)
        .onAppear { name = store.topology.profiles.first { $0.id == store.state.deviceID }?.name ?? "此 Mac" }
        .confirmationDialog("从远端账户撤销此公钥？", isPresented: Binding(get: { selectedAuthorization != nil }, set: { if !$0 { selectedAuthorization = nil } })) {
            if let a = selectedAuthorization { Button("撤销此指纹", role: .destructive) { run(a, revoke: true); selectedAuthorization = nil } }
        } message: { Text(selectedAuthorization?.fingerprint ?? "") }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { notice = error.localizedDescription } }
    private func run(_ authorization: SSHAuthorization, revoke: Bool) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await store.refreshAuthorization(authorization, revoke: revoke); notice = revoke ? "指定公钥已撤销。" : "远端授权已核对。" }
            catch { notice = error.localizedDescription }
        }
    }
}
