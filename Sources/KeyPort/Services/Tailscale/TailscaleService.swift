import Foundation
import KeyPortCore

enum TailscaleServiceError: LocalizedError {
    case notInstalled
    case statusFailed(Int32)
    case invalidStatus(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "未找到 Tailscale。请先安装并登录 Tailscale。"
        case .statusFailed(let status):
            "无法读取 Tailscale 状态（退出码 \(status)）。"
        case .invalidStatus(let detail):
            "Tailscale 返回了无法识别的设备状态：\(detail)"
        }
    }
}

actor TailscaleService {
    private let runner: ProcessRunner

    init(runner: ProcessRunner) {
        self.runner = runner
    }

    func status() async throws -> TailscaleStatus {
        guard let executable = Self.executablePath() else {
            throw TailscaleServiceError.notInstalled
        }
        let result = try await runner.run(executable, arguments: ["status", "--json"])
        guard result.succeeded else {
            throw TailscaleServiceError.statusFailed(result.status)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw TailscaleServiceError.invalidStatus("输出不是 UTF-8 文本。")
        }
        do {
            return try TailscaleStatusParser.parse(data)
        } catch {
            throw TailscaleServiceError.invalidStatus(String(describing: error))
        }
    }

    private static func executablePath() -> String? {
        let manager = FileManager.default
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        return candidates.first(where: manager.isExecutableFile(atPath:))
    }
}
