import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

/// TrustedSSHSession：Host Key fail closed 门禁、闭集命令执行与稳定失败码映射。
final class TrustedSSHSessionTests: XCTestCase {
    private let knownHostsLine = "db.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureSessionKeyBlob"
    private let fingerprint = "SHA256:fixtureSessionFingerprint"
    private let identityPath = "/Users/fixture/.ssh/keyport/identities/key_fixture"

    private func record(fingerprint: String? = nil) -> HostKeyRecord {
        HostKeyRecord(
            algorithm: "ssh-ed25519",
            fingerprint: fingerprint ?? self.fingerprint,
            knownHostsLine: knownHostsLine,
            firstConfirmedAt: Date(timeIntervalSince1970: 1_787_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_787_000_100)
        )
    }

    /// 路由使用 Tailscale CGNAT 地址：证明即使地址来自 Tailscale/可达，
    /// Host Key 判断也不会被绕过。
    private func route(confirmedKeys: [HostKeyRecord]) -> ServerConnection {
        ServerConnection(
            id: UUID(uuidString: "12340000-0000-4000-8000-000000000001")!,
            name: "tailscale-host",
            host: "100.64.0.7",
            port: 22,
            username: "alice",
            alias: "ts-alice",
            confirmedHostKeys: confirmedKeys,
            status: .authorized
        )
    }

    private func key() -> SSHKeyRecord {
        SSHKeyRecord(
            id: "key_fixture", deviceID: "device_fixture", kind: .ed25519,
            publicKey: "ssh-ed25519 \(Data("fixture-session-public".utf8).base64EncodedString()) keyport",
            fingerprint: "SHA256:fixturePublic",
            privateKeyPath: identityPath,
            isInAgent: false, origin: .generated, isLocallyAvailable: true
        )
    }

    private func keyWithoutPrivateKey() -> SSHKeyRecord {
        var record = key()
        record.privateKeyPath = nil
        return record
    }

    private func makePaths() -> KeyPortPaths {
        KeyPortPaths(home: URL(fileURLWithPath: "/tmp/keyport-session-tests"))
    }

    // MARK: - 门禁

