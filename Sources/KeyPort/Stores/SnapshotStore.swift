import Foundation
import KeyPortCore

actor SnapshotStore {
    private let paths: KeyPortPaths
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(paths: KeyPortPaths = KeyPortPaths()) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> AppSnapshot {
        try paths.prepareDirectories()
        guard FileManager.default.fileExists(atPath: paths.snapshot.path) else { return AppSnapshot() }
        return try decoder.decode(AppSnapshot.self, from: Data(contentsOf: paths.snapshot))
    }

    func save(_ snapshot: AppSnapshot) throws {
        try paths.prepareDirectories()
        let data = try encoder.encode(snapshot)
        try data.write(to: paths.snapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.snapshot.path)
    }

    func stageV6Shadow(
        currentDeviceID: String,
        credentialInspector: any HostV6ShadowCredentialInspecting
    ) async throws -> HostV6.ShadowMigrationBundle {
        try paths.prepareDirectories()
        let legacyData = try Data(contentsOf: paths.snapshot)
        let userConfig = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
        let coordinator = HostV6.ShadowMigrationCoordinator(
            engine: HostV6.ShadowMigrationEngine(currentDeviceID: currentDeviceID),
            credentialInspector: credentialInspector,
            artifactInspector: HostV6ProtectedArtifactInspector(paths: paths),
            stagingStore: HostV6ShadowFileStagingStore(paths: paths)
        )
        return try await coordinator.stage(
            legacyData: legacyData,
            existingSSHHostAliases: SSHConfigGenerator.aliases(in: userConfig)
        )
    }
}
