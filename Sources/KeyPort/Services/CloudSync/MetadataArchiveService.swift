import Foundation
import KeyPortCore

actor MetadataArchiveService {
    func export(snapshot: AppSnapshot, password: String, destination: URL) throws {
        let data = try MetadataArchiveCodec.seal(snapshot, password: password)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func importArchive(from source: URL, password: String) throws -> AppSnapshot {
        try MetadataArchiveCodec.open(Data(contentsOf: source), password: password)
    }
}
