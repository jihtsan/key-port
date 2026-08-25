import Foundation

public extension HostV6 {
    struct ShadowMigrationEngine: Sendable {
        public let currentDeviceID: String

        public init(currentDeviceID: String) {
            self.currentDeviceID = currentDeviceID
        }

        public func legacyIdentityAccountIDs(from legacyData: Data) throws -> [String] {
            do {
                let snapshot = try CanonicalJSON.decode(AppSnapshot.self, from: legacyData)
                guard (1...5).contains(snapshot.schemaVersion) else {
                    throw migrationError(
                        .decodeFailed,
                        objectID: "state-v1",
                        detail: "unsupportedLegacySchema"
                    )
                }
                return Array(Set(snapshot.servers.map { $0.id.uuidString.lowercased() })).sorted()
            } catch let error as ShadowMigrationError {
                throw error
            } catch {
                throw migrationError(.decodeFailed, objectID: "state-v1", detail: "legacyAccountDecode")
            }
        }

        public func prepare(
            legacyData: Data,
            previousStateData: Data?,
            inspection: ShadowMigrationInspection
        ) throws -> ShadowMigrationBundle {
            let decoded: AppSnapshot
            do {
                decoded = try CanonicalJSON.decode(AppSnapshot.self, from: legacyData)
            } catch {
                throw migrationError(.decodeFailed, objectID: "state-v1", detail: "legacySnapshotDecode")
            }
            guard (1...5).contains(decoded.schemaVersion) else {
                throw migrationError(.decodeFailed, objectID: "state-v1", detail: "unsupportedLegacySchema")
            }
            let legacySchemaVersion = decoded.schemaVersion
            let legacy = migratedToV5(decoded)
            let projection = try LegacyProjection(snapshot: legacy, currentDeviceID: currentDeviceID).build()
            let projectedEnvelope = MetadataEnvelope(
                synced: projection.graph,
                local: projection.local,
                migrationProvenance: MigrationProvenance(
                    legacySources: projection.legacySources,
                    authorityManifest: nil
                )
            )
            let ownedLegacyAliases = Set(legacy.servers.lazy.filter { !$0.isDeleted }.map {
                $0.alias.lowercased()
            })
            let externalAliases = Set(inspection.existingSSHHostAliases.lazy.map { $0.lowercased() })
                .subtracting(ownedLegacyAliases)
            try validate(projectedEnvelope, existingSSHHostAliases: externalAliases)
            let envelope: MetadataEnvelope
            let ignoredStaleSourceIDs: Set<String>
            if let previousStateData {
                let previous: MetadataEnvelope
                do {
                    previous = try CanonicalJSON.decode(MetadataEnvelope.self, from: previousStateData)
                } catch {
                    throw migrationError(.decodeFailed, objectID: "state-v6", detail: "previousShadowDecode")
                }
                guard previous.migrationProvenance.authorityManifest == nil else {
                    throw migrationError(.authorityGateFailed, objectID: "state-v6", detail: "shadowCannotImportAuthority")
                }
                try validate(previous, existingSSHHostAliases: [])
                try validateLegacyTransition(from: previous, to: projectedEnvelope)
                ignoredStaleSourceIDs = staleSourceIDs(from: previous, to: projectedEnvelope)
                envelope = merge(
                    previous: previous,
                    projected: projectedEnvelope,
                    staleSourceIDs: ignoredStaleSourceIDs
                )
            } else {
                ignoredStaleSourceIDs = []
                envelope = projectedEnvelope
            }

            try validate(envelope, existingSSHHostAliases: externalAliases)

            let proofs = makeProofs(
                legacy: legacy,
                envelope: envelope,
                inspection: inspection,
                ignoredStaleSourceIDs: ignoredStaleSourceIDs,
                referencesValid: true
            )
            guard proofs.protectedArtifactsUnchanged else {
                throw migrationError(.artifactMismatch, objectID: "protected-artifacts", detail: "hashSetChanged")
            }
            guard proofs.keychainAccountsUnchanged else {
                throw migrationError(.artifactMismatch, objectID: "keychain-accounts", detail: "accountMatrixChanged")
            }
            guard proofs.allPassed else {
                throw migrationError(.invariantFailed, objectID: "lossless-report", detail: "proofFailed")
            }

            let stateData = try CanonicalJSON.encode(envelope)
            let details = try makeDetailedReports(
                legacy: legacy,
                envelope: envelope,
                inspection: inspection,
                ignoredStaleSourceIDs: ignoredStaleSourceIDs
            )
            guard details.allowList.forbiddenMatchCounts.values.allSatisfy({ $0 == 0 }) else {
                let counts = details.allowList.forbiddenMatchCounts
                    .filter { $0.value > 0 }
                    .map { "\($0.key)=\($0.value)" }
                    .sorted()
                    .joined(separator: ",")
                throw migrationError(
                    .invariantFailed,
                    objectID: "allow-list",
                    detail: "forbiddenFieldEncoded:\(counts)"
                )
            }
            let report = ShadowMigrationReport(
                legacySchemaVersion: legacySchemaVersion,
                inputSHA256: CanonicalJSON.sha256(legacyData),
                stateSHA256: CanonicalJSON.sha256(stateData),
                envelope: envelope,
                proofs: proofs,
                idContinuity: details.idContinuity,
                references: details.references,
                keychain: details.keychain,
                ssh: details.ssh,
                authorizations: details.authorizations,
                causality: details.causality,
                allowList: details.allowList,
                ignoredStaleSourceIDs: Array(ignoredStaleSourceIDs),
                artifacts: ShadowMigrationArtifactReport(
                    before: inspection.artifactHashesBefore,
                    after: inspection.artifactHashesAfter
                )
            )
            return ShadowMigrationBundle(
                envelope: envelope,
                report: report,
                stateData: stateData,
                reportData: try CanonicalJSON.encode(report)
            )
        }

        private func validate(
            _ envelope: MetadataEnvelope,
            existingSSHHostAliases: Set<String>
        ) throws {
            let violations = envelope.validate(existingSSHHostAliases: existingSSHHostAliases)
            guard violations.isEmpty else {
                let detail = violations.map {
                    "\($0.code.rawValue):\($0.subject.entityType.rawValue):\($0.subject.stableID)"
                }.joined(separator: ",")
                throw migrationError(.invariantFailed, objectID: "state-v6", detail: detail)
            }
        }

        private func migratedToV5(_ input: AppSnapshot) -> AppSnapshot {
            var result = input
            if result.schemaVersion < 3 {
                for index in result.servers.indices
                where !result.servers[index].isDeleted && result.servers[index].keyCheck == nil {
                    guard let checkedAt = result.servers[index].lastCheckedAt else { continue }
                    let check: AuthenticationCheck?
                    switch result.servers[index].status {
                    case .authorized:
                        check = AuthenticationCheck(
                            state: .succeeded,
                            detail: result.servers[index].statusDetail ?? "keyAuthenticationSucceeded",
                            checkedAt: checkedAt
                        )
                    case .needsAuthorization, .keyAuthenticationFailed:
                        check = AuthenticationCheck(
                            state: .failed,
                            detail: result.servers[index].statusDetail ?? "keyAuthenticationFailed",
                            checkedAt: checkedAt
                        )
                    case .hostKeyPending, .hostKeyMismatch:
                        check = AuthenticationCheck(
                            state: .blocked,
                            detail: result.servers[index].statusDetail ?? "hostKeyPending",
                            checkedAt: checkedAt
                        )
                    default:
                        check = nil
                    }
                    result.servers[index].keyCheck = check
                }
            }
            if result.schemaVersion < 5 {
                result.nodeAssociations = []
            }
            result.schemaVersion = 5
            return result
        }

