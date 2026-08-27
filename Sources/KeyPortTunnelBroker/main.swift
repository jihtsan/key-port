import Darwin
import Foundation
import KeyPortCore
import Network

@main
struct KeyPortTunnelBrokerMain {
    static func main() {
        do {
            let arguments = try TunnelBrokerArguments(Array(CommandLine.arguments.dropFirst()))
            try TunnelBrokerRuntime(arguments: arguments).run()
            exit(EXIT_SUCCESS)
        } catch let error as TunnelBrokerRuntimeError {
            writeBrokerStatus("FORWARD_FAILED \(error.rawValue)")
            exit(EXIT_FAILURE)
        } catch {
            writeBrokerStatus("FORWARD_FAILED unknown")
            exit(EXIT_FAILURE)
        }
    }
}

private func writeBrokerStatus(_ status: String) {
    FileHandle.standardOutput.write(Data("\(status)\n".utf8))
}

private struct TunnelBrokerArguments: Sendable {
    let configuration: TunnelBrokerConfiguration

    init(_ arguments: [String]) throws {
        guard arguments.first == "start" else { throw TunnelBrokerRuntimeError.invalidArguments }
        let values = Array(arguments.dropFirst())
        guard values.count.isMultiple(of: 2) else { throw TunnelBrokerRuntimeError.invalidArguments }

        var fields: [String: String] = [:]
        var index = 0
        while index < values.count {
            let key = values[index]
            let value = values[index + 1]
            guard Self.allowedKeys.contains(key), fields[key] == nil, !value.isEmpty else {
                throw TunnelBrokerRuntimeError.invalidArguments
            }
            fields[key] = value
            index += 2
        }

        guard let localPort = UInt16(fields["--local-port"] ?? ""),
              let remotePort = UInt16(fields["--remote-port"] ?? ""),
              let sshPort = UInt16(fields["--ssh-port"] ?? ""),
              let remoteHost = fields["--remote-host"],
              let sshHost = fields["--ssh-host"],
              let username = fields["--username"],
              let identityPath = fields["--identity-path"],
              let knownHostsPath = fields["--known-hosts-path"],
              let controlPath = fields["--control-path"],
              let leasePath = fields["--lease-path"] else {
            throw TunnelBrokerRuntimeError.invalidArguments
        }
        let configuration = TunnelBrokerConfiguration(
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            sshHost: sshHost,
            sshPort: sshPort,
            username: username,
            identityPath: identityPath,
            knownHostsPath: knownHostsPath,
            controlPath: controlPath,
            leasePath: leasePath
        )
        do {
            _ = try TunnelBrokerCommandBuilder.make(configuration: configuration)
        } catch {
            throw TunnelBrokerRuntimeError.invalidArguments
        }
        self.configuration = configuration
    }

    private static let allowedKeys: Set<String> = [
        "--local-port",
        "--remote-host",
        "--remote-port",
        "--ssh-host",
        "--ssh-port",
        "--username",
        "--identity-path",
        "--known-hosts-path",
        "--control-path",
        "--lease-path"
    ]
}

private enum TunnelBrokerRuntimeError: String, Error {
    case invalidArguments = "invalid_arguments"
    case forwardRejected = "forward_rejected"
    case targetRefused = "target_refused"
    case targetTimeout = "target_timeout"
    case targetProbeIndeterminate = "target_probe_indeterminate"
    case unknown = "unknown"
}

private struct TunnelBrokerRuntime {
    let arguments: TunnelBrokerArguments

