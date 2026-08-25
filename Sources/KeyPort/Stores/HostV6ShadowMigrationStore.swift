import Darwin
import Foundation
import KeyPortCore

actor HostV6ShadowFileStagingStore: HostV6ShadowStagingStoring {
    struct Pointer: Codable, Hashable, Sendable {
        let bundleID: String
        let stateSHA256: String
        let reportSHA256: String
    }

    private let paths: KeyPortPaths
    private let fileManager: FileManager
    private let beforeCurrentPointerReplace: @Sendable () throws -> Void

    init(
        paths: KeyPortPaths,
        fileManager: FileManager = .default,
        beforeCurrentPointerReplace: @escaping @Sendable () throws -> Void = {}
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.beforeCurrentPointerReplace = beforeCurrentPointerReplace
    }

    func previousStateData() async throws -> Data? {
        guard fileManager.fileExists(atPath: paths.shadowMigrationCurrentPointer.path) else {
            return nil
        }
        do {
            let pointer = try HostV6.CanonicalJSON.decode(
                Pointer.self,
                from: Data(contentsOf: paths.shadowMigrationCurrentPointer)
            )
            let bundle = paths.shadowMigrationBundlesDirectory
                .appendingPathComponent(pointer.bundleID, isDirectory: true)
            let state = try Data(contentsOf: bundle.appendingPathComponent("state-v6.json"))
            let report = try Data(contentsOf: bundle.appendingPathComponent("migration-report.json"))
            guard HostV6.CanonicalJSON.sha256(state) == pointer.stateSHA256,
                  HostV6.CanonicalJSON.sha256(report) == pointer.reportSHA256 else {
                throw StoreError.hashMismatch
            }
            return state
        } catch let error as HostV6.ShadowMigrationError {
            throw error
        } catch {
            throw stableError("publishedBundleInvalid")
        }
    }

    func atomicPublish(stateData: Data, reportData: Data) async throws {
        do {
            try paths.prepareShadowMigrationDirectories()
            let stateHash = HostV6.CanonicalJSON.sha256(stateData)
            let reportHash = HostV6.CanonicalJSON.sha256(reportData)
            let bundleID = "\(stateHash)-\(reportHash)"
            let bundle = paths.shadowMigrationBundlesDirectory
                .appendingPathComponent(bundleID, isDirectory: true)

            if fileManager.fileExists(atPath: bundle.path) {
                try validateBundle(bundle, stateHash: stateHash, reportHash: reportHash)
            } else {
                try createBundle(
                    bundle,
                    stateData: stateData,
                    reportData: reportData,
                    stateHash: stateHash,
                    reportHash: reportHash
                )
            }

            let pointer = Pointer(
                bundleID: bundleID,
                stateSHA256: stateHash,
                reportSHA256: reportHash
            )
            try replaceCurrentPointer(with: HostV6.CanonicalJSON.encode(pointer))
        } catch let error as HostV6.ShadowMigrationError {
            throw error
        } catch {
            throw stableError("atomicPublishFailed")
        }
    }

    func removeAllStaging() throws {
        guard fileManager.fileExists(atPath: paths.shadowMigrationRoot.path) else { return }
        try fileManager.removeItem(at: paths.shadowMigrationRoot)
    }

    private func createBundle(
        _ bundle: URL,
        stateData: Data,
        reportData: Data,
        stateHash: String,
        reportHash: String
    ) throws {
        let temporary = paths.shadowMigrationBundlesDirectory
            .appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }
        try fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try writeSecure(stateData, to: temporary.appendingPathComponent("state-v6.json"))
        try writeSecure(reportData, to: temporary.appendingPathComponent("migration-report.json"))
        try validateBundle(temporary, stateHash: stateHash, reportHash: reportHash)
        try syncDirectory(temporary)
        try fileManager.moveItem(at: temporary, to: bundle)
        try syncDirectory(paths.shadowMigrationBundlesDirectory)
    }

    private func validateBundle(_ bundle: URL, stateHash: String, reportHash: String) throws {
        let state = try Data(contentsOf: bundle.appendingPathComponent("state-v6.json"))
        let report = try Data(contentsOf: bundle.appendingPathComponent("migration-report.json"))
        guard HostV6.CanonicalJSON.sha256(state) == stateHash,
              HostV6.CanonicalJSON.sha256(report) == reportHash else {
            throw StoreError.hashMismatch
        }
    }

    private func replaceCurrentPointer(with data: Data) throws {
        let temporary = paths.shadowMigrationRoot
            .appendingPathComponent(".current-\(UUID().uuidString).tmp")
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }
        try writeSecure(data, to: temporary)
        try beforeCurrentPointerReplace()
        if fileManager.fileExists(atPath: paths.shadowMigrationCurrentPointer.path) {
            _ = try fileManager.replaceItemAt(paths.shadowMigrationCurrentPointer, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: paths.shadowMigrationCurrentPointer)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.shadowMigrationCurrentPointer.path
        )
        try syncDirectory(paths.shadowMigrationRoot)
    }

    private func writeSecure(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.directorySyncFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw StoreError.directorySyncFailed }
    }

    private func stableError(_ detail: String) -> HostV6.ShadowMigrationError {
        HostV6.ShadowMigrationError(
            failure: StableOperationFailure(
                stage: .migration,
                objectID: "v6-shadow-staging",
                code: .artifactMismatch,
                recoveryAction: .reload
            ),
            detailCode: detail
        )
    }

    private enum StoreError: Error {
        case hashMismatch
        case directorySyncFailed
    }
}

struct HostV6ProtectedArtifactInspector: HostV6ShadowArtifactInspecting {
    let paths: KeyPortPaths

    init(paths: KeyPortPaths) {
        self.paths = paths
    }

    func protectedArtifactHashes() async throws -> [String: String] {
        let fileManager = FileManager.default
        var result = [
            "state-v1.json": try hash(paths.snapshot),
            "ssh-user-config": try hash(paths.userConfig),
            "ssh-managed-config": try hash(paths.managedConfig),
            "known-hosts": try hash(paths.knownHosts),
        ]
        guard fileManager.fileExists(atPath: paths.identitiesDirectory.path) else { return result }
        let identities = try fileManager.contentsOfDirectory(
            at: paths.identitiesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for identity in identities where try identity.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result["identity/\(identity.lastPathComponent)"] = try hash(identity)
        }
        return result
    }

    private func hash(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        return HostV6.CanonicalJSON.sha256(try Data(contentsOf: url))
    }
}

extension KeychainService: HostV6ShadowCredentialInspecting {
    func accountState(for accountID: String) async -> HostV6.KeychainAccountState {
        guard let serverID = UUID(uuidString: accountID) else { return .missing }
        switch serverPasswordStorage(serverID: serverID) {
        case .local:
            return HostV6.KeychainAccountState.local
        case .synchronizable:
            return HostV6.KeychainAccountState.synchronizable
        case nil:
            return HostV6.KeychainAccountState.missing
        }
    }
}
