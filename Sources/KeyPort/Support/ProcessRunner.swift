import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

actor ProcessRunner {
    private let executor: (any ProcessExecuting)?
    init(executor: (any ProcessExecuting)? = nil) { self.executor = executor }

    func run(
        _ executable: String,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        if let executor {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if let input {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        process.waitUntilExit()
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}
