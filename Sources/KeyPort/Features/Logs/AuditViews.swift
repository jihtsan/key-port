import KeyPortCore
import SwiftUI

struct AuditLogListView: View {
    let model: AppModel

    var body: some View {
        List(model.snapshot.auditEvents) { event in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.localizedAction).fontWeight(.medium)
                    Spacer()
                    Text(event.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(event.localizedCategory) · \(event.localizedResult)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .navigationTitle("审计日志")
        .overlay {
            if model.snapshot.auditEvents.isEmpty {
                ContentUnavailableView("暂无审计事件", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

private extension AuditEvent {
    var localizedCategory: String {
        switch category {
        case "app": "应用"
        case "server": "服务器"
        case "key": "密钥"
        case "host-key": "主机密钥"
        case "authorization": "授权"
        case "ssh-config": "SSH 配置"
        case "ssh-auth": "SSH 身份验证"
        case "keychain": "Keychain"
        case "cloud": "云同步"
        case "archive": "归档"
        case "machine-config": "机器配置"
        default: category
        }
    }

    var localizedAction: String {
        switch action {
        case "load": "加载应用状态"
        case "create": "创建服务器"
        case "update": "更新服务器"
        case "delete": "删除服务器"
        case "copy-alias": "复制 SSH 别名"
        case "copy-host": "复制主机地址"
        case "scan": "扫描密钥"
        case "generate": "生成密钥"
        case "import": "导入"
        case "load-agent": "加载到 SSH Agent"
        case "confirm": "确认主机密钥"
        case "rotate": "轮换主机密钥"
        case "batch-item": "批量授权"
        case "read": "读取授权"
        case "revoke": "撤销授权"
        case "install": "安装授权"
        case "sync": "同步"
        case "write": "写入配置"
        case "import-server": "导入服务器"
        case "save-password": "保存密码"
        case "export": "导出归档"
        case "password-check": "检查密码 SSH"
        case "key-check": "检查密钥 SSH"
        case "refresh": "刷新"
        default: action
        }
    }

    var localizedResult: String {
        if result.hasPrefix("found-") {
            return "发现 \(result.dropFirst("found-".count)) 项"
        }
        if result.hasPrefix("confirmed-") {
            return "已确认 \(result.dropFirst("confirmed-".count)) 项"
        }
        if result.hasPrefix("keyport-entries-") {
            return "读取到 \(result.dropFirst("keyport-entries-".count)) 项 KeyPort 授权"
        }
        return switch result {
        case "success": "成功"
        case "failed": "失败"
        case "unavailable": "不可用"
        case "tombstoned": "已标记删除"
        case "password-verified": "密码已验证"
        case "ed25519-success": "Ed25519 生成成功"
        case "new-device-ed25519": "已为新设备生成 Ed25519"
        case "fingerprint-verified": "指纹已验证"
        case "metadata-only": "仅导入元数据"
        case "saved-synchronizable": "已保存并允许同步"
        case "saved-local": "已保存到本机"
        case "encrypted-metadata": "已加密元数据"
        case "merged": "已合并"
        case "pending-confirmation": "等待确认"
        case "mismatch-blocked": "因不匹配而阻止"
        case "missing-password": "缺少密码"
        case "missing-key": "缺少密钥"
        case "succeeded": "成功"
        case "rejected": "已拒绝"
        case "not-authorized": "未授权"
        case "succeeded-during-authorization": "授权期间验证成功"
        case "rejected-during-authorization": "授权期间被拒绝"
        case "verified": "已验证"
        case "ed25519": "Ed25519"
        case "rsa": "RSA"
        default: result
        }
    }
}

struct AuditOverviewView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("结构化审计日志") {
                LabeledContent("保留的事件", value: String(model.snapshot.auditEvents.count))
                Text("日志仅包含操作分类、稳定的目标标识符、阶段和结果类型，绝不会记录密码、私钥、命令输出或原始身份验证数据。")
                    .foregroundStyle(.secondary)
                Button("清除日志", role: .destructive) { Task { await model.clearAuditLog() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("审计日志")
    }
}
