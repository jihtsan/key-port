import Darwin
import Foundation
import KeyPortCore

/// File-backed bytes store for `history-v1.json`. Every save prepares and
/// synchronizes a `0600` temporary file before atomically renaming it over the
/// destination, matching the local-only privacy boundary of history and SSID.
struct FileConnectionHistoryBytesStore: ConnectionHistoryBytesStoring {
    let fileURL: URL
    private let beforeReplace: @Sendable () throws -> Void

    init(
        fileURL: URL,
        beforeReplace: @escaping @Sendable () throws -> Void = {}
    ) {
        self.fileURL = fileURL
        self.beforeReplace = beforeReplace
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func atomicReplace(with data: Data) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var temporaryNeedsRemoval = true
        defer {
            if temporaryNeedsRemoval {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.currentPOSIXError()
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try beforeReplace()
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw Self.currentPOSIXError()
        }
        temporaryNeedsRemoval = false
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

extension ConnectionHistoryStore {
    /// Production store for the local history file. The SSID lookup is
    /// intentionally not installed: the network hint stays off until the C2
    /// signed-build matrix is accepted, so every record is written with
    /// `ssid = nil`. Rollback is deleting `history-v1.json`.
    static func makeDefault(paths: KeyPortPaths = KeyPortPaths()) -> ConnectionHistoryStore {
        ConnectionHistoryStore(
            bytesStore: FileConnectionHistoryBytesStore(fileURL: paths.connectionHistory),
            clock: SystemHostV6Clock()
        )
    }
}
