import Foundation

private typealias LegacyDevice = Device
private typealias LegacySSHKeyRecord = SSHKeyRecord
private typealias LegacyAuthorization = Authorization
private typealias LegacyNodeAssociation = NodeAssociation
private typealias LegacyAuditEvent = AuditEvent

public extension HostV6 {
    enum AuthorityRequirement: String, Codable, CaseIterable, Hashable, Sendable {
        case losslessMigration
        case cloudRoundTrip
        case mixedV5V6
        case pairedV6V6
        case deviceKeyAuthorization
        case keychainLocalAndSynchronizable
        case tombstonesAndConflictReview
        case compatibilityRollback
        case derivedArtifactSemanticDiff
    }

    struct AuthorityC3Report: Codable, Hashable, Sendable {
        public static let currentSchemaVersion = 1

        public var schemaVersion: Int
        public var deviceID: String
        public var teamIdentifier: String
        public var completedRequirements: Set<AuthorityRequirement>
        public var acknowledgedDeviceIDs: [String]
        public var verifiedCloudPayloadHash: String
        public var cloudChangeTag: String
        public var codeVersion: String

        public init(
            schemaVersion: Int = currentSchemaVersion,
            deviceID: String,
            teamIdentifier: String,
            completedRequirements: Set<AuthorityRequirement>,
            acknowledgedDeviceIDs: [String],
            verifiedCloudPayloadHash: String,
            cloudChangeTag: String,
            codeVersion: String
        ) {
            self.schemaVersion = schemaVersion
            self.deviceID = deviceID
            self.teamIdentifier = teamIdentifier
            self.completedRequirements = completedRequirements
            self.acknowledgedDeviceIDs = Array(Set(acknowledgedDeviceIDs)).sorted()
            self.verifiedCloudPayloadHash = verifiedCloudPayloadHash
            self.cloudChangeTag = cloudChangeTag
            self.codeVersion = codeVersion
        }
    }

    struct AuthorityActivationEvidence: Hashable, Sendable {
        public let completedRequirements: Set<AuthorityRequirement>
        public let signedMacDeviceIDs: [String]
        public let acknowledgedDeviceIDs: [String]
        public let verifiedCloudPayloadHash: String
        public let cloudChangeTag: String
        public let codeVersion: String
        public let signerTeamIdentifier: String
        public let signedArtifactDigests: [String]

        package init(
            completedRequirements: Set<AuthorityRequirement>,
            signedMacDeviceIDs: [String],
            acknowledgedDeviceIDs: [String],
            verifiedCloudPayloadHash: String,
            cloudChangeTag: String,
            codeVersion: String,
            signerTeamIdentifier: String,
            signedArtifactDigests: [String]
        ) {
            self.completedRequirements = completedRequirements
            self.signedMacDeviceIDs = Array(Set(signedMacDeviceIDs)).sorted()
            self.acknowledgedDeviceIDs = Array(Set(acknowledgedDeviceIDs)).sorted()
            self.verifiedCloudPayloadHash = verifiedCloudPayloadHash
            self.cloudChangeTag = cloudChangeTag
            self.codeVersion = codeVersion
            self.signerTeamIdentifier = signerTeamIdentifier
            self.signedArtifactDigests = Array(Set(signedArtifactDigests)).sorted()
        }
    }

    struct CompatibilityProjection: Sendable {
        public var snapshot: AppSnapshot
        public var data: Data
        public var notRepresentable: [EntityReference]

        public init(snapshot: AppSnapshot, data: Data, notRepresentable: [EntityReference]) {
            self.snapshot = snapshot
            self.data = data
            self.notRepresentable = notRepresentable
        }
    }

    struct AuthorityCommitPlan: Sendable {
        public var envelope: MetadataEnvelope
        public var manifest: AuthorityManifest
        public var stateData: Data
        public var checkpointData: Data
        public var compatibilitySnapshot: AppSnapshot
        public var compatibilityData: Data

