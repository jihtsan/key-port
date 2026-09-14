import SwiftUI

public struct AccessFormView: View {
    @State private var draft: AccessFormDraft
    @State private var showsPassword = false
    @State private var aliasEdited = false
    private let directory: AliasDirectory
    @State private var submissionState = AccessFormSubmissionState()
    private let onCancel: (AccessFormDraft) -> Void
    private let onSubmit: (AccessFormDraft) -> Void
    private let recoveryNotice: String?
    private let fixture: Bool

    public init(draft: AccessFormDraft = .init(), fixture: Bool = false, directory: AliasDirectory = .init(), recoveryNotice: String? = nil, onCancel: @escaping (AccessFormDraft) -> Void, onSubmit: @escaping (AccessFormDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.fixture = fixture
        self.directory = directory
        self.recoveryNotice = recoveryNotice
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("KeyPort  /  服务器访问").font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8794A7)).frame(height: 18)
            Text("添加服务器并配置免密").font(.system(size: 25, weight: .medium)).frame(height: 38)
            Text("别名用于 SSH 连接，描述帮助你识别服务器。").font(.system(size: 13)).foregroundStyle(InterfaceStyle.muted).frame(height: 20)
            VStack(alignment: .leading, spacing: 10) {
                row("SSH 别名") {
                    TextField("例如 home-router", text: $draft.alias).accessibilityLabel("SSH 别名")
                        .modifier(InputSurface(invalid: aliasError != nil))
                }
                Text(aliasError ?? "以字母开头，仅含英文字母、数字、- 和 _；别名不可重复。")
                    .font(.system(size: aliasError == nil ? 12 : 11))
                    .foregroundStyle(InterfaceStyle.color(aliasError == nil ? 0x8090A6 : 0xB2382E)).frame(height: 18)
                row("描述（选填）") {
                    TextField("选填，例如：家里的主路由器", text: $draft.description)
                        .accessibilityLabel("描述（选填）").modifier(InputSurface(technical: false))
                }
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
                        Text("使用本机现有 SSH 密钥").frame(maxWidth: .infinity, alignment: .leading).modifier(InputSurface(technical: false))
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
                Text("描述可随时修改，不改变 SSH 别名与连接配置。")
                    .font(.system(size: 11)).foregroundStyle(InterfaceStyle.color(0x94A1B3)).frame(height: 17)
                if let recoveryNotice { Text(recoveryNotice).font(.system(size: 11)).foregroundStyle(InterfaceStyle.muted) }
                Spacer(minLength: 0)
            }.padding(24).frame(height: 464).frame(maxWidth: .infinity).background(InterfaceStyle.color(0xF7F9FC), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button("验证并配置免密") {
                    guard let submission = submissionState.prepare(&draft, directory: directory) else { return }
                    showsPassword = false
                    onSubmit(submission)
                }.buttonStyle(InterfaceButtonStyle(primary: true, width: 137, height: 38)).keyboardShortcut(.defaultAction)
                    .disabled(aliasError != nil).opacity(aliasError == nil ? 1 : 0.45)
                Button("取消") { draft.password = ""; onCancel(draft) }.buttonStyle(InterfaceButtonStyle(width: 112, height: 38)).keyboardShortcut(.cancelAction)
                if let error = submissionState.error, aliasError == nil { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }.frame(height: 38)
            Text(fixture ? "可点击演示 · 固定示例数据，无真实凭据与网络操作" : "密码仅在本次操作中使用。")
                .font(.system(size: 10)).foregroundStyle(InterfaceStyle.color(0x9AA5B5)).frame(height: 15)
        }.padding(32).frame(width: 880, height: 740, alignment: .topLeading).foregroundStyle(InterfaceStyle.ink).background(.white)
        .onDisappear { draft.password = "" }
        .onChange(of: draft) { _, _ in submissionState.edited() }
        .onChange(of: draft.alias) { _, _ in aliasEdited = true }
    }
    private var aliasError: String? {
        guard aliasEdited || submissionState.error != nil else { return nil }
        return directory.validationMessage(for: draft.alias, editingEntryID: draft.editingEntryID)
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) { Text(label).font(.system(size: 13)).foregroundStyle(InterfaceStyle.color(0x5A6F8B)).frame(width: 120, alignment: .leading); content() }.frame(height: 48)
    }
    private func field(_ title: String, text: Binding<String>) -> some View { TextField(title, text: text).accessibilityLabel(title).modifier(InputSurface()) }
}

private struct InputSurface: ViewModifier {
    var technical = true
    var invalid = false
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(technical ? InterfaceStyle.technical(14) : .system(size: 14)).padding(.horizontal, 12).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(InterfaceStyle.color(invalid ? 0xC73B38 : 0xD8E0EB)))
    }
}
