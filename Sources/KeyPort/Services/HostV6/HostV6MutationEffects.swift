import Foundation
import KeyPortCore

protocol HostV6TunnelClosing: Sendable {
    func closeHostTunnels(_ hostID: UUID) async throws
    func closeIdentityTunnels(_ identityID: UUID) async throws
    func closeAddressTunnels(_ addressID: UUID) async throws
    func closeServiceTunnel(_ serviceID: UUID) async throws
}

struct UnavailableHostV6TunnelCloser: HostV6TunnelClosing {
    func closeHostTunnels(_ hostID: UUID) async throws { throw unavailable() }
    func closeIdentityTunnels(_ identityID: UUID) async throws { throw unavailable() }
    func closeAddressTunnels(_ addressID: UUID) async throws { throw unavailable() }
    func closeServiceTunnel(_ serviceID: UUID) async throws { throw unavailable() }

    private func unavailable() -> HostV6.CloudV2Error {
        .failure(.artifactMismatch)
    }
}

struct TunnelRegistryHostV6TunnelCloser: HostV6TunnelClosing {
    let registry: TunnelRegistry

    func closeHostTunnels(_ hostID: UUID) async throws {
        try requireCompleted(await registry.closeHostTunnels(hostID))
    }

    func closeIdentityTunnels(_ identityID: UUID) async throws {
        try requireCompleted(await registry.closeIdentityTunnels(identityID))
    }

    func closeAddressTunnels(_ addressID: UUID) async throws {
        try requireCompleted(await registry.closeAddressTunnels(addressID))
    }

    func closeServiceTunnel(_ serviceID: UUID) async throws {
        try requireCompleted(await registry.closeServiceTunnel(serviceID))
    }

    private func requireCompleted(_ result: TunnelCloseResult) throws {
        guard result.cleanup != .pending else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }
}

actor ProductionHostV6MutationEffects: HostV6MutationEffectApplying {
    private let configService: SSHConfigService
    private let hostKeyService: HostKeyService
    private let keychainService: KeychainService
    private let cloudCoordinator: HostV6CloudSyncCoordinator
    private let authorityStore: any HostV6AuthorityStoring
    private let paths: KeyPortPaths
    private let fileManager: FileManager
    private let tunnelCloser: any HostV6TunnelClosing

    init(
        configService: SSHConfigService,
        hostKeyService: HostKeyService,
        keychainService: KeychainService,
        cloudCoordinator: HostV6CloudSyncCoordinator,
        authorityStore: any HostV6AuthorityStoring,
        paths: KeyPortPaths,
        tunnelCloser: any HostV6TunnelClosing,
        fileManager: FileManager = .default
    ) {
        self.configService = configService
        self.hostKeyService = hostKeyService
        self.keychainService = keychainService
        self.cloudCoordinator = cloudCoordinator
        self.authorityStore = authorityStore
        self.paths = paths
        self.fileManager = fileManager
        self.tunnelCloser = tunnelCloser
    }

    func closeTunnels(_ effects: [HostV6.PendingExternalEffect]) async throws {
        for effect in effects {
            switch effect {
            case .closeHostTunnels(let hostID):
                try await tunnelCloser.closeHostTunnels(hostID)
            case .closeIdentityTunnels(let identityID):
                try await tunnelCloser.closeIdentityTunnels(identityID)
            case .closeAddressTunnels(let addressID):
                try await tunnelCloser.closeAddressTunnels(addressID)
            case .closeServiceTunnel(let serviceID):
                try await tunnelCloser.closeServiceTunnel(serviceID)
            default:
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
        }
    }

    func rebuildSSHConfig(from envelope: HostV6.MetadataEnvelope) async throws {
        let snapshot = try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: false
        ).snapshot
        try await configService.write(
            servers: snapshot.servers.filter { !$0.isDeleted },
            keys: snapshot.keys,
            authorizations: snapshot.authorizations
        )
    }

    func rebuildKnownHosts(from envelope: HostV6.MetadataEnvelope) async throws {
        let snapshot = try HostV6.AuthorityController.compatibilityProjection(
            from: envelope,
            requiresCompleteRoutes: false
        ).snapshot
        try await hostKeyService.persistConfirmedKeys(
            [],
            allServers: snapshot.servers.filter { !$0.isDeleted }
        )
    }

    func deleteCredentials(_ identityIDs: [UUID]) async throws {
        for identityID in identityIDs {
            try await keychainService.deleteServerCredential(serverID: identityID)
        }
    }

    func deletePrivateKeyMaterial(
        _ keyIDs: [String],
        localState: HostV6.LocalState
    ) throws {
        let states = Dictionary(uniqueKeysWithValues: localState.keyStates.map { ($0.keyID, $0) })
        for keyID in keyIDs {
            guard isSafeKeyID(keyID) else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            guard let privateKeyPath = states[keyID]?.privateKeyPath else { continue }
            let expected = paths.identitiesDirectory.appendingPathComponent(keyID).standardizedFileURL
            let recorded = URL(fileURLWithPath: privateKeyPath).standardizedFileURL
            guard expected == recorded,
                  expected.deletingLastPathComponent() == paths.identitiesDirectory.standardizedFileURL else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            try removeIfPresent(expected)
            try removeIfPresent(expected.appendingPathExtension("pub"))
        }
    }

    func synchronizeCloudV2(
        _ envelope: HostV6.MetadataEnvelope,
        mutationID: UUID
    ) async throws {
        let result = try await cloudCoordinator.synchronize(envelope)
        guard result.envelope.migrationProvenance.authorityManifest != nil else {
            throw HostV6.CloudV2Error.failure(.authorityGateFailed)
        }
        let plan = try HostV6.AuthorityController.recordMutation(mutationID, in: result.envelope)
        try await authorityStore.commit(plan)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func isSafeKeyID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }
}
