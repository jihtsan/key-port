import KeyPortCore
import SwiftUI

struct HostKeyConfirmationView: View {
    let keys: [HostKeyRecord]
    let previousKeys: [HostKeyRecord]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(previousKeys.isEmpty ? "确认服务器身份" : "确认主机密钥变更", systemImage: previousKeys.isEmpty ? "checkmark.shield" : "exclamationmark.shield")
                .font(.title2).fontWeight(.semibold)
            Text(previousKeys.isEmpty ? "这些指纹由当前网络端点返回。确认前，请与可信来源进行核对。" : "当前端点返回了不同的主机密钥。身份验证已被阻止，请将新旧两组指纹与可信来源核对，并明确接受密钥轮换。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if !previousKeys.isEmpty {
                    fingerprintList(title: "此前已确认", keys: previousKeys)
                }
                fingerprintList(title: previousKeys.isEmpty ? "检测到的指纹" : "当前检测结果", keys: keys)
            }
            .frame(minHeight: 170)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("我已核对这些指纹", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: previousKeys.isEmpty ? 620 : 820, height: 390)
    }

    private func fingerprintList(title: String, keys: [HostKeyRecord]) -> some View {
        GroupBox(title) {
            List(keys) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(key.algorithm).fontWeight(.medium)
                    Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
