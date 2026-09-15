import SwiftUI
import KeyPortCore
import KeyPortInterface

struct TailscaleAddressPicker: View {
    @Binding var draft: AccessFormDraft
    @State private var presented = false
    var body: some View {
        HStack {
            Button("检测并导入 Tailscale 地址") { presented = true }
                .buttonStyle(.plain).foregroundStyle(.blue)
            Text("自动发现设备与地址").foregroundStyle(.secondary)
        }.font(.system(size: 12)).frame(height: 28)
        .sheet(isPresented: $presented) {
            TailscaleDiscoveryView { node, address in
                TailscaleDiscovery.apply(address: address, node: node, to: &draft)
                presented = false
            }
        }
    }
}

private struct TailscaleDiscoveryView: View {
    let select: (TailscaleNode, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: TailscaleStatus?
    @State private var error: String?
    @State private var detecting = true
    @State private var generation = 0
    @State private var search = ""
    private var nodes: [TailscaleNode] {
        (status?.nodes ?? []).filter { node in
            !TailscaleDiscovery.addresses(for: node).isEmpty && (search.isEmpty || node.name.localizedCaseInsensitiveContains(search) || TailscaleDiscovery.addresses(for: node).contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tailscale 地址").font(.title2)
                Spacer()
                Button("重新检测") { generation += 1 }.disabled(detecting)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("选择地址后自动填入连接表单。登录账户请填写目标机器的 SSH 用户名。")
            Text("设备在线仅表示已连接 Tailscale；SSH 可达性与免密登录将在配置时验证。")
                .font(.callout).foregroundStyle(.secondary)
            if detecting { HStack { ProgressView().controlSize(.small); Text("正在检测本机 Tailscale…") } }
            if let error { Text(error).foregroundStyle(.red) }
            if let status {
                Text("已连接 · \(status.tailnetName ?? "Tailscale") · \(status.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("搜索设备或地址", text: $search).textFieldStyle(.roundedBorder)
                if nodes.isEmpty { Text(search.isEmpty ? "未发现可导入的设备地址。" : "没有匹配的设备或地址。").foregroundStyle(.secondary) }
                List(nodes) { node in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(node.name).font(.headline)
                            if node.isCurrent { Text("此 Mac").foregroundStyle(.secondary) }
                            Spacer()
                            Text(node.isOnline ? "在线" : "离线").foregroundStyle(node.isOnline ? .green : .secondary)
                        }
                        ForEach(TailscaleDiscovery.addresses(for: node), id: \.self) { address in
                            HStack {
                                Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("使用此地址") { select(node, address) }
                                    .accessibilityLabel("使用地址 " + address)
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
        }.padding(24).frame(width: 720, height: 550)
        .task(id: generation) {
            detecting = true; error = nil; status = nil
            defer { detecting = false }
            do { status = try await TailscaleDiscovery.detect() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