    func run() throws {
        try validateRuntimePaths()
        try validateOpenSSHVersion()
        let command = try TunnelBrokerCommandBuilder.make(configuration: arguments.configuration)
        defer { cleanup() }

        let ssh = Process()
        let diagnostics = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = command.sshArguments
        ssh.standardOutput = FileHandle.nullDevice
        ssh.standardError = diagnostics
        let collector = BoundedDiagnosticCollector()
        defer { diagnostics.fileHandleForReading.readabilityHandler = nil }
        diagnostics.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.consume(data) }
        }
        do {
            try ssh.run()
        } catch {
            throw TunnelBrokerRuntimeError.forwardRejected
        }

        guard waitForControlMaster(timeout: 5.0, process: ssh) else {
            collector.finish()
            terminateSSHIfRunning(ssh)
            throw collector.failure ?? TunnelBrokerRuntimeError.forwardRejected
        }
        guard ssh.isRunning else {
            collector.finish()
            throw collector.failure ?? TunnelBrokerRuntimeError.forwardRejected
        }

        let probe = LocalTargetProbe(port: arguments.configuration.localPort).run()
        let targetResult: OpenSSHTargetResult
        switch probe.result {
        case .reachable:
            targetResult = collector.waitForTargetResult(timeout: 5.0)
        case .refused, .timedOut, .indeterminate:
            guard probe.cancelAndWait(timeout: probe.cancellationTimeout) else {
                throw TunnelBrokerRuntimeError.targetProbeIndeterminate
            }
            throw runtimeError(for: probe.result)
        }

        switch targetResult {
        case .confirmed:
            try publishForwardEstablished(
                after: probe,
                cancellationTimeout: probe.cancellationTimeout
            )
        case .refused:
            guard probe.cancelAndWait(timeout: probe.cancellationTimeout) else {
                terminateSSHIfRunning(ssh)
                throw TunnelBrokerRuntimeError.targetProbeIndeterminate
            }
            throw TunnelBrokerRuntimeError.targetRefused
        case .timedOut:
            guard probe.cancelAndWait(timeout: probe.cancellationTimeout) else {
                terminateSSHIfRunning(ssh)
                throw TunnelBrokerRuntimeError.targetProbeIndeterminate
            }
            throw TunnelBrokerRuntimeError.targetTimeout
        case .indeterminate, .none:
            guard probe.cancelAndWait(timeout: probe.cancellationTimeout) else {
                terminateSSHIfRunning(ssh)
                throw TunnelBrokerRuntimeError.targetProbeIndeterminate
            }
            terminateSSHIfRunning(ssh)
            throw TunnelBrokerRuntimeError.targetProbeIndeterminate
        }

        _ = FileHandle.standardInput.readDataToEndOfFile()
    }

    private func validateOpenSSHVersion() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-V"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw TunnelBrokerRuntimeError.forwardRejected
        }
        guard waitForExit(process, timeout: 1.0), process.terminationStatus == 0 else {
            throw TunnelBrokerRuntimeError.targetProbeIndeterminate
        }
        let versionData = output.fileHandleForReading.readData(ofLength: 4 * 1024)
        let versionOutput = String(decoding: versionData, as: UTF8.self)
        guard OpenSSHVersionPolicy.isSupported(versionOutput) else {
            throw TunnelBrokerRuntimeError.targetProbeIndeterminate
        }
    }

    private func waitForControlMaster(timeout: TimeInterval, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if controlMasterIsAlive() { return true }
            if !process.isRunning { return false }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    private func terminateSSHIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        _ = waitForExit(process, timeout: 0.25)
    }

    private func runtimeError(for result: LocalTargetProbeResult) -> TunnelBrokerRuntimeError {
        switch result {
        case .reachable, .indeterminate: .targetProbeIndeterminate
        case .refused: .targetRefused
        case .timedOut: .targetTimeout
        }
    }

    private func validateRuntimePaths() throws {
        let configuration = arguments.configuration
        let runtimeDirectory = URL(fileURLWithPath: configuration.leasePath)
            .standardizedFileURL
            .deletingLastPathComponent()
        let controlPath = URL(fileURLWithPath: configuration.controlPath).standardizedFileURL
        let leasePath = URL(fileURLWithPath: configuration.leasePath).standardizedFileURL
        let resolvedRuntimeDirectory = runtimeDirectory.resolvingSymlinksInPath()
        let resolvedControlPath = controlPath.resolvingSymlinksInPath()
        let resolvedLeasePath = leasePath.resolvingSymlinksInPath()
        let controlToken = String(controlPath.lastPathComponent.dropFirst("control-".count)
            .dropLast(".sock".count))
        let leaseToken = String(leasePath.lastPathComponent.dropFirst("lease-".count)
            .dropLast(".json".count))
        guard controlPath.deletingLastPathComponent() == runtimeDirectory,
              leasePath.deletingLastPathComponent() == runtimeDirectory,
              resolvedControlPath.deletingLastPathComponent() == resolvedRuntimeDirectory,
              resolvedLeasePath.deletingLastPathComponent() == resolvedRuntimeDirectory,
              controlPath.path.utf8.count <= 103,
              controlPath.lastPathComponent.hasPrefix("control-"),
              controlPath.pathExtension == "sock",
              leasePath.lastPathComponent.hasPrefix("lease-"),
              leasePath.pathExtension == "json",
              controlToken == leaseToken,
              isValidRuntimeToken(controlToken) else {
            throw TunnelBrokerRuntimeError.invalidArguments
        }
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeDirectory.path
        )
        guard isOwnedPrivateDirectory(runtimeDirectory) else {
            throw TunnelBrokerRuntimeError.invalidArguments
        }
        if FileManager.default.fileExists(atPath: leasePath.path),
           !isOwnedPrivateFile(leasePath) {
            throw TunnelBrokerRuntimeError.invalidArguments
        }
    }

    private func controlMasterIsAlive() -> Bool {
        let configuration = arguments.configuration
        let target = configuration.sshHost.contains(":")
            ? "\(configuration.username)@[\(configuration.sshHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]"
            : "\(configuration.username)@\(configuration.sshHost)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-S", configuration.controlPath, "-O", "check",
            "-p", String(configuration.sshPort), target
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func cleanup() {
        let configuration = arguments.configuration
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let target = configuration.sshHost.contains(":")
            ? "\(configuration.username)@[\(configuration.sshHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]"
            : "\(configuration.username)@\(configuration.sshHost)"
        process.arguments = [
            "-T",
            "-S", configuration.controlPath,
            "-O", "exit",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=1",
            "-p", String(configuration.sshPort),
            target
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exitSucceeded: Bool
        if let _ = try? process.run() {
            exitSucceeded = waitForExit(process, timeout: 0.5) && process.terminationStatus == 0
        } else {
            exitSucceeded = false
        }
        let controlSocketExists = FileManager.default.fileExists(atPath: configuration.controlPath)
        guard exitSucceeded || !controlSocketExists else { return }
        try? FileManager.default.removeItem(atPath: configuration.controlPath)
        try? FileManager.default.removeItem(atPath: configuration.leasePath)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if semaphore.wait(timeout: .now() + 0.25) == .timedOut,
               process.processIdentifier > 0 {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 0.25)
            }
            return false
        }
        return true
    }

    private func isOwnedPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            return false
        }
        return (info.st_mode & 0o077) == 0
    }

    private func isOwnedPrivateFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            return false
        }
        return (info.st_mode & 0o077) == 0
    }

    private func isValidRuntimeToken(_ token: String) -> Bool {
        if UUID(uuidString: token) != nil { return true }
        guard token.utf8.count == 22 else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x2D
                || scalar.value == 0x5F
        }
    }
}