        public init(
            envelope: MetadataEnvelope,
            manifest: AuthorityManifest,
            stateData: Data,
            checkpointData: Data,
            compatibilitySnapshot: AppSnapshot,
            compatibilityData: Data
        ) {
            self.envelope = envelope
            self.manifest = manifest
            self.stateData = stateData
            self.checkpointData = checkpointData
            self.compatibilitySnapshot = compatibilitySnapshot
            self.compatibilityData = compatibilityData
        }
    }

    enum AuthorityController {
        public static func activate(
            envelope: MetadataEnvelope,
            legacyData: Data,
            evidence: AuthorityActivationEvidence
        ) throws -> AuthorityCommitPlan {
            guard evidence.completedRequirements == Set(AuthorityRequirement.allCases),
                  Set(evidence.signedMacDeviceIDs).count >= 2,
                  evidence.signedArtifactDigests.count >= 2,
                  !evidence.signerTeamIdentifier.isEmpty,
                  !evidence.cloudChangeTag.isEmpty,
                  !evidence.codeVersion.isEmpty else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            let activeDeviceIDs = Set(
                envelope.synced.devices.lazy.filter { $0.deletedAt == nil }.map(\.id)
            )
            let acknowledgedDeviceIDs = Set(evidence.acknowledgedDeviceIDs)
            guard activeDeviceIDs.isSubset(of: acknowledgedDeviceIDs),
                  Set(evidence.signedMacDeviceIDs).isSubset(of: activeDeviceIDs) else {
                throw CloudV2Error.failure(.mixedVersionPending)
            }
            guard envelope.schemaVersion == 6,
                  envelope.validate(existingSSHHostAliases: []).isEmpty,
                  !envelope.synced.mergeReviews.contains(where: {
                      $0.deletedAt == nil && !$0.isResolved && $0.isBlocking
                  }) else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            let cloudPayload = try CloudPayloadCodec.encode(envelope)
            guard CanonicalJSON.sha256(cloudPayload) == evidence.verifiedCloudPayloadHash else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            let projection = try compatibilityProjection(
                from: envelope,
                requiresCompleteRoutes: true
            )
            guard try compatibilitySemanticData(projection.snapshot)
                    == compatibilitySemanticData(decodedLegacySnapshot(legacyData)),
                  try sshRouteSemanticData(projection.snapshot)
                    == sshRouteSemanticData(decodedLegacySnapshot(legacyData)) else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }

            return try makePlan(
                envelope: envelope,
                mode: .v6Authoritative,
                v1Hash: CanonicalJSON.sha256(legacyData),
                acknowledgedDeviceIDs: evidence.acknowledgedDeviceIDs,
                cloudChangeTag: evidence.cloudChangeTag,
                firstV6MutationID: nil,
                codeVersion: evidence.codeVersion,
                requiresCompleteCompatibilityProjection: true
            )
        }

        public static func recordMutation(
            _ mutationID: UUID,
            in envelope: MetadataEnvelope
        ) throws -> AuthorityCommitPlan {
            try authorizeMetadataMutation(in: envelope)
            guard let current = envelope.migrationProvenance.authorityManifest else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            return try makePlan(
                envelope: envelope,
                mode: .v6Authoritative,
                v1Hash: current.v1Hash,
                acknowledgedDeviceIDs: current.acknowledgedDeviceIDs,
                cloudChangeTag: current.cloudChangeTag,
                firstV6MutationID: current.firstV6MutationID ?? mutationID,
                codeVersion: current.codeVersion,
                requiresCompleteCompatibilityProjection: false
            )
        }

