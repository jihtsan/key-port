import Foundation
import KeyPortCore

enum HostV6RuntimeFeatureFlags {
    static let canaryKey = "KeyPort.hostV6CanaryEnabled"
    static let cloudV2Key = "KeyPort.hostV6CloudV2Enabled"
    static let mutationWorkflowKey = "KeyPort.hostV6MutationWorkflowEnabled"
    static let workbenchKey = "KeyPort.hostV6WorkbenchEnabled"
    static let hostWorkbenchKey = workbenchKey

    static func isCanaryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: canaryKey)
    }

    static func isCloudV2Enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cloudV2Key)
    }

    static func isMutationWorkflowEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mutationWorkflowKey)
    }

    static func isWorkbenchEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: workbenchKey)
    }
}

enum HostV6PresentationMode: Equatable, Sendable {
    case canary
    case authoritative
    case compatibilityRollback

    var allowsLegacyWrites: Bool { self == .canary }
}

struct HostV6Presentation: Sendable {
    let snapshot: AppSnapshot
    let mode: HostV6PresentationMode
    let envelope: HostV6.MetadataEnvelope?

    init(
        snapshot: AppSnapshot,
        mode: HostV6PresentationMode,
        envelope: HostV6.MetadataEnvelope? = nil
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.envelope = envelope
    }
}

