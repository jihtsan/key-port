import Foundation
import Darwin

/// 一次进程执行的边界：墙钟超时、stdout/stderr 字节上限、TERM 后的宽限时间。
/// 秘密不得进入参数或环境值以外的任何通道；执行器本身不写日志，
/// 结果只带有界输出，调用方负责只记录稳定失败码。
struct ProcessExecutionLimits: Sendable, Equatable {
    var timeout: TimeInterval
    var maximumStdoutBytes: Int
    var maximumStderrBytes: Int
    /// Optional combined stdout/stderr budget. A discovery command uses this
    /// to keep the total bounded even when both pipes produce output.
    var maximumCombinedOutputBytes: Int?
    /// 超限/超时/取消后先 SIGTERM，超过该宽限仍存活则 SIGKILL。
    var terminationGrace: TimeInterval

    init(
        timeout: TimeInterval,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int,
        maximumCombinedOutputBytes: Int? = nil,
        terminationGrace: TimeInterval = 2
    ) {
        self.timeout = timeout
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.maximumCombinedOutputBytes = maximumCombinedOutputBytes
        self.terminationGrace = terminationGrace
    }

    /// SSH 固定命令的默认边界（架构第 11/13 节：发现 10 秒、512 KiB；TERM 后 2 秒 KILL）。
    static let sshDefault = ProcessExecutionLimits(
        timeout: 10,
        maximumStdoutBytes: 512 * 1024,
        maximumStderrBytes: 512 * 1024,
        maximumCombinedOutputBytes: 512 * 1024
    )
}

struct ProcessExecutionRequest: Sendable {
    var executable: String
    var arguments: [String]
    var standardInput: Data?
    var environment: [String: String]
    var limits: ProcessExecutionLimits

    init(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        limits: ProcessExecutionLimits
    ) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.limits = limits
    }
}

enum ProcessExecutionEnding: Sendable, Equatable {
    /// 进程自行退出（含非零状态）。
    case exited(Int32)
    /// 超过墙钟超时后被终止；`forcedKill` 表示 TERM 宽限耗尽后使用了 SIGKILL。
    case timedOut(forcedKill: Bool)
    /// stdout 或 stderr 超过字节上限后被终止。
    case outputLimitExceeded(forcedKill: Bool)
    /// 响应 Task cancellation 被终止。
    case cancelled(forcedKill: Bool)
}

struct ProcessExecutionResult: Sendable {
    var ending: ProcessExecutionEnding
    /// 有界输出：超过上限时只保留上限内的前缀。
    var stdout: Data
    var stderr: Data
    var duration: TimeInterval

    var succeeded: Bool {
        if case .exited(0) = ending { return true }
        return false
    }
}

enum ProcessExecutionError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self { case .launchFailed(let message): message }
    }
}

/// 可注入的进程执行端口；测试用 fake 完整驱动 TrustedSSHSession。
protocol ProcessExecuting: Sendable {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult
}

/// 可取消、有超时与输出上限的进程执行器。
/// 与 legacy `ProcessRunner` 相比：支持 Task cancellation、墙钟超时、
/// stdout/stderr 字节上限，终止时先 SIGTERM、宽限（默认 2 秒）后 SIGKILL，
/// 并返回结构化结果而不是裸字符串。
struct ProcessExecutor: ProcessExecuting {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        let startedAt = Date()
        let state = ProcessExecutionState(limits: request.limits)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe? = request.standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        state.attach(process: process)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            state.appendStdout(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            state.appendStderr(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessExecutionError.launchFailed("无法启动 \(request.executable)。")
        }

        if let input = request.standardInput, let inputPipe {
            // stdin 写入失败（子进程提前关闭）不影响主流程，与 legacy 行为一致。
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }

        // 取消可能先于 run 到达；启动后补偿一次已记录的终止请求。
        state.terminateIfRequested()

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, request.limits.timeout) * 1_000_000_000))
            state.requestTermination(reason: .timedOut)
        }

        await withTaskCancellationHandler {
            await state.waitForExit()
        } onCancel: {
            state.requestTermination(reason: .cancelled)
        }

        timeoutTask.cancel()

        // 进程已退出：收尾剩余管道数据（此时必然 EOF），保持输出有界。
        state.finishDraining(
            stdout: outputPipe.fileHandleForReading,
            stderr: errorPipe.fileHandleForReading
        )

        return state.result(duration: Date().timeIntervalSince(startedAt))
    }
}

/// 单次执行的锁保护状态机。
private final class ProcessExecutionState: @unchecked Sendable {
    enum TerminationReason {
        case timedOut
        case outputLimitExceeded
        case cancelled
    }

