import SwiftUI

public struct FirstAccessView<Controls: View>: View {
    @ObservedObject private var flow: FirstAccessFlow
    @State private var firstForm = true
    private let initialDraft: AccessFormDraft
    private let onClose: (AccessFormDraft) -> Void
    private let controls: () -> Controls
    public init(flow: FirstAccessFlow, initialDraft: AccessFormDraft, onClose: @escaping (AccessFormDraft) -> Void, @ViewBuilder controls: @escaping () -> Controls) {
        self.flow = flow; self.initialDraft = initialDraft; self.onClose = onClose; self.controls = controls
    }
    public var body: some View {
        Group {
            if flow.state == .form {
                AccessFormView(draft: firstForm ? initialDraft : flow.draft, fixture: flow.isSimulation, directory: flow.aliasDirectory, recoveryNotice: flow.formNotice, onCancel: { flow.retainForm($0); finish() }, onSubmit: {
                    firstForm = false; flow.submit($0)
                })
                .overlay(alignment: .bottomTrailing) { controls().padding(.trailing, 32).padding(.bottom, 34) }

            } else {
                panel
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { flow.close() }
    }
    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("KeyPort  /  服务器访问").font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8794A7)).frame(height: 18)
            Text(title).font(.system(size: 25, weight: .medium)).frame(height: 38)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(InterfaceStyle.muted).frame(height: 20)
            VStack(alignment: .leading, spacing: 14) {
                switch flow.state {
                case .confirmHost(let host): hostConfirmation(host)
                case .checkingHost: progress
                case .running: progress
                case .failed(let failure): failureContent(failure)
                case .cancelled: cancelledContent
                case .success: successContent
                case .form: EmptyView()
                }
                Spacer(minLength: 0)
            }.padding(24).frame(height: 464).frame(maxWidth: .infinity, alignment: .leading)
                .background(InterfaceStyle.color(0xF7F9FC), in: RoundedRectangle(cornerRadius: 10))
            actions.frame(height: 38)
            HStack {
                Text(flow.isSimulation ? "隔离模拟 · 无真实凭据与网络操作" : "密码仅在本次操作中使用。")
                    .foregroundStyle(InterfaceStyle.color(0x9AA5B5))
                Spacer(minLength: 8)
                controls()
            }.font(.system(size: 10)).frame(height: 15)
        }.padding(32).frame(width: 880, height: 740, alignment: .topLeading)
            .foregroundStyle(InterfaceStyle.ink).background(.white)
    }
    private var title: String {
        switch flow.state {
        case .confirmHost: return "确认服务器身份"
        case .failed(let failure): return failureTitle(failure)
        case .cancelled: return "配置已停止"
        case .success: return "免密访问已就绪"
        default: return "正在配置免密"
        }
    }
    private var subtitle: String {
        switch flow.state {
        case .success: return "此 Mac 已通过 \(flow.draft.account) 账户的免密登录验证。" + (flow.isSimulation ? "（模拟）" : "")
        case .failed(.authentication): return "尚未完成登录验证与本次免密配置。"
        case .failed, .cancelled: return authorizationText
        case .confirmHost: return "只有首次连接或身份需要确认时才出现；不匹配时停止。"
        default: return "\(flow.draft.account) @ \(flow.draft.alias) · 请保持服务器网络连接。"
        }
    }
    private var authorizationText: String {
        switch flow.authorization {
        case .absent: return "本次尚未安装本机公钥。"
        case .installed: return "本机公钥已存在；尚未完成免密验证，不代表全部成功。"
        case .unknown: return "授权结果尚不确定；重试前必须先核对，不能直接重复安装。"
        }
    }
    private func hostConfirmation(_ host: AccessHostIdentity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("首次连接：确认服务器身份").font(.system(size: 21, weight: .medium)).frame(height: 32)
            Text("\(flow.draft.address):\(flow.draft.port)  ·  ED25519").font(InterfaceStyle.technical(13)).foregroundStyle(InterfaceStyle.color(0x7087A5))
            Text(host.fingerprint).font(InterfaceStyle.technical(12)).textSelection(.enabled)
            Text(flow.isSimulation ? "指纹为演示占位，非真实服务器指纹。" : "请通过可信渠道核对完整主机指纹。").font(.system(size: 13)).foregroundStyle(InterfaceStyle.color(0xA4773C))
            Text("实际使用时须核对完整主机指纹。只有首次连接或身份需要确认时才出现；不匹配时停止。")
                .font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8797AC))
            HStack(spacing: 12) {
                Button("已核对，继续") { flow.confirmHost() }.buttonStyle(InterfaceButtonStyle(primary: true, width: 122, height: 38))
                Button("取消") { flow.cancel() }.buttonStyle(InterfaceButtonStyle(width: 112, height: 38)).keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 600, height: 360, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(InterfaceStyle.color(0xDCE3ED)))
    }
    private var progress: some View {
        VStack(spacing: 14) {
            step("1 · 验证登录", detail: loginDetail, active: true, titleHighlighted: true)
            step("2 · 安装本机公钥", detail: authorizationDetail, active: flow.state == .running(.authorization) || flow.state == .running(.verification))
            step("3 · 验证免密登录", detail: flow.state == .running(.verification) ? "正在使用本机密钥验证免密登录…" : "等待授权完成", active: flow.state == .running(.verification))
        }
    }
    private var loginDetail: String {
        switch flow.state {
        case .running(.authorization), .running(.verification): return "已验证地址、身份和登录凭据"
        default: return "正在检查地址、主机身份和账户凭据…"
        }
    }
    private var authorizationDetail: String {
        if flow.state == .running(.authorization) { return "先核对设备与服务器账户授权；仅在缺失时安装公钥…" }
        if flow.authorization == .installed { return "此 Mac 对该服务器账户的公钥授权已确认；不重复安装" }
        return "等待登录验证"
    }
    private func step(_ title: String, detail: String, active: Bool, titleHighlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(titleHighlighted ? InterfaceStyle.blue : InterfaceStyle.color(0x8797AC)).frame(height: 23)
            Text(detail).font(.system(size: 12)).foregroundStyle(active ? InterfaceStyle.blue : InterfaceStyle.color(0x8797AC)).frame(height: 18)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 88).background(.white, in: RoundedRectangle(cornerRadius: 7))
    }
    private func failureTitle(_ failure: AccessFlowFailure) -> String {
        switch failure {
        case .unreachable: return "连接地址不可达"
        case .identityMismatch: return "服务器身份不匹配，已停止"
        case .authentication: return flow.failureDetail == nil ? "账户验证未通过" : "登录验证未完成"
        case .authorization: return "设备授权未完成"
        case .verification: return "公钥已授权，免密验证未通过"
        case .authorizationUnknown: return "授权结果待核对"
        }
    }
    private func failureContent(_ failure: AccessFlowFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 26)).foregroundStyle(InterfaceStyle.color(0xB66A26)).frame(width: 28, height: 28)
            Text(failure == .authentication ? "第 1 步 · 登录验证失败" : failureTitle(failure)).font(.system(size: 20, weight: .medium)).foregroundStyle(InterfaceStyle.color(0x9C622D)).frame(height: 30)
            Text(flow.failureDetail ?? failureExplanation(failure)).font(.system(size: 13)).foregroundStyle(InterfaceStyle.color(0x74859E)).frame(height: 20)
            Text(failure == .identityMismatch ? "请通过可信渠道核对主机身份；此处不能忽略或自动继续。" : "检查后修改表单或重新验证；已有授权会先核对。")
                .font(.system(size: 14)).foregroundStyle(InterfaceStyle.color(0x4C6688)).frame(height: 21)
            Text("别名、描述、地址与账户保留。密码已清空，不落盘保存。").font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8797AC)).frame(height: 18)
            Text(authorizationText).font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8797AC)).frame(height: 18)
        }
    }
    private func failureExplanation(_ failure: AccessFlowFailure) -> String {
        switch failure {
        case .unreachable: return "尚未验证主机身份与登录凭据，请检查地址、端口和网络。"
        case .identityMismatch: return "本次主机身份与已信任身份不一致；没有继续登录或授权。"
        case .authentication: return "地址可到达，主机身份已确认；账户或凭据未通过验证。"
        case .authorization: return "登录已验证，授权操作未成功；再次尝试前会重新检查公钥是否存在。"
        case .verification: return "授权已确认，但本机密钥登录未通过；不会显示为免密已就绪。"
        case .authorizationUnknown: return "请求可能已经写入公钥，无法确认结果；先核对现状再决定是否安装。"
        }
    }
    private var cancelledContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已取消后续步骤").font(.system(size: 20, weight: .medium))
            Text("取消不代表撤销已经发生的授权。迟到结果不会改变当前页面。")
            Text("再次尝试会重新核对主机身份和账户授权；密码已清空。")
        }.font(.system(size: 12)).foregroundStyle(InterfaceStyle.muted)
    }
    private var successContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 26)).foregroundStyle(InterfaceStyle.color(0x258456)).frame(width: 30, height: 30)
            Text(flow.draft.alias).font(InterfaceStyle.technical(22, medium: true)).lineLimit(1).frame(height: 33).help(flow.draft.alias)
            if !flow.draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(flow.draft.description).font(.system(size: 14)).foregroundStyle(InterfaceStyle.muted)
                    .lineLimit(2).help(flow.draft.description)
            }
            Text("\(flow.draft.account) · 此 Mac · 免密登录验证成功" + (flow.isSimulation ? "（模拟）" : "")).font(.system(size: 14)).foregroundStyle(InterfaceStyle.color(0x258456)).frame(height: 21)
            Text(flow.command).font(InterfaceStyle.technical(17)).foregroundStyle(InterfaceStyle.color(0x536C8D)).frame(height: 26).textSelection(.enabled)
            Text("SSH 命令使用别名；修改描述不改变连接配置。")
                .font(.system(size: 12)).foregroundStyle(InterfaceStyle.color(0x8797AC)).frame(height: 18)
            if flow.handoff != .idle {
                VStack(alignment: .leading, spacing: 10) {
                    Text(handoffTitle).foregroundStyle(InterfaceStyle.blue)
                    Text(handoffHelp).foregroundStyle(InterfaceStyle.color(0x7087A5))
                }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 80)
                    .background(InterfaceStyle.color(0xECF4FF), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var handoffTitle: String {
        let suffix = flow.isSimulation ? " · 演示反馈" : ""
        switch flow.handoff {
        case .opening: return "正在请求打开终端" + suffix
        case .opened: return "已请求打开终端" + suffix
        case .terminalUnavailable: return "终端不可用，请重试或复制命令" + suffix
        case .copying: return "正在复制命令" + suffix
        case .copied: return "已复制" + suffix
        case .copyFailed: return "复制失败，可重试或选择命令文本" + suffix
        case .idle: return ""
        }
    }
    private var handoffHelp: String {
        flow.isSimulation ? "未打开终端、未写剪贴板；预览中的 SSH 别名没有安装。" : "终端交接不代表 SSH 会话已经连接；可复制命令手动执行。"
    }
    @ViewBuilder private var actions: some View {
        HStack(spacing: 12) {
            switch flow.state {
            case .success:
                Button(flow.handoff == .opened ? "已请求打开终端" : "在终端打开") { flow.performHandoff() }.buttonStyle(InterfaceButtonStyle(primary: true, width: 112, height: 38))
                Button("返回服务器", action: finish).buttonStyle(InterfaceButtonStyle(width: 112, height: 38)).keyboardShortcut(.cancelAction)
                if flow.handoff != .idle {
                    Button((flow.handoff == .copied ? "已复制" : "复制命令") + (flow.isSimulation ? "（演示）" : "")) { flow.performHandoff(copy: true) }.buttonStyle(InterfaceButtonStyle(height: 38))
                }
            case .failed(let failure):
                Button(failure == .authentication && flow.failureDetail == nil ? "修改账户或密码" : "返回修改") { flow.edit() }.buttonStyle(InterfaceButtonStyle(primary: true, width: 137, height: 38)).keyboardShortcut(.cancelAction)
                if failure != .identityMismatch {
                    Button("重新验证") { flow.retry() }.buttonStyle(InterfaceButtonStyle(width: 112, height: 38)).keyboardShortcut(.defaultAction)
                }
            case .cancelled:
                Button("返回表单") { flow.edit() }.buttonStyle(InterfaceButtonStyle(primary: true, width: 137, height: 38)).keyboardShortcut(.cancelAction)
                Button("重新验证") { flow.retry() }.buttonStyle(InterfaceButtonStyle(width: 112, height: 38))
            case .running, .checkingHost:
                Button(flow.state == .running(.login) || flow.state == .checkingHost ? "取消并返回表单" : "停止后续步骤") { flow.cancel() }.buttonStyle(InterfaceButtonStyle(primary: true, width: 137, height: 38)).keyboardShortcut(.cancelAction)
            default: EmptyView()
            }
        }
    }
    private func finish() { flow.close(); onClose(flow.draft) }
}