actor HostV6Runtime {
    private let metadataRepository: any HostV6MetadataRepositoryPort
    private let authorityStore: HostV6AuthorityFileStore
    private let evidenceVerifier: HostV6C3EvidenceVerifier
    private let cloudCoordinator: HostV6CloudSyncCoordinator
    private let currentDeviceID: String
    private let credentialInspector: any HostV6ShadowCredentialInspecting
    private let configService: SSHConfigService
    private let paths: KeyPortPaths

    init(
        metadataRepository: any HostV6MetadataRepositoryPort,
        authorityStore: HostV6AuthorityFileStore,
        evidenceVerifier: HostV6C3EvidenceVerifier,
        cloudCoordinator: HostV6CloudSyncCoordinator,
        currentDeviceID: String,
        credentialInspector: any HostV6ShadowCredentialInspecting,
        configService: SSHConfigService,
        paths: KeyPortPaths
    ) {
        self.metadataRepository = metadataRepository
        self.authorityStore = authorityStore
        self.evidenceVerifier = evidenceVerifier
        self.cloudCoordinator = cloudCoordinator
        self.currentDeviceID = currentDeviceID
        self.credentialInspector = credentialInspector
        self.configService = configService
        self.paths = paths
    }

    func loadPresentationSnapshot(from legacyStore: SnapshotStore) async throws -> HostV6Presentation {
        if let resumed = try await resumePendingAuthorityActivation() {
            return try await presentation(from: resumed, legacyStore: legacyStore)
        }
        guard authorityStateExists() else {
            let legacySnapshot = try await legacyStore.load()
            let configBaselineMatches = (try? await configService.adoptExistingManagedConfigBaseline(
                servers: legacySnapshot.servers.filter { !$0.isDeleted },
                keys: legacySnapshot.keys,
                authorizations: legacySnapshot.authorizations
            )) == true
            let bundle: HostV6.ShadowMigrationBundle?
            if FileManager.default.fileExists(atPath: paths.snapshot.path) {
                bundle = try await legacyStore.stageV6Shadow(
                    currentDeviceID: currentDeviceID,
                    credentialInspector: credentialInspector
                )
            } else {
                bundle = nil
            }
            let localAuthorityCandidate = bundle?.envelope ?? HostV6.MetadataEnvelope(
                synced: .init(),
                local: .init(),
                migrationProvenance: .empty
            )
            if let published = try await cloudCoordinator.fetchPublishedAuthority(
                restoringLocalStateFrom: localAuthorityCandidate
            ) {
                try await authorityStore.commit(published)
                return try await presentation(from: published.envelope, legacyStore: legacyStore)
            }
            if configBaselineMatches, let bundle,
               let activated = try await activateAuthorityIfC3EvidenceIsReady(
                   bundle: bundle
               ) {
                return try await presentation(from: activated, legacyStore: legacyStore)
            }
            return HostV6Presentation(snapshot: legacySnapshot, mode: .canary)
        }
        let envelope = try await metadataRepository.snapshot()
        return try await presentation(from: envelope, legacyStore: legacyStore)
    }

    private func presentation(
        from envelope: HostV6.MetadataEnvelope,
        legacyStore: SnapshotStore
    ) async throws -> HostV6Presentation {
        guard let manifest = envelope.migrationProvenance.authorityManifest else {
            throw HostV6.CloudV2Error.failure(.authorityGateFailed)
        }
        switch manifest.mode {
        case .legacyAuthoritative, .v6Canary:
            return HostV6Presentation(snapshot: try await legacyStore.load(), mode: .canary)
        case .v6Authoritative:
            return HostV6Presentation(
                snapshot: try compatibilitySnapshot(from: envelope),
                mode: .authoritative,
                envelope: envelope
            )
        case .compatibilityRollback:
            return HostV6Presentation(
                snapshot: try compatibilitySnapshot(from: envelope),
                mode: .compatibilityRollback,
                envelope: envelope
            )
        }
    }

    func authorizeLegacyWrite() async throws {
        guard authorityStateExists() else { return }
        let envelope = try await metadataRepository.snapshot()
        guard let mode = envelope.migrationProvenance.authorityManifest?.mode,
              mode == .legacyAuthoritative || mode == .v6Canary else {
            throw HostV6.CloudV2Error.failure(.authorityGateFailed)
        }
    }

    func saveLegacySnapshot(_ snapshot: AppSnapshot, to legacyStore: SnapshotStore) async throws {
        try await authorizeLegacyWrite()
        try await legacyStore.save(snapshot)
        _ = try await legacyStore.stageV6Shadow(
            currentDeviceID: currentDeviceID,
            credentialInspector: credentialInspector
        )
    }

    private func compatibilitySnapshot(from envelope: HostV6.MetadataEnvelope) throws -> AppSnapshot {
        try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: false
        ).snapshot
    }

    private func activateAuthorityIfC3EvidenceIsReady(
        bundle: HostV6.ShadowMigrationBundle
    ) async throws -> HostV6.MetadataEnvelope? {
        let artifactURLs = c3ArtifactURLs()
        guard artifactURLs.count >= 2 else { return nil }
        do {
            let legacyData = try Data(contentsOf: paths.snapshot)
            let artifacts = try artifactURLs.map { try Data(contentsOf: $0) }
            let evidence = try evidenceVerifier.verify(artifacts)
            try await cloudCoordinator.validateAuthorityPrecondition(
                bundle.envelope,
                evidence: evidence
            )
            let plan = try HostV6.AuthorityController.prepareActivation(
                envelope: bundle.envelope,
                legacyData: legacyData,
                evidence: evidence
            )
            try await authorityStore.prepareActivation(plan, evidence: evidence)
            guard let published = try await resumePendingAuthorityActivation() else {
                return nil
            }
            return published
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (try? await authorityStore.pendingActivation()) != nil {
                throw error
            }
            return nil
        }
    }

    private func resumePendingAuthorityActivation() async throws -> HostV6.MetadataEnvelope? {
        guard let pending = try await authorityStore.pendingActivation() else { return nil }
        guard let published = try await cloudCoordinator.publishPreparedAuthority(
            pending,
            currentBuildIdentifier: evidenceVerifier.runningBuildIdentifier()
        ) else {
            try await authorityStore.discardPreparedActivation()
            return nil
        }
        try await authorityStore.completePreparedActivation(using: published)
        return published.envelope
    }

    private func c3ArtifactURLs() -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.authorityC3EvidenceDirectory.path) else {
            return []
        }
        return ((try? fileManager.contentsOfDirectory(
            at: paths.authorityC3EvidenceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            url.pathExtension.lowercased() == "cms"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func authorityStateExists() -> Bool {
        HostV6RuntimeAssembly.hasDurableAuthorityState(paths: paths)
    }
}

enum HostV6RuntimeAssembly {
    static func hasDurableAuthorityState(
        paths: KeyPortPaths,
        fileManager: FileManager = .default
    ) -> Bool {
        if [
            paths.stateV6,
            paths.authorityManifest,
            paths.authorityActivationJournal,
            paths.v6CommitJournal,
        ].contains(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            return true
        }
        let checkpoints = try? fileManager.contentsOfDirectory(
            at: paths.v6CheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return checkpoints?.contains(where: { $0.pathExtension == "json" }) == true
    }

    static func makeIfEnabled(
        currentDeviceID: String,
        defaults: UserDefaults = .standard,
        paths: KeyPortPaths = KeyPortPaths(),
        evidenceVerifier: HostV6C3EvidenceVerifier = HostV6C3EvidenceVerifier(),
        cloudTransport: any HostV6CloudV2Transport = CloudKitV2RecordTransport()
    ) -> HostV6Runtime? {
        let rolloutEnabled = HostV6RuntimeFeatureFlags.isCanaryEnabled(defaults: defaults)
            && HostV6RuntimeFeatureFlags.isCloudV2Enabled(defaults: defaults)
            && HostV6RuntimeFeatureFlags.isMutationWorkflowEnabled(defaults: defaults)
        guard rolloutEnabled || hasDurableAuthorityState(paths: paths) else {
            return nil
        }

        let runner = ProcessRunner()
        let authorityStore = HostV6AuthorityFileStore(paths: paths)
        let cloudCoordinator = HostV6CloudSyncCoordinator(
            transport: cloudTransport,
            currentDeviceID: currentDeviceID
        )
        let keychain = KeychainService()
        let configService = SSHConfigService(runner: runner, paths: paths)
        let effects = ProductionHostV6MutationEffects(
            configService: configService,
            hostKeyService: HostKeyService(runner: runner, paths: paths),
            keychainService: keychain,
            cloudCoordinator: cloudCoordinator,
            authorityStore: authorityStore,
            paths: paths
        )
        let repository = HostV6MutationWorkflow(
            authorityStore: authorityStore,
            ledgerStore: HostV6CommandLedgerFileStore(paths: paths),
            journalStore: HostV6MutationJournalFileStore(paths: paths),
            effects: effects,
            existingSSHHostAliases: {
                let config = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
                return SSHConfigGenerator.aliases(in: config)
            }
        )
        return HostV6Runtime(
            metadataRepository: repository,
            authorityStore: authorityStore,
            evidenceVerifier: evidenceVerifier,
            cloudCoordinator: cloudCoordinator,
            currentDeviceID: currentDeviceID,
            credentialInspector: keychain,
            configService: configService,
            paths: paths
        )
    }
}