private final class BoundedDiagnosticCollector: @unchecked Sendable {
    static let maximumBytes = 512 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var totalBytes = 0
    private var result: OpenSSHTargetResult?
    private var outputExceededLimit = false
    private let semaphore = DispatchSemaphore(value: 0)

    func consume(_ data: Data) {
        lock.lock()
        guard result == nil, !outputExceededLimit else {
            lock.unlock()
            return
        }
        guard totalBytes <= Self.maximumBytes,
              data.count <= Self.maximumBytes - totalBytes else {
            outputExceededLimit = true
            result = .indeterminate
            buffer.removeAll(keepingCapacity: false)
            semaphore.signal()
            lock.unlock()
            return
        }
        totalBytes += data.count
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let parsed = parse(lineData) {
                result = parsed
                semaphore.signal()
                break
            }
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = buffer.isEmpty ? .indeterminate : (parse(buffer) ?? .indeterminate)
        buffer.removeAll(keepingCapacity: false)
        semaphore.signal()
        lock.unlock()
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outputExceededLimit
    }

    var failure: TunnelBrokerRuntimeError? {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .some(.refused): return .targetRefused
        case .some(.timedOut): return .targetTimeout
        case .some(.indeterminate): return .targetProbeIndeterminate
        case .some(.confirmed), .some(OpenSSHTargetResult.none), nil: return nil
        }
    }

    func waitForTargetResult(timeout: TimeInterval) -> OpenSSHTargetResult {
        lock.lock()
        if let result {
            lock.unlock()
            return result
        }
        lock.unlock()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return .none
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .none
    }

    private func parse(_ data: Data) -> OpenSSHTargetResult? {
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        guard lower.range(
            of: #"channel [0-9]+: open (confirm|failed)"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        if lower.contains("open confirm") { return .confirmed }
        if lower.contains("refused") { return .refused }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .timedOut
        }
        return .indeterminate
    }
}

