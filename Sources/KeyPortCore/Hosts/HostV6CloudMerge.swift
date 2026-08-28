import Foundation

public extension HostV6 {
    enum CloudGraphMergeEngine {
        public static func merge(
            local: MetadataEnvelope,
            remote: CloudPayload
        ) throws -> MetadataEnvelope {
            guard local.schemaVersion == 6, remote.schemaVersion == 6 else {
                throw CloudV2Error.failure(.decodeFailed)
            }
            guard local.validate(existingSSHHostAliases: []).isEmpty,
                  remote.synced.validate(existingSSHHostAliases: []).isEmpty else {
                throw CloudV2Error.failure(.invariantFailed)
            }

            var createdReviews: [MergeReview] = []
            var graph = SyncedGraph(
                hosts: mergeEntities(local.synced.hosts, remote.synced.hosts, reviews: &createdReviews) {
                    $0.id.uuidString < $1.id.uuidString
                },
                addresses: mergeEntities(local.synced.addresses, remote.synced.addresses, reviews: &createdReviews) {
                    $0.id.uuidString < $1.id.uuidString
                },
                identities: mergeEntities(local.synced.identities, remote.synced.identities, reviews: &createdReviews) {
                    $0.id.uuidString < $1.id.uuidString
                },
                devices: mergeEntities(local.synced.devices, remote.synced.devices, reviews: &createdReviews) {
                    $0.id < $1.id
                },
                sshKeys: mergeEntities(local.synced.sshKeys, remote.synced.sshKeys, reviews: &createdReviews) {
                    $0.id < $1.id
                },
                hostKeyPins: mergeEntities(local.synced.hostKeyPins, remote.synced.hostKeyPins, reviews: &createdReviews) {
                    $0.id.uuidString < $1.id.uuidString
                },
                knownHostsLines: mergeEntities(
                    local.synced.knownHostsLines,
                    remote.synced.knownHostsLines,
                    reviews: &createdReviews
                ) {
                    $0.id.uuidString < $1.id.uuidString
                },
                services: mergeEntities(local.synced.services, remote.synced.services, reviews: &createdReviews) {
                    $0.id.uuidString < $1.id.uuidString
                },
                authorizations: mergeEntities(
                    local.synced.authorizations,
                    remote.synced.authorizations,
                    reviews: &createdReviews
                ) {
                    $0.id < $1.id
                },
                nodeAssociations: mergeEntities(
                    local.synced.nodeAssociations,
                    remote.synced.nodeAssociations,
                    reviews: &createdReviews
                ) {
                    $0.id < $1.id
                },
                mergeReviews: []
            )

            var nestedReviews: [MergeReview] = []
            let carriedReviews = mergeEntities(
                local.synced.mergeReviews,
                remote.synced.mergeReviews,
                reviews: &nestedReviews
            ) {
                $0.id.uuidString < $1.id.uuidString
            }
            graph.mergeReviews = coalesceReviews(carriedReviews + createdReviews + nestedReviews)

            var provenanceReviews: [MergeReview] = []
            let legacySources = mergeEntities(
                local.migrationProvenance.legacySources,
                remote.migrationProvenance.legacySources,
                reviews: &provenanceReviews
            ) {
                $0.id < $1.id
            }
            graph.mergeReviews = coalesceReviews(graph.mergeReviews + provenanceReviews)

            let envelope = MetadataEnvelope(
                schemaVersion: 6,
                synced: graph,
                local: local.local,
                migrationProvenance: MigrationProvenance(
                    legacySources: legacySources,
                    authorityManifest: try mergeManifest(
                        local.migrationProvenance.authorityManifest,
                        remote.migrationProvenance.authorityManifest
                    )
                )
            )
            guard envelope.validate(existingSSHHostAliases: []).isEmpty else {
                throw CloudV2Error.failure(.invariantFailed)
            }
            return envelope
        }

        private static func mergeEntities<Entity: HostV6SyncedEntity>(
            _ local: [Entity],
            _ remote: [Entity],
            reviews: inout [MergeReview],
            sortedBy: (Entity, Entity) -> Bool
        ) -> [Entity] where Entity.ID: Hashable {
            var values = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
            for candidate in remote {
                guard let existing = values[candidate.id] else {
                    values[candidate.id] = candidate
                    continue
                }
                let outcome = MergeEngine.merge(existing, candidate)
                values[candidate.id] = outcome.selected
                if let review = outcome.review {
                    reviews.append(review)
                }
            }
            return values.values.sorted(by: sortedBy)
        }

        private static func coalesceReviews(_ values: [MergeReview]) -> [MergeReview] {
            var reviews: [UUID: MergeReview] = [:]
            for candidate in values.sorted(by: reviewOrder) {
                guard let existing = reviews[candidate.id] else {
                    reviews[candidate.id] = candidate
                    continue
                }
                reviews[candidate.id] = MergeEngine.merge(existing, candidate).selected
            }
            return reviews.values.sorted(by: reviewOrder)
        }

        private static func reviewOrder(_ left: MergeReview, _ right: MergeReview) -> Bool {
            left.id.uuidString < right.id.uuidString
        }

        private static func mergeManifest(
            _ local: AuthorityManifest?,
            _ remote: AuthorityManifest?
        ) throws -> AuthorityManifest? {
            guard let local else { return remote }
            guard let remote else { return local }
            guard local.v1Hash == remote.v1Hash,
                  local.mode == remote.mode else {
                throw CloudV2Error.failure(.authorityGateFailed)
            }

            var merged = manifestOrder(local) < manifestOrder(remote) ? remote : local
            merged.acknowledgedDeviceIDs = Array(
                Set(local.acknowledgedDeviceIDs).union(remote.acknowledgedDeviceIDs)
            ).sorted()
            merged.firstV6MutationID = [local.firstV6MutationID, remote.firstV6MutationID]
                .compactMap { $0 }
                .min { $0.uuidString < $1.uuidString }
            merged.notRepresentable = Array(Set(local.notRepresentable).union(remote.notRepresentable))
                .sorted { entityOrder($0) < entityOrder($1) }
            return merged
        }

        private static func manifestOrder(_ manifest: AuthorityManifest) -> String {
            [
                manifest.checkpointHash,
                manifest.v6Hash,
                manifest.compatibilityHash,
                manifest.codeVersion,
                manifest.cloudChangeTag ?? "",
            ].joined(separator: "|")
        }
    }
}

private func entityOrder(_ value: HostV6.EntityReference) -> String {
    "\(value.entityType.rawValue)|\(value.stableID)"
}
