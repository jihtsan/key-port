import Darwin
import Foundation

public enum AskPassRunner {
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let path = environment["KEYPORT_PASSWORD_PIPE"] else { return 1 }

        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFIFO,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              let handle = FileHandle(forReadingAtPath: path) else {
            return 1
        }

        let password = handle.readDataToEndOfFile()
        try? handle.close()
        guard !password.isEmpty else { return 1 }
        FileHandle.standardOutput.write(password + Data("\n".utf8))
        return 0
    }
}