    func testEstablishSucceedsOnlyAfterConfirmedHostKeyAndKeyProbe() async throws {
        let executor = FakeProcessExecutor(responses: [.exited(0)])
        let session = try await TrustedSSHSession.establish(
            route: route(confirmedKeys: [record()]),
            observedHostKeys: [record()],
            identity: key(),
            executor: executor,
            paths: makePaths()
        )
        XCTAssertEqual(session.identityPath, identityPath)

        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(executor.requests.count, 1, "establish 只做一次闭集 authenticationProbe")
        XCTAssertEqual(request.executable, "/usr/bin/ssh")
        XCTAssertEqual(request.arguments, [
            "-T", "-p", "22",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(makePaths().knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "IdentitiesOnly=yes",
        ] + SSHAuthenticationPolicy.publicKeyOnlyArguments + [
            "-i", identityPath,
            "alice@100.64.0.7",
            "exit",
        ])
        XCTAssertNil(request.standardInput)
        XCTAssertTrue(request.environment.isEmpty, "可信会话为公钥认证，不应注入任何秘密环境变量")
    }

    func testPendingHostKeyFailsClosedBeforeAnyProcess() async {
        let executor = FakeProcessExecutor(responses: [])
        do {
            _ = try await TrustedSSHSession.establish(
                route: route(confirmedKeys: []),
                observedHostKeys: [record()],
                identity: key(),
                executor: executor,
                paths: makePaths()
            )
            XCTFail("未确认 Host Key 不得建立会话")
        } catch let failure as StableOperationFailure {
            XCTAssertEqual(failure.code, .hostKeyPending)
            XCTAssertEqual(failure.stage, .sshTrust)
        } catch {
            XCTFail("非预期错误类型 \(error)")
        }
        XCTAssertTrue(executor.requests.isEmpty, "fail closed：不得启动任何进程")
    }

    func testChangedHostKeyFailsClosedEvenOnReachableTailscaleRoute() async {
        let executor = FakeProcessExecutor(responses: [])
        do {
            _ = try await TrustedSSHSession.establish(
                route: route(confirmedKeys: [record()]),
                observedHostKeys: [record(fingerprint: "SHA256:attackerChangedFingerprint")],
                identity: key(),
                executor: executor,
                paths: makePaths()
            )
            XCTFail("Host Key 变更不得建立会话")
        } catch let failure as StableOperationFailure {
            XCTAssertEqual(failure.code, .hostKeyChanged)
            XCTAssertEqual(failure.recoveryAction, .verifyFingerprint)
        } catch {
            XCTFail("非预期错误类型 \(error)")
        }
        XCTAssertTrue(executor.requests.isEmpty)
    }

    func testMissingPrivateKeyYieldsIdentityUnavailable() async {
        let executor = FakeProcessExecutor(responses: [])
        do {
            _ = try await TrustedSSHSession.establish(
                route: route(confirmedKeys: [record()]),
                observedHostKeys: [record()],
                identity: keyWithoutPrivateKey(),
                executor: executor,
                paths: makePaths()
            )
            XCTFail("缺私钥不得建立会话")
        } catch let failure as StableOperationFailure {
            XCTAssertEqual(failure.code, .identityUnavailable)
        } catch {
            XCTFail("非预期错误类型 \(error)")
        }
        XCTAssertTrue(executor.requests.isEmpty)
    }

    // MARK: - 失败码映射

    func testProbeRejectionMapsToKeyAuthenticationFailed() async {
        let executor = FakeProcessExecutor(responses: [
            .exited(255, stderr: "alice@100.64.0.7: Permission denied (publickey).\r\n"),
        ])
        await assertEstablishFails(executor: executor, code: .keyAuthenticationFailed)
    }

    func testProbeHostKeyRejectionMapsToStrictHostKeyRejected() async {
        let executor = FakeProcessExecutor(responses: [
            .exited(255, stderr: "Host key verification failed.\r\n"),
        ])
        await assertEstablishFails(executor: executor, code: .strictHostKeyRejected)
    }

    func testProbeGenericFailureMapsToRemoteExecutionFailed() async {
        let executor = FakeProcessExecutor(responses: [
            .exited(255, stderr: "ssh: connect to host 100.64.0.7 port 22: Connection refused\r\n"),
        ])
        await assertEstablishFails(executor: executor, code: .remoteExecutionFailed)
    }

    func testExecutorTimeoutMapsToTcpTimeout() async {
        let executor = FakeProcessExecutor(responses: [.init(ending: .timedOut(forcedKill: true))])
        await assertEstablishFails(executor: executor, code: .tcpTimeout)
    }

    func testExecutorOutputLimitMapsToOutputLimit() async {
        let executor = FakeProcessExecutor(responses: [.init(ending: .outputLimitExceeded(forcedKill: false))])
        await assertEstablishFails(executor: executor, code: .outputLimit)
    }

    func testExecutorCancellationMapsToProbeCancelled() async {
        let executor = FakeProcessExecutor(responses: [.init(ending: .cancelled(forcedKill: false))])
        await assertEstablishFails(executor: executor, code: .probeCancelled)
    }

    private func assertEstablishFails(
        executor: FakeProcessExecutor,
        code: OperationFailureCode
    ) async {
        do {
            _ = try await TrustedSSHSession.establish(
                route: route(confirmedKeys: [record()]),
                observedHostKeys: [record()],
                identity: key(),
                executor: executor,
                paths: makePaths()
            )
            XCTFail("预期失败 \(code)")
        } catch let failure as StableOperationFailure {
            XCTAssertEqual(failure.code, code)
            // 审计/记录口径：objectID 只含稳定 UUID，不含地址、用户名或秘密。
            XCTAssertEqual(failure.objectID, route(confirmedKeys: []).id.uuidString.lowercased())
        } catch {
            XCTFail("非预期错误类型 \(error)")
        }
    }

    // MARK: - 闭集命令执行

    func testExecuteReadAuthorizedKeysUsesFixedScriptAndNoSecrets() async throws {
        let executor = FakeProcessExecutor(responses: [
            .exited(0),
            .exited(0, stdout: "ssh-ed25519 AAAA... keyport:v1:key_remote:device_remote\n"),
        ])
        let session = try await TrustedSSHSession.establish(
            route: route(confirmedKeys: [record()]),
            observedHostKeys: [record()],
            identity: key(),
            executor: executor,
            paths: makePaths()
        )
        let result = try await session.execute(.readAuthorizedKeys)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("keyport:v1:key_remote"))

        let request = try XCTUnwrap(executor.requests.last)
        XCTAssertEqual(Array(request.arguments.suffix(3)), ["alice@100.64.0.7", "sh", "-s"])
        XCTAssertEqual(
            String(decoding: request.standardInput ?? Data(), as: UTF8.self),
            SSHRemoteCommand.readAuthorizedKeys.spec.standardInputScript
        )
        let markerPassword = "FIXTURE-SECRET-PASSWORD-7f3a9c"
        for captured in executor.requests {
            XCTAssertFalse(captured.arguments.joined(separator: " ").contains(markerPassword))
            XCTAssertFalse(captured.environment.values.joined(separator: " ").contains(markerPassword))
            XCTAssertFalse(String(decoding: captured.standardInput ?? Data(), as: UTF8.self).contains(markerPassword))
        }
    }

    func testExecuteRevokeUsesClosedCommandShape() async throws {
        let executor = FakeProcessExecutor(responses: [.exited(0), .exited(0)])
        let session = try await TrustedSSHSession.establish(
            route: route(confirmedKeys: [record()]),
            observedHostKeys: [record()],
            identity: key(),
            executor: executor,
            paths: makePaths()
        )
        let blob = Data("fixture-revoke-blob".utf8).base64EncodedString()
        _ = try await session.execute(.revokeAuthorizedKey(keyBlob: blob))
        let request = try XCTUnwrap(executor.requests.last)
        let script = String(decoding: request.standardInput ?? Data(), as: UTF8.self)
        XCTAssertTrue(script.contains("awk -v blob='\(blob)'"))
        XCTAssertTrue(script.contains("mv \"$tmp\" \"$auth\""))
        // 协议层没有 run(command: String)：调用方只能给闭集 case 的结构化数据。
        XCTAssertEqual(Array(request.arguments.suffix(2)), ["sh", "-s"])
    }
}

// MARK: - Fake executor

private final class FakeProcessExecutor: ProcessExecuting, @unchecked Sendable {
    struct Stub {
        let result: ProcessExecutionResult

        init(ending: ProcessExecutionEnding, stdout: String = "", stderr: String = "") {
            result = ProcessExecutionResult(
                ending: ending,
                stdout: Data(stdout.utf8),
                stderr: Data(stderr.utf8),
                duration: 0.01
            )
        }

        static func exited(_ status: Int32, stdout: String = "", stderr: String = "") -> Stub {
            Stub(ending: .exited(status), stdout: stdout, stderr: stderr)
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private(set) var requests: [ProcessExecutionRequest] = []

    init(responses: [Stub]) {
        stubs = responses
    }

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        lock.lock()
        requests.append(request)
        let stub = stubs.isEmpty ? Stub(ending: .exited(0)) : stubs.removeFirst()
        lock.unlock()
        return stub.result
    }
}
