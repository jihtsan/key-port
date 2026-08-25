import Foundation

public enum HostV6 {}

public protocol HostV6SyncedEntity: Identifiable, Codable, Hashable, Sendable {
    var stamp: HostV6.SyncStamp { get set }
    var deletedAt: Date? { get set }
    var entityReference: HostV6.EntityReference { get }
    var mergeCandidateFields: [String: String] { get }
}

public extension HostV6 {
    enum VersionRelation: String, Codable, Hashable, Sendable {
        case before
        case equal
        case after
        case concurrent
    }

    enum VectorClockError: Error, Equatable, Sendable {
        case counterOverflow(String)
    }

    struct SyncStamp: Codable, Hashable, Sendable {
        public var vector: [String: UInt64]
        public var mutationID: UUID
        public var updatedAt: Date

        public init(vector: [String: UInt64], mutationID: UUID, updatedAt: Date) {
            self.vector = vector
            self.mutationID = mutationID
            self.updatedAt = updatedAt
        }

        public func compared(to other: Self) -> VersionRelation {
            let dimensions = Set(vector.keys).union(other.vector.keys)
            var isBefore = false
            var isAfter = false
            for dimension in dimensions {
                let left = vector[dimension, default: 0]
                let right = other.vector[dimension, default: 0]
                isBefore = isBefore || left < right
                isAfter = isAfter || left > right
            }
            switch (isBefore, isAfter) {
            case (false, false): return .equal
            case (true, false): return .before
            case (false, true): return .after
            case (true, true): return .concurrent
            }
        }

        public func joined(with other: Self) -> [String: UInt64] {
            Self.join(vector, other.vector)
        }

        public static func join(
            _ left: [String: UInt64],
            _ right: [String: UInt64]
        ) -> [String: UInt64] {
            var result = left
            for (dimension, counter) in right {
                result[dimension] = max(result[dimension, default: 0], counter)
            }
            return result
        }

        public func incrementing(
            deviceID: String,
            mutationID: UUID,
            at date: Date
        ) throws -> Self {
            let dimension = deviceID.hasPrefix("device/") ? deviceID : "device/\(deviceID)"
            let current = vector[dimension, default: 0]
            guard current < UInt64.max else {
                throw VectorClockError.counterOverflow(dimension)
            }
            var nextVector = vector
            nextVector[dimension] = current + 1
            return Self(vector: nextVector, mutationID: mutationID, updatedAt: date)
        }
    }

    enum EntityType: String, Codable, CaseIterable, Hashable, Sendable {
        case host
        case address
        case sshIdentity
        case device
        case sshKeyRecord
        case hostKeyPin
        case knownHostsLine
        case service
        case authorization
        case nodeAssociation
        case mergeReview
        case legacySourceRevision
        case auditEvent
    }

    enum EntityReference: Codable, Hashable, Sendable {
        case host(UUID)
        case address(UUID)
        case sshIdentity(UUID)
        case device(String)
        case sshKeyRecord(String)
        case hostKeyPin(UUID)
        case knownHostsLine(UUID)
        case service(UUID)
        case authorization(String)
        case nodeAssociation(String)
        case mergeReview(UUID)
        case legacySourceRevision(String)
        case auditEvent(UUID)

        public var entityType: EntityType {
            switch self {
            case .host: .host
            case .address: .address
            case .sshIdentity: .sshIdentity
            case .device: .device
            case .sshKeyRecord: .sshKeyRecord
            case .hostKeyPin: .hostKeyPin
            case .knownHostsLine: .knownHostsLine
            case .service: .service
            case .authorization: .authorization
            case .nodeAssociation: .nodeAssociation
            case .mergeReview: .mergeReview
            case .legacySourceRevision: .legacySourceRevision
            case .auditEvent: .auditEvent
            }
        }

        public var stableID: String {
            switch self {
            case .host(let id), .address(let id), .sshIdentity(let id), .hostKeyPin(let id),
                 .knownHostsLine(let id), .service(let id), .mergeReview(let id), .auditEvent(let id):
                id.uuidString.lowercased()
            case .device(let id), .sshKeyRecord(let id), .authorization(let id),
                 .nodeAssociation(let id), .legacySourceRevision(let id):
                id
            }
        }
    }

