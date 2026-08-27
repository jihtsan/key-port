import Darwin
import Foundation
import KeyPortCore

actor HostV6AuthorityFileStore {
    enum FailurePoint: CaseIterable, Equatable, Sendable {
        case beforeStateReplace
        case beforeCompatibilityReplace
        case beforeCheckpointReplace
        case beforeManifestReplace
        case beforeJournalCleanup
    }

    private enum Phase: String, Codable, Sendable {
        case prepared
        case stateCommitted
        case compatibilityCommitted
        case checkpointCommitted
        case manifestCommitted
    }

    private struct CommitJournal: Codable, Sendable {
        var phase: Phase
        let stateDataHash: String
        let compatibilityDataHash: String
        let checkpointDataHash: String
        let manifestDataHash: String
        let checkpointHash: String
    }

    private let paths: KeyPortPaths
    private let fileManager: FileManager
    private let failureInjector: @Sendable (FailurePoint) throws -> Void

    init(
        paths: KeyPortPaths = KeyPortPaths(),
        fileManager: FileManager = .default,
        failureInjector: @escaping @Sendable (FailurePoint) throws -> Void = { _ in }
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func commit(_ plan: HostV6.AuthorityCommitPlan) throws {
        try paths.prepareV6AuthorityDirectories()
        if fileManager.fileExists(atPath: paths.v6CommitJournal.path) {
            try finishPendingCommit()
        }
        try validate(plan)

        let manifestData = try HostV6.CanonicalJSON.encode(plan.manifest)
        try writeSecure(plan.stateData, to: paths.stagedStateV6)
        try writeSecure(plan.compatibilityData, to: paths.stagedCompatibility)
        try writeSecure(plan.checkpointData, to: paths.stagedCheckpoint)
        try writeSecure(manifestData, to: paths.stagedManifest)
        var journal = CommitJournal(
            phase: .prepared,
            stateDataHash: HostV6.CanonicalJSON.sha256(plan.stateData),
            compatibilityDataHash: HostV6.CanonicalJSON.sha256(plan.compatibilityData),
            checkpointDataHash: HostV6.CanonicalJSON.sha256(plan.checkpointData),
            manifestDataHash: HostV6.CanonicalJSON.sha256(manifestData),
            checkpointHash: plan.manifest.checkpointHash
        )
        try writeJournal(journal)
        try syncDirectory(paths.applicationSupport)
        try finish(&journal)
    }

    func recover() throws -> HostV6.MetadataEnvelope {
        try paths.prepareV6AuthorityDirectories()
        if fileManager.fileExists(atPath: paths.v6CommitJournal.path) {
            try finishPendingCommit()
        }

        let hasExternalManifest = fileManager.fileExists(atPath: paths.authorityManifest.path)
        let externalManifest = try? decodeManifest(at: paths.authorityManifest)
        if let current = try? Data(contentsOf: paths.stateV6),
           let envelope = try? HostV6.AuthorityController.verifyCheckpoint(current) {
            guard let embedded = envelope.migrationProvenance.authorityManifest else {
                throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
            }
            if externalManifest != embedded {
                try atomicReplace(HostV6.CanonicalJSON.encode(embedded), at: paths.authorityManifest)
            }
            let projection = try HostV6.AuthorityController.compatibilityProjection(
                from: envelope,
                requiresCompleteRoutes: false
            )
            let currentCompatibility = try? Data(contentsOf: paths.stateV1Compatibility)
            if currentCompatibility.map(HostV6.CanonicalJSON.sha256)
                != HostV6.CanonicalJSON.sha256(projection.data) {
                try atomicReplace(projection.data, at: paths.stateV1Compatibility)
            }
            return envelope
        }

        guard !hasExternalManifest || externalManifest != nil else {
            throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
        }

        let candidates: [URL]
        if let externalManifest {
            candidates = [paths.checkpoint(for: externalManifest.checkpointHash)]
        } else {
            candidates = (try? fileManager.contentsOfDirectory(
                at: paths.v6CheckpointsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).sorted(by: checkpointRecency)) ?? []
        }
        for checkpointURL in candidates {
            guard let data = try? Data(contentsOf: checkpointURL),
                  var envelope = try? HostV6.AuthorityController.verifyCheckpoint(data),
                  let embedded = envelope.migrationProvenance.authorityManifest,
                  checkpointURL.lastPathComponent == "\(embedded.checkpointHash).json" else {
                continue
            }
            if let externalManifest {
                guard canReconcile(externalManifest, with: embedded) else { continue }
                envelope.migrationProvenance.authorityManifest = externalManifest
                guard let reconciledData = try? HostV6.CanonicalJSON.encode(envelope),
                      (try? HostV6.AuthorityController.verifyCheckpoint(reconciledData)) != nil else {
                    continue
                }
            }
            let stateData = try HostV6.CanonicalJSON.encode(envelope)
            let projection = try HostV6.AuthorityController.compatibilityProjection(
                from: envelope,
                requiresCompleteRoutes: false
            )
            try atomicReplace(stateData, at: paths.stateV6)
            try atomicReplace(projection.data, at: paths.stateV1Compatibility)
            try atomicReplace(
                HostV6.CanonicalJSON.encode(envelope.migrationProvenance.authorityManifest!),
                at: paths.authorityManifest
            )
            try syncDirectory(paths.applicationSupport)
            return envelope
        }
        throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
    }

    private func canReconcile(
        _ external: HostV6.AuthorityManifest,
        with embedded: HostV6.AuthorityManifest
    ) -> Bool {
        var normalizedExternal = external
        normalizedExternal.mode = embedded.mode
        guard normalizedExternal == embedded else { return false }
        if external.mode == embedded.mode { return true }
        return Set([external.mode, embedded.mode]) == Set([
            HostV6.AuthorityMode.v6Authoritative,
            HostV6.AuthorityMode.compatibilityRollback,
        ])
    }

    private func checkpointRecency(_ left: URL, _ right: URL) -> Bool {
        let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return left.lastPathComponent > right.lastPathComponent
    }

    private func validate(_ plan: HostV6.AuthorityCommitPlan) throws {
        let state = try HostV6.CanonicalJSON.decode(
            HostV6.MetadataEnvelope.self,
            from: plan.stateData
        )
        guard state == plan.envelope,
              state.migrationProvenance.authorityManifest == plan.manifest,
              plan.compatibilityData == (try HostV6.CanonicalJSON.encode(plan.compatibilitySnapshot)),
              try HostV6.AuthorityController.compatibilitySemanticHash(plan.compatibilitySnapshot)
                == plan.manifest.compatibilityHash else {
            throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
        }
        let checkpoint = try HostV6.AuthorityController.verifyCheckpoint(plan.checkpointData)
        guard checkpoint.migrationProvenance.authorityManifest?.checkpointHash == plan.manifest.checkpointHash else {
            throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
        }
    }

    private func finishPendingCommit() throws {
        let data = try Data(contentsOf: paths.v6CommitJournal)
        var journal = try HostV6.CanonicalJSON.decode(CommitJournal.self, from: data)
        try finish(&journal)
    }

    private func finish(_ journal: inout CommitJournal) throws {
        let stateData = try stagedOrCommittedData(
            staged: paths.stagedStateV6,
            committed: paths.stateV6,
            expectedHash: journal.stateDataHash
        )
        try failureInjector(.beforeStateReplace)
        try atomicReplace(stateData, at: paths.stateV6)
        journal.phase = .stateCommitted
        try writeJournal(journal)

        let compatibilityData = try stagedOrCommittedData(
            staged: paths.stagedCompatibility,
            committed: paths.stateV1Compatibility,
            expectedHash: journal.compatibilityDataHash
        )
        try failureInjector(.beforeCompatibilityReplace)
        try atomicReplace(compatibilityData, at: paths.stateV1Compatibility)
        journal.phase = .compatibilityCommitted
        try writeJournal(journal)

        let checkpointURL = paths.checkpoint(for: journal.checkpointHash)
        let checkpointData = try stagedOrCommittedData(
            staged: paths.stagedCheckpoint,
            committed: checkpointURL,
            expectedHash: journal.checkpointDataHash
        )
        try failureInjector(.beforeCheckpointReplace)
        try atomicReplace(checkpointData, at: checkpointURL)
        journal.phase = .checkpointCommitted
        try writeJournal(journal)

        let manifestData = try stagedOrCommittedData(
            staged: paths.stagedManifest,
            committed: paths.authorityManifest,
            expectedHash: journal.manifestDataHash
        )
        try failureInjector(.beforeManifestReplace)
        try atomicReplace(manifestData, at: paths.authorityManifest)
        journal.phase = .manifestCommitted
        try writeJournal(journal)

        try syncDirectory(paths.applicationSupport)
        try failureInjector(.beforeJournalCleanup)
        try fileManager.removeItem(at: paths.v6CommitJournal)
        if fileManager.fileExists(atPath: paths.v6CommitStagingDirectory.path) {
            try fileManager.removeItem(at: paths.v6CommitStagingDirectory)
        }
        try paths.prepareV6AuthorityDirectories()
        try syncDirectory(paths.applicationSupport)
    }

    private func stagedOrCommittedData(
        staged: URL,
        committed: URL,
        expectedHash: String
    ) throws -> Data {
        if let data = try? Data(contentsOf: staged),
           HostV6.CanonicalJSON.sha256(data) == expectedHash {
            return data
        }
        if let data = try? Data(contentsOf: committed),
           HostV6.CanonicalJSON.sha256(data) == expectedHash {
            return data
        }
        throw HostV6.CloudV2Error.failure(.rollbackProjectionInvalid)
    }

    private func writeJournal(_ journal: CommitJournal) throws {
        try atomicReplace(HostV6.CanonicalJSON.encode(journal), at: paths.v6CommitJournal)
    }

    private func decodeManifest(at url: URL) throws -> HostV6.AuthorityManifest {
        try HostV6.CanonicalJSON.decode(
            HostV6.AuthorityManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func atomicReplace(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try writeSecure(data, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try syncDirectory(directory)
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
        guard descriptor >= 0 else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }
}
