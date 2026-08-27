import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

final class ListenerDiscoveryAdapterTests: XCTestCase {
    private let hostID = UUID(uuidString: "12340000-0000-4000-8000-000000000001")!

    func testAdapterUsesTrustedSessionAndReturnsOnlySanitizedCandidates() async throws {
        let executor = DiscoveryFakeProcessExecutor(responses: [
            .exited(0),
            .exited(0, stdout: "platform=linux\ntool=ss\n"),
            .exited(0, stdout: "LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:((\"api\",pid=1,fd=3))\n")
        ])
        let session = try await makeSession(executor: executor)

        let result = try await SSHListenerDiscoveryAdapter().discover(using: session)

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].port, 8080)
        XCTAssertEqual(result.candidates[0].processHint, "api")
        XCTAssertEqual(executor.requests.count, 3)
        XCTAssertEqual(
            String(decoding: executor.requests[1].standardInput ?? Data(), as: UTF8.self),
            SSHRemoteCommand.listenerCapabilities.spec.standardInputScript
        )
        XCTAssertEqual(
            String(decoding: executor.requests[2].standardInput ?? Data(), as: UTF8.self),
            SSHRemoteCommand.listenerSnapshot.spec.standardInputScript
        )
        XCTAssertEqual(executor.requests[2].limits.timeout, 10)
        XCTAssertEqual(executor.requests[2].limits.maximumStdoutBytes, 512 * 1024)
        XCTAssertEqual(executor.requests[2].limits.maximumStderrBytes, 512 * 1024)
        XCTAssertEqual(executor.requests[2].limits.maximumCombinedOutputBytes, 512 * 1024)
    }

    func testAdapterDispatchesLinuxOnlyLsofOutputToTheLsofParser() async throws {
        let executor = DiscoveryFakeProcessExecutor(responses: [
            .exited(0),
            .exited(0, stdout: "platform=linux\ntool=lsof\n"),
            .exited(
                0,
                stdout: "p101\0cnginx\0\nf1\0n127.0.0.1:8080\0TST=LISTEN\0"
            )
        ])
        let session = try await makeSession(executor: executor)

        let result = try await SSHListenerDiscoveryAdapter().discover(using: session)

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].port, 8080)
        XCTAssertEqual(result.candidates[0].processHint, "nginx")
    }

    func testMissingToolMapsToStableDiscoveryFailure() async throws {
        let executor = DiscoveryFakeProcessExecutor(responses: [
            .exited(0),
            .exited(0, stdout: "platform=linux\n")
        ])
        let session = try await makeSession(executor: executor)

        do {
            _ = try await SSHListenerDiscoveryAdapter().discover(using: session)
            XCTFail("缺少监听工具必须失败")
        } catch let failure as StableOperationFailure {
            XCTAssertEqual(failure.stage, .discovery)
            XCTAssertEqual(failure.objectID, hostID.uuidString.lowercased())
            XCTAssertEqual(failure.code, .toolUnavailable)
            XCTAssertEqual(failure.recoveryAction, .installSystemTool)
        }
    }

    func testSnapshotExit127AndExecutionBoundariesMapToStableCodes() async throws {
        let endings: [(ProcessExecutionEnding, OperationFailureCode)] = [
            (.exited(127), .toolUnavailable),
            (.timedOut(forcedKill: false), .tcpTimeout),
            (.outputLimitExceeded(forcedKill: true), .outputLimit),
            (.cancelled(forcedKill: false), .probeCancelled)
        ]

        for (ending, expectedCode) in endings {
            let executor = DiscoveryFakeProcessExecutor(responses: [
                .exited(0),
                .exited(0, stdout: "platform=linux\ntool=ss\n"),
                .init(ending: ending)
            ])
            let session = try await makeSession(executor: executor)

            do {
                _ = try await SSHListenerDiscoveryAdapter().discover(using: session)
                XCTFail("预期发现失败 \(expectedCode)")
            } catch let failure as StableOperationFailure {
                XCTAssertEqual(failure.stage, .discovery)
                XCTAssertEqual(failure.code, expectedCode)
            }
        }
    }

    func testPermissionDiagnosticBecomesWarningWithoutPersistingDiagnosticText() async throws {
        let executor = DiscoveryFakeProcessExecutor(responses: [
            .exited(0),
            .exited(0, stdout: "platform=macos\ntool=lsof\n"),
            .exited(
                0,
                stdout: "p1\0n127.0.0.1:8080\0TST=LISTEN\0",
                stderr: "permission denied for process details: FIXTURE_RAW_DIAGNOSTIC"
            )
        ])
        let session = try await makeSession(executor: executor)

        let result = try await SSHListenerDiscoveryAdapter().discover(using: session)

        XCTAssertTrue(result.warnings.contains(.permissionLimited))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertFalse(result.candidates.description.contains("FIXTURE_RAW_DIAGNOSTIC"))
    }

    private func makeSession(executor: DiscoveryFakeProcessExecutor) async throws -> TrustedSSHSession {
        let hostKey = HostKeyRecord(
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:fixture-discovery-host",
            knownHostsLine: "discovery.example ssh-ed25519 AAAAFixtureDiscoveryHostKey",
            firstConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let route = ServerConnection(
            id: hostID,
            name: "discovery-host",
            host: "discovery.example",
            username: "alice",
            alias: "discovery-alice",
            confirmedHostKeys: [hostKey],
            status: .authorized
        )
        let key = SSHKeyRecord(
            id: "key-discovery",
            deviceID: "device-discovery",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAAFixtureDiscoveryPublicKey keyport",
            fingerprint: "SHA256:fixture-discovery-public",
            privateKeyPath: "/Users/fixture/.ssh/keyport/identities/discovery",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )
        return try await TrustedSSHSession.establish(
            route: route,
            observedHostKeys: [hostKey],
            identity: key,
            executor: executor,
            paths: KeyPortPaths(home: URL(fileURLWithPath: "/tmp/keyport-discovery-tests"))
        )
    }
}

private final class DiscoveryFakeProcessExecutor: ProcessExecuting, @unchecked Sendable {
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