    enum AddressSource: String, Codable, CaseIterable, Hashable, Sendable {
        case legacy
        case manual
        case tailscale
        case discovered
    }

    struct Host: HostV6SyncedEntity {
        public var id: UUID
        public var name: String
        public var group: String
        public var machineConfiguration: RemoteMachineConfiguration?
        public var fixedAddressID: UUID?
        public var createdAt: Date
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            name: String,
            group: String,
            machineConfiguration: RemoteMachineConfiguration?,
            fixedAddressID: UUID?,
            createdAt: Date,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.group = group
            self.machineConfiguration = machineConfiguration
            self.fixedAddressID = fixedAddressID
            self.createdAt = createdAt
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .host(id) }
    }

    struct AccessAddress: HostV6SyncedEntity {
        public var id: UUID
        public var hostID: UUID
        public var normalizedHost: String
        public var sshPort: UInt16
        public var originalLabel: String
        public var source: AddressSource
        public var sortOrder: Int
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            hostID: UUID,
            normalizedHost: String,
            sshPort: UInt16,
            originalLabel: String,
            source: AddressSource,
            sortOrder: Int,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.hostID = hostID
            self.normalizedHost = normalizedHost
            self.sshPort = sshPort
            self.originalLabel = originalLabel
            self.source = source
            self.sortOrder = sortOrder
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .address(id) }
    }

    struct SSHIdentity: HostV6SyncedEntity {
        public var id: UUID
        public var hostID: UUID
        public var username: String
        public var alias: String
        public var preferredAddressID: UUID?
        public var createdAt: Date
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            hostID: UUID,
            username: String,
            alias: String,
            preferredAddressID: UUID?,
            createdAt: Date,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.hostID = hostID
            self.username = username
            self.alias = alias
            self.preferredAddressID = preferredAddressID
            self.createdAt = createdAt
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .sshIdentity(id) }
    }

    struct Device: HostV6SyncedEntity {
        public var id: String
        public var name: String
        public var registeredAt: Date
        public var lastActiveAt: Date
        public var tailscaleIdentity: TailscaleDeviceIdentity?
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: String,
            name: String,
            registeredAt: Date,
            lastActiveAt: Date,
            tailscaleIdentity: TailscaleDeviceIdentity?,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.registeredAt = registeredAt
            self.lastActiveAt = lastActiveAt
            self.tailscaleIdentity = tailscaleIdentity
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .device(id) }
    }

    struct SSHKeyRecord: HostV6SyncedEntity {
        public var id: String
        public var deviceID: String
        public var kind: SSHKeyKind
        public var publicKey: String
        public var fingerprint: String
        public var origin: SSHKeyOrigin
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: String,
            deviceID: String,
            kind: SSHKeyKind,
            publicKey: String,
            fingerprint: String,
            origin: SSHKeyOrigin,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.deviceID = deviceID
            self.kind = kind
            self.publicKey = publicKey
            self.fingerprint = fingerprint
            self.origin = origin
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .sshKeyRecord(id) }
    }

    enum HostKeyPinState: String, Codable, CaseIterable, Hashable, Sendable {
        case confirmed
        case replaced
        case pendingReview
    }

    struct HostKeyPin: HostV6SyncedEntity {
        public var id: UUID
        public var hostID: UUID
        public var addressID: UUID
        public var algorithm: String
        public var fingerprint: String
        public var state: HostKeyPinState
        public var firstConfirmedAt: Date?
        public var lastSeenAt: Date
        public var replacedAt: Date?
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            hostID: UUID,
            addressID: UUID,
            algorithm: String,
            fingerprint: String,
            state: HostKeyPinState,
            firstConfirmedAt: Date?,
            lastSeenAt: Date,
            replacedAt: Date? = nil,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.hostID = hostID
            self.addressID = addressID
            self.algorithm = algorithm
            self.fingerprint = fingerprint
            self.state = state
            self.firstConfirmedAt = firstConfirmedAt
            self.lastSeenAt = lastSeenAt
            self.replacedAt = replacedAt
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .hostKeyPin(id) }
    }

    enum KnownHostsLineSource: Codable, Hashable, Sendable {
        case legacyIdentity(UUID)
        case operation(UUID)

        public var id: UUID {
            switch self {
            case .legacyIdentity(let id), .operation(let id): id
            }
        }
    }

    struct KnownHostsLine: HostV6SyncedEntity {
        public var id: UUID
        public var pinID: UUID
        public var rawLine: String
        public var source: KnownHostsLineSource
        public var duplicateOrdinal: UInt32
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            pinID: UUID,
            rawLine: String,
            source: KnownHostsLineSource,
            duplicateOrdinal: UInt32,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.pinID = pinID
            self.rawLine = rawLine
            self.source = source
            self.duplicateOrdinal = duplicateOrdinal
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .knownHostsLine(id) }

        public static func derivedFileLines(from values: [Self]) -> [String] {
            Array(Set(values.lazy.filter { $0.deletedAt == nil }.map(\.rawLine))).sorted()
        }
    }

    enum ServiceProtocol: String, Codable, CaseIterable, Hashable, Sendable {
        case http
        case https
        case tcp
    }

    struct IPAddress: Codable, Hashable, Sendable {
        public enum Family: String, Codable, Hashable, Sendable { case v4, v6 }
        public var value: String
        public var family: Family

        public init(value: String, family: Family) {
            self.value = value
            self.family = family
        }
    }

    enum ListenerBind: Codable, Hashable, Sendable {
        case loopbackV4
        case loopbackV6
        case wildcardV4
        case wildcardV6
        case specific(IPAddress)
    }

    struct RemoteServiceEndpoint: Codable, Hashable, Sendable {
        public var bind: ListenerBind
        public var port: UInt16
        public var path: String?

        private enum CodingKeys: String, CodingKey {
            case bind
            case port
            case path
        }

        public init(bind: ListenerBind, port: UInt16, path: String?) {
            self.bind = bind
            self.port = port
            self.path = path.map { $0.hasPrefix("/") ? $0 : "/\($0)" }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bind: try container.decode(ListenerBind.self, forKey: .bind),
                port: try container.decode(UInt16.self, forKey: .port),
                path: try container.decodeIfPresent(String.self, forKey: .path)
            )
        }
    }

    struct SavedService: HostV6SyncedEntity {
        public var id: UUID
        public var hostID: UUID
        public var name: String
        public var serviceProtocol: ServiceProtocol
        public var endpoint: RemoteServiceEndpoint
        public var isFavorite: Bool
        public var fixedAddressID: UUID?
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            hostID: UUID,
            name: String,
            serviceProtocol: ServiceProtocol,
            endpoint: RemoteServiceEndpoint,
            isFavorite: Bool,
            fixedAddressID: UUID?,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.hostID = hostID
            self.name = name
            self.serviceProtocol = serviceProtocol
            self.endpoint = endpoint
            self.isFavorite = isFavorite
            self.fixedAddressID = fixedAddressID
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .service(id) }
    }

    enum AuthorizationRemoteState: String, Codable, CaseIterable, Hashable, Sendable {
        case unknown
        case authorized
        case revoked
    }

    enum AuthorizationRelationState: String, Codable, CaseIterable, Hashable, Sendable {
        case active
        case detached
    }

    struct Authorization: HostV6SyncedEntity {
        public var sshIdentityID: UUID
        public var keyID: String
        public var fingerprint: String
        public var remoteComment: String
        public var remoteState: AuthorizationRemoteState
        public var relationState: AuthorizationRelationState
        public var authorizedAt: Date?
        public var lastVerifiedAt: Date?
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public var id: String { "\(sshIdentityID.uuidString):\(fingerprint)" }

        public init(
            sshIdentityID: UUID,
            keyID: String,
            fingerprint: String,
            remoteComment: String,
            remoteState: AuthorizationRemoteState,
            relationState: AuthorizationRelationState,
            authorizedAt: Date?,
            lastVerifiedAt: Date?,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.sshIdentityID = sshIdentityID
            self.keyID = keyID
            self.fingerprint = fingerprint
            self.remoteComment = remoteComment
            self.remoteState = remoteState
            self.relationState = relationState
            self.authorizedAt = authorizedAt
            self.lastVerifiedAt = lastVerifiedAt
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .authorization(id) }
    }

    struct NodeAssociation: HostV6SyncedEntity {
        public var id: String
        public var sshIdentityID: UUID
        public var target: ActualNodeReference?
        public var state: NodeAssociationState
        public var method: NodeAssociationMethod?
        public var autoLinkEnabled: Bool
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: String,
            sshIdentityID: UUID,
            target: ActualNodeReference?,
            state: NodeAssociationState,
            method: NodeAssociationMethod?,
            autoLinkEnabled: Bool,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.sshIdentityID = sshIdentityID
            self.target = target
            self.state = state
            self.method = method
            self.autoLinkEnabled = autoLinkEnabled
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .nodeAssociation(id) }
    }

    struct MergeCandidate: Codable, Hashable, Sendable {
        public var mutationID: UUID
        public var vector: [String: UInt64]
        public var isDeleted: Bool
        public var summaryFields: [String: String]

        public init(
            mutationID: UUID,
            vector: [String: UInt64],
            isDeleted: Bool,
            summaryFields: [String: String] = [:]
        ) {
            self.mutationID = mutationID
            self.vector = vector
            self.isDeleted = isDeleted
            self.summaryFields = summaryFields
        }
    }

    enum MergeResolutionReason: String, Codable, CaseIterable, Hashable, Sendable {
        case userSelected
        case resolvedByTargetDeletion
    }

    struct MergeReview: HostV6SyncedEntity {
        public var id: UUID
        public var entityType: EntityType
        public var entityID: String
        public var candidates: [MergeCandidate]
        public var isBlocking: Bool
        public var resolvedAt: Date?
        public var resolutionMutationID: UUID?
        public var resolutionReason: MergeResolutionReason?
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: UUID,
            entityType: EntityType,
            entityID: String,
            candidates: [MergeCandidate],
            isBlocking: Bool,
            resolvedAt: Date? = nil,
            resolutionMutationID: UUID? = nil,
            resolutionReason: MergeResolutionReason? = nil,
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.entityType = entityType
            self.entityID = entityID
            self.candidates = candidates.sorted { $0.mutationID.uuidString < $1.mutationID.uuidString }
            self.isBlocking = isBlocking
            self.resolvedAt = resolvedAt
            self.resolutionMutationID = resolutionMutationID
            self.resolutionReason = resolutionReason
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .mergeReview(id) }
        public var isResolved: Bool { resolvedAt != nil }
    }

    struct LegacySourceRevision: HostV6SyncedEntity {
        public var id: String
        public var legacyKind: String
        public var legacyID: String
        public var revision: UInt64
        public var digest: String
        public var sourceDeleted: Bool
        public var derivedEntityIDs: [EntityReference]
        public var stamp: SyncStamp
        public var deletedAt: Date?

        public init(
            id: String,
            legacyKind: String,
            legacyID: String,
            revision: UInt64,
            digest: String,
            sourceDeleted: Bool,
            derivedEntityIDs: [EntityReference],
            stamp: SyncStamp,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.legacyKind = legacyKind
            self.legacyID = legacyID
            self.revision = revision
            self.digest = digest
            self.sourceDeleted = sourceDeleted
            self.derivedEntityIDs = derivedEntityIDs
            self.stamp = stamp
            self.deletedAt = deletedAt
        }

        public var entityReference: EntityReference { .legacySourceRevision(id) }
    }

    struct SyncedGraph: Codable, Hashable, Sendable {
        public static let cloudCodingKeys = [
            "hosts", "addresses", "identities", "devices", "sshKeys", "hostKeyPins",
            "knownHostsLines", "services", "authorizations", "nodeAssociations", "mergeReviews",
        ]

        public var hosts: [Host]
        public var addresses: [AccessAddress]
        public var identities: [SSHIdentity]
        public var devices: [Device]
        public var sshKeys: [SSHKeyRecord]
        public var hostKeyPins: [HostKeyPin]
        public var knownHostsLines: [KnownHostsLine]
        public var services: [SavedService]
        public var authorizations: [Authorization]
        public var nodeAssociations: [NodeAssociation]
        public var mergeReviews: [MergeReview]

        public init(
            hosts: [Host] = [],
            addresses: [AccessAddress] = [],
            identities: [SSHIdentity] = [],
            devices: [Device] = [],
            sshKeys: [SSHKeyRecord] = [],
            hostKeyPins: [HostKeyPin] = [],
            knownHostsLines: [KnownHostsLine] = [],
            services: [SavedService] = [],
            authorizations: [Authorization] = [],
            nodeAssociations: [NodeAssociation] = [],
            mergeReviews: [MergeReview] = []
        ) {
            self.hosts = hosts
            self.addresses = addresses
            self.identities = identities
            self.devices = devices
            self.sshKeys = sshKeys
            self.hostKeyPins = hostKeyPins
            self.knownHostsLines = knownHostsLines
            self.services = services
            self.authorizations = authorizations
            self.nodeAssociations = nodeAssociations
            self.mergeReviews = mergeReviews
        }
    }

    struct LocalHostAnnotation: Identifiable, Codable, Hashable, Sendable {
        public var hostID: UUID
        public var legacyIdentityID: UUID
        public var notes: String
        public var id: String { "\(hostID.uuidString.lowercased()):\(legacyIdentityID.uuidString.lowercased())" }

        public init(hostID: UUID, legacyIdentityID: UUID, notes: String) {
            self.hostID = hostID
            self.legacyIdentityID = legacyIdentityID
            self.notes = notes
        }
    }

    struct LocalSSHIdentityState: Identifiable, Codable, Hashable, Sendable {
        public var sshIdentityID: UUID
        public var status: AuthorizationStatus
        public var statusDetail: String?
        public var lastCheckedAt: Date?
        public var passwordCheck: AuthenticationCheck?
        public var keyCheck: AuthenticationCheck?
        public var machineConfigurationRefreshAttemptedAt: Date?
        public var id: UUID { sshIdentityID }

        public init(
            sshIdentityID: UUID,
            status: AuthorizationStatus,
            statusDetail: String?,
            lastCheckedAt: Date?,
            passwordCheck: AuthenticationCheck?,
            keyCheck: AuthenticationCheck?,
            machineConfigurationRefreshAttemptedAt: Date?
        ) {
            self.sshIdentityID = sshIdentityID
            self.status = status
            self.statusDetail = statusDetail
            self.lastCheckedAt = lastCheckedAt
            self.passwordCheck = passwordCheck
            self.keyCheck = keyCheck
            self.machineConfigurationRefreshAttemptedAt = machineConfigurationRefreshAttemptedAt
        }
    }

    struct LocalDeviceState: Identifiable, Codable, Hashable, Sendable {
        public var deviceID: String
        public var isCurrent: Bool
        public var id: String { deviceID }

        public init(deviceID: String, isCurrent: Bool) {
            self.deviceID = deviceID
            self.isCurrent = isCurrent
        }
    }

    struct LocalSSHKeyState: Identifiable, Codable, Hashable, Sendable {
        public var keyID: String
        public var privateKeyPath: String?
        public var isInAgent: Bool
        public var isLocallyAvailable: Bool
        public var id: String { keyID }

        public init(
            keyID: String,
            privateKeyPath: String?,
            isInAgent: Bool,
            isLocallyAvailable: Bool
        ) {
            self.keyID = keyID
            self.privateKeyPath = privateKeyPath
            self.isInAgent = isInAgent
            self.isLocallyAvailable = isLocallyAvailable
        }
    }

    struct ReachabilityEvidence: Identifiable, Codable, Hashable, Sendable {
        public var addressID: UUID
        public var networkEpoch: UInt64
        public var observedAt: Date
        public var wasReachable: Bool
        public var id: UUID { addressID }

        public init(addressID: UUID, networkEpoch: UInt64, observedAt: Date, wasReachable: Bool) {
            self.addressID = addressID
            self.networkEpoch = networkEpoch
            self.observedAt = observedAt
            self.wasReachable = wasReachable
        }
    }

    struct AuditEvent: Identifiable, Codable, Hashable, Sendable {
        public enum Level: String, Codable, CaseIterable, Hashable, Sendable {
            case info
            case warning
            case error
        }

        public var id: UUID
        public var timestamp: Date
        public var category: String
        public var action: String
        public var targetID: String?
        public var result: String
        public var level: Level

        public init(
            id: UUID,
            timestamp: Date,
            category: String,
            action: String,
            targetID: String?,
            result: String,
            level: Level
        ) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.action = action
            self.targetID = targetID
            self.result = result
            self.level = level
        }
    }

    struct LocalState: Codable, Hashable, Sendable {
        public var hostAnnotations: [LocalHostAnnotation]
        public var identityStates: [LocalSSHIdentityState]
        public var deviceStates: [LocalDeviceState]
        public var keyStates: [LocalSSHKeyState]
        public var reachabilityEvidence: [ReachabilityEvidence]
        public var auditEvents: [AuditEvent]

        public init(
            hostAnnotations: [LocalHostAnnotation] = [],
            identityStates: [LocalSSHIdentityState] = [],
            deviceStates: [LocalDeviceState] = [],
            keyStates: [LocalSSHKeyState] = [],
            reachabilityEvidence: [ReachabilityEvidence] = [],
            auditEvents: [AuditEvent] = []
        ) {
            self.hostAnnotations = hostAnnotations
            self.identityStates = identityStates
            self.deviceStates = deviceStates
            self.keyStates = keyStates
            self.reachabilityEvidence = reachabilityEvidence
            self.auditEvents = auditEvents
        }
    }

    enum AuthorityMode: String, Codable, CaseIterable, Hashable, Sendable {
        case legacyAuthoritative
        case v6Canary
        case v6Authoritative
        case compatibilityRollback
    }

    struct AuthorityManifest: Codable, Hashable, Sendable {
        public var mode: AuthorityMode
        public var v1Hash: String
        public var v6Hash: String
        public var compatibilityHash: String
        public var checkpointHash: String
        public var acknowledgedDeviceIDs: [String]
        public var cloudChangeTag: String?
        public var firstV6MutationID: UUID?
        public var codeVersion: String
        public var notRepresentable: [EntityReference]

        public init(
            mode: AuthorityMode,
            v1Hash: String,
            v6Hash: String,
            compatibilityHash: String,
            checkpointHash: String,
            acknowledgedDeviceIDs: [String],
            cloudChangeTag: String?,
            firstV6MutationID: UUID?,
            codeVersion: String,
            notRepresentable: [EntityReference]
        ) {
            self.mode = mode
            self.v1Hash = v1Hash
            self.v6Hash = v6Hash
            self.compatibilityHash = compatibilityHash
            self.checkpointHash = checkpointHash
            self.acknowledgedDeviceIDs = acknowledgedDeviceIDs.sorted()
            self.cloudChangeTag = cloudChangeTag
            self.firstV6MutationID = firstV6MutationID
            self.codeVersion = codeVersion
            self.notRepresentable = notRepresentable
        }
    }

    struct MigrationProvenance: Codable, Hashable, Sendable {
        public var legacySources: [LegacySourceRevision]
        public var authorityManifest: AuthorityManifest?

        public init(legacySources: [LegacySourceRevision], authorityManifest: AuthorityManifest?) {
            self.legacySources = legacySources
            self.authorityManifest = authorityManifest
        }

        public static let empty = Self(legacySources: [], authorityManifest: nil)
    }

    struct MetadataEnvelope: Codable, Hashable, Sendable {
        public var schemaVersion: Int
        public var synced: SyncedGraph
        public var local: LocalState
        public var migrationProvenance: MigrationProvenance

        public init(
            schemaVersion: Int = 6,
            synced: SyncedGraph,
            local: LocalState,
            migrationProvenance: MigrationProvenance
        ) {
            self.schemaVersion = schemaVersion
            self.synced = synced
            self.local = local
            self.migrationProvenance = migrationProvenance
        }
    }
}
