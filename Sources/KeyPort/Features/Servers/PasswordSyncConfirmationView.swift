import SwiftUI

struct PasswordSyncConfirmationView: View {
    let initialSynchronizable: Bool
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    @State private var synchronizable: Bool

    init(
        initialSynchronizable: Bool,
        onConfirm: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialSynchronizable = initialSynchronizable
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _synchronizable = State(initialValue: initialSynchronizable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("保存密码", systemImage: "key.fill")
                .font(.title3)
                .fontWeight(.semibold)

            Text("连接测试已通过，请选择密码的保存方式。")
                .foregroundStyle(.secondary)

            Toggle("通过 iCloud Keychain 同步", isOn: $synchronizable)

            Text(
                synchronizable
                    ? "开启后，登录同一 Apple 账户的设备可以使用此密码。"
                    : "关闭后，密码仅保存在此 Mac。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("继续") {
                    onConfirm(synchronizable)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
