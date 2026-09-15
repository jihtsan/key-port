import Darwin
import Foundation
import KeyPortCore

@main
struct KeyPortSSHRelayMain {
    static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--resolve" {
            let hosts = BoundedDNS.numericHosts(CommandLine.arguments[2], port: CommandLine.arguments[3])
            if let data = try? JSONEncoder().encode(hosts) { FileHandle.standardOutput.write(data) }
            return
        }
        signal(SIGTERM) { _ in relayCancelled = 1 }
        signal(SIGINT) { _ in relayCancelled = 1 }
        do {
            let command = try RelayCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .version:
                writeStdout("\(SSHPreconnectRelayRuntime.versionString)\n")
            case .forward(let configuration, let target):
                try RelayRuntime(configuration: configuration, target: target).run()
            }
            exit(EXIT_SUCCESS)
        } catch let error as RelayRuntimeError {
            writeStderr("\(SSHPreconnectRelayRuntime.executableName) \(error.rawValue)\n")
            exit(EXIT_FAILURE)
        } catch {
            writeStderr("\(SSHPreconnectRelayRuntime.executableName) unknown\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func writeStdout(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func writeStderr(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}

private enum RelayCommand {
    case version
    case forward(configuration: SSHPreconnectRelayConfiguration, target: RelayTargetArguments)

    init(arguments: [String]) throws {
        if arguments == ["--version"] {
            self = .version
            return
        }

        let fields = try Self.parseFields(arguments)
        guard let configPath = fields["--config"],
              let profileValue = fields["--profile-id"],
              let profileID = UUID(uuidString: profileValue),
              let forwardHost = fields["--forward-host"],
              let forwardPortValue = fields["--forward-port"],
              let forwardPort = UInt16(forwardPortValue),
              forwardPort > 0 else {
            throw RelayRuntimeError.invalidArguments
        }

        guard configPath.hasPrefix("/") else {
            throw RelayRuntimeError.invalidArguments
        }
        let configURL = URL(fileURLWithPath: configPath).standardizedFileURL
        guard let data = try? SSHRelayOwnedFile.read(configURL, limit: SSHPreconnectRelayRuntime.maximumManifestBytes),
              data.count <= SSHPreconnectRelayRuntime.maximumManifestBytes,
              let manifest = try? HostV6.CanonicalJSON.decode(
                  SSHPreconnectRelayManifest.self,
                  from: data
              ) else {
            throw RelayRuntimeError.configInvalid
        }
        guard (try? manifest.validate()) != nil,
              let configuration = manifest.configuration(for: profileID) else {
            throw RelayRuntimeError.profileNotFound
        }
        guard configuration.matchesForwardingTarget(
            host: forwardHost,
            port: forwardPort
        ) else {
            throw RelayRuntimeError.targetMismatch
        }
        self = .forward(
            configuration: configuration,
            target: RelayTargetArguments(host: forwardHost, port: forwardPort, generation: configURL.deletingLastPathComponent().lastPathComponent)
        )
    }

    private static func parseFields(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2), !arguments.isEmpty else {
            throw RelayRuntimeError.invalidArguments
        }
        let allowed: Set<String> = [
            "--config", "--profile-id", "--forward-host", "--forward-port"
        ]
        var fields: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard allowed.contains(key), fields[key] == nil, !value.isEmpty else {
                throw RelayRuntimeError.invalidArguments
            }
            fields[key] = value
            index += 2
        }
        guard fields.count == allowed.count else {
            throw RelayRuntimeError.invalidArguments
        }
        return fields
    }
}

private struct RelayTargetArguments: Sendable {
    let host: String
    let port: UInt16
    let generation: String
}

private enum RelayRuntimeError: String, Error {
    case invalidArguments = "invalid_arguments"
    case configInvalid = "config_invalid"
    case profileNotFound = "profile_not_found"
    case targetMismatch = "target_mismatch"
    case candidateTimeout = "candidate_timeout"
    case candidateUnavailable = "candidate_unavailable"
    case budgetExceeded = "budget_exceeded"
    case forwardingFailed = "forwarding_failed"
}

private struct RelayRuntime {
    let configuration: SSHPreconnectRelayConfiguration
    let target: RelayTargetArguments

