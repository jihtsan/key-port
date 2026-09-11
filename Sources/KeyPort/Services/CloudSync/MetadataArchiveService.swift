import Foundation
import KeyPortCore

actor MetadataArchiveService {
    func export(
        snapshot: AppSnapshot,
        topology: TopologySnapshot? = nil,
        password: String,
        destination: URL
    ) throws {
        let data: Data
        if let topology {
            data = try MetadataArchiveCodec.seal(
                snapshot,
                topology: topology,
                password: password
            )
        } else {
            data = try MetadataArchiveCodec.seal(snapshot, password: password)
        }
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func importArchive(from source: URL, password: String) throws -> MetadataArchivePayload {
        try MetadataArchiveCodec.openPayload(Data(contentsOf: source), password: password)
    }
}
