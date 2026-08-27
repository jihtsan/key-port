import Foundation

public extension HostV6 {
    /// Read-only view model for the Host workbench. It deliberately keeps
    /// reachability, SSH trust, and the last access mode as separate values.
    struct HostWorkbenchProjection: Hashable, Sendable {
        public enum FixedAddressOwner: String, Codable, CaseIterable, Hashable, Sendable {
            case service
            case identity
            case host
        }

        public enum FixedAddressResolution: Hashable, Sendable {
            case none
            case selected(addressID: UUID, owner: FixedAddressOwner)
            case invalid(owner: FixedAddressOwner)
        }

        public enum SSHTrustState: String, Codable, CaseIterable, Hashable, Sendable {
            case pending
            case confirmed
            case changed

            public static let unknown = Self.pending
            public static let unconfirmed = Self.pending
        }

        public struct Axes: Hashable, Sendable {
            public var reachability: ReachabilityState
            public var sshTrust: SSHTrustState
            public var accessMode: AccessMode

            public init(
                reachability: ReachabilityState,
                sshTrust: SSHTrustState,
                accessMode: AccessMode
            ) {
                self.reachability = reachability
                self.sshTrust = sshTrust
                self.accessMode = accessMode
            }
        }

        public struct AddressRow: Identifiable, Hashable, Sendable {
            public let address: AccessAddress
            public let reachability: ReachabilityState
            public let evidence: ReachabilityEvidence?

            public var id: UUID { address.id }
            public var isFixedCandidate: Bool { false }

            public init(
                address: AccessAddress,
                reachability: ReachabilityState,
                evidence: ReachabilityEvidence?
            ) {
                self.address = address
                self.reachability = reachability
                self.evidence = evidence
            }
        }

        public struct Row: Identifiable, Hashable, Sendable {
            public let host: Host
            public let addresses: [AddressRow]
            public let identities: [SSHIdentity]
            public let services: [SavedService]
            public let axes: Axes
            public let recentRecords: [ConnectionRecord]

            public var id: UUID { host.id }
            public var identityCount: Int { identities.count }
            public var addressCount: Int { addresses.count }
            public var serviceCount: Int { services.count }

            public init(
                host: Host,
                addresses: [AddressRow],
                identities: [SSHIdentity],
                services: [SavedService],
                axes: Axes,
                recentRecords: [ConnectionRecord] = []
            ) {
                self.host = host
                self.addresses = addresses
                self.identities = identities
                self.services = services
                self.axes = axes
                self.recentRecords = recentRecords
            }
        }

        public let rows: [Row]
        public let aggregates: [UUID: HostAggregate]

        public init(rows: [Row], aggregates: [UUID: HostAggregate]) {
            self.rows = rows
            self.aggregates = aggregates
        }

        /// Builds one row per active Host. No account-level grouping is used;
        /// multiple identities remain children of the same Host aggregate.
        public static func make(
            from envelope: MetadataEnvelope,
            currentNetworkEpoch: UInt64,
            history: [ConnectionRecord] = []
        ) -> Self {
            let graph = envelope.synced
            let activeHosts = graph.hosts
                .filter { $0.deletedAt == nil }
                .sorted { hostOrder($0, $1) }

            var aggregates: [UUID: HostAggregate] = [:]
            var rows: [Row] = []
            rows.reserveCapacity(activeHosts.count)

            let evidenceByAddress = latestEvidenceByAddress(envelope.local.reachabilityEvidence)
            let recordsByHost = Dictionary(grouping: history, by: \.hostID)

            for host in activeHosts {
                guard let aggregate = activeAggregate(for: host, graph: graph) else { continue }
                let addressRows = aggregate.addresses
                    .sorted { addressOrder($0, $1) }
                    .map { address in
                        let evidence = evidenceByAddress[address.id]
                        return AddressRow(
                            address: address,
                            reachability: reachability(for: evidence, currentEpoch: currentNetworkEpoch),
                            evidence: evidence
                        )
                    }
                let hostRecords = (recordsByHost[host.id] ?? []).sorted(by: recordOrder)
                let axes = Axes(
                    reachability: aggregateReachability(addressRows.map(\.reachability)),
                    sshTrust: trustState(for: aggregate, graph: graph),
                    accessMode: hostRecords.first(where: { $0.accessMode != nil })?.accessMode ?? .unavailable
                )
                let row = Row(
                    host: aggregate.host,
                    addresses: addressRows,
                    identities: aggregate.identities.sorted { identityOrder($0, $1) },
                    services: aggregate.services.sorted { serviceOrder($0, $1) },
                    axes: axes,
                    recentRecords: hostRecords
                )
                aggregates[host.id] = aggregate
                rows.append(row)
            }

            return Self(rows: rows, aggregates: aggregates)
        }

