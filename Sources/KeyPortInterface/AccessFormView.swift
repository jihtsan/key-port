import SwiftUI

public struct AccessFormView: View {
    @State private var draft: AccessFormDraft
    @State private var showsPassword = false
    @State private var advanced = false
    @State private var submissionState = AccessFormSubmissionState()
    private let onCancel: () -> Void
    private let onSubmit: (AccessFormDraft) -> Void
    private let recoveryNotice: String?
    private let fixture: Bool

    public init(draft: AccessFormDraft = .init(), fixture: Bool = false, recoveryNotice: String? = nil, onCancel: @escaping () -> Void, onSubmit: @escaping (AccessFormDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.fixture = fixture
        self.recoveryNotice = recoveryNotice
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("KeyPort  /  服务器访问").font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8794A7)).frame(height: 18)
            Text("添加服务器并配置免密").font(.system(size: 25, weight: .medium)).frame(height: 38)
            Text("填写一次，随后自动验证、授权并检查免密登录。").font(.system(size: 13)).foregroundStyle(InterfaceStyle.muted).frame(height: 20)
            VStack(alignment: .leading, spacing: 14) {
                row("服务器名称") { field("服务器名称", text: $draft.name) }
                row("地址 / 端口") {
                    HStack(spacing: 12) {
                        TextField("IP 地址或主机名", text: $draft.address).frame(width: max(100, min(360, CGFloat(draft.address.count) * 8.5))).accessibilityLabel("地址")
                        Text(":").foregroundStyle(InterfaceStyle.muted)
                        TextField("22", text: $draft.port).frame(width: 72).accessibilityLabel("端口")
                        Spacer(minLength: 0)
                    }.modifier(InputSurface())
                }
                row("登录账户") { field("登录账户", text: $draft.account) }
                row(draft.existingKey ? "认证方式" : "登录密码") {
                    if draft.existingKey {
                        Text("使用本机现有 SSH 密钥").frame(maxWidth: .infinity, alignment: .leading).modifier(InputSurface())
                    } else {
                        HStack(spacing: 12) {
                            if showsPassword { TextField("登录密码", text: $draft.password).frame(width: 84) }
                            else { SecureField("登录密码", text: $draft.password).frame(width: 84) }
                            Button(showsPassword ? "隐藏" : "显示") { showsPassword.toggle() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(InterfaceStyle.blue)
                            Spacer(minLength: 0)
                        }.modifier(InputSurface())
                    }
                }
                Text(draft.existingKey ? "优先使用本机已有密钥认证；不需要填写登录密码。" : "密码仅用于首次登录和安装公钥，默认不保存。")
                    .font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8090A6)).frame(height: 18)
                Button(draft.existingKey ? "改用登录密码" : "已能通过密钥登录？使用现有密钥") {
                    draft.existingKey.toggle(); draft.password = ""; showsPassword = false
                }.buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue).font(.system(size: 12)).frame(height: 18)
                Button { advanced.toggle() } label: {
                    HStack(spacing: 8) { Image(systemName: advanced ? "chevron.down" : "chevron.right").frame(width: 16); Text(advanced ? "收起高级选项" : "高级选项 · SSH 别名") }
                        .font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x677D98)).frame(height: 34)
                }.buttonStyle(.plain)
                if advanced {
                    HStack(spacing: 12) {
                        Text("SSH 别名").fixedSize().frame(width: 44, alignment: .leading)
                        TextField("SSH 别名", text: $draft.alias, prompt: Text(draft.suggestedAlias + "（自动生成，可修改）").foregroundStyle(InterfaceStyle.color(0x677D98)))
                            .accessibilityLabel("SSH 别名").textFieldStyle(.plain).font(.system(size: 11))
                    }.font(.system(size: 11)).foregroundStyle(InterfaceStyle.muted).frame(height: 17)
                } else {
                    Text("首次连接会请求核对主机身份；之后的步骤自动继续。").font(.system(size: 11)).foregroundStyle(InterfaceStyle.color(0x94A1B3)).frame(height: 17)
                }
                if let recoveryNotice { Text(recoveryNotice).font(.system(size: 11)).foregroundStyle(InterfaceStyle.muted) }
                Spacer(minLength: 0)
            }.padding(24).frame(height: 464).frame(maxWidth: .infinity).background(InterfaceStyle.color(0xF7F9FC), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button("验证并配置免密") {
                    guard let submission = submissionState.prepare(&draft) else { return }
                    showsPassword = false
                    onSubmit(submission)
                }.buttonStyle(InterfaceButtonStyle(primary: true, width: 137, height: 38)).keyboardShortcut(.defaultAction)
                Button("取消") { draft.password = ""; onCancel() }.buttonStyle(InterfaceButtonStyle(width: 112, height: 38)).keyboardShortcut(.cancelAction)
                if let error = submissionState.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }.frame(height: 38)
            Text(fixture ? "可点击演示 · 固定示例数据，无真实凭据与网络操作" : "密码仅在本次操作中使用。")
                .font(.system(size: 10)).foregroundStyle(InterfaceStyle.color(0x9AA5B5)).frame(height: 15)
        }.padding(32).frame(width: 880, height: 740, alignment: .topLeading).foregroundStyle(InterfaceStyle.ink).background(.white)
        .onDisappear { draft.password = "" }
        .onChange(of: draft) { _, _ in submissionState.edited() }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) { Text(label).font(.system(size: 13)).foregroundStyle(InterfaceStyle.color(0x5A6F8B)).frame(width: 120, alignment: .leading); content() }.frame(height: 48)
    }
    private func field(_ title: String, text: Binding<String>) -> some View { TextField(title, text: text).accessibilityLabel(title).modifier(InputSurface()) }
}

private struct InputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(InterfaceStyle.technical(14)).padding(.horizontal, 12).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(InterfaceStyle.color(0xD8E0EB)))
    }
}
