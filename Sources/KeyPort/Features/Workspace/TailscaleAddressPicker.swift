import SwiftUI
import KeyPortCore
import KeyPortInterface

struct TailscaleAddressPicker: View {
    @Binding var draft: AccessFormDraft
    @State private var presented = false
    @State private var managing = false
    var body: some View {
        HStack {
            Button("检测并导入 Tailscale 地址") { presented = true }
                .buttonStyle(.plain).foregroundStyle(.blue)
            Button("管理地址（\(draft.addresses.count)）") { managing = true }
                .buttonStyle(.plain).foregroundStyle(.blue)
        }.font(.system(size: 12)).frame(height: 28)
        .sheet(isPresented: $presented) {
            TailscaleDiscoveryView { node, address in
                TailscaleDiscovery.apply(addresses: address, node: node, to: &draft)
                presented = false
            }
        }
        .sheet(isPresented: $managing) { WorkspaceAddressEditor(draft: $draft) }
    }
}

private struct TailscaleDiscoveryView: View {
    let select: (TailscaleNode, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: TailscaleStatus?
    @State private var error: String?
    @State private var detecting = true
    @State private var generation = 0
    @State private var search = ""
    @State private var selectedNodeID: String?
    @State private var selectedAddresses = Set<String>()
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
            Text("勾选同一台设备的多个地址，或全选后一次导入。账户与端口共用。")
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
                            Button("全选地址") {
                                selectedNodeID = node.id
                                selectedAddresses = Set(TailscaleDiscovery.addresses(for: node))
                            }
                            Text(node.isOnline ? "在线" : "离线").foregroundStyle(node.isOnline ? .green : .secondary)
                        }
                        ForEach(TailscaleDiscovery.addresses(for: node), id: \.self) { address in
                            HStack {
                                Text(address).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Toggle("选择", isOn: Binding(get: { selectedNodeID == node.id && selectedAddresses.contains(address) }, set: { included in
                                    if included {
                                        selectedNodeID = node.id
                                        selectedAddresses.insert(address)
                                    } else {
                                        selectedAddresses.remove(address)
                                        if selectedAddresses.isEmpty { selectedNodeID = nil }
                                    }
                                })).toggleStyle(.checkbox).labelsHidden()
                                    .accessibilityLabel("选择地址 " + address)
                                    .disabled(selectedNodeID != nil && selectedNodeID != node.id)
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }
            HStack {
                Text("已选择 \(selectedAddresses.count) 个地址").foregroundStyle(.secondary)
                Button("清空选择") { selectedAddresses = []; selectedNodeID = nil }
                    .disabled(selectedAddresses.isEmpty)
                Spacer()
                Button("导入所选地址") {
                    guard let node = status?.nodes.first(where: { $0.id == selectedNodeID }) else { return }
                    select(node, TailscaleDiscovery.addresses(for: node).filter { selectedAddresses.contains($0) })
                }.disabled(detecting || selectedAddresses.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 580)
        .task(id: generation) {
            detecting = true; error = nil; status = nil; selectedNodeID = nil; selectedAddresses = []
            defer { detecting = false }
            do { status = try await TailscaleDiscovery.detect() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