        /// Resolves the fixed address before any reachability probe. A present
        /// but invalid reference is terminal at its priority level; lower
        /// priority references are intentionally never consulted.
        public static func resolveFixedAddress(
            in aggregate: HostAggregate,
            identityID: UUID? = nil,
            serviceID: UUID? = nil
        ) -> FixedAddressResolution {
            if let serviceID {
                guard let service = aggregate.services.first(where: { $0.id == serviceID && $0.deletedAt == nil }) else {
                    return .invalid(owner: .service)
                }
                if let addressID = service.fixedAddressID {
                    return resolve(
                        addressID: addressID,
                        owner: .service,
                        aggregate: aggregate
                    )
                }
            }

            if let identityID {
                guard let identity = aggregate.identities.first(where: { $0.id == identityID && $0.deletedAt == nil }) else {
                    return .invalid(owner: .identity)
                }
                if let addressID = identity.preferredAddressID {
                    return resolve(
                        addressID: addressID,
                        owner: .identity,
                        aggregate: aggregate
                    )
                }
            }

            if let addressID = aggregate.host.fixedAddressID {
                return resolve(
                    addressID: addressID,
                    owner: .host,
                    aggregate: aggregate
                )
            }
            return .none
        }

        private static func resolve(
            addressID: UUID,
            owner: FixedAddressOwner,
            aggregate: HostAggregate
        ) -> FixedAddressResolution {
            guard let address = aggregate.addresses.first(where: {
                $0.id == addressID
                    && $0.hostID == aggregate.host.id
                    && $0.deletedAt == nil
                    && $0.sshPort > 0
            }) else {
                return .invalid(owner: owner)
            }
            return .selected(addressID: address.id, owner: owner)
        }

        private static func activeAggregate(
            for host: Host,
            graph: SyncedGraph
        ) -> HostAggregate? {
            guard let aggregate = graph.aggregate(hostID: host.id) else { return nil }
            return HostAggregate(
                host: aggregate.host,
                addresses: aggregate.addresses.filter { $0.deletedAt == nil },
                identities: aggregate.identities.filter { $0.deletedAt == nil },
                pins: aggregate.pins.filter { $0.deletedAt == nil },
                knownHostsLines: aggregate.knownHostsLines.filter { $0.deletedAt == nil },
                services: aggregate.services.filter { $0.deletedAt == nil },
                authorizations: aggregate.authorizations.filter { $0.deletedAt == nil },
                nodeAssociations: aggregate.nodeAssociations.filter { $0.deletedAt == nil }
            )
        }

        private static func latestEvidenceByAddress(
            _ evidence: [ReachabilityEvidence]
        ) -> [UUID: ReachabilityEvidence] {
            evidence.reduce(into: [:]) { result, candidate in
                guard let current = result[candidate.addressID] else {
                    result[candidate.addressID] = candidate
                    return
                }
                if evidenceOrder(candidate, current) {
                    result[candidate.addressID] = candidate
                }
            }
        }

        private static func reachability(
            for evidence: ReachabilityEvidence?,
            currentEpoch: UInt64
        ) -> ReachabilityState {
            guard let evidence else { return .unknown }
            guard evidence.networkEpoch == currentEpoch else { return .stale }
            return evidence.wasReachable ? .reachable : .unreachable
        }