        public static func rebindManifest(in envelope: MetadataEnvelope) throws -> AuthorityCommitPlan {
            guard let current = envelope.migrationProvenance.authorityManifest,
                  current.mode != .compatibilityRollback else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            return try makePlan(
                envelope: envelope,
                mode: current.mode,
                v1Hash: current.v1Hash,
                acknowledgedDeviceIDs: current.acknowledgedDeviceIDs,
                cloudChangeTag: current.cloudChangeTag,
                firstV6MutationID: current.firstV6MutationID,
                codeVersion: current.codeVersion,
                requiresCompleteCompatibilityProjection: false
            )
        }

        public static func requestWritableLegacyRollback(
            envelope: MetadataEnvelope,
            currentLegacyData: Data
        ) throws -> MetadataEnvelope {
            guard var manifest = envelope.migrationProvenance.authorityManifest else {
                return envelope
            }
            guard manifest.firstV6MutationID == nil else {
                throw CloudV2Error.failure(.binaryDowngradeUnsafe)
            }
            guard manifest.v1Hash == CanonicalJSON.sha256(currentLegacyData) else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            manifest.mode = .v6Canary
            var result = envelope
            result.migrationProvenance.authorityManifest = manifest
            return result
        }

        public static func enterCompatibilityRollback(
            envelope: MetadataEnvelope,
            checkpointData: Data
        ) throws -> AuthorityCommitPlan {
            guard let current = envelope.migrationProvenance.authorityManifest,
                  current.mode == .v6Authoritative else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            let checkpoint = try verifyCheckpoint(checkpointData)
            guard let checkpointManifest = checkpoint.migrationProvenance.authorityManifest,
                  checkpointManifest.checkpointHash == current.checkpointHash,
                  checkpointManifest.firstV6MutationID == current.firstV6MutationID else {
                throw CloudV2Error.failure(.rollbackProjectionInvalid)
            }
            var plan = try makePlan(
                envelope: checkpoint,
                mode: .compatibilityRollback,
                v1Hash: current.v1Hash,
                acknowledgedDeviceIDs: current.acknowledgedDeviceIDs,
                cloudChangeTag: current.cloudChangeTag,
                firstV6MutationID: current.firstV6MutationID,
                codeVersion: current.codeVersion,
                requiresCompleteCompatibilityProjection: false
            )
            plan.checkpointData = checkpointData
            return plan
        }

        public static func forwardRecover(
            envelope: MetadataEnvelope,
            checkpointData: Data
        ) throws -> MetadataEnvelope {
            guard let rollbackManifest = envelope.migrationProvenance.authorityManifest,
                  rollbackManifest.mode == .compatibilityRollback else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
            var checkpoint = try verifyCheckpoint(checkpointData)
            guard var manifest = checkpoint.migrationProvenance.authorityManifest,
                  manifest.checkpointHash == rollbackManifest.checkpointHash,
                  manifest.firstV6MutationID == rollbackManifest.firstV6MutationID else {
                throw CloudV2Error.failure(.rollbackProjectionInvalid)
            }
            manifest.mode = .v6Authoritative
            checkpoint.migrationProvenance.authorityManifest = manifest
            return checkpoint
        }

        public static func authorizeMetadataMutation(in envelope: MetadataEnvelope) throws {
            guard envelope.migrationProvenance.authorityManifest?.mode == .v6Authoritative else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
        }

        @discardableResult
        public static func verifyCheckpoint(_ data: Data) throws -> MetadataEnvelope {
            do {
                let envelope = try CanonicalJSON.decode(MetadataEnvelope.self, from: data)
                guard envelope.schemaVersion == 6,
                      let manifest = envelope.migrationProvenance.authorityManifest,
                      envelope.validate(existingSSHHostAliases: []).isEmpty else {
                    throw CloudV2Error.failure(.rollbackProjectionInvalid)
                }
                let hash = try contentHash(envelope)
                let projection = try compatibilityProjection(
                    from: envelope,
                    requiresCompleteRoutes: false
                )
                guard hash == manifest.v6Hash,
                      hash == manifest.checkpointHash,
                      try compatibilitySemanticHash(projection.snapshot) == manifest.compatibilityHash,
                      projection.notRepresentable == manifest.notRepresentable else {
                    throw CloudV2Error.failure(.rollbackProjectionInvalid)
                }
                return envelope
            } catch let error as CloudV2Error {
                throw error
            } catch {
                throw CloudV2Error.failure(.rollbackProjectionInvalid)
            }
        }

