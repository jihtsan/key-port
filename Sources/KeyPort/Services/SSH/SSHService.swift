import Foundation
import KeyPortCore
import Darwin

enum SSHServiceError: LocalizedError {
    case hostKeyNotConfirmed
    case hostKeyChanged
    case missingPrivateKey
    case missingPassword
    case passwordAuthenticationRejected
    case identityRouteUnavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyNotConfirmed: "身份验证前，请先确认服务器主机密钥。"
        case .hostKeyChanged: "主机密钥已变更，身份验证被阻止。"
        case .missingPrivateKey: "所选密钥没有可用的本地私钥。"
        case .missingPassword: "Keychain 中未存储服务器密码。"
        case .passwordAuthenticationRejected: "服务器拒绝了密码登录。"
        case .identityRouteUnavailable: "该身份的 SSH 路由被 v6 兼容层关闭（存在待解决冲突或无可用地址）。"
        case .operationFailed(let message): message
        }
    }
}

actor OpenSSHService {
    private let runner: ProcessRunner
    private let paths: KeyPortPaths
    private let askPassPath: String

    init(runner: ProcessRunner, paths: KeyPortPaths = KeyPortPaths(), askPassPath: String) {
        self.runner = runner
        self.paths = paths
        self.askPassPath = askPassPath
    }

    func testPublicKey(server: ServerConnection, key: SSHKeyRecord) async throws -> Bool {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        guard let identity = key.privateKeyPath else { throw SSHServiceError.missingPrivateKey }
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + SSHAuthenticationPolicy.publicKeyOnlyArguments + [
            "-i", identity,
            "\(server.username)@\(server.host)",
            "exit",
        ])
        if result.succeeded { return true }
        if authenticationWasRejected(result.stderr) { return false }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func testPassword(server: ServerConnection, passwordData: Data) async throws -> Bool {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let broker = try passwordBroker(passwordData: passwordData)
        defer { broker.cleanup() }
        broker.startWriter()
        let result = try await runner.run(
            "/usr/bin/ssh",
            arguments: commonArguments(server: server) + SSHAuthenticationPolicy.passwordOnlyArguments + [
                "\(server.username)@\(server.host)",
                "exit",
            ],
            environment: askPassEnvironment(broker: broker)
        )
        if result.succeeded { return true }
        if authenticationWasRejected(result.stderr) { return false }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func inspectMachineWithPassword(server: ServerConnection, passwordData: Data) async throws -> RemoteMachineConfiguration? {
        let broker = try passwordBroker(passwordData: passwordData)
        defer { broker.cleanup() }
        broker.startWriter()
        let result = try await runner.run(
            "/usr/bin/ssh",
            arguments: commonArguments(server: server) + SSHAuthenticationPolicy.passwordOnlyArguments + [
                "\(server.username)@\(server.host)",
                "sh", "-s",
            ],
            input: Data(machineConfigurationScript.utf8),
            environment: askPassEnvironment(broker: broker)
        )
        if result.succeeded { return RemoteMachineConfigurationParser.parse(result.stdout) }
        if authenticationWasRejected(result.stderr) { return nil }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func inspectMachineWithPublicKey(server: ServerConnection, key: SSHKeyRecord) async throws -> RemoteMachineConfiguration? {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        guard let identity = key.privateKeyPath else { throw SSHServiceError.missingPrivateKey }
        let result = try await runner.run(
            "/usr/bin/ssh",
            arguments: commonArguments(server: server) + SSHAuthenticationPolicy.publicKeyOnlyArguments + [
                "-i", identity,
                "\(server.username)@\(server.host)",
                "sh", "-s",
            ],
            input: Data(machineConfigurationScript.utf8)
        )
        if result.succeeded { return RemoteMachineConfigurationParser.parse(result.stdout) }
        if authenticationWasRejected(result.stderr) { return nil }
        throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
    }

    func installPublicKey(server: ServerConnection, key: SSHKeyRecord, passwordData: Data) async throws {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        guard let parsed = PublicKeyParser.parse(key.publicKey) else {
            throw SSHServiceError.operationFailed("所选公钥无效。")
        }

        let encodedLine = Data(key.publicKey.utf8).base64EncodedString()
        let script = enrollmentScript(encodedLine: encodedLine, keyBlob: parsed.blob)
        let broker = try passwordBroker(passwordData: passwordData)
        defer { broker.cleanup() }
        broker.startWriter()
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + SSHAuthenticationPolicy.passwordOnlyArguments + [
            "\(server.username)@\(server.host)",
            "sh", "-s",
        ], input: Data(script.utf8), environment: askPassEnvironment(broker: broker))
        guard result.succeeded else {
            if authenticationWasRejected(result.stderr) {
                throw SSHServiceError.passwordAuthenticationRejected
            }
            throw SSHServiceError.operationFailed(classifyAuthenticationError(result.stderr))
        }
    }

    func revokePublicKey(server: ServerConnection, fingerprint: String, publicKeyBlob: String, identityPath: String) async throws {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let script = revocationScript(keyBlob: publicKeyBlob)
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + [
            "-o", "BatchMode=yes", "-i", identityPath,
            "\(server.username)@\(server.host)", "sh", "-s",
        ], input: Data(script.utf8))
        guard result.succeeded else { throw SSHServiceError.operationFailed("无法撤销远程授权。") }
        _ = fingerprint
    }

    func readAuthorizedKeys(server: ServerConnection, identityPath: String) async throws -> [AuthorizedKeyLine] {
        guard !server.confirmedHostKeys.isEmpty else { throw SSHServiceError.hostKeyNotConfirmed }
        let script = SSHRemoteCommandScripts.readAuthorizedKeys
        let result = try await runner.run("/usr/bin/ssh", arguments: commonArguments(server: server) + [
            "-o", "BatchMode=yes", "-i", identityPath,
            "\(server.username)@\(server.host)", "sh", "-s",
        ], input: Data(script.utf8))
        guard result.succeeded else { throw SSHServiceError.operationFailed("无法读取远程 authorized_keys 文件。") }
        return AuthorizedKeysParser.parse(result.stdout)
    }

    private func commonArguments(server: ServerConnection) -> [String] {
        [
            "-T", "-p", String(server.port),
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(paths.knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
        ]
    }

    private var machineConfigurationScript: String {
        SSHRemoteCommandScripts.machineInspection
    }

    private func passwordBroker(passwordData: Data) throws -> PasswordFIFO {
        guard FileManager.default.isExecutableFile(atPath: askPassPath) else {
            throw SSHServiceError.operationFailed("KeyPort AskPass 辅助程序不可用。")
        }
        return try PasswordFIFO(paths: paths, passwordData: passwordData)
    }

    private func askPassEnvironment(broker: PasswordFIFO) -> [String: String] {
        [
            "SSH_ASKPASS": askPassPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "keyport",
            "KEYPORT_PASSWORD_PIPE": broker.path,
        ]
    }

    private func enrollmentScript(encodedLine: String, keyBlob: String) -> String {
        SSHRemoteCommandScripts.installAuthorizedKey(encodedLine: encodedLine, keyBlob: keyBlob)
    }

    private func revocationScript(keyBlob: String) -> String {
        SSHRemoteCommandScripts.revokeAuthorizedKey(keyBlob: keyBlob)
    }

    private func classifyAuthenticationError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("host key verification failed") { return "主机密钥验证失败，SSH 操作已被阻止。" }
        if lower.contains("permission denied") { return "服务器拒绝了密码登录。" }
        if lower.contains("connection timed out") || lower.contains("operation timed out") { return "SSH 连接超时。" }
        if lower.contains("connection refused") { return "SSH 服务器拒绝了连接。" }
        if lower.contains("could not resolve hostname") { return "无法解析 SSH 服务器名称。" }
        if lower.contains("no route to host") { return "没有可用的网络路由连接 SSH 服务器。" }
        return "SSH 身份验证操作失败。"
    }

    private func authenticationWasRejected(_ stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("permission denied")
    }
}

