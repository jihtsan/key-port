import Foundation
import Darwin

public enum SSHRelayOwnedFile {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size <= limit else { throw CocoaError(.fileReadNoPermission) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw CocoaError(.fileReadUnknown) }
            guard result.count + count <= limit else { throw CocoaError(.fileReadTooLarge) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
