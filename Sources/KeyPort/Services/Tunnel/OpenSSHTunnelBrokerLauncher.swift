import Darwin
import Foundation
import KeyPortCore

struct OpenSSHTunnelBrokerLauncher: TunnelBrokerLaunching, Sendable {
    let executablePath: String
    let readinessTimeoutNanoseconds: UInt64
    let evidenceClock: @Sendable () -> Date

    init(
        executablePath: String = OpenSSHTunnelBrokerLauncher.defaultExecutablePath(),
        readinessTimeoutNanoseconds: UInt64 = 5_000_000_000,
        evidenceClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executablePath = executablePath
        self.readinessTimeoutNanoseconds = readinessTimeoutNanoseconds
        self.evidenceClock = evidenceClock
    }

    func launch(_ configuration: TunnelBrokerConfiguration) async throws -> any TunnelBrokerSession {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw TunnelBrokerLaunchError.exited
        }
        let command: TunnelBrokerCommand
        do {
            command = try TunnelBrokerCommandBuilder.make(configuration: configuration)
        } catch {
            throw TunnelBrokerLaunchError.exited
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = command.brokerArguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw TunnelBrokerLaunchError.exited
        }

        let session = OpenSSHTunnelBrokerSession(
            process: process,
            input: input,
            output: output,
            controlPath: configuration.controlPath,
            readinessTimeoutNanoseconds: readinessTimeoutNanoseconds,
            evidenceClock: evidenceClock
        )
        do {
            try await session.waitForForwardEstablished()
            return session
        } catch {
            _ = await session.close()
            if error is CancellationError {
                throw error
            }
            if let error = error as? TunnelBrokerLaunchError {
                throw error
            }
            throw TunnelBrokerLaunchError.exited
        }
    }

    private static func defaultExecutablePath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/KeyPortTunnelBroker")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("KeyPortTunnelBroker").path ?? bundled
    }
}

private final class OpenSSHTunnelBrokerSession: TunnelBrokerTerminationObserving, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let controlPath: String
    private let readinessTimeoutNanoseconds: UInt64
    private let evidenceClock: @Sendable () -> Date
    private let outputReadLock = NSLock()
    private let lock = NSLock()
    private var recognizer = TunnelBrokerOutputRecognizer()
    private var readiness: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        process: Process,
        input: Pipe,
        output: Pipe,
        controlPath: String,
        readinessTimeoutNanoseconds: UInt64,
        evidenceClock: @escaping @Sendable () -> Date
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.controlPath = controlPath
        self.readinessTimeoutNanoseconds = readinessTimeoutNanoseconds
        self.evidenceClock = evidenceClock

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finishAfterTermination()
        }
    }

    func waitForForwardEstablished() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await waitUntilReady()
            }
            group.addTask { [readinessTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: readinessTimeoutNanoseconds)
                throw TunnelBrokerLaunchError.targetProbeIndeterminate
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func verifyTarget() async throws {
        guard process.isRunning else { throw TunnelBrokerLaunchError.exited }
        let readiness = readinessValue()
        guard case .success? = readiness else {
            throw TunnelBrokerLaunchError.exited
        }
    }

    func verifyTarget(
        tunnelID: UUID,
        operationID: UUID,
        subject: TunnelSubject
    ) async throws -> TargetVerificationEvidence {
        try await verifyTarget()
        return TargetVerificationEvidence(
            tunnelID: tunnelID,
            operationID: operationID,
            subject: subject,
            verifiedAt: evidenceClock()
        )
    }

    var processIdentifier: Int32? {
        process.processIdentifier > 0 ? process.processIdentifier : nil
    }

    func waitForTermination() async {
        while process.isRunning, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func close() async -> CleanupStatus {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return await closeControlMaster() }

        let exited = waitForExit(timeout: 0.25)
        if exited { return await closeControlMaster() }
        process.terminate()
        if waitForExit(timeout: 0.25) {
            return await closeControlMaster()
        }
        kill(process.processIdentifier, SIGKILL)
        let processExited = waitForExit(timeout: 0.25)
        let controlMasterCleanup = await closeControlMaster()
        return processExited && controlMasterCleanup == .completed ? .completed : .pending
    }

    private func consume(_ data: Data) {
        lock.lock()
        let events = recognizer.consume(data)
        lock.unlock()

        for event in events {
            switch event {
            case .forwardEstablished:
                resolve(.success(()))
            case .forwardRejected:
                resolve(.failure(TunnelBrokerLaunchError.forwardRejected))
            case .targetRefused:
                resolve(.failure(TunnelBrokerLaunchError.targetRefused))
            case .targetTimedOut:
                resolve(.failure(TunnelBrokerLaunchError.targetTimeout))
            case .targetProbeIndeterminate:
                resolve(.failure(TunnelBrokerLaunchError.targetProbeIndeterminate))
            case .unknownOutput:
                resolve(.failure(TunnelBrokerLaunchError.unknownOutput))
            }
        }
    }

    private func consumeAvailableData(from handle: FileHandle) {
        outputReadLock.lock()
        let data = handle.availableData
        if !data.isEmpty {
            consume(data)
        }
        outputReadLock.unlock()
    }

    private func finishAfterTermination() {
        output.fileHandleForReading.readabilityHandler = nil
        outputReadLock.lock()
        let data = output.fileHandleForReading.availableData
        if !data.isEmpty {
            consume(data)
        }
        consumeFinalLine()
        outputReadLock.unlock()
        resolve(.failure(TunnelBrokerLaunchError.exited))
    }

    private func consumeFinalLine() {
        lock.lock()
        let events = recognizer.finish()
        lock.unlock()
        for event in events {
            switch event {
            case .forwardEstablished:
                resolve(.success(()))
            case .forwardRejected:
                resolve(.failure(TunnelBrokerLaunchError.forwardRejected))
            case .targetRefused:
                resolve(.failure(TunnelBrokerLaunchError.targetRefused))
            case .targetTimedOut:
                resolve(.failure(TunnelBrokerLaunchError.targetTimeout))
            case .targetProbeIndeterminate:
                resolve(.failure(TunnelBrokerLaunchError.targetProbeIndeterminate))
            case .unknownOutput:
                resolve(.failure(TunnelBrokerLaunchError.unknownOutput))
            }
        }
    }

    private func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let readiness {
                    lock.unlock()
                    continuation.resume(with: readiness)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard readiness == nil else {
            lock.unlock()
            return
        }
        readiness = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func readinessValue() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return readiness
    }

    private func closeControlMaster() async -> CleanupStatus {
        if await OpenSSHControlMasterExiter().exit(controlPath: controlPath) {
            return .completed
        }
        return FileManager.default.fileExists(atPath: controlPath) ? .pending : .completed
    }

    private func waitForExit(timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        let semaphore = DispatchSemaphore(value: 0)
        let process = self.process
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