private enum OpenSSHTargetResult {
    case confirmed
    case refused
    case timedOut
    case indeterminate
    case none
}

enum LocalTargetProbeResult: Equatable {
    case reachable
    case refused
    case timedOut
    case indeterminate
}

struct LocalTargetProbe {
    let port: UInt16
    let callbackQueue: DispatchQueue
    let cancellationTimeout: TimeInterval

    init(
        port: UInt16,
        callbackQueue: DispatchQueue = DispatchQueue(label: "com.jihtsan.KeyPort.tunnel-probe"),
        cancellationTimeout: TimeInterval = 0.5
    ) {
        self.port = port
        self.callbackQueue = callbackQueue
        self.cancellationTimeout = cancellationTimeout
    }

    func run() -> LocalTargetProbeOutcome {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return LocalTargetProbeOutcome(
                result: .indeterminate,
                connection: nil,
                cancellation: nil,
                cancellationTimeout: cancellationTimeout
            )
        }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpointPort,
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        let result = ProbeResultBox()
        let cancellation = ProbeCancellationSignal()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.set(.reachable)
                semaphore.signal()
            case .failed(let error):
                result.set(Self.map(error))
                semaphore.signal()
            case .cancelled:
                cancellation.markCancelled()
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: callbackQueue)
        if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
            return LocalTargetProbeOutcome(
                result: .timedOut,
                connection: connection,
                cancellation: cancellation,
                cancellationTimeout: cancellationTimeout
            )
        }
        let probeResult = result.value ?? .indeterminate
        if probeResult == .reachable {
            // A zero-byte EOF triggers the SSH direct-tcpip open without sending application data.
            connection.send(
                content: nil,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
            return LocalTargetProbeOutcome(
                result: probeResult,
                connection: connection,
                cancellation: cancellation,
                cancellationTimeout: cancellationTimeout
            )
        }
        return LocalTargetProbeOutcome(
            result: probeResult,
            connection: connection,
            cancellation: cancellation,
            cancellationTimeout: cancellationTimeout
        )
    }

    private static func map(_ error: NWError) -> LocalTargetProbeResult {
        if case .posix(let code) = error {
            if code == .ECONNREFUSED || code == .ECONNRESET || code == .ECONNABORTED || code == .EPIPE {
                return .refused
            }
            if code == .ETIMEDOUT { return .timedOut }
        }
        return .indeterminate
    }
}

struct LocalTargetProbeOutcome {
    let result: LocalTargetProbeResult
    let connection: NWConnection?
    let cancellationTimeout: TimeInterval
    private let cancellation: ProbeCancellationSignal?

    fileprivate init(
        result: LocalTargetProbeResult,
        connection: NWConnection?,
        cancellation: ProbeCancellationSignal?,
        cancellationTimeout: TimeInterval
    ) {
        self.result = result
        self.connection = connection
        self.cancellation = cancellation
        self.cancellationTimeout = cancellationTimeout
    }

    func cancelAndWait(timeout: TimeInterval = 0.5) -> Bool {
        guard let connection, let cancellation else { return true }
        connection.cancel()
        return cancellation.wait(timeout: timeout)
    }
}

fileprivate final class ProbeCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isCancelled = false

    func markCancelled() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return true
        }
        lock.unlock()
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}

func publishForwardEstablished(
    after probe: LocalTargetProbeOutcome,
    cancellationTimeout: TimeInterval = 0.5,
    writeStatus: (String) -> Void = writeBrokerStatus
) throws {
    guard probe.cancelAndWait(timeout: cancellationTimeout) else {
        throw TunnelBrokerRuntimeError.targetProbeIndeterminate
    }
    writeStatus("FORWARD_ESTABLISHED")
}

private final class ProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LocalTargetProbeResult?

    func set(_ result: LocalTargetProbeResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: LocalTargetProbeResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