private final class PasswordFIFO: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let lock = NSLock()
    private var passwordData: Data
    private var isActive = true

    init(paths: KeyPortPaths, passwordData: Data) throws {
        let directory = paths.applicationSupport.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        self.path = directory.appendingPathComponent("password.fifo").path
        self.passwordData = passwordData
        guard mkfifo(path, S_IRUSR | S_IWUSR) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw SSHServiceError.operationFailed("无法创建受保护的 AskPass 通道。")
        }
    }

    func startWriter() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while writerIsActive {
                let descriptor = Darwin.open(path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    guard var secret = takePassword() else {
                        Darwin.close(descriptor)
                        return
                    }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    handle.write(secret)
                    try? handle.close()
                    secret.resetBytes(in: secret.indices)
                    return
                }
                guard errno == ENXIO || errno == ENOENT else {
                    cancelWriter()
                    return
                }
                usleep(10_000)
            }
        }
    }

    func cleanup() {
        cancelWriter()
        try? FileManager.default.removeItem(at: directory)
    }

    private var writerIsActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    private func takePassword() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        isActive = false
        let secret = passwordData
        passwordData.resetBytes(in: passwordData.indices)
        return secret
    }

    private func cancelWriter() {
        lock.lock()
        isActive = false
        passwordData.resetBytes(in: passwordData.indices)
        lock.unlock()
    }
}