        public static func compatibilityProjection(
            from envelope: MetadataEnvelope,
            requiresCompleteRoutes: Bool = true
        ) throws -> CompatibilityProjection {
            guard envelope.schemaVersion == 6,
                  envelope.validate(existingSSHHostAliases: []).isEmpty else {
                throw CloudV2Error.failure(.rollbackProjectionInvalid)
            }
            let routeProjection = HostV6SSHCompatProjection.project(
                graph: envelope.synced,
                local: envelope.local
            )
            guard !requiresCompleteRoutes
                    || (routeProjection.blockedIdentityIDs.isEmpty
                        && routeProjection.unavailableIdentityIDs.isEmpty) else {
                throw CloudV2Error.failure(.rollbackProjectionInvalid)
            }

            let currentDevices = Dictionary(
                uniqueKeysWithValues: envelope.local.deviceStates.map { ($0.deviceID, $0.isCurrent) }
            )
            let localKeys = Dictionary(
                uniqueKeysWithValues: envelope.local.keyStates.map { ($0.keyID, $0) }
            )
            var snapshot = AppSnapshot()
            snapshot.servers = routeProjection.servers
            snapshot.devices = envelope.synced.devices.map { device in
                LegacyDevice(
                    id: device.id,
                    name: device.name,
                    isCurrent: currentDevices[device.id, default: false],
                    registeredAt: device.registeredAt,
                    lastActiveAt: device.lastActiveAt,
                    isRevoked: device.deletedAt != nil,
                    tailscaleIdentity: device.tailscaleIdentity
                )
            }.sorted { $0.id < $1.id }
            snapshot.keys = envelope.synced.sshKeys.filter { $0.deletedAt == nil }.map { key in
                let local = localKeys[key.id]
                return LegacySSHKeyRecord(
                    id: key.id,
                    deviceID: key.deviceID,
                    kind: key.kind,
                    publicKey: key.publicKey,
                    fingerprint: key.fingerprint,
                    privateKeyPath: local?.privateKeyPath,
                    isInAgent: local?.isInAgent ?? false,
                    origin: key.origin,
                    isLocallyAvailable: local?.isLocallyAvailable ?? false
                )
            }.sorted { $0.id < $1.id }
            snapshot.authorizations = envelope.synced.authorizations.map { authorization in
                LegacyAuthorization(
                    serverID: authorization.sshIdentityID,
                    keyID: authorization.keyID,
                    fingerprint: authorization.fingerprint,
                    remoteComment: authorization.remoteComment,
                    status: legacyAuthorizationStatus(authorization),
                    authorizedAt: authorization.authorizedAt,
                    lastVerifiedAt: authorization.lastVerifiedAt,
                    updatedAt: authorization.stamp.updatedAt,
                    isDeleted: authorization.deletedAt != nil,
                    version: legacyRevision(authorization.stamp)
                )
            }.sorted { $0.id < $1.id }
            snapshot.nodeAssociations = envelope.synced.nodeAssociations
                .filter { $0.deletedAt == nil }
                .map { association in
                    LegacyNodeAssociation(
                        testCaseNodeID: association.id,
                        serverID: association.sshIdentityID,
                        target: association.target,
                        state: association.state,
                        method: association.method,
                        autoLinkEnabled: association.autoLinkEnabled,
                        updatedAt: association.stamp.updatedAt,
                        revision: legacyRevision(association.stamp)
                    )
                }
                .sorted { $0.id < $1.id }
            snapshot.auditEvents = envelope.local.auditEvents.map { event in
                LegacyAuditEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    category: event.category,
                    action: event.action,
                    targetID: event.targetID,
                    result: event.result,
                    level: legacyAuditLevel(event.level)
                )
            }