        private static func aggregateReachability(_ states: [ReachabilityState]) -> ReachabilityState {
            if states.contains(.reachable) { return .reachable }
            if states.contains(.unreachable) { return .unreachable }
            if states.contains(.stale) { return .stale }
            return .unknown
        }

        private static func trustState(
            for aggregate: HostAggregate,
            graph: SyncedGraph
        ) -> SSHTrustState {
            let pins = aggregate.pins.filter { $0.deletedAt == nil }
            if pins.contains(where: { $0.state == .pendingReview })
                || hasBlockingReview(for: aggregate.host.id, graph: graph) {
                return .changed
            }
            if pins.contains(where: { $0.state == .confirmed }) {
                return .confirmed
            }
            if pins.contains(where: { $0.state == .replaced }) {
                return .changed
            }
            return .pending
        }

        private static func hasBlockingReview(for hostID: UUID, graph: SyncedGraph) -> Bool {
            graph.mergeReviews.contains { review in
                guard review.deletedAt == nil, review.isBlocking, !review.isResolved else { return false }
                return owningHostID(of: review, graph: graph) == hostID
            }
        }

        private static func owningHostID(of review: MergeReview, graph: SyncedGraph) -> UUID? {
            switch review.entityType {
            case .authorization:
                guard let authorization = graph.authorizations.first(where: { $0.id == review.entityID }) else {
                    return nil
                }
                return graph.identities.first { identity in
                    identity.id == authorization.sshIdentityID
                }?.hostID
            case .nodeAssociation:
                guard let association = graph.nodeAssociations.first(where: { $0.id == review.entityID }) else {
                    return nil
                }
                return graph.identities.first { identity in
                    identity.id == association.sshIdentityID
                }?.hostID
            case .device, .sshKeyRecord, .mergeReview, .legacySourceRevision, .auditEvent:
                return nil
            default:
                break
            }

            guard let identifier = UUID(uuidString: review.entityID) else { return nil }
            switch review.entityType {
            case .host:
                return identifier
            case .address:
                return graph.addresses.first { $0.id == identifier }?.hostID
            case .sshIdentity:
                return graph.identities.first { $0.id == identifier }?.hostID
            case .hostKeyPin:
                return graph.hostKeyPins.first { $0.id == identifier }?.hostID
            case .knownHostsLine:
                guard let line = graph.knownHostsLines.first(where: { $0.id == identifier }) else { return nil }
                return graph.hostKeyPins.first { $0.id == line.pinID }?.hostID
            case .service:
                return graph.services.first { $0.id == identifier }?.hostID
            case .device, .sshKeyRecord, .authorization, .nodeAssociation,
                 .mergeReview, .legacySourceRevision, .auditEvent:
                return nil
            }
        }

        private static func hostOrder(_ lhs: Host, _ rhs: Host) -> Bool {
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        private static func addressOrder(_ lhs: AccessAddress, _ rhs: AccessAddress) -> Bool {
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let hostOrder = lhs.normalizedHost.localizedCaseInsensitiveCompare(rhs.normalizedHost)
            if hostOrder != .orderedSame { return hostOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        private static func identityOrder(_ lhs: SSHIdentity, _ rhs: SSHIdentity) -> Bool {
            let aliasOrder = lhs.alias.localizedCaseInsensitiveCompare(rhs.alias)
            if aliasOrder != .orderedSame { return aliasOrder == .orderedAscending }
            let usernameOrder = lhs.username.localizedCaseInsensitiveCompare(rhs.username)
            if usernameOrder != .orderedSame { return usernameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        private static func serviceOrder(_ lhs: SavedService, _ rhs: SavedService) -> Bool {
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        private static func evidenceOrder(_ lhs: ReachabilityEvidence, _ rhs: ReachabilityEvidence) -> Bool {
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
            if lhs.networkEpoch != rhs.networkEpoch { return lhs.networkEpoch > rhs.networkEpoch }
            return lhs.wasReachable && !rhs.wasReachable
        }

        private static func recordOrder(_ lhs: ConnectionRecord, _ rhs: ConnectionRecord) -> Bool {
            if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }
}
