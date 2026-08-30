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
    private let transportAdapter: SSHTransportAdapter

    init(
        runner: ProcessRunner,
        paths: KeyPortPaths = KeyPortPaths(),
        transportAdapter: SSHTransportAdapter = SSHTransportAdapter()
    ) {
        self.runner = runner
        self.paths = paths
        self.transportAdapter = transportAdapter
    }

    func scan(
        server: ServerConnection,
        transport: SSHConnectionTransport = .direct
    ) async throws -> [HostKeyRecord] {
        let transport = try transportAdapter.configuration(for: transport)
        if transport.proxyCommand != nil {
            return try await scanThroughOpenSSH(server: server, transport: transport)
        }

        let result = try await runner.run("/usr/bin/ssh-keyscan", arguments: ["-T", "5", "-p", String(server.port), server.host])
        let keys = hostKeys(in: result.stdout)
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

    private func scanThroughOpenSSH(
        server: ServerConnection,
        transport: SSHTransportConfiguration
    ) async throws -> [HostKeyRecord] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-host-key-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedKnownHosts = directory.appendingPathComponent("known_hosts")
        let arguments = [
            "-T", "-p", String(server.port),
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(capturedKnownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HashKnownHosts=no",
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=none",
            "-o", "NumberOfPasswordPrompts=0",
        ] + transport.openSSHArguments + [
            "\(server.username)@\(server.host)",
        ]
        let result = try await runner.run("/usr/bin/ssh", arguments: arguments)
        let captured = (try? String(contentsOf: capturedKnownHosts, encoding: .utf8)) ?? ""
        let keys = hostKeys(in: captured)
        guard keys.isEmpty else { return keys }
        if !result.succeeded {
            throw HostKeyServiceError.scanFailed(
                sanitized(result.stderr, status: result.status, endpoint: server.endpoint)
            )
        }
        throw HostKeyServiceError.noKeys
    }

    private func hostKeys(in output: String) -> [HostKeyRecord] {
        output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") }
            .compactMap { line -> HostKeyRecord? in
                guard let parsed = PublicKeyParser.parse(line) else { return nil }
                return HostKeyRecord(
                    algorithm: parsed.type,
                    fingerprint: parsed.fingerprint,
                    knownHostsLine: line
                )
            }
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
