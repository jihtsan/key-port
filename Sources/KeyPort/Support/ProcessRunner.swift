import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

actor ProcessRunner {
    private let executor: any ProcessExecuting
    init(executor: any ProcessExecuting = ProcessExecutor()) { self.executor = executor }

    func run(
        _ executable: String,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let result = try await executor.execute(.init(executable: executable, arguments: arguments,
            standardInput: input, environment: environment, limits: .sshDefault))
        switch result.ending {
        case .exited(let status):
            return ProcessResult(status: status, stdout: String(decoding: result.stdout, as: UTF8.self),
                                 stderr: String(decoding: result.stderr, as: UTF8.self))
        case .cancelled: throw CancellationError()
        default: throw SSHServiceError.operationFailed("操作超时或输出超限，已停止。")
        }
    }
}