    private let lock = NSLock()
    private let limits: ProcessExecutionLimits
    private var process: Process?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutReceived = 0
    private var stderrReceived = 0
    private var combinedReceived = 0
    private var stdoutEOF = false
    private var stderrEOF = false
    private var terminationReason: TerminationReason?
    private var terminationRequested = false
    private var terminationSignalSent = false
    private var forcedKill = false
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var didExit = false

    init(limits: ProcessExecutionLimits) {
        self.limits = limits
    }

    func attach(process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
        process.terminationHandler = { [weak self] _ in
            self?.markExited()
        }
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else {
            lock.lock()
            stdoutEOF = true
            lock.unlock()
            return
        }
        lock.lock()
        stdoutReceived += data.count
        combinedReceived += data.count
        if stdoutData.count < limits.maximumStdoutBytes {
            let remaining = limits.maximumStdoutBytes - stdoutData.count
            let combinedRemaining = limits.maximumCombinedOutputBytes.map {
                max(0, $0 - stdoutData.count - stderrData.count)
            } ?? remaining
            stdoutData.append(data.prefix(min(remaining, combinedRemaining)))
        }
        let streamOverflow = stdoutReceived > limits.maximumStdoutBytes
        let combinedOverflow = limits.maximumCombinedOutputBytes.map {
            combinedReceived > $0
        } ?? false
        lock.unlock()
        if streamOverflow || combinedOverflow {
            requestTermination(reason: .outputLimitExceeded)
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else {
            lock.lock()
            stderrEOF = true
            lock.unlock()
            return
        }
        lock.lock()
        stderrReceived += data.count
        combinedReceived += data.count
        if stderrData.count < limits.maximumStderrBytes {
            let remaining = limits.maximumStderrBytes - stderrData.count
            let combinedRemaining = limits.maximumCombinedOutputBytes.map {
                max(0, $0 - stdoutData.count - stderrData.count)
            } ?? remaining
            stderrData.append(data.prefix(min(remaining, combinedRemaining)))
        }
        let streamOverflow = stderrReceived > limits.maximumStderrBytes
        let combinedOverflow = limits.maximumCombinedOutputBytes.map {
            combinedReceived > $0
        } ?? false
        lock.unlock()
        if streamOverflow || combinedOverflow {
            requestTermination(reason: .outputLimitExceeded)
        }
    }

    /// 只记录第一个终止原因；重复调用幂等。
    func requestTermination(reason: TerminationReason) {
        lock.lock()
        if terminationReason == nil { terminationReason = reason }
        terminationRequested = true
        lock.unlock()
        terminateIfRequested()
    }

    /// 已记录终止请求且进程在运行时执行 TERM->KILL；进程刚启动时也可补偿调用，
    /// 内部标志保证信号序列只发起一次。
    func terminateIfRequested() {
        lock.lock()
        guard terminationRequested, !didExit, !terminationSignalSent,
              let process, process.isRunning else {
            lock.unlock()
            return
        }
        terminationSignalSent = true
        lock.unlock()

        // 契约要求先 SIGTERM；Foundation 的 interrupt() 是 SIGINT，不能用。
        kill(process.processIdentifier, SIGTERM)
        let grace = limits.terminationGrace
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            self?.forceKillIfAlive()
        }
    }

    private func forceKillIfAlive() {
        lock.lock()
        guard !didExit, let process, process.isRunning else {
            lock.unlock()
            return
        }
        forcedKill = true
        let pid = process.processIdentifier
        lock.unlock()
        kill(pid, SIGKILL)
    }

    private func markExited() {
        lock.lock()
        didExit = true
        let continuation = exitContinuation
        exitContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didExit {
                lock.unlock()
                continuation.resume()
            } else {
                exitContinuation = continuation
                lock.unlock()
            }
        }
    }

    /// 进程已退出后的收尾：正常退出时管道立即 EOF，handler 会清空剩余缓冲；
    /// 被终止进程可能留下持有管道的孤儿子进程（永远没有 EOF），因此 EOF 等待
    /// 必须有界——超过 300ms 直接以已收集的有界输出收口。
    func finishDraining(stdout: FileHandle, stderr: FileHandle) {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            lock.lock()
            let done = stdoutEOF && stderrEOF
            lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
    }

    func result(duration: TimeInterval) -> ProcessExecutionResult {
        lock.lock()
        let reason = terminationReason
        let killed = forcedKill
        let status = process?.terminationStatus ?? -1
        let ending: ProcessExecutionEnding
        switch reason {
        case .timedOut: ending = .timedOut(forcedKill: killed)
        case .outputLimitExceeded: ending = .outputLimitExceeded(forcedKill: killed)
        case .cancelled: ending = .cancelled(forcedKill: killed)
        case nil: ending = .exited(status)
        }
        let result = ProcessExecutionResult(
            ending: ending,
            stdout: stdoutData,
            stderr: stderrData,
            duration: duration
        )
        lock.unlock()
        return result
    }
}
