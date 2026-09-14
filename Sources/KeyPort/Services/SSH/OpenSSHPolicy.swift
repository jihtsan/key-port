import Foundation
import KeyPortCore

/// Shared strict policy for enrollment, verification and authorization management.
enum OpenSSHPolicy {
    static func arguments(server: ServerConnection, knownHostsPath: String) throws -> [String] {
        guard !knownHostsPath.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SSHServiceError.operationFailed("主机身份记录路径无效，无法开始 SSH 验证。")
        }
        // argv boundaries do not quote OpenSSH's -o configuration-value grammar.
        // UserKnownHostsFile is a list: an unquoted space silently creates another path.
        let quotedKnownHosts = knownHostsPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
        return ["-F", "/dev/null", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "HostKeyAlgorithms=ssh-ed25519"] + [
            "-T", "-p", String(server.port),
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(quotedKnownHosts)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
        ]
    }

}
