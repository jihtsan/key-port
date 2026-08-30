import Foundation
import KeyPortCore

enum SSHTransportAdapterError: LocalizedError, Equatable, Sendable {
    case tailscaleCLIUnavailable

    var errorDescription: String? {
        switch self {
        case .tailscaleCLIUnavailable:
            "所选 Tailnet 路径需要 Tailscale CLI，但当前 Mac 未找到可执行的 Tailscale。"
        }
    }
}

struct SSHTransportConfiguration: Equatable, Sendable {
    let openSSHArguments: [String]
    let proxyCommand: String?
}

/// Resolves a planned transport once, then supplies the matching OpenSSH and
/// SSH Config representation to every caller.
struct SSHTransportAdapter: Sendable {
    private let tailscaleCLIPath: String?

    init() {
        self.init(tailscaleCLIPath: Self.installedTailscaleCLIPath())
    }

    init(tailscaleCLIPath: String?) {
        self.tailscaleCLIPath = tailscaleCLIPath
    }

    func configuration(
        for transport: SSHConnectionTransport
    ) throws -> SSHTransportConfiguration {
        switch transport {
        case .direct:
            return SSHTransportConfiguration(openSSHArguments: [], proxyCommand: nil)
        case .tailscaleCLI:
            guard let tailscaleCLIPath else {
                throw SSHTransportAdapterError.tailscaleCLIUnavailable
            }
            let proxyCommand = "\(tailscaleCLIPath) nc %h %p"
            return SSHTransportConfiguration(
                openSSHArguments: ["-o", "ProxyCommand=\(proxyCommand)"],
                proxyCommand: proxyCommand
            )
        }
    }

    private static func installedTailscaleCLIPath(
        fileManager: FileManager = .default
    ) -> String? {
        [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ].first(where: fileManager.isExecutableFile(atPath:))
    }
}
