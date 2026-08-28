import Foundation
import KeyPortCore

enum HostKeyServiceError: LocalizedError {
    case scanFailed(String)
    case noKeys

    var errorDescription: String? {
        switch self {
        case .scanFailed(let detail): "主机密钥扫描失败：\(detail)"
        case .noKeys: "端点未返回受支持的 SSH 主机密钥。"
        }
    }
}

actor HostKeyService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths

    init(runner: ProcessRunner, paths: KeyPortPaths = KeyPortPaths()) {
        self.runner = runner
        self.paths = paths
    }

    func scan(server: ServerConnection) async throws -> [HostKeyRecord] {
        let result = try await runner.run("/usr/bin/ssh-keyscan", arguments: ["-T", "5", "-p", String(server.port), server.host])
        let lines = result.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        let keys = lines.compactMap { line -> HostKeyRecord? in
            guard let parsed = PublicKeyParser.parse(line) else { return nil }
            return HostKeyRecord(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: line)
        }
        if keys.isEmpty {
            if !result.succeeded {
                throw HostKeyServiceError.scanFailed(
                    sanitized(result.stderr, status: result.status, endpoint: server.endpoint)
                )
            }
            throw HostKeyServiceError.noKeys
        }
        return keys
    }

    func persistConfirmedKeys(_ keys: [HostKeyRecord], allServers: [ServerConnection]) throws {
        try paths.prepareDirectories()
        let lines = allServers.flatMap(\.confirmedHostKeys).map(\.knownHostsLine)
        let merged = Array(Set(lines + keys.map(\.knownHostsLine))).sorted().joined(separator: "\n")
        try atomicWrite((merged.isEmpty ? "" : merged + "\n"), to: paths.knownHosts, permissions: 0o600)
    }

    private func sanitized(_ error: String, status: Int32, endpoint: String) -> String {
        let lowercasedError = error.lowercased()
        if lowercasedError.contains("timed out") || lowercasedError.contains("timeout") {
            return "连接 \(endpoint) 超时。"
        }
        if lowercasedError.contains("connection refused") {
            return "端点 \(endpoint) 拒绝了连接。"
        }
        if lowercasedError.contains("resolve") || lowercasedError.contains("name or service not known") {
            return "无法解析端点 \(endpoint)。"
        }
        if lowercasedError.contains("no route to host") || lowercasedError.contains("network is unreachable") {
            return "没有可用的网络路由连接端点 \(endpoint)。"
        }
        if status == 1 {
            return "5 秒内未收到来自 \(endpoint) 的 SSH 主机密钥响应。"
        }
        return "对 \(endpoint) 执行 ssh-keyscan 时以状态码 \(status) 退出。"
    }

    private func atomicWrite(_ text: String, to destination: URL, permissions: Int) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }
}
