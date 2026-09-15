import Foundation
import Darwin

var relayCancelled: sig_atomic_t = 0

/// Runs blocking libc DNS in a disposable child. Parent owns the complete deadline.
enum BoundedDNS {
    static func numericHosts(_ host: String, port: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [String] = [], next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next, result.count < 64 {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: buffer)
                if !result.contains(value) { result.append(value) }
            }
            next = entry.pointee.ai_next
        }
        return result
    }
    static func resolve(_ host: String, port: String, deadline: UInt64, executable: String = CommandLine.arguments[0]) -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--resolve", host, port]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        var failed = false
        repeat {
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
                if data.count > 16384 { failed = true; break }
            }
            if failed || relayCancelled != 0 || DispatchTime.now().uptimeNanoseconds >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return []
            }
            if !process.isRunning { break }
            usleep(1000)
        } while true
        // Drain the finite remainder after child exit, without waiting on EOF.
        while true { let n = Darwin.read(fd, &buffer, buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)); if data.count > 16384 { return [] } }
        guard process.terminationStatus == 0 else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
