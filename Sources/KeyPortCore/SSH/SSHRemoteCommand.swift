import Foundation

/// 一次远端调用的固定形态：远端参数与可选的 stdin 脚本。
/// 脚本文本编译进应用，调用方只能提供闭集 enum 要求的结构化数据（如公钥行），
/// 不能拼接脚本文本、参数数组或用户插值。
public struct SSHRemoteCommandSpec: Hashable, Sendable {
    /// 追加在 `user@host` 之后的远端参数，例如 `["exit"]` 或 `["sh", "-s"]`。
    public var remoteArguments: [String]
    /// 通过 stdin 发送的固定脚本；`nil` 表示该命令不读取 stdin。
    public var standardInputScript: String?

    public init(remoteArguments: [String], standardInputScript: String?) {
        self.remoteArguments = remoteArguments
        self.standardInputScript = standardInputScript
    }
}

/// 闭集远端命令。这是协议层唯一的远端执行入口：
/// 不存在 `run(command: String)` 形式的 API，任何新远端能力都必须先在这里
/// 增加具名 case 并固定其命令形态。
public enum SSHRemoteCommand: Hashable, Sendable {
    /// 认证探针：`exit`，只证明当前认证方式可用。
    case authenticationProbe
    /// 采集远端机器配置（hostname / OS / kernel / arch / CPU / 内存）。
    case machineInspection
    /// 读取远端 `~/.ssh/authorized_keys`（不存在时返回空）。
    case readAuthorizedKeys
    /// 安装一行公钥到 `authorized_keys`（备份 + 原子替换 + 写后校验）。
    /// `encodedLine` 是完整公钥行的 base64；`keyBlob` 是去重用的公钥正文。
    case installAuthorizedKey(encodedLine: String, keyBlob: String)
    /// 按公钥正文从 `authorized_keys` 移除（备份 + 原子替换 + 写后校验）。
    case revokeAuthorizedKey(keyBlob: String)

    /// 从一行 OpenSSH 公钥文本构造安装命令；公钥无法解析时返回 `nil`。
    public static func installAuthorizedKey(publicKeyLine: String) -> SSHRemoteCommand? {
        guard let parsed = PublicKeyParser.parse(publicKeyLine) else { return nil }
        return .installAuthorizedKey(
            encodedLine: Data(publicKeyLine.utf8).base64EncodedString(),
            keyBlob: parsed.blob
        )
    }

    public var spec: SSHRemoteCommandSpec {
        switch self {
        case .authenticationProbe:
            return SSHRemoteCommandSpec(remoteArguments: ["exit"], standardInputScript: nil)
        case .machineInspection:
            return SSHRemoteCommandSpec(
                remoteArguments: ["sh", "-s"],
                standardInputScript: SSHRemoteCommandScripts.machineInspection
            )
        case .readAuthorizedKeys:
            return SSHRemoteCommandSpec(
                remoteArguments: ["sh", "-s"],
                standardInputScript: SSHRemoteCommandScripts.readAuthorizedKeys
            )
        case .installAuthorizedKey(let encodedLine, let keyBlob):
            return SSHRemoteCommandSpec(
                remoteArguments: ["sh", "-s"],
                standardInputScript: SSHRemoteCommandScripts.installAuthorizedKey(
                    encodedLine: encodedLine,
                    keyBlob: keyBlob
                )
            )
        case .revokeAuthorizedKey(let keyBlob):
            return SSHRemoteCommandSpec(
                remoteArguments: ["sh", "-s"],
                standardInputScript: SSHRemoteCommandScripts.revokeAuthorizedKey(keyBlob: keyBlob)
            )
        }
    }
}

/// 编译进应用的固定脚本文本。密码等秘密永远不会进入脚本或参数；
/// 密码只经 AskPass FIFO 传递（见 App 侧 SSH 服务）。
public enum SSHRemoteCommandScripts {
    public static let machineInspection = """
    hostname_value=$(hostname 2>/dev/null || uname -n)
    kernel_value=$(uname -sr 2>/dev/null || uname -a)
    architecture_value=$(uname -m 2>/dev/null || printf unknown)
    if command -v sw_vers >/dev/null 2>&1; then
      operating_system_value=$(printf '%s %s' "$(sw_vers -productName)" "$(sw_vers -productVersion)")
      memory_bytes_value=$(sysctl -n hw.memsize 2>/dev/null || true)
      processor_count_value=$(sysctl -n hw.logicalcpu 2>/dev/null || true)
    else
      operating_system_value=$(awk -F= '/^PRETTY_NAME=/{value=$2; gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release 2>/dev/null)
      [ -n "$operating_system_value" ] || operating_system_value=$(uname -s 2>/dev/null || printf unknown)
      memory_kib_value=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
      memory_bytes_value=$([ -n "$memory_kib_value" ] && printf '%s' "$((memory_kib_value * 1024))" || true)
      processor_count_value=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    fi
    printf 'hostname\t%s\n' "$hostname_value"
    printf 'operating_system\t%s\n' "$operating_system_value"
    printf 'kernel\t%s\n' "$kernel_value"
    printf 'architecture\t%s\n' "$architecture_value"
    printf 'processor_count\t%s\n' "$processor_count_value"
    printf 'memory_bytes\t%s\n' "$memory_bytes_value"
    """

    public static let readAuthorizedKeys = """
    test ! -f "$HOME/.ssh/authorized_keys" || cat "$HOME/.ssh/authorized_keys"

    """

    public static func installAuthorizedKey(encodedLine: String, keyBlob: String) -> String {
        """
        set -eu
        umask 077
        key_line=$(printf '%s' '\(encodedLine)' | base64 -d)
        key_blob='\(keyBlob)'
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        auth="$HOME/.ssh/authorized_keys"
        touch "$auth"
        chmod 600 "$auth"
        if awk -v blob="$key_blob" '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"; then
          exit 0
        fi
        backup="$auth.keyport-backup-$(date +%Y%m%d%H%M%S)"
        cp -p "$auth" "$backup"
        tmp="$auth.keyport-tmp-$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        cp "$auth" "$tmp"
        printf '%s\n' "$key_line" >> "$tmp"
        chmod 600 "$tmp"
        mv "$tmp" "$auth"
        trap - EXIT HUP INT TERM
        awk -v blob="$key_blob" '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"
        """
    }

    public static func revokeAuthorizedKey(keyBlob: String) -> String {
        """
        set -eu
        umask 077
        auth="$HOME/.ssh/authorized_keys"
        [ -f "$auth" ] || exit 0
        backup="$auth.keyport-backup-$(date +%Y%m%d%H%M%S)"
        cp -p "$auth" "$backup"
        tmp="$auth.keyport-tmp-$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        awk -v blob='\(keyBlob)' '{ remove=0; for (i=1; i<=NF; i++) if ($i == blob) remove=1; if (!remove) print $0 }' "$auth" > "$tmp"
        chmod 600 "$tmp"
        mv "$tmp" "$auth"
        trap - EXIT HUP INT TERM
        if awk -v blob='\(keyBlob)' '{ for (i=1; i<=NF; i++) if ($i == blob) found=1 } END { exit(found ? 0 : 1) }' "$auth"; then
          exit 1
        fi
        """
    }
}
