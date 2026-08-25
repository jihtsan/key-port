import Foundation
import KeyPortCore

/// File-backed bytes store for `history-v1.json`. Every save is a single
/// atomic replace followed by a `0600` permission fix, matching the local-only
/// privacy boundary of connection records and SSID hints.
struct FileConnectionHistoryBytesStore: ConnectionHistoryBytesStoring {
    let fileURL: URL

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func atomicReplace(with data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
