import Foundation
import KeyPortCore

/// Local persistence for the unified topology authority.
///
/// The legacy snapshot remains readable by the SSH compatibility adapters, but
/// Graph and future topology use cases read this versioned document.
actor TopologyStore {
    private let paths: KeyPortPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: KeyPortPaths = KeyPortPaths()) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> TopologySnapshot? {
        try paths.prepareDirectories()
        guard FileManager.default.fileExists(atPath: paths.topologySnapshot.path) else {
            guard FileManager.default.fileExists(atPath: paths.topologySnapshotBackup.path) else {
                return nil
            }
            return try decoder.decode(
                TopologySnapshot.self,
                from: Data(contentsOf: paths.topologySnapshotBackup)
            )
        }
        do {
            return try decoder.decode(
                TopologySnapshot.self,
                from: Data(contentsOf: paths.topologySnapshot)
            )
        } catch {
            guard FileManager.default.fileExists(atPath: paths.topologySnapshotBackup.path) else {
                throw error
            }
            return try decoder.decode(
                TopologySnapshot.self,
                from: Data(contentsOf: paths.topologySnapshotBackup)
            )
        }
    }

    func save(_ snapshot: TopologySnapshot) throws {
        try paths.prepareDirectories()
        let data = try encoder.encode(snapshot)
        if FileManager.default.fileExists(atPath: paths.topologySnapshot.path) {
            let previous = try Data(contentsOf: paths.topologySnapshot)
            try previous.write(to: paths.topologySnapshotBackup, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.topologySnapshotBackup.path
            )
        }
        try data.write(to: paths.topologySnapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.topologySnapshot.path)
    }
}