        private func validateLegacyTransition(
            from previous: MetadataEnvelope,
            to projected: MetadataEnvelope
        ) throws {
            let previousSources = Dictionary(
                uniqueKeysWithValues: previous.migrationProvenance.legacySources.map { ($0.id, $0) }
            )
            for candidate in projected.migrationProvenance.legacySources {
                guard let existing = previousSources[candidate.id], existing.digest != candidate.digest else {
                    continue
                }
                if candidate.legacyKind == "key" {
                    throw migrationError(
                        .legacyImmutableKeyConflict,
                        objectID: candidate.id,
                        detail: "immutableDigestChanged"
                    )
                }
                if candidate.revision == existing.revision, candidate.legacyKind != "device" {
                    throw migrationError(
                        .legacyVersionReuse,
                        objectID: candidate.id,
                        detail: "sameRevisionDifferentDigest"
                    )
                }
            }
        }

        private func merge(
            previous: MetadataEnvelope,
            projected: MetadataEnvelope,
            staleSourceIDs: Set<String>
        ) -> MetadataEnvelope {
            var reviews = previous.synced.mergeReviews + projected.synced.mergeReviews
            let graph = SyncedGraph(
                hosts: mergeEntities(
                    previous.synced.hosts,
                    projected.synced.hosts,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                addresses: mergeEntities(
                    previous.synced.addresses,
                    projected.synced.addresses,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                identities: mergeEntities(
                    previous.synced.identities,
                    projected.synced.identities,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                devices: mergeEntities(
                    previous.synced.devices,
                    projected.synced.devices,
                    reviews: &reviews,
                    sortedBy: { $0.id < $1.id }
                ),
                sshKeys: mergeEntities(
                    previous.synced.sshKeys,
                    projected.synced.sshKeys,
                    reviews: &reviews,
                    sortedBy: { $0.id < $1.id }
                ),
                hostKeyPins: mergeEntities(
                    previous.synced.hostKeyPins,
                    projected.synced.hostKeyPins,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                knownHostsLines: mergeEntities(
                    previous.synced.knownHostsLines,
                    projected.synced.knownHostsLines,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                services: mergeEntities(
                    previous.synced.services,
                    projected.synced.services,
                    reviews: &reviews,
                    sortedBy: { uuidOrder($0.id, $1.id) }
                ),
                authorizations: mergeEntities(
                    previous.synced.authorizations,
                    projected.synced.authorizations,
                    reviews: &reviews,
                    sortedBy: { $0.id < $1.id }
                ),
                nodeAssociations: mergeEntities(
                    previous.synced.nodeAssociations,
                    projected.synced.nodeAssociations,
                    reviews: &reviews,
                    sortedBy: { $0.id < $1.id }
                ),
                mergeReviews: []
            )
            var mergedGraph = graph
            appendPinConflictReviews(pins: &mergedGraph.hostKeyPins, reviews: &reviews)
            let legacySources = mergeEntities(
                previous.migrationProvenance.legacySources,
                projected.migrationProvenance.legacySources,
                reviews: &reviews,
                sortedBy: { $0.id < $1.id }
            )
            mergedGraph.mergeReviews = coalescedReviews(reviews)

            let local = mergeLocalState(
                previous: previous.local,
                projected: projected.local,
                previousSources: previous.migrationProvenance.legacySources,
                staleSourceIDs: staleSourceIDs
            )
            return MetadataEnvelope(
                schemaVersion: 6,
                synced: mergedGraph,
                local: local,
                migrationProvenance: MigrationProvenance(
                    legacySources: legacySources,
                    authorityManifest: nil
                )
            )
        }

        private func staleSourceIDs(
            from previous: MetadataEnvelope,
            to projected: MetadataEnvelope
        ) -> Set<String> {
            let existing = Dictionary(
                uniqueKeysWithValues: previous.migrationProvenance.legacySources.map { ($0.id, $0) }
            )
            return Set(projected.migrationProvenance.legacySources.compactMap { candidate in
                guard let current = existing[candidate.id], candidate.revision < current.revision else {
                    return nil
                }
                return candidate.id
            })
        }

        private func makeProofs(
            legacy: AppSnapshot,
            envelope: MetadataEnvelope,
            inspection: ShadowMigrationInspection,
            ignoredStaleSourceIDs: Set<String>,
            referencesValid: Bool
        ) -> ShadowMigrationProofReport {
            let legacyIdentityIDs = legacy.servers.map { $0.id.uuidString.lowercased() }.sorted()
            let v6IdentityIDs = envelope.synced.identities.map { $0.id.uuidString.lowercased() }.sorted()
            let staleServerIDs = Set(ignoredStaleSourceIDs.compactMap { sourceID -> UUID? in
                guard sourceID.hasPrefix("server/") else { return nil }
                return UUID(uuidString: String(sourceID.dropFirst("server/".count)))
            })
            let legacyAliases = Dictionary(uniqueKeysWithValues: legacy.servers.filter {
                !staleServerIDs.contains($0.id)
            }.map {
                ($0.id.uuidString.lowercased(), $0.alias)
            })
            let v6Aliases = Dictionary(uniqueKeysWithValues: envelope.synced.identities.filter {
                !staleServerIDs.contains($0.id)
            }.map {
                ($0.id.uuidString.lowercased(), $0.alias)
            })
            let legacyAuthorizationIDs = legacy.authorizations.map(authorizationKey).sorted()
            let v6AuthorizationIDs = envelope.synced.authorizations.map {
                authorizationKey(identityID: $0.sshIdentityID, fingerprint: $0.fingerprint)
            }.sorted()
            let legacyAudit = legacy.auditEvents.map(auditEvent)
            let legacyProvenance = legacy.servers.filter {
                !staleServerIDs.contains($0.id)
            }.flatMap { server in
                server.confirmedHostKeys.map {
                    provenanceKey(sourceID: server.id, rawLine: $0.knownHostsLine)
                }
            }.sorted()
            let v6Provenance = envelope.synced.knownHostsLines.filter {
                !staleServerIDs.contains($0.source.id)
            }.map {
                provenanceKey(sourceID: $0.source.id, rawLine: $0.rawLine)
            }.sorted()
            let legacyKnownHosts = Array(Set(
                legacy.servers.lazy
                    .filter { !$0.isDeleted && !staleServerIDs.contains($0.id) }
                    .flatMap(\.confirmedHostKeys)
                    .map(\.knownHostsLine)
            )).sorted()
            let v6KnownHosts = Array(Set(
                envelope.synced.knownHostsLines.lazy
                    .filter { $0.deletedAt == nil && !staleServerIDs.contains($0.source.id) }
                    .map(\.rawLine)
            )).sorted()
            let expectedKeychainAccounts = Set(legacyIdentityIDs)

            return ShadowMigrationProofReport(
                identityIDsUnchanged: legacyIdentityIDs == v6IdentityIDs,
                deviceIDsUnchanged: legacy.devices.map(\.id).sorted() == envelope.synced.devices.map(\.id).sorted(),
                keyIDsUnchanged: legacy.keys.map(\.id).sorted() == envelope.synced.sshKeys.map(\.id).sorted(),
                authorizationIDsUnchanged: legacyAuthorizationIDs == v6AuthorizationIDs,
                nodeAssociationIDsUnchanged: legacy.nodeAssociations.map(\.id).sorted()
                    == envelope.synced.nodeAssociations.map(\.id).sorted(),
                auditEventsUnchanged: !ignoredStaleSourceIDs.isEmpty
                    || legacyAudit == envelope.local.auditEvents,
                keychainAccountsUnchanged: inspection.keychainAccountsBefore == inspection.keychainAccountsAfter
                    && Set(inspection.keychainAccountsBefore.keys) == expectedKeychainAccounts,
                sshAliasesUnchanged: legacyAliases == v6Aliases,
                knownHostsProvenancePreserved: legacyProvenance == v6Provenance,
                renderedKnownHostsUnchanged: legacyKnownHosts == v6KnownHosts,
                referencesValid: referencesValid,
                protectedArtifactsUnchanged: inspection.artifactHashesBefore == inspection.artifactHashesAfter
            )
        }
    }
}

private struct LegacySourceDescriptor: Hashable, Sendable {
    let ledgerID: String
    let kind: String
    let legacyID: String
    let dimension: String
    let counter: UInt64
    let digest: String
    let isDeleted: Bool
    let updatedAt: Date
}

private struct LegacyServerSource: Sendable {
    let server: ServerConnection
    let descriptor: LegacySourceDescriptor
    let hostID: UUID
    let addressID: UUID
}

private struct ProjectedKnownHostsLine: Sendable {
    let source: LegacyServerSource
    let key: HostKeyRecord
    let pinID: UUID
    let lineID: UUID
    let duplicateOrdinal: UInt32
}

private struct LegacyProjection {
    let snapshot: AppSnapshot
    let currentDeviceID: String

    struct Result {
        var graph: HostV6.SyncedGraph
        var local: HostV6.LocalState
        var legacySources: [HostV6.LegacySourceRevision]
    }

    func build() throws -> Result {
        let serverSources = try snapshot.servers.map(serverSource).sorted {
            $0.descriptor.legacyID < $1.descriptor.legacyID
        }
        let groupedSources = Dictionary(grouping: serverSources, by: { $0.hostID })
        var hosts: [HostV6.Host] = []
        var addresses: [HostV6.AccessAddress] = []
        var reviews: [HostV6.MergeReview] = []

        for hostID in groupedSources.keys.sorted(by: uuidOrder) {
            let sources = groupedSources[hostID]!.sorted { $0.descriptor.legacyID < $1.descriptor.legacyID }
            let active = sources.filter { !$0.server.isDeleted }
            let fieldSources = active.isEmpty ? sources : active
            let selected = fieldSources[0]
            let deletedAt = active.isEmpty ? sources.map(\.server.updatedAt).max() : nil
            let hostStamp = stamp(
                entityType: .host,
                entityID: hostID.uuidString.lowercased(),
                sources: sources.map(\.descriptor),
                updatedAt: sources.map(\.server.updatedAt).max() ?? selected.server.updatedAt
            )
            let host = HostV6.Host(
                id: hostID,
                name: selected.server.name,
                group: selected.server.group,
                machineConfiguration: selected.server.machineConfiguration,
                fixedAddressID: nil,
                createdAt: fieldSources.map(\.server.createdAt).min() ?? selected.server.createdAt,
                stamp: hostStamp,
                deletedAt: deletedAt
            )
            hosts.append(host)

            let hostCandidates = fieldSources.map { source in
                HostV6.Host(
                    id: hostID,
                    name: source.server.name,
                    group: source.server.group,
                    machineConfiguration: source.server.machineConfiguration,
                    fixedAddressID: nil,
                    createdAt: source.server.createdAt,
                    stamp: stamp(
                        entityType: .host,
                        entityID: hostID.uuidString.lowercased(),
                        sources: [source.descriptor],
                        updatedAt: source.server.updatedAt
                    ),
                    deletedAt: source.server.isDeleted ? source.server.updatedAt : nil
                )
            }
            if let review = sharedReview(candidates: hostCandidates, isBlocking: hostConflictIsBlocking) {
                reviews.append(review)
            }

            let addressStamp = stamp(
                entityType: .address,
                entityID: selected.addressID.uuidString.lowercased(),
                sources: sources.map(\.descriptor),
                updatedAt: sources.map(\.server.updatedAt).max() ?? selected.server.updatedAt
            )
            addresses.append(HostV6.AccessAddress(
                id: selected.addressID,
                hostID: hostID,
                normalizedHost: normalizedHost(selected.server.host),
                sshPort: try validPort(selected.server.port),
                originalLabel: selected.server.host,
                source: .legacy,
                sortOrder: 0,
                stamp: addressStamp,
                deletedAt: deletedAt
            ))
            let addressCandidates = fieldSources.map { source in
                HostV6.AccessAddress(
                    id: source.addressID,
                    hostID: hostID,
                    normalizedHost: normalizedHost(source.server.host),
                    sshPort: UInt16(source.server.port),
                    originalLabel: source.server.host,
                    source: .legacy,
                    sortOrder: 0,
                    stamp: stamp(
                        entityType: .address,
                        entityID: source.addressID.uuidString.lowercased(),
                        sources: [source.descriptor],
                        updatedAt: source.server.updatedAt
                    ),
                    deletedAt: source.server.isDeleted ? source.server.updatedAt : nil
                )
            }
            if let review = sharedReview(candidates: addressCandidates, isBlocking: { _, _ in true }) {
                reviews.append(review)
            }
        }

        let identities = serverSources.map { source in
            HostV6.SSHIdentity(
                id: source.server.id,
                hostID: source.hostID,
                username: source.server.username,
                alias: source.server.alias,
                preferredAddressID: source.addressID,
                createdAt: source.server.createdAt,
                stamp: stamp(
                    entityType: .sshIdentity,
                    entityID: source.descriptor.legacyID,
                    sources: [source.descriptor],
                    updatedAt: source.server.updatedAt
                ),
                deletedAt: source.server.isDeleted ? source.server.updatedAt : nil
            )
        }

        let projectedLines = serverSources.flatMap(projectKnownHostsLines)
        let knownHostsLines = projectedLines.map { value in
            HostV6.KnownHostsLine(
                id: value.lineID,
                pinID: value.pinID,
                rawLine: value.key.knownHostsLine,
                source: .legacyIdentity(value.source.server.id),
                duplicateOrdinal: value.duplicateOrdinal,
                stamp: stamp(
                    entityType: .knownHostsLine,
                    entityID: value.lineID.uuidString.lowercased(),
                    sources: [value.source.descriptor],
                    updatedAt: value.source.server.updatedAt
                ),
                deletedAt: value.source.server.isDeleted ? value.source.server.updatedAt : nil
            )
        }.sorted { uuidOrder($0.id, $1.id) }
        var hostKeyPins = Dictionary(grouping: projectedLines, by: \.pinID).keys.map { pinID in
            let values = Dictionary(grouping: projectedLines, by: \.pinID)[pinID]!.sorted {
                $0.source.descriptor.legacyID < $1.source.descriptor.legacyID
            }
            let selected = values[0]
            let active = values.filter { !$0.source.server.isDeleted }
            return HostV6.HostKeyPin(
                id: pinID,
                hostID: selected.source.hostID,
                addressID: selected.source.addressID,
                algorithm: selected.key.algorithm,
                fingerprint: selected.key.fingerprint,
                state: .confirmed,
                firstConfirmedAt: values.compactMap(\.key.firstConfirmedAt).min(),
                lastSeenAt: values.map(\.key.lastSeenAt).max() ?? selected.key.lastSeenAt,
                stamp: stamp(
                    entityType: .hostKeyPin,
                    entityID: pinID.uuidString.lowercased(),
                    sources: uniqueDescriptors(values.map { $0.source.descriptor }),
                    updatedAt: values.map { $0.source.server.updatedAt }.max() ?? selected.source.server.updatedAt
                ),
                deletedAt: active.isEmpty ? values.map { $0.source.server.updatedAt }.max() : nil
            )
        }.sorted { uuidOrder($0.id, $1.id) }
        appendPinConflictReviews(pins: &hostKeyPins, reviews: &reviews)

        let devicePairs = try snapshot.devices.map { device -> (HostV6.Device, [LegacySourceDescriptor]) in
            let descriptors = try deviceDescriptors(device)
            return (
                HostV6.Device(
                    id: device.id,
                    name: device.name,
                    registeredAt: device.registeredAt,
                    lastActiveAt: device.lastActiveAt,
                    tailscaleIdentity: device.tailscaleIdentity,
                    stamp: stamp(
                        entityType: .device,
                        entityID: device.id,
                        sources: descriptors,
                        updatedAt: device.lastActiveAt
                    ),
                    deletedAt: device.isRevoked ? device.lastActiveAt : nil
                ),
                descriptors
            )
        }.sorted { $0.0.id < $1.0.id }

        let keyPairs = try snapshot.keys.map { key -> (HostV6.SSHKeyRecord, LegacySourceDescriptor) in
            let descriptor = try keyDescriptor(key)
            return (
                HostV6.SSHKeyRecord(
                    id: key.id,
                    deviceID: key.deviceID,
                    kind: key.kind,
                    publicKey: key.publicKey,
                    fingerprint: key.fingerprint,
                    origin: key.origin,
                    stamp: stamp(
                        entityType: .sshKeyRecord,
                        entityID: key.id,
                        sources: [descriptor],
                        updatedAt: descriptor.updatedAt
                    )
                ),
                descriptor
            )
        }.sorted { $0.0.id < $1.0.id }

        var serverByID: [UUID: LegacyServerSource] = [:]
        for source in serverSources {
            guard serverByID.updateValue(source, forKey: source.server.id) == nil else {
                throw projectionError("duplicateLegacyServerID")
            }
        }
        let authorizationPairs = try snapshot.authorizations.map {
            authorization -> (HostV6.Authorization, LegacySourceDescriptor) in
            guard let identitySource = serverByID[authorization.serverID] else {
                throw projectionError("authorizationIdentityMissing")
            }
            let descriptor = try authorizationDescriptor(authorization)
            let isDetached = authorization.isDeleted || identitySource.server.isDeleted
            let deletedAt = isDetached
                ? max(authorization.updatedAt, identitySource.server.updatedAt)
                : nil
            return (
                HostV6.Authorization(
                    sshIdentityID: authorization.serverID,
                    keyID: authorization.keyID,
                    fingerprint: authorization.fingerprint,
                    remoteComment: authorization.remoteComment,
                    remoteState: authorization.status == .authorized ? .authorized : .unknown,
                    relationState: isDetached ? .detached : .active,
                    authorizedAt: authorization.authorizedAt,
                    lastVerifiedAt: authorization.lastVerifiedAt,
                    stamp: stamp(
                        entityType: .authorization,
                        entityID: authorizationKey(authorization),
                        sources: [descriptor, identitySource.descriptor],
                        updatedAt: max(authorization.updatedAt, identitySource.server.updatedAt)
                    ),
                    deletedAt: deletedAt
                ),
                descriptor
            )
        }.sorted { $0.0.id < $1.0.id }

        let nodePairs = try snapshot.nodeAssociations.map {
            node -> (HostV6.NodeAssociation, LegacySourceDescriptor) in
            guard let identitySource = serverByID[node.serverID] else {
                throw projectionError("nodeIdentityMissing")
            }
            let descriptor = try nodeDescriptor(node)
            return (
                HostV6.NodeAssociation(
                    id: node.id,
                    sshIdentityID: node.serverID,
                    target: node.target,
                    state: node.state,
                    method: node.method,
                    autoLinkEnabled: node.autoLinkEnabled,
                    stamp: stamp(
                        entityType: .nodeAssociation,
                        entityID: node.id,
                        sources: [descriptor, identitySource.descriptor],
                        updatedAt: max(node.updatedAt, identitySource.server.updatedAt)
                    ),
                    deletedAt: identitySource.server.isDeleted ? identitySource.server.updatedAt : nil
                ),
                descriptor
            )
        }.sorted { $0.0.id < $1.0.id }

        let local = HostV6.LocalState(
            hostAnnotations: serverSources.map {
                HostV6.LocalHostAnnotation(hostID: $0.hostID, legacyIdentityID: $0.server.id, notes: $0.server.notes)
            }.sorted { $0.id < $1.id },
            identityStates: serverSources.map {
                HostV6.LocalSSHIdentityState(
                    sshIdentityID: $0.server.id,
                    status: $0.server.status,
                    statusDetail: $0.server.statusDetail,
                    lastCheckedAt: $0.server.lastCheckedAt,
                    passwordCheck: $0.server.passwordCheck,
                    keyCheck: $0.server.keyCheck,
                    machineConfigurationRefreshAttemptedAt: $0.server.machineConfigurationRefreshAttemptedAt
                )
            }.sorted { uuidOrder($0.id, $1.id) },
            deviceStates: snapshot.devices.map {
                HostV6.LocalDeviceState(deviceID: $0.id, isCurrent: $0.id == currentDeviceID)
            }.sorted { $0.id < $1.id },
            keyStates: snapshot.keys.map {
                HostV6.LocalSSHKeyState(
                    keyID: $0.id,
                    privateKeyPath: $0.privateKeyPath,
                    isInAgent: $0.isInAgent,
                    isLocallyAvailable: $0.isLocallyAvailable
                )
            }.sorted { $0.id < $1.id },
            auditEvents: snapshot.auditEvents.map(auditEvent)
        )

        var legacySources: [HostV6.LegacySourceRevision] = []
        for source in serverSources {
            var derived: [HostV6.EntityReference] = [
                .host(source.hostID),
                .address(source.addressID),
                .sshIdentity(source.server.id),
            ]
            let sourceLines = projectedLines.filter { $0.source.server.id == source.server.id }
            derived.append(contentsOf: Set(sourceLines.map(\.pinID)).map(HostV6.EntityReference.hostKeyPin))
            derived.append(contentsOf: sourceLines.map { .knownHostsLine($0.lineID) })
            legacySources.append(ledger(source.descriptor, derived: derived))
        }
        legacySources.append(contentsOf: devicePairs.flatMap { device, descriptors in
            descriptors.map { ledger($0, derived: [.device(device.id)]) }
        })
        legacySources.append(contentsOf: keyPairs.map { ledger($0.1, derived: [.sshKeyRecord($0.0.id)]) })
        legacySources.append(contentsOf: authorizationPairs.map {
            ledger($0.1, derived: [.authorization($0.0.id)])
        })
        legacySources.append(contentsOf: nodePairs.map {
            ledger($0.1, derived: [.nodeAssociation($0.0.id)])
        })

        return Result(
            graph: HostV6.SyncedGraph(
                hosts: hosts.sorted { uuidOrder($0.id, $1.id) },
                addresses: addresses.sorted { uuidOrder($0.id, $1.id) },
                identities: identities.sorted { uuidOrder($0.id, $1.id) },
                devices: devicePairs.map(\.0),
                sshKeys: keyPairs.map(\.0),
                hostKeyPins: hostKeyPins,
                knownHostsLines: knownHostsLines,
                authorizations: authorizationPairs.map(\.0),
                nodeAssociations: nodePairs.map(\.0),
                mergeReviews: uniqueReviews(reviews)
            ),
            local: local,
            legacySources: legacySources.sorted { $0.id < $1.id }
        )
    }

    private func serverSource(_ server: ServerConnection) throws -> LegacyServerSource {
        let port = try validPort(server.port)
        let legacyID = server.id.uuidString.lowercased()
        let endpointKey = HostV6.StableID.legacyEndpointKey(host: server.host, port: port)
        let hostID = HostV6.StableID.host(legacyEndpointKey: endpointKey)
        return LegacyServerSource(
            server: server,
            descriptor: LegacySourceDescriptor(
                ledgerID: "server/\(legacyID)",
                kind: "server",
                legacyID: legacyID,
                dimension: "legacy-v1/server/\(legacyID)",
                counter: UInt64(max(1, server.version)),
                digest: try digest(ServerDigest(server)),
                isDeleted: server.isDeleted,
                updatedAt: server.updatedAt
            ),
            hostID: hostID,
            addressID: HostV6.StableID.address(hostID: hostID, endpointKey: endpointKey)
        )
    }

    private func deviceDescriptors(_ device: Device) throws -> [LegacySourceDescriptor] {
        let milliseconds = floor(device.lastActiveAt.timeIntervalSince1970 * 1_000)
        let counter = milliseconds > 1 ? UInt64(milliseconds) : 1
        var result = [LegacySourceDescriptor(
            ledgerID: "device/\(device.id)",
            kind: "device",
            legacyID: device.id,
            dimension: "legacy-v1/device/\(device.id)",
            counter: counter,
            digest: try digest(DeviceDigest(device)),
            isDeleted: false,
            updatedAt: device.lastActiveAt
        )]
        if device.isRevoked {
            result.append(LegacySourceDescriptor(
                ledgerID: "device-revocation/\(device.id)",
                kind: "device-revocation",
                legacyID: device.id,
                dimension: "legacy-v1/device-revocation/\(device.id)",
                counter: 1,
                digest: try digest(DeviceRevocationDigest(id: device.id)),
                isDeleted: true,
                updatedAt: device.lastActiveAt
            ))
        }
        return result
    }

    private func keyDescriptor(_ key: SSHKeyRecord) throws -> LegacySourceDescriptor {
        LegacySourceDescriptor(
            ledgerID: "key/\(key.id)",
            kind: "key",
            legacyID: key.id,
            dimension: "legacy-v1/key/\(key.id)",
            counter: 1,
            digest: try digest(KeyDigest(key)),
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func authorizationDescriptor(_ value: Authorization) throws -> LegacySourceDescriptor {
        let legacyID = authorizationKey(value)
        return LegacySourceDescriptor(
            ledgerID: "authorization/\(legacyID)",
            kind: "authorization",
            legacyID: legacyID,
            dimension: "legacy-v1/authorization/\(legacyID)",
            counter: UInt64(max(1, value.version)),
            digest: try digest(AuthorizationDigest(value)),
            isDeleted: value.isDeleted,
            updatedAt: value.updatedAt
        )
    }

    private func nodeDescriptor(_ value: NodeAssociation) throws -> LegacySourceDescriptor {
        LegacySourceDescriptor(
            ledgerID: "node/\(value.id)",
            kind: "node",
            legacyID: value.id,
            dimension: "legacy-v1/node/\(value.id)",
            counter: UInt64(max(1, value.revision)),
            digest: try digest(NodeDigest(value)),
            isDeleted: false,
            updatedAt: value.updatedAt
        )
    }

    private func projectKnownHostsLines(_ source: LegacyServerSource) -> [ProjectedKnownHostsLine] {
        let groups = Dictionary(grouping: source.server.confirmedHostKeys) {
            "\($0.algorithm)\u{0}\($0.fingerprint)\u{0}\($0.knownHostsLine)"
        }
        return groups.keys.sorted().flatMap { key -> [ProjectedKnownHostsLine] in
            let values = groups[key]!.sorted {
                ($0.firstConfirmedAt ?? .distantPast, $0.lastSeenAt)
                    < ($1.firstConfirmedAt ?? .distantPast, $1.lastSeenAt)
            }
            return values.enumerated().map { index, value in
                let pinID = HostV6.StableID.hostKeyPin(
                    addressID: source.addressID,
                    algorithm: value.algorithm,
                    fingerprint: value.fingerprint
                )
                let ordinal = UInt32(index)
                return ProjectedKnownHostsLine(
                    source: source,
                    key: value,
                    pinID: pinID,
                    lineID: HostV6.StableID.knownHostsLine(
                        pinID: pinID,
                        sourceID: source.server.id,
                        rawLine: value.knownHostsLine,
                        duplicateOrdinal: ordinal
                    ),
                    duplicateOrdinal: ordinal
                )
            }
        }
    }
}

private struct DetailedMigrationReports {
    var idContinuity: HostV6.ShadowMigrationIDContinuityReport
    var references: HostV6.ShadowMigrationReferenceReport
    var keychain: HostV6.ShadowMigrationKeychainReport
    var ssh: HostV6.ShadowMigrationSSHReport
    var authorizations: HostV6.ShadowMigrationAuthorizationReport
    var causality: HostV6.ShadowMigrationCausalityReport
    var allowList: HostV6.ShadowMigrationAllowListReport
}

private func makeDetailedReports(
    legacy: AppSnapshot,
    envelope: HostV6.MetadataEnvelope,
    inspection: HostV6.ShadowMigrationInspection,
    ignoredStaleSourceIDs: Set<String>
) throws -> DetailedMigrationReports {
    let staleIdentityIDs = Set(ignoredStaleSourceIDs.compactMap { sourceID -> UUID? in
        guard sourceID.hasPrefix("server/") else { return nil }
        return UUID(uuidString: String(sourceID.dropFirst("server/".count)))
    })
    let aliasesBefore = Dictionary(uniqueKeysWithValues: legacy.servers.filter {
        !staleIdentityIDs.contains($0.id)
    }.map { ($0.id.uuidString.lowercased(), $0.alias) })
    let aliasesAfter = Dictionary(uniqueKeysWithValues: envelope.synced.identities.filter {
        !staleIdentityIDs.contains($0.id)
    }.map { ($0.id.uuidString.lowercased(), $0.alias) })

    let provenanceBefore = legacy.servers.filter {
        !staleIdentityIDs.contains($0.id)
    }.flatMap { server in
        server.confirmedHostKeys.map {
            provenanceKey(sourceID: server.id, rawLine: $0.knownHostsLine)
        }
    }.sorted()
    let provenanceAfter = envelope.synced.knownHostsLines.filter {
        !staleIdentityIDs.contains($0.source.id)
    }.map {
        provenanceKey(sourceID: $0.source.id, rawLine: $0.rawLine)
    }.sorted()
    let renderedBefore = Array(Set(legacy.servers.lazy.filter {
        !$0.isDeleted && !staleIdentityIDs.contains($0.id)
    }.flatMap(\.confirmedHostKeys).map(\.knownHostsLine))).sorted()
    let renderedAfter = Array(Set(envelope.synced.knownHostsLines.lazy.filter {
        $0.deletedAt == nil && !staleIdentityIDs.contains($0.source.id)
    }.map(\.rawLine))).sorted()

    let v6AuthorizationByKey = Dictionary(uniqueKeysWithValues: envelope.synced.authorizations.map {
        (authorizationKey(identityID: $0.sshIdentityID, fingerprint: $0.fingerprint), $0)
    })
    let legacyToV6 = Dictionary(uniqueKeysWithValues: legacy.authorizations.compactMap { value in
        let key = authorizationKey(value)
        return v6AuthorizationByKey[key].map { (key, $0.id) }
    })
    let cloudData = try HostV6.CanonicalJSON.encode(HostV6.CloudPayload(envelope: envelope))
    let archiveData = try HostV6.CanonicalJSON.encode(HostV6.ArchivePayload(envelope: envelope))
    let forbiddenMatchCounts = forbiddenMatches(
        legacy: legacy,
        cloudData: cloudData,
        archiveData: archiveData
    )

    return DetailedMigrationReports(
        idContinuity: HostV6.ShadowMigrationIDContinuityReport(
            legacyIdentityIDs: legacy.servers.map { $0.id.uuidString.lowercased() }.sorted(),
            v6IdentityIDs: envelope.synced.identities.map { $0.id.uuidString.lowercased() }.sorted(),
            legacyDeviceIDs: legacy.devices.map(\.id).sorted(),
            v6DeviceIDs: envelope.synced.devices.map(\.id).sorted(),
            legacyKeyIDs: legacy.keys.map(\.id).sorted(),
            v6KeyIDs: envelope.synced.sshKeys.map(\.id).sorted(),
            legacyNodeAssociationIDs: legacy.nodeAssociations.map(\.id).sorted(),
            v6NodeAssociationIDs: envelope.synced.nodeAssociations.map(\.id).sorted()
        ),
        references: HostV6.ShadowMigrationReferenceReport(
            violationCount: 0,
            keyToDevice: Dictionary(uniqueKeysWithValues: envelope.synced.sshKeys.map { ($0.id, $0.deviceID) }),
            authorizationToIdentity: Dictionary(uniqueKeysWithValues: envelope.synced.authorizations.map {
                ($0.id, $0.sshIdentityID.uuidString.lowercased())
            }),
            authorizationToKey: Dictionary(uniqueKeysWithValues: envelope.synced.authorizations.map {
                ($0.id, $0.keyID)
            }),
            nodeAssociationToIdentity: Dictionary(uniqueKeysWithValues: envelope.synced.nodeAssociations.map {
                ($0.id, $0.sshIdentityID.uuidString.lowercased())
            })
        ),
        keychain: HostV6.ShadowMigrationKeychainReport(
            accountsBefore: inspection.keychainAccountsBefore,
            accountsAfter: inspection.keychainAccountsAfter,
            queryAccountIDs: Array(Set(
                Array(inspection.keychainAccountsBefore.keys)
                    + Array(inspection.keychainAccountsAfter.keys)
            )).sorted(),
            writeCallCount: 0
        ),
        ssh: HostV6.ShadowMigrationSSHReport(
            aliasesBefore: aliasesBefore,
            aliasesAfter: aliasesAfter,
            provenanceCountBefore: provenanceBefore.count,
            provenanceCountAfter: provenanceAfter.count,
            provenanceSHA256Before: try hashStringArray(provenanceBefore),
            provenanceSHA256After: try hashStringArray(provenanceAfter),
            renderedKnownHostsLineCountBefore: renderedBefore.count,
            renderedKnownHostsLineCountAfter: renderedAfter.count,
            renderedKnownHostsSHA256Before: try hashStringArray(renderedBefore),
            renderedKnownHostsSHA256After: try hashStringArray(renderedAfter)
        ),
        authorizations: HostV6.ShadowMigrationAuthorizationReport(
            legacyToV6: legacyToV6,
            identityReferences: Dictionary(uniqueKeysWithValues: envelope.synced.authorizations.map {
                ($0.id, $0.sshIdentityID.uuidString.lowercased())
            }),
            keyReferences: Dictionary(uniqueKeysWithValues: envelope.synced.authorizations.map {
                ($0.id, $0.keyID)
            })
        ),
        causality: HostV6.ShadowMigrationCausalityReport(
            sourceVectors: Dictionary(uniqueKeysWithValues: envelope.migrationProvenance.legacySources.map {
                ($0.id, $0.stamp.vector)
            }),
            sourceDigests: Dictionary(uniqueKeysWithValues: envelope.migrationProvenance.legacySources.map {
                ($0.id, $0.digest)
            }),
            mergeReviewIDs: envelope.synced.mergeReviews.map(\.id).sorted(by: uuidOrder)
        ),
        allowList: HostV6.ShadowMigrationAllowListReport(
            cloudSHA256: HostV6.CanonicalJSON.sha256(cloudData),
            archiveSHA256: HostV6.CanonicalJSON.sha256(archiveData),
            cloudByteCount: cloudData.count,
            archiveByteCount: archiveData.count,
            cloudAuditEventCount: 0,
            archiveAuditEventCount: 0,
            forbiddenMatchCounts: forbiddenMatchCounts
        )
    )
}

private func forbiddenMatches(
    legacy: AppSnapshot,
    cloudData: Data,
    archiveData: Data
) -> [String: Int] {
    let encodedPayloads = [String(decoding: cloudData, as: UTF8.self), String(decoding: archiveData, as: UTF8.self)]
    let privatePaths = legacy.keys.compactMap(\.privateKeyPath).filter { !$0.isEmpty }
    let auditValues = legacy.auditEvents.map(\.result).filter { !$0.isEmpty }
    let localFieldNames = [
        "privateKeyPath", "isInAgent", "isLocallyAvailable", "isCurrent", "auditEvents",
        "reachabilityEvidence", "ssid", "bssid", "rawDiscoveryOutput",
    ]
    return [
        "privateKeyPathValue": matchCount(privatePaths, in: encodedPayloads),
        "auditEventValue": matchCount(auditValues, in: encodedPayloads),
        "localFieldName": matchCount(localFieldNames, in: encodedPayloads),
    ]
}

private func matchCount(_ needles: [String], in values: [String]) -> Int {
    needles.reduce(0) { count, needle in
        count + values.reduce(0) { $0 + occurrenceCount(of: needle, in: $1) }
    }
}

private func occurrenceCount(of needle: String, in value: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var search = value.startIndex..<value.endIndex
    while let range = value.range(of: needle, range: search) {
        count += 1
        search = range.upperBound..<value.endIndex
    }
    return count
}

private func hashStringArray(_ values: [String]) throws -> String {
    HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(values))
}

private struct ServerDigest: Codable {
    struct Key: Codable, Comparable {
        var algorithm: String
        var fingerprint: String
        var knownHostsLine: String
        var firstConfirmedAt: Date?
        var lastSeenAt: Date

        static func < (left: Self, right: Self) -> Bool {
            (
                left.algorithm,
                left.fingerprint,
                left.knownHostsLine,
                left.firstConfirmedAt ?? .distantPast,
                left.lastSeenAt
            ) < (
                right.algorithm,
                right.fingerprint,
                right.knownHostsLine,
                right.firstConfirmedAt ?? .distantPast,
                right.lastSeenAt
            )
        }
    }

    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var alias: String
    var group: String
    var confirmedHostKeys: [Key]
    var machineConfiguration: RemoteMachineConfiguration?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ value: ServerConnection) {
        id = value.id
        name = value.name
        host = value.host
        port = value.port
        username = value.username
        alias = value.alias
        group = value.group
        confirmedHostKeys = value.confirmedHostKeys.map {
            Key(
                algorithm: $0.algorithm,
                fingerprint: $0.fingerprint,
                knownHostsLine: $0.knownHostsLine,
                firstConfirmedAt: $0.firstConfirmedAt,
                lastSeenAt: $0.lastSeenAt
            )
        }.sorted()
        machineConfiguration = value.machineConfiguration
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        isDeleted = value.isDeleted
    }
}

private struct DeviceDigest: Codable {
    var id: String
    var name: String
    var registeredAt: Date
    var lastActiveAt: Date
    var tailscaleIdentity: TailscaleDeviceIdentity?

    init(_ value: Device) {
        id = value.id
        name = value.name
        registeredAt = value.registeredAt
        lastActiveAt = value.lastActiveAt
        tailscaleIdentity = value.tailscaleIdentity
    }
}

private struct DeviceRevocationDigest: Codable {
    var id: String
}

private struct KeyDigest: Codable {
    var id: String
    var deviceID: String
    var kind: SSHKeyKind
    var publicKey: String
    var fingerprint: String
    var origin: SSHKeyOrigin

    init(_ value: SSHKeyRecord) {
        id = value.id
        deviceID = value.deviceID
        kind = value.kind
        publicKey = value.publicKey
        fingerprint = value.fingerprint
        origin = value.origin
    }
}

private struct AuthorizationDigest: Codable {
    var serverID: UUID
    var keyID: String
    var fingerprint: String
    var remoteComment: String
    var status: AuthorizationStatus
    var authorizedAt: Date?
    var lastVerifiedAt: Date?
    var updatedAt: Date
    var isDeleted: Bool

    init(_ value: Authorization) {
        serverID = value.serverID
        keyID = value.keyID
        fingerprint = value.fingerprint
        remoteComment = value.remoteComment
        status = value.status
        authorizedAt = value.authorizedAt
        lastVerifiedAt = value.lastVerifiedAt
        updatedAt = value.updatedAt
        isDeleted = value.isDeleted
    }
}

private struct NodeDigest: Codable {
    var id: String
    var serverID: UUID
    var target: ActualNodeReference?
    var state: NodeAssociationState
    var method: NodeAssociationMethod?
    var autoLinkEnabled: Bool
    var evidenceKinds: [NodeAssociationEvidence]
    var reasonCodes: [NodeAssociationReason]
    var confirmedAt: Date?
    var lastVerifiedAt: Date?
    var updatedAt: Date

    init(_ value: NodeAssociation) {
        id = value.id
        serverID = value.serverID
        target = value.target
        state = value.state
        method = value.method
        autoLinkEnabled = value.autoLinkEnabled
        evidenceKinds = value.evidenceKinds.sorted { $0.rawValue < $1.rawValue }
        reasonCodes = value.reasonCodes.sorted { $0.rawValue < $1.rawValue }
        confirmedAt = value.confirmedAt
        lastVerifiedAt = value.lastVerifiedAt
        updatedAt = value.updatedAt
    }
}

private let shadowMigrationNamespace = UUID(uuidString: "67f546cb-e48d-5d91-a993-4a8896c0b51f")!

private func stamp(
    entityType: HostV6.EntityType,
    entityID: String,
    sources: [LegacySourceDescriptor],
    updatedAt: Date
) -> HostV6.SyncStamp {
    let sources = uniqueDescriptors(sources)
    let vector = Dictionary(uniqueKeysWithValues: sources.map { ($0.dimension, $0.counter) })
    let sourceKey = sources.map { "\($0.dimension):\($0.counter):\($0.digest)" }.joined(separator: "|")
    let mutationID = HostV6.StableID.uuidV5(
        namespace: shadowMigrationNamespace,
        name: "migration|\(entityType.rawValue)|\(entityID)|\(sourceKey)"
    )
    return HostV6.SyncStamp(vector: vector, mutationID: mutationID, updatedAt: updatedAt)
}

private func uniqueDescriptors(_ values: [LegacySourceDescriptor]) -> [LegacySourceDescriptor] {
    var byDimension: [String: LegacySourceDescriptor] = [:]
    for value in values {
        if let existing = byDimension[value.dimension], existing.counter > value.counter { continue }
        byDimension[value.dimension] = value
    }
    return byDimension.values.sorted { $0.dimension < $1.dimension }
}

private func ledger(
    _ source: LegacySourceDescriptor,
    derived: [HostV6.EntityReference]
) -> HostV6.LegacySourceRevision {
    let sortedDerived = Array(Set(derived)).sorted {
        ($0.entityType.rawValue, $0.stableID) < ($1.entityType.rawValue, $1.stableID)
    }
    return HostV6.LegacySourceRevision(
        id: source.ledgerID,
        legacyKind: source.kind,
        legacyID: source.legacyID,
        revision: source.counter,
        digest: source.digest,
        sourceDeleted: source.isDeleted,
        derivedEntityIDs: sortedDerived,
        stamp: stamp(
            entityType: .legacySourceRevision,
            entityID: source.ledgerID,
            sources: [source],
            updatedAt: source.updatedAt
        )
    )
}

private func sharedReview<Entity: HostV6SyncedEntity>(
    candidates: [Entity],
    isBlocking: ([String: String], [String: String]) -> Bool
) -> HostV6.MergeReview? {
    guard let first = candidates.first else { return nil }
    let fields = candidates.map(\.mergeCandidateFields)
    guard fields.dropFirst().contains(where: { $0 != fields[0] }) else { return nil }
    let mergeCandidates = candidates.map {
        HostV6.MergeCandidate(
            mutationID: $0.stamp.mutationID,
            vector: $0.stamp.vector,
            isDeleted: $0.deletedAt != nil,
            summaryFields: $0.mergeCandidateFields
        )
    }
    let reviewID = HostV6.StableID.mergeReview(
        entityType: first.entityReference.entityType,
        entityID: first.entityReference.stableID,
        conflictingMutationIDs: mergeCandidates.map(\.mutationID)
    )
    let vector = candidates.reduce(into: [String: UInt64]()) { result, candidate in
        result = HostV6.SyncStamp.join(result, candidate.stamp.vector)
    }
    return HostV6.MergeReview(
        id: reviewID,
        entityType: first.entityReference.entityType,
        entityID: first.entityReference.stableID,
        candidates: mergeCandidates,
        isBlocking: fields.dropFirst().contains { isBlocking(fields[0], $0) },
        stamp: HostV6.SyncStamp(
            vector: vector,
            mutationID: reviewID,
            updatedAt: candidates.map(\.stamp.updatedAt).max() ?? first.stamp.updatedAt
        )
    )
}

private struct PinConflictKey: Hashable {
    var addressID: UUID
    var algorithm: String
}

private func appendPinConflictReviews(
    pins: inout [HostV6.HostKeyPin],
    reviews: inout [HostV6.MergeReview]
) {
    let candidateIndices = pins.indices.filter {
        pins[$0].deletedAt == nil && pins[$0].state != .replaced
    }
    let groups = Dictionary(grouping: candidateIndices) { index in
        PinConflictKey(addressID: pins[index].addressID, algorithm: pins[index].algorithm.lowercased())
    }
    for indices in groups.values {
        guard Set(indices.map { pins[$0].fingerprint }).count > 1 else { continue }
        for index in indices {
            pins[index].state = .pendingReview
        }
        let candidates = indices.map { pins[$0] }.sorted(by: { uuidOrder($0.id, $1.id) })
        if let review = sharedReview(candidates: candidates, isBlocking: { _, _ in true }) {
            reviews.append(review)
        }
    }
}

private func hostConflictIsBlocking(_ left: [String: String], _ right: [String: String]) -> Bool {
    let keys = Set(left.keys).union(right.keys)
    let changed = Set(keys.filter { left[$0] != right[$0] })
    return !changed.isSubset(of: ["name", "group"])
}

private func uniqueReviews(_ values: [HostV6.MergeReview]) -> [HostV6.MergeReview] {
    Dictionary(grouping: values, by: \.id)
        .compactMap { $0.value.first }
        .sorted { uuidOrder($0.id, $1.id) }
}

private func mergeEntities<Entity: HostV6SyncedEntity>(
    _ previous: [Entity],
    _ projected: [Entity],
    reviews: inout [HostV6.MergeReview],
    sortedBy areInIncreasingOrder: (Entity, Entity) -> Bool
) -> [Entity] where Entity.ID: Hashable {
    var result = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    for candidate in projected {
        if let existing = result[candidate.id] {
            let outcome = HostV6.MergeEngine.merge(existing, candidate)
            result[candidate.id] = outcome.selected
            if let review = outcome.review {
                reviews.append(review)
            }
        } else {
            result[candidate.id] = candidate
        }
    }
    return result.values.sorted(by: areInIncreasingOrder)
}

private func coalescedReviews(_ values: [HostV6.MergeReview]) -> [HostV6.MergeReview] {
    Dictionary(grouping: values, by: \.id).compactMap { _, candidates in
        candidates.sorted { left, right in
            if left.isResolved != right.isResolved { return left.isResolved }
            switch left.stamp.compared(to: right.stamp) {
            case .after: return true
            case .before: return false
            case .equal, .concurrent:
                return left.stamp.mutationID.uuidString < right.stamp.mutationID.uuidString
            }
        }.first
    }.sorted { uuidOrder($0.id, $1.id) }
}

private func mergeLocalState(
    previous: HostV6.LocalState,
    projected: HostV6.LocalState,
    previousSources: [HostV6.LegacySourceRevision],
    staleSourceIDs: Set<String>
) -> HostV6.LocalState {
    var hostAnnotations = Dictionary(uniqueKeysWithValues: projected.hostAnnotations.map {
        ($0.legacyIdentityID, $0)
    })
    var identityStates = Dictionary(uniqueKeysWithValues: projected.identityStates.map { ($0.id, $0) })
    var deviceStates = Dictionary(uniqueKeysWithValues: projected.deviceStates.map { ($0.id, $0) })
    var keyStates = Dictionary(uniqueKeysWithValues: projected.keyStates.map { ($0.id, $0) })
    let sources = Dictionary(uniqueKeysWithValues: previousSources.map { ($0.id, $0) })

    for sourceID in staleSourceIDs {
        guard let source = sources[sourceID] else { continue }
        switch source.legacyKind {
        case "server":
            guard let id = UUID(uuidString: source.legacyID) else { continue }
            if let value = previous.hostAnnotations.first(where: { $0.legacyIdentityID == id }) {
                hostAnnotations[id] = value
            }
            if let value = previous.identityStates.first(where: { $0.id == id }) {
                identityStates[id] = value
            }
        case "device":
            if let value = previous.deviceStates.first(where: { $0.id == source.legacyID }) {
                deviceStates[source.legacyID] = value
            }
        case "key":
            if let value = previous.keyStates.first(where: { $0.id == source.legacyID }) {
                keyStates[source.legacyID] = value
            }
        default:
            continue
        }
    }

    return HostV6.LocalState(
        hostAnnotations: hostAnnotations.values.sorted { $0.id < $1.id },
        identityStates: identityStates.values.sorted { uuidOrder($0.id, $1.id) },
        deviceStates: deviceStates.values.sorted { $0.id < $1.id },
        keyStates: keyStates.values.sorted { $0.id < $1.id },
        reachabilityEvidence: previous.reachabilityEvidence,
        auditEvents: staleSourceIDs.isEmpty ? projected.auditEvents : previous.auditEvents
    )
}

private func normalizedHost(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while result.hasSuffix(".") { result.removeLast() }
    return result
}

private func validPort(_ value: Int) throws -> UInt16 {
    guard let port = UInt16(exactly: value), port > 0 else {
        throw projectionError("invalidSSHPort")
    }
    return port
}

private func digest<T: Encodable>(_ value: T) throws -> String {
    HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(value))
}

private func uuidOrder(_ left: UUID, _ right: UUID) -> Bool {
    left.uuidString < right.uuidString
}

private func authorizationKey(_ value: Authorization) -> String {
    authorizationKey(identityID: value.serverID, fingerprint: value.fingerprint)
}

private func authorizationKey(identityID: UUID, fingerprint: String) -> String {
    "\(identityID.uuidString.lowercased()):\(fingerprint)"
}

private func auditEvent(_ value: AuditEvent) -> HostV6.AuditEvent {
    HostV6.AuditEvent(
        id: value.id,
        timestamp: value.timestamp,
        category: value.category,
        action: value.action,
        targetID: value.targetID,
        result: value.result,
        level: HostV6.AuditEvent.Level(rawValue: value.level.rawValue)!
    )
}

private func provenanceKey(sourceID: UUID, rawLine: String) -> String {
    "\(sourceID.uuidString.lowercased())|\(HostV6.CanonicalJSON.sha256(Data(rawLine.utf8)))|\(rawLine)"
}

private func migrationError(
    _ code: OperationFailureCode,
    objectID: String,
    detail: String
) -> HostV6.ShadowMigrationError {
    HostV6.ShadowMigrationError(
        failure: StableOperationFailure(
            stage: .migration,
            objectID: objectID,
            code: code,
            recoveryAction: code == .artifactMismatch ? .reload : .resolveConflict
        ),
        detailCode: detail
    )
}

private func projectionError(_ detail: String) -> HostV6.ShadowMigrationError {
    migrationError(.invariantFailed, objectID: "legacy-projection", detail: detail)
}
