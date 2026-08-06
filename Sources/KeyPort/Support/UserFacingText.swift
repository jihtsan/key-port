import Foundation
import OSLog

enum UserFacingText {
    private static let logger = Logger(subsystem: "com.jihtsan.KeyPort", category: "UserFacingError")

    // Compatibility shim for English details persisted by earlier app versions.
    static func localized(_ text: String) -> String {
        if text.hasPrefix("Changed algorithms: "), text.hasSuffix(". Authentication was blocked.") {
            let algorithms = text
                .dropFirst("Changed algorithms: ".count)
                .dropLast(". Authentication was blocked.".count)
            return "发生变更的算法：\(algorithms)。身份验证已被阻止。"
        }
        if text.hasPrefix("Host key changed for "), text.hasSuffix(". Password authentication was blocked.") {
            let algorithms = text
                .dropFirst("Host key changed for ".count)
                .dropLast(". Password authentication was blocked.".count)
            return "以下算法的主机密钥已变更：\(algorithms)。密码身份验证已被阻止。"
        }

        return switch text {
        case "The endpoint changed. Confirm its host key before authentication.": "端点已变更，身份验证前请确认其主机密钥。"
        case "The login account changed and must be checked again.": "登录账户已变更，必须重新检查。"
        case "Connection details changed. Password SSH was verified; check key authorization again.": "连接信息已变更。密码 SSH 已验证，请重新检查密钥授权。"
        case "Password SSH verified. This Mac key can now be authorized.": "密码 SSH 已验证，现在可以授权此 Mac 的密钥。"
        case "Host key confirmed from the current network response.": "已根据当前网络响应确认主机密钥。"
        case "This Mac key is ready for authorization.": "此 Mac 的密钥已准备好授权。"
        case "This Mac authorization was revoked.": "此 Mac 的授权已撤销。"
        case "The configured SSH identity changed. Check this connection before authorizing it.": "已配置的 SSH 身份密钥发生变化，请在授权前检查此连接。"
        case "Passwordless SSH authentication succeeded.": "免密 SSH 身份验证成功。"
        case "The current Mac key is not authorized.": "当前 Mac 的密钥尚未授权。"
        case "Host key confirmation is required.": "需要确认主机密钥。"
        case "Fetching host keys before the key login check.": "密钥登录检查前正在获取主机密钥。"
        case "Review the host key fingerprints before authentication.": "身份验证前，请核对主机密钥指纹。"
        case "Enter and test a server password before checking Password SSH.": "检查密码 SSH 前，请输入并测试服务器密码。"
        case "Password SSH authentication succeeded.": "密码 SSH 身份验证成功。"
        case "Server password authentication succeeded.": "服务器密码身份验证成功。"
        case "The stored server password was rejected.": "服务器拒绝了已存储的密码。"
        case "No local private key is available for this Mac.": "此 Mac 没有可用的本地私钥。"
        case "Server password authentication succeeded during authorization.": "授权期间服务器密码身份验证成功。"
        case "The key was installed, but passwordless SSH verification failed.": "密钥已安装，但免密 SSH 验证失败。"
        case "Passwordless SSH authentication succeeded after authorization.": "授权后免密 SSH 身份验证成功。"
        case "Public key installed and verified.": "公钥已安装并通过验证。"
        case "Confirm this endpoint on the current network before authentication.": "身份验证前，请在当前网络上确认此端点。"
        case "Synced metadata has no private key for this Mac.": "同步的元数据中没有此 Mac 的私钥。"
        case "Run a local check before relying on this authorization.": "依赖此授权前，请先运行本地检查。"
        default: text
        }
    }

    static func localizedError(_ error: Error) -> String {
        let description = error.localizedDescription
        let translated = localized(description)
        if translated != description || containsHanCharacters(description) {
            return translated
        }

        logger.error("Normalizing system error for display: \(description, privacy: .private)")
        let lowercaseDescription = description.lowercased()
        if error is CancellationError || lowercaseDescription.contains("cancelled") || lowercaseDescription.contains("canceled") {
            return "操作已取消。"
        }
        if lowercaseDescription.contains("timed out") || lowercaseDescription.contains("timeout") {
            return "操作超时，请检查网络连接后重试。"
        }
        if lowercaseDescription.contains("network") || lowercaseDescription.contains("not connected to the internet") {
            return "网络不可用，请检查网络连接后重试。"
        }
        if lowercaseDescription.contains("permission") || lowercaseDescription.contains("not permitted") {
            return "没有完成此操作所需的权限。"
        }
        if lowercaseDescription.contains("not found") || lowercaseDescription.contains("no such file") {
            return "找不到完成此操作所需的文件或项目。"
        }
        return "操作失败，请稍后重试。"
    }

    private static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
