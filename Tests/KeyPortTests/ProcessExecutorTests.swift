import Foundation
@testable import KeyPort
import XCTest

/// 可取消 ProcessExecutor 的结构化结果、超时、输出上限、
/// Task cancellation 与 TERM 后 2 秒 KILL 的证据（真实子进程）。
final class ProcessExecutorTests: XCTestCase {
    private let executor = ProcessExecutor()

    private func limits(
        timeout: TimeInterval = 10,
        maxOut: Int = 512 * 1024,
        maxErr: Int = 512 * 1024,
        maxCombined: Int? = nil,
        grace: TimeInterval = 2
    ) -> ProcessExecutionLimits {
        ProcessExecutionLimits(
            timeout: timeout,
            maximumStdoutBytes: maxOut,
            maximumStderrBytes: maxErr,
            maximumCombinedOutputBytes: maxCombined,
            terminationGrace: grace
        )
    }

    func testExitStatusAndSeparatedOutputAreCaptured() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello; printf oops >&2; exit 3"],
            limits: limits()
        ))
        XCTAssertEqual(result.ending, .exited(3))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "oops")
        XCTAssertFalse(result.succeeded)
    }

    func testStandardInputIsDelivered() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/cat",
            arguments: [],
            standardInput: Data("fixture-stdin-payload".utf8),
            limits: limits()
        ))
        XCTAssertEqual(result.ending, .exited(0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "fixture-stdin-payload")
    }

    func testEnvironmentIsMergedWithoutLeakingIntoResult() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$KEYPORT_FIXTURE_ENV\""],
            environment: ["KEYPORT_FIXTURE_ENV": "fixture-env-value"],
            limits: limits()
        ))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "fixture-env-value")
    }

    func testStdoutLimitTerminatesAndKeepsBoundedPrefix() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 1000000 /dev/zero"],
            limits: limits(timeout: 30, maxOut: 4096)
        ))
        guard case .outputLimitExceeded = result.ending else {
            return XCTFail("超过 stdout 上限必须是 outputLimitExceeded，实际 \(result.ending)")
        }
        XCTAssertLessThanOrEqual(result.stdout.count, 4096)
    }

    func testStderrLimitTerminates() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 1000000 /dev/zero >&2"],
            limits: limits(timeout: 30, maxErr: 2048)
        ))
        guard case .outputLimitExceeded = result.ending else {
            return XCTFail("超过 stderr 上限必须是 outputLimitExceeded，实际 \(result.ending)")
        }
        XCTAssertLessThanOrEqual(result.stderr.count, 2048)
    }

    func testCombinedOutputLimitTerminatesWhenNeitherStreamIsIndividuallyOverLimit() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 3000 /dev/zero; head -c 3000 /dev/zero >&2"],
            limits: limits(maxOut: 4096, maxErr: 4096, maxCombined: 4096)
        ))

        guard case .outputLimitExceeded = result.ending else {
            return XCTFail("stdout/stderr 总量超过上限必须终止，实际 \(result.ending)")
        }
        XCTAssertLessThanOrEqual(result.stdout.count + result.stderr.count, 4096)
    }

    func testTimeoutTerminatesCooperativeProcessWithTERM() async throws {
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 60"],
            limits: limits(timeout: 0.3)
        ))
        guard case .timedOut(let forcedKill) = result.ending else {
            return XCTFail("超时必须是 timedOut，实际 \(result.ending)")
        }
        XCTAssertFalse(forcedKill, "协作进程应在 TERM 后退出，不需要 KILL")
        XCTAssertLessThan(result.duration, 10, "执行器必须等进程真正退出后才返回")
    }

    func testStubbornProcessIsKilledAfterTwoSecondGrace() async throws {
        let startedAt = Date()
        let result = try await executor.execute(ProcessExecutionRequest(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 10"],
            limits: limits(timeout: 0.3, grace: 2)
        ))
        let elapsed = Date().timeIntervalSince(startedAt)
        guard case .timedOut(let forcedKill) = result.ending else {
            return XCTFail("超时必须是 timedOut，实际 \(result.ending)")
        }
        XCTAssertTrue(forcedKill, "拒绝 TERM 的进程必须在宽限后被 SIGKILL")
        XCTAssertGreaterThanOrEqual(elapsed, 2.0, "KILL 必须发生在 TERM 后 2 秒宽限耗尽时")
        XCTAssertLessThan(elapsed, 15)
    }

    func testTaskCancellationTerminatesProcessPromptly() async throws {
        let task = Task {
            try await executor.execute(ProcessExecutionRequest(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 60"],
                limits: limits(timeout: 60)
            ))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let startedAt = Date()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(startedAt)
        guard case .cancelled = result.ending else {
            return XCTFail("Task 取消必须是 cancelled，实际 \(result.ending)")
        }
        XCTAssertLessThan(elapsed, 10, "执行器在进程真正退出后才返回，因此返回即证明子进程已终止")
    }

    func testLaunchFailureThrows() async {
        do {
            _ = try await executor.execute(ProcessExecutionRequest(
                executable: "/nonexistent/keyport-fixture-binary",
                arguments: [],
                limits: limits()
            ))
            XCTFail("不存在的可执行文件必须抛错")
        } catch let error as ProcessExecutionError {
            guard case .launchFailed = error else {
                return XCTFail("必须是 launchFailed")
            }
        } catch {
            XCTFail("非预期错误类型 \(error)")
        }
    }
}