            let notRepresentable = notRepresentableEntities(
                envelope: envelope,
                projectedIdentityIDs: Set(snapshot.servers.map(\.id))
            )
            return CompatibilityProjection(
                snapshot: snapshot,
                data: try CanonicalJSON.encode(snapshot),
                notRepresentable: notRepresentable
            )
        }

        private static func makePlan(
            envelope: MetadataEnvelope,
            mode: AuthorityMode,
            v1Hash: String,
            acknowledgedDeviceIDs: [String],
            cloudChangeTag: String?,
            firstV6MutationID: UUID?,
            codeVersion: String,
            requiresCompleteCompatibilityProjection: Bool
        ) throws -> AuthorityCommitPlan {
            let projection = try compatibilityProjection(
                from: envelope,
                requiresCompleteRoutes: requiresCompleteCompatibilityProjection
            )
            let hash = try contentHash(envelope)
            let manifest = AuthorityManifest(
                mode: mode,
                v1Hash: v1Hash,
                v6Hash: hash,
                compatibilityHash: try compatibilitySemanticHash(projection.snapshot),
                checkpointHash: hash,
                acknowledgedDeviceIDs: acknowledgedDeviceIDs,
                cloudChangeTag: cloudChangeTag,
                firstV6MutationID: firstV6MutationID,
                codeVersion: codeVersion,
                notRepresentable: projection.notRepresentable
            )
            var committed = envelope
            committed.migrationProvenance.authorityManifest = manifest
            let stateData = try CanonicalJSON.encode(committed)
            return AuthorityCommitPlan(
                envelope: committed,
                manifest: manifest,
                stateData: stateData,
                checkpointData: stateData,
                compatibilitySnapshot: projection.snapshot,
                compatibilityData: projection.data
            )
        }

        private static func contentHash(_ envelope: MetadataEnvelope) throws -> String {
            var content = envelope
            content.migrationProvenance.authorityManifest = nil
            return CanonicalJSON.sha256(try CanonicalJSON.encode(CloudPayload(envelope: content)))
        }

        public static func compatibilitySemanticHash(_ snapshot: AppSnapshot) throws -> String {
            CanonicalJSON.sha256(try compatibilitySemanticData(
                cloudStableCompatibilitySnapshot(snapshot)
            ))
        }

        private static func decodedLegacySnapshot(_ data: Data) throws -> AppSnapshot {
            do {
                var snapshot = try CanonicalJSON.decode(AppSnapshot.self, from: data)
                guard (1...5).contains(snapshot.schemaVersion) else {
                    throw CloudV2Error.failure(.authorityGateFailed)
                }
                snapshot.migrateNodeAssociationsSchemaIfNeeded()
                return snapshot
            } catch let error as CloudV2Error {
                throw error
            } catch {
                throw CloudV2Error.failure(.authorityGateFailed)
            }
        }

        private static func compatibilitySemanticData(_ snapshot: AppSnapshot) throws -> Data {
            var normalized = snapshot
            normalized.schemaVersion = 5
            for index in normalized.servers.indices {
                normalized.servers[index].confirmedHostKeys.sort {
                    ($0.algorithm, $0.fingerprint, $0.knownHostsLine)
                        < ($1.algorithm, $1.fingerprint, $1.knownHostsLine)
                }
            }
            normalized.servers.sort { $0.id.uuidString < $1.id.uuidString }
            normalized.devices.sort { $0.id < $1.id }
            normalized.keys.sort { $0.id < $1.id }
            normalized.authorizations.sort { $0.id < $1.id }
            normalized.nodeAssociations.sort { $0.id < $1.id }
            return try CanonicalJSON.encode(normalized)
        }

        private struct SSHRouteSemantic: Codable {
            let identityID: UUID
            let alias: String
            let host: String
            let port: Int
            let username: String
            let identityPath: String?
            let knownHostsLines: [String]
        }

        private static func sshRouteSemanticData(_ snapshot: AppSnapshot) throws -> Data {
            let keys = Dictionary(uniqueKeysWithValues: snapshot.keys.map { ($0.id, $0) })
            let authorizations = Dictionary(grouping: snapshot.authorizations.filter {
                !$0.isDeleted && $0.status == .authorized
            }, by: \.serverID)
            let routes = snapshot.servers.filter { !$0.isDeleted }.map { server in
                let authorization = authorizations[server.id]?.sorted { $0.id < $1.id }.first
                return SSHRouteSemantic(
                    identityID: server.id,
                    alias: server.alias,
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    identityPath: authorization.flatMap { keys[$0.keyID]?.privateKeyPath },
                    knownHostsLines: server.confirmedHostKeys.map(\.knownHostsLine).sorted()
                )
            }.sorted { $0.identityID.uuidString < $1.identityID.uuidString }
            return try CanonicalJSON.encode(routes)
        }

        private static func cloudStableCompatibilitySnapshot(_ snapshot: AppSnapshot) -> AppSnapshot {
            var stable = snapshot
            for index in stable.servers.indices {
                stable.servers[index].notes = ""
                stable.servers[index].status = .hostKeyPending
                stable.servers[index].statusDetail = nil
                stable.servers[index].lastCheckedAt = nil
                stable.servers[index].passwordCheck = nil
                stable.servers[index].keyCheck = nil
                stable.servers[index].machineConfigurationRefreshAttemptedAt = nil
            }
            for index in stable.devices.indices {
                stable.devices[index].isCurrent = false
            }
            for index in stable.keys.indices {
                stable.keys[index].privateKeyPath = nil
                stable.keys[index].isInAgent = false
                stable.keys[index].isLocallyAvailable = false
            }
            stable.auditEvents = []
            return stable
        }

        private static func legacyAuthorizationStatus(_ value: HostV6.Authorization) -> AuthorizationStatus {
            if value.relationState == .detached { return .authorizationConflict }
            switch value.remoteState {
            case .authorized: return .authorized
            case .revoked: return .needsAuthorization
            case .unknown: return .syncPending
            }
        }

        private static func legacyRevision(_ stamp: SyncStamp) -> Int {
            let maximum = stamp.vector.values.max() ?? 1
            return Int(clamping: max(1, maximum))
        }

        private static func legacyAuditLevel(_ value: HostV6.AuditEvent.Level) -> LegacyAuditEvent.Level {
            switch value {
            case .info: return .info
            case .warning: return .warning
            case .error: return .error
            }
        }

        private static func notRepresentableEntities(
            envelope: MetadataEnvelope,
            projectedIdentityIDs: Set<UUID>
        ) -> [EntityReference] {
            var result = Set(envelope.synced.services.map { EntityReference.service($0.id) })
            result.formUnion(envelope.synced.sshKeys.lazy
                .filter { $0.deletedAt != nil }
                .map { .sshKeyRecord($0.id) })
            let representedHostIDs = Set(envelope.synced.identities.lazy
                .filter { projectedIdentityIDs.contains($0.id) }
                .map(\.hostID))
            result.formUnion(envelope.synced.hosts.lazy
                .filter { !representedHostIDs.contains($0.id) }
                .map { .host($0.id) })
            result.formUnion(envelope.synced.identities.lazy
                .filter { !projectedIdentityIDs.contains($0.id) }
                .map { .sshIdentity($0.id) })
            result.formUnion(envelope.synced.mergeReviews.map { .mergeReview($0.id) })
            return result.sorted { entityOrder($0) < entityOrder($1) }
        }

        private static func entityOrder(_ value: EntityReference) -> String {
            "\(value.entityType.rawValue)|\(value.stableID)"
        }
    }
}
