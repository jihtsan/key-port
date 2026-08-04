import Darwin
import Foundation

guard let path = ProcessInfo.processInfo.environment["KEYPORT_PASSWORD_PIPE"] else { exit(1) }
var info = stat()
guard lstat(path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFIFO,
      info.st_uid == getuid(),
      (info.st_mode & 0o077) == 0 else {
    exit(1)
}

guard let handle = FileHandle(forReadingAtPath: path) else { exit(1) }
let password = handle.readDataToEndOfFile()
try? handle.close()
guard !password.isEmpty else { exit(1) }
FileHandle.standardOutput.write(password + Data("\n".utf8))
