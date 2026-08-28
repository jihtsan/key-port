import Foundation
import KeyPortCore

extension StableOperationFailure: Error {}

struct TrustedSSHCommandResult: Sendable {
    var stdout: Data
    var stderr: Data
    var ending: ProcessExecutionEnding
}

/// 可信 SSH 会话（架构 8.1）：只有 Host Key 已确认且当前 Mac 公钥认证通过后
/// 才能创建；创建后只能执行 `SSHRemoteCommand` 闭集命令，没有 `run(command: String)`。
/// Host Key changed 一律 fail closed——可达性、SSID、Tailscale 都不是会话的输入，
/// 结构上无法绕过信任判断。
struct TrustedSSHSession: Sendable {
    let route: ServerConnection
    let identityPath: String

    private let executor: any ProcessExecuting
    private let knownHostsPath: String

    private init(
        route: ServerConnection,
        identityPath: String,
        executor: any ProcessExecuting,
        knownHostsPath: String
    ) {
        self.route = route
        self.identityPath = identityPath
        self.executor = executor
        self.knownHostsPath = knownHostsPath
    }

    /// 建立会话：先对扫描到的 Host Key 做信任评估（fail closed），
    /// 再用闭集 `authenticationProbe` 验证当前 Mac 的公钥认证。
    static func establish(
        route: ServerConnection,
        observedHostKeys: [HostKeyRecord],
        identity: SSHKeyRecord,
        executor: any ProcessExecuting,
        paths: KeyPortPaths = KeyPortPaths(),
        limits: ProcessExecutionLimits = .sshDefault
    ) async throws -> TrustedSSHSession {
        let objectID = route.id.uuidString.lowercased()
        switch HostKeyEvaluator.evaluate(observed: observedHostKeys, confirmed: route.confirmedHostKeys) {
        case .confirmed:
            break
        case .pending:
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .hostKeyPending, recoveryAction: .verifyFingerprint
            )
        case .changed:
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .hostKeyChanged, recoveryAction: .verifyFingerprint
            )
        }
        guard let identityPath = identity.privateKeyPath, !identityPath.isEmpty else {
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .identityUnavailable, recoveryAction: .prepareLocalKey
            )
        }

        let session = TrustedSSHSession(
            route: route,
            identityPath: identityPath,
            executor: executor,
            knownHostsPath: paths.knownHosts.path
        )
        _ = try await session.execute(.authenticationProbe, limits: limits)
        return session
    }

    /// 执行闭集命令；秘密不进入参数，密码类操作不经过可信会话
    /// （可信会话固定 BatchMode 公钥认证）。
    func execute(
        _ command: SSHRemoteCommand,
        limits: ProcessExecutionLimits = .sshDefault
    ) async throws -> TrustedSSHCommandResult {
        let result = try await executeRaw(command, limits: limits)
        let objectID = route.id.uuidString.lowercased()
        switch result.ending {
        case .exited(0):
            return result
        case .exited:
            let stderrText = String(decoding: result.stderr, as: UTF8.self)
            if stderrText.localizedCaseInsensitiveContains("permission denied") {
                throw StableOperationFailure(
                    stage: .sshTrust, objectID: objectID,
                    code: .keyAuthenticationFailed, recoveryAction: .reauthorize
                )
            }
            if stderrText.localizedCaseInsensitiveContains("host key verification failed") {
                throw StableOperationFailure(
                    stage: .sshTrust, objectID: objectID,
                    code: .strictHostKeyRejected, recoveryAction: .verifyFingerprint
                )
            }
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .remoteExecutionFailed, recoveryAction: .retry
            )
        case .timedOut:
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .tcpTimeout, recoveryAction: .retry
            )
        case .outputLimitExceeded:
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .outputLimit, recoveryAction: .retry
            )
        case .cancelled:
            throw StableOperationFailure(
                stage: .sshTrust, objectID: objectID,
                code: .probeCancelled, recoveryAction: .retry
            )
        }
    }

    /// 返回闭集命令的有界原始结果，供平台适配器将退出状态转换为各自的稳定码。
    /// 调用方必须在内存中消费 stdout/stderr，禁止将其写入记录、日志或归档。
    func executeRaw(
        _ command: SSHRemoteCommand,
        limits: ProcessExecutionLimits = .sshDefault
    ) async throws -> TrustedSSHCommandResult {
        let result = try await executor.execute(Self.request(
            route: route,
            identityPath: identityPath,
            knownHostsPath: knownHostsPath,
            command: command,
            limits: limits
        ))
        return TrustedSSHCommandResult(stdout: result.stdout, stderr: result.stderr, ending: result.ending)
    }

    /// 组装一次可信执行的完整请求。参数与 legacy `commonArguments` 语义一致；
    /// 只含路由与密钥定位，绝不含密码或其他秘密。
    static func request(
        route: ServerConnection,
        identityPath: String,
        knownHostsPath: String,
        command: SSHRemoteCommand,
        limits: ProcessExecutionLimits
    ) -> ProcessExecutionRequest {
        let spec = command.spec
        let arguments = [
            "-T", "-p", String(route.port),
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
        ] + SSHAuthenticationPolicy.publicKeyOnlyArguments + [
            "-i", identityPath,
            "\(route.username)@\(route.host)",
        ] + spec.remoteArguments
        return ProcessExecutionRequest(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            standardInput: spec.standardInputScript.map { Data($0.utf8) },
            limits: limits
        )
    }
}