    func run() throws {
        try configuration.validate()
        guard configuration.matchesForwardingTarget(host: target.host, port: target.port) else {
            throw RelayRuntimeError.targetMismatch
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(configuration.overallBudgetMilliseconds) * 1_000_000
        let deadline = started.addingReportingOverflow(budget).partialValue
        var sawTimeout = false

        for candidate in configuration.candidates {
            let now = DispatchTime.now().uptimeNanoseconds
            guard relayCancelled == 0, now < deadline else { throw RelayRuntimeError.budgetExceeded }
            let remaining = deadline - now
            let candidateBudget = min(
                UInt64(configuration.connectTimeoutMilliseconds) * 1_000_000,
                remaining
            )
            switch connect(candidate: candidate, timeoutNanoseconds: candidateBudget) {
            case .connected(let descriptor):
                recordSelection(candidate.endpointID)
                try relay(descriptor)
                return
            case .timedOut:
                sawTimeout = true
            case .unavailable:
                continue
            }
        }

        if DispatchTime.now().uptimeNanoseconds >= deadline {
            throw RelayRuntimeError.budgetExceeded
        }
        throw sawTimeout ? RelayRuntimeError.candidateTimeout : RelayRuntimeError.candidateUnavailable
    }

    private func recordSelection(_ endpointID: UUID) {
        guard let directory = configuration.eventsDirectory else { return }
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return }
        let event = SSHRelaySelectionEvent(attemptID: UUID(), profileID: configuration.profileID, endpointID: endpointID, selectedAt: Date(), generation: target.generation, phase: "tcpConnected")
        guard let data = try? JSONEncoder().encode(event) else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(configuration.profileID.uuidString + ".json")
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private enum ConnectResult {
        case connected(Int32)
        case timedOut
        case unavailable
    }

    private func connect(
        candidate: SSHPreconnectRelayCandidate,
        timeoutNanoseconds: UInt64
    ) -> ConnectResult {
        let host = SSHPreconnectRelayConfiguration.normalizedHost(candidate.host)
        let service = String(candidate.port)
        let candidateDeadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        let hosts = BoundedDNS.resolve(host, port: service, deadline: candidateDeadline)
        for (index, numericHost) in hosts.enumerated() {
            guard relayCancelled == 0 else { return .unavailable }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < candidateDeadline else { return .timedOut }
            // Reserve time for the other address family within the same DNS candidate.
            let deadline = now + (candidateDeadline - now) / UInt64(max(1, hosts.count - index))
            var hints = addrinfo(ai_flags: AI_NUMERICHOST | AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(numericHost, service, &hints, &list) == 0, let address = list else { continue }
            let descriptor = connect(address: address.pointee.ai_addr, length: address.pointee.ai_addrlen, deadline: deadline)
            freeaddrinfo(address)
            if let descriptor { return .connected(descriptor) }
        }
        let sawTimeout = DispatchTime.now().uptimeNanoseconds >= candidateDeadline
        return sawTimeout ? .timedOut : .unavailable
    }

    private func connect(
        address: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t,
        deadline: UInt64
    ) -> Int32? {
        guard let address else { return nil }
        let descriptor = socket(Int32(address.pointee.sa_family), SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        guard setNonBlocking(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }

        let result = Darwin.connect(descriptor, address, length)
        if result == 0 { return descriptor }
        guard errno == EINPROGRESS else {
            Darwin.close(descriptor)
            return nil
        }

        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard relayCancelled == 0, now < deadline else {
                Darwin.close(descriptor)
                return nil
            }
            let remainingMilliseconds = Int32(max(1, min(
                UInt64(Int32.max),
                (deadline - now + 999_999) / 1_000_000
            )))
            let pollResult = Darwin.poll(&pollDescriptor, 1, min(100, remainingMilliseconds))
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                Darwin.close(descriptor)
                return nil
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let errorResult = withUnsafeMutablePointer(to: &socketError) { errorPointer in
                getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    errorPointer,
                    &socketErrorLength
                )
            }
            guard errorResult == 0, socketError == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            return descriptor
        }
    }

    private func relay(_ descriptor: Int32) throws {
        defer { Darwin.close(descriptor) }
        guard setNonBlocking(descriptor),
              setNonBlocking(STDIN_FILENO),
              setNonBlocking(STDOUT_FILENO) else {
            throw RelayRuntimeError.forwardingFailed
        }

        var inputBuffer = Data()
        var outputBuffer = Data()
        var inputOpen = true
        var socketOpen = true
        var socketWriteClosed = false
        var outputOpen = true
        let maximumBufferSize = 1_024 * 1_024
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)

        while socketOpen || !outputBuffer.isEmpty {
            guard relayCancelled == 0 else { throw RelayRuntimeError.forwardingFailed }
            var pollDescriptors: [pollfd] = []
            var inputIndex: Int?
            var socketIndex: Int?
            var outputIndex: Int?

            if inputOpen && inputBuffer.count < maximumBufferSize {
                inputIndex = pollDescriptors.count
                pollDescriptors.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
            }
            if socketOpen {
                socketIndex = pollDescriptors.count
                var events = Int16(POLLIN)
                if !inputBuffer.isEmpty { events |= Int16(POLLOUT) }
                pollDescriptors.append(pollfd(fd: descriptor, events: events, revents: 0))
            }
            if outputOpen && !outputBuffer.isEmpty {
                outputIndex = pollDescriptors.count
                pollDescriptors.append(pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0))
            }

            if pollDescriptors.isEmpty { break }
            let pollResult = pollDescriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 250)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw RelayRuntimeError.forwardingFailed
            }

            if let inputIndex, pollDescriptors[inputIndex].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(STDIN_FILENO, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    inputBuffer.append(contentsOf: bytes.prefix(Int(count)))
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                    inputOpen = false
                }
            }

            if let socketIndex {
                let events = pollDescriptors[socketIndex].revents
                if events & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    let count = bytes.withUnsafeMutableBytes { buffer in
                        Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                    }
                    if count > 0 {
                        guard outputBuffer.count + Int(count) <= maximumBufferSize else {
                            throw RelayRuntimeError.forwardingFailed
                        }
                        outputBuffer.append(contentsOf: bytes.prefix(Int(count)))
                    } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                        socketOpen = false
                    }
                }
                if events & Int16(POLLOUT) != 0 && !inputBuffer.isEmpty {
                    let count = inputBuffer.withUnsafeBytes { buffer in
                        Darwin.write(descriptor, buffer.baseAddress, buffer.count)
                    }
                    if count > 0 {
                        inputBuffer.removeSubrange(0..<Int(count))
                    } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                        socketOpen = false
                    }
                }
            }

            if let outputIndex, pollDescriptors[outputIndex].revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                let count = outputBuffer.withUnsafeBytes { buffer in
                    Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    outputBuffer.removeSubrange(0..<Int(count))
                } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    outputOpen = false
                    outputBuffer.removeAll(keepingCapacity: false)
                }
            }

            if !inputOpen && inputBuffer.isEmpty && !socketWriteClosed && socketOpen {
                shutdown(descriptor, SHUT_WR)
                socketWriteClosed = true
            }
            if !socketOpen { inputOpen = false }
        }
    }
}

private func setNonBlocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0 else { return false }
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
}
