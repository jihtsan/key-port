import CryptoKit
import Foundation

/// The stable identity of a machine or network participant.
///
/// A Node is deliberately independent from addresses, ports, accounts and
/// observations. Those facts can change without changing the Node's identity.
public struct Node: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var roles: [NodeRole]
    public var group: String
    public var notes: String
    public var machineConfiguration: RemoteMachineConfiguration?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        id: UUID,
        name: String,
        roles: [NodeRole],
        group: String = "",
        notes: String = "",
        machineConfiguration: RemoteMachineConfiguration? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.roles = Array(Set(roles)).sorted { $0.rawValue < $1.rawValue }
        self.group = group
        self.notes = notes
        self.machineConfiguration = machineConfiguration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public var isWorkspaceDevice: Bool { roles.contains(.clientDevice) }
    public var isSSHHost: Bool { roles.contains(.sshHost) }
}

public enum NodeRole: String, Codable, CaseIterable, Hashable, Sendable {
    case clientDevice
    case sshHost
    case rdpHost
    case vpnGateway
    case serviceHost
}

public enum EndpointProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case ssh
    case rdp
    case vpn
    case http
    case https
    case tcp
    case postgresql
    case mysql
}

public enum NetworkScope: String, Codable, CaseIterable, Hashable, Sendable {
    case lan
    case publicNetwork
    case tailnet
    case vpn
    case unknown
}

public enum EndpointSource: String, Codable, CaseIterable, Hashable, Sendable {
    case migrated
    case manual
    case discovered
    case tailscale
}

/// A coordinate used to reach a Node or one of its logical services.
public struct Endpoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var nodeID: UUID
    public var serviceID: UUID?
    public var address: String
    public var label: String
    public var port: UInt16
    public var `protocol`: EndpointProtocol
    public var networkScope: NetworkScope
    public var source: EndpointSource
    public var priority: Int
    public var isDeleted: Bool

    public init(
        id: UUID,
        nodeID: UUID,
        serviceID: UUID? = nil,
        address: String,
        label: String? = nil,
        port: UInt16,
        protocol: EndpointProtocol,
        networkScope: NetworkScope = .unknown,
        source: EndpointSource = .manual,
        priority: Int = 0,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.nodeID = nodeID
        self.serviceID = serviceID
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label ?? address
        self.port = port
        self.protocol = `protocol`
        self.networkScope = networkScope
        self.source = source
        self.priority = priority
        self.isDeleted = isDeleted
    }

    public var displayAddress: String {
        if address.contains(":") && !address.hasPrefix("[") {
            return "[\(address)]:\(port)"
        }
        return "\(address):\(port)"
    }
}

/// A logical capability hosted by a Node. A Service is not a second machine.
public struct Service: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var nodeID: UUID
    public var name: String
    public var `protocol`: EndpointProtocol
    public var endpointIDs: [UUID]
    public var isFavorite: Bool
    public var isDeleted: Bool

    public init(
        id: UUID,
        nodeID: UUID,
        name: String,
        protocol: EndpointProtocol,
        endpointIDs: [UUID] = [],
        isFavorite: Bool = false,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.nodeID = nodeID
        self.name = name
        self.protocol = `protocol`
        self.endpointIDs = endpointIDs
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
    }
}

/// KeyPort's registration of a Node as an access source.
public struct WorkspaceDeviceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var nodeID: UUID
    public var name: String
    public var registeredAt: Date
    public var lastActiveAt: Date
    public var isCurrent: Bool
    public var isRevoked: Bool
    public var tailscaleIdentity: TailscaleDeviceIdentity?

    public init(
        id: String,
        nodeID: UUID,
        name: String,
        registeredAt: Date = .now,
        lastActiveAt: Date = .now,
        isCurrent: Bool = false,
        isRevoked: Bool = false,
        tailscaleIdentity: TailscaleDeviceIdentity? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.name = name
        self.registeredAt = registeredAt
        self.lastActiveAt = lastActiveAt
        self.isCurrent = isCurrent
        self.isRevoked = isRevoked
        self.tailscaleIdentity = tailscaleIdentity
    }
}

public struct SSHAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var nodeID: UUID
    public var endpointID: UUID
    public var username: String
    public var alias: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(
        id: UUID,
        nodeID: UUID,
        endpointID: UUID,
        username: String,
        alias: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isDeleted: Bool = false,
        version: Int = 1
    ) {
        self.id = id
        self.nodeID = nodeID
        self.endpointID = endpointID
        self.username = username
        self.alias = alias
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }
}

public enum SSHHostKeyTrustState: String, Codable, CaseIterable, Hashable, Sendable {
    case confirmed
    case pendingReview
    case replaced
}

public struct SSHHostKeyTrust: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var endpointID: UUID
    public var algorithm: String
    public var fingerprint: String
    public var knownHostsLine: String
    public var state: SSHHostKeyTrustState
    public var firstConfirmedAt: Date?
    public var lastSeenAt: Date
    public var replacedAt: Date?
    public var isDeleted: Bool

    public init(
        id: UUID,
        endpointID: UUID,
        algorithm: String,
        fingerprint: String,
        knownHostsLine: String,
        state: SSHHostKeyTrustState = .confirmed,
        firstConfirmedAt: Date? = nil,
        lastSeenAt: Date = .now,
        replacedAt: Date? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.endpointID = endpointID
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.knownHostsLine = knownHostsLine
        self.state = state
        self.firstConfirmedAt = firstConfirmedAt
        self.lastSeenAt = lastSeenAt
        self.replacedAt = replacedAt
        self.isDeleted = isDeleted
    }
}

public struct SSHKey: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var deviceID: String
    public var kind: SSHKeyKind
    public var publicKey: String
    public var fingerprint: String
    public var privateKeyPath: String?
    public var isInAgent: Bool
    public var origin: SSHKeyOrigin
    public var isLocallyAvailable: Bool

    public init(
        id: String,
        deviceID: String,
        kind: SSHKeyKind,
        publicKey: String,
        fingerprint: String,
        privateKeyPath: String? = nil,
        isInAgent: Bool = false,
        origin: SSHKeyOrigin,
        isLocallyAvailable: Bool = false
    ) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.privateKeyPath = privateKeyPath
        self.isInAgent = isInAgent
        self.origin = origin
        self.isLocallyAvailable = isLocallyAvailable
    }
}

public enum SSHRemoteAuthorizationState: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case authorized
    case revoked
}

public enum SSHAuthorizationRelationState: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case detached
}

public struct SSHAuthorization: Identifiable, Codable, Hashable, Sendable {
    public var accountID: UUID
    public var keyID: String
    public var fingerprint: String
    public var remoteComment: String
    public var remoteState: SSHRemoteAuthorizationState
    public var relationState: SSHAuthorizationRelationState
    public var authorizedAt: Date?
    public var lastVerifiedAt: Date?
    public var updatedAt: Date
    public var isDeleted: Bool

    public var id: String { "\(accountID.uuidString.lowercased()):\(fingerprint)" }

    public init(
        accountID: UUID,
        keyID: String,
        fingerprint: String,
        remoteComment: String,
        remoteState: SSHRemoteAuthorizationState,
        relationState: SSHAuthorizationRelationState = .active,
        authorizedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        updatedAt: Date = .now,
        isDeleted: Bool = false
    ) {
        self.accountID = accountID
        self.keyID = keyID
        self.fingerprint = fingerprint
        self.remoteComment = remoteComment
        self.remoteState = remoteState
        self.relationState = relationState
        self.authorizedAt = authorizedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

/// Local, expiring evidence. It never changes Node identity or authorization.
public struct ReachabilityObservation: Identifiable, Codable, Hashable, Sendable {
    public var endpointID: UUID
    public var observerDeviceID: String
    public var networkEpoch: UInt64
    public var observedAt: Date
    public var wasReachable: Bool

    public var id: String { "\(observerDeviceID):\(endpointID.uuidString.lowercased())" }

    public init(
        endpointID: UUID,
        observerDeviceID: String,
        networkEpoch: UInt64,
        observedAt: Date,
        wasReachable: Bool
    ) {
        self.endpointID = endpointID
        self.observerDeviceID = observerDeviceID
        self.networkEpoch = networkEpoch
        self.observedAt = observedAt
        self.wasReachable = wasReachable
    }
}

/// The result of checking one local device against one SSH account.
public struct AccessVerification: Identifiable, Codable, Hashable, Sendable {
    public var accountID: UUID
    public var deviceID: String
    public var status: AuthorizationStatus
    public var statusDetail: String?
    public var lastCheckedAt: Date?
    public var passwordCheck: AuthenticationCheck?
    public var keyCheck: AuthenticationCheck?
    public var machineConfigurationRefreshAttemptedAt: Date?

    public var id: String { "\(deviceID):\(accountID.uuidString.lowercased())" }

    public init(
        accountID: UUID,
        deviceID: String,
        status: AuthorizationStatus,
        statusDetail: String? = nil,
        lastCheckedAt: Date? = nil,
        passwordCheck: AuthenticationCheck? = nil,
        keyCheck: AuthenticationCheck? = nil,
        machineConfigurationRefreshAttemptedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.status = status
        self.statusDetail = statusDetail
        self.lastCheckedAt = lastCheckedAt
        self.passwordCheck = passwordCheck
        self.keyCheck = keyCheck
        self.machineConfigurationRefreshAttemptedAt = machineConfigurationRefreshAttemptedAt
    }
}

public struct TopologySnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var nodes: [Node]
    public var profiles: [WorkspaceDeviceProfile]
    public var endpoints: [Endpoint]
    public var services: [Service]
    public var sshAccounts: [SSHAccount]
    public var sshKeys: [SSHKey]
    public var hostKeyTrusts: [SSHHostKeyTrust]
    public var authorizations: [SSHAuthorization]
    public var reachabilityObservations: [ReachabilityObservation]
    public var accessVerifications: [AccessVerification]
    public var nodeAssociations: [NodeAssociation]
    public var auditEvents: [AuditEvent]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        nodes: [Node] = [],
        profiles: [WorkspaceDeviceProfile] = [],
        endpoints: [Endpoint] = [],
        services: [Service] = [],
        sshAccounts: [SSHAccount] = [],
        sshKeys: [SSHKey] = [],
        hostKeyTrusts: [SSHHostKeyTrust] = [],
        authorizations: [SSHAuthorization] = [],
        reachabilityObservations: [ReachabilityObservation] = [],
        accessVerifications: [AccessVerification] = [],
        nodeAssociations: [NodeAssociation] = [],
        auditEvents: [AuditEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.profiles = profiles
        self.endpoints = endpoints
        self.services = services
        self.sshAccounts = sshAccounts
        self.sshKeys = sshKeys
        self.hostKeyTrusts = hostKeyTrusts
        self.authorizations = authorizations
        self.reachabilityObservations = reachabilityObservations
        self.accessVerifications = accessVerifications
        self.nodeAssociations = nodeAssociations
        self.auditEvents = auditEvents
    }

    public static let empty = Self()

    public var activeNodes: [Node] { nodes.filter { !$0.isDeleted } }
    public var activeEndpoints: [Endpoint] { endpoints.filter { !$0.isDeleted } }
    public var activeAccounts: [SSHAccount] { sshAccounts.filter { !$0.isDeleted } }

    public func node(id: UUID) -> Node? {
        nodes.first { $0.id == id && !$0.isDeleted }
    }

    public func endpoint(id: UUID) -> Endpoint? {
        endpoints.first { $0.id == id && !$0.isDeleted }
    }
}

public enum TopologyStableID {
    private static let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
    private static let namespace = uuidV5(namespace: dnsNamespace, name: "app.keyport/topology-v1")

    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        let value = namespace.uuid
        var bytes: [UInt8] = [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ]
        bytes.append(contentsOf: name.utf8)
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    public static func node(forHost host: String) -> UUID {
        uuidV5(namespace: namespace, name: "node/host/\(normalize(host))")
    }

    public static func node(forDeviceID deviceID: String) -> UUID {
        uuidV5(namespace: namespace, name: "node/device/\(deviceID.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    public static func endpoint(
        nodeID: UUID,
        address: String,
        port: UInt16,
        protocol: EndpointProtocol
    ) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "endpoint/\(nodeID.uuidString.lowercased())/\(normalize(address))/\(port)/\(`protocol`.rawValue)"
        )
    }

    public static func hostKeyTrust(endpointID: UUID, algorithm: String, fingerprint: String) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "host-key/\(endpointID.uuidString.lowercased())/\(algorithm)/\(fingerprint)"
        )
    }

    public static func service(nodeID: UUID, name: String, protocol: EndpointProtocol) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "service/\(nodeID.uuidString.lowercased())/\(normalize(name))/\(`protocol`.rawValue)"
        )
    }

    public static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

/// One deterministic import path from the pre-refactor snapshot to the unified model.
public enum TopologySnapshotMigration {
    public static func fromLegacy(
        _ legacy: AppSnapshot,
        currentDeviceID: String,
        currentDeviceName: String,
        now: Date = .now
    ) -> TopologySnapshot {
        var nodesByID: [UUID: Node] = [:]
        var profiles: [WorkspaceDeviceProfile] = []
        var endpointsByKey: [String: Endpoint] = [:]
        var accounts: [SSHAccount] = []
        var keys: [SSHKey] = []
        var trustsByKey: [String: SSHHostKeyTrust] = [:]
        var authorizations: [SSHAuthorization] = []
        var verifications: [AccessVerification] = []

        let legacyDevices = legacy.devices + (legacy.devices.contains(where: { $0.id == currentDeviceID })
            ? []
            : [Device(id: currentDeviceID, name: currentDeviceName, isCurrent: true)])
        for device in legacyDevices {
            let nodeID = TopologyStableID.node(forDeviceID: device.id)
            var node = nodesByID[nodeID] ?? Node(
                id: nodeID,
                name: device.name.isEmpty ? device.id : device.name,
                roles: [.clientDevice],
                createdAt: device.registeredAt,
                updatedAt: device.lastActiveAt,
                isDeleted: device.isRevoked
            )
            node.roles = Array(Set(node.roles + [.clientDevice])).sorted { $0.rawValue < $1.rawValue }
            node.updatedAt = max(node.updatedAt, device.lastActiveAt)
            node.isDeleted = device.isRevoked
            nodesByID[nodeID] = node
            profiles.append(WorkspaceDeviceProfile(
                id: device.id,
                nodeID: nodeID,
                name: device.name.isEmpty ? device.id : device.name,
                registeredAt: device.registeredAt,
                lastActiveAt: device.lastActiveAt,
                isCurrent: device.id == currentDeviceID || device.isCurrent,
                isRevoked: device.isRevoked,
                tailscaleIdentity: device.tailscaleIdentity
            ))
        }

        let groups = Dictionary(grouping: legacy.servers) { TopologyStableID.normalize($0.host) }
        for (hostKey, serverRecords) in groups.sorted(by: { $0.key < $1.key }) {
            let orderedRecords = serverRecords.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard let first = orderedRecords.first else { continue }
            let nodeID = TopologyStableID.node(forHost: hostKey)
            let node = Node(
                id: nodeID,
                name: orderedRecords.first(where: { !$0.name.isEmpty })?.name ?? hostKey,
                roles: [.sshHost],
                group: orderedRecords.first(where: { !$0.group.isEmpty })?.group ?? "",
                notes: orderedRecords.first(where: { !$0.notes.isEmpty })?.notes ?? "",
                machineConfiguration: orderedRecords.compactMap(\.machineConfiguration).first,
                createdAt: orderedRecords.map(\.createdAt).min() ?? first.createdAt,
                updatedAt: orderedRecords.map(\.updatedAt).max() ?? now,
                isDeleted: orderedRecords.allSatisfy(\.isDeleted)
            )
            nodesByID[nodeID] = node

            for record in orderedRecords {
                let port = UInt16(clamping: max(1, min(65_535, record.port)))
                let endpointID = TopologyStableID.endpoint(
                    nodeID: nodeID,
                    address: record.host,
                    port: port,
                    protocol: .ssh
                )
                let endpointKey = "\(nodeID.uuidString.lowercased()):\(port):\(TopologyStableID.normalize(record.host))"
                if endpointsByKey[endpointKey] == nil {
                    endpointsByKey[endpointKey] = Endpoint(
                        id: endpointID,
                        nodeID: nodeID,
                        address: record.host,
                        label: record.host,
                        port: port,
                        protocol: .ssh,
                        networkScope: networkScope(for: record.host),
                        source: .migrated,
                        priority: endpointsByKey.count
                    )
                }
                accounts.append(SSHAccount(
                    id: record.id,
                    nodeID: nodeID,
                    endpointID: endpointID,
                    username: record.username,
                    alias: record.alias,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    isDeleted: record.isDeleted,
                    version: record.version
                ))
                verifications.append(AccessVerification(
                    accountID: record.id,
                    deviceID: currentDeviceID,
                    status: record.status,
                    statusDetail: record.statusDetail,
                    lastCheckedAt: record.lastCheckedAt,
                    passwordCheck: record.passwordCheck,
                    keyCheck: record.keyCheck,
                    machineConfigurationRefreshAttemptedAt: record.machineConfigurationRefreshAttemptedAt
                ))

                for hostKeyRecord in record.confirmedHostKeys {
                    let trustKey = "\(endpointID.uuidString.lowercased()):\(hostKeyRecord.algorithm):\(hostKeyRecord.fingerprint)"
                    trustsByKey[trustKey] = SSHHostKeyTrust(
                        id: TopologyStableID.hostKeyTrust(
                            endpointID: endpointID,
                            algorithm: hostKeyRecord.algorithm,
                            fingerprint: hostKeyRecord.fingerprint
                        ),
                        endpointID: endpointID,
                        algorithm: hostKeyRecord.algorithm,
                        fingerprint: hostKeyRecord.fingerprint,
                        knownHostsLine: hostKeyRecord.knownHostsLine,
                        state: .confirmed,
                        firstConfirmedAt: hostKeyRecord.firstConfirmedAt,
                        lastSeenAt: hostKeyRecord.lastSeenAt
                    )
                }
            }
        }

        keys = legacy.keys.map { key in
            SSHKey(
                id: key.id,
                deviceID: key.deviceID,
                kind: key.kind,
                publicKey: key.publicKey,
                fingerprint: key.fingerprint,
                privateKeyPath: key.privateKeyPath,
                isInAgent: key.isInAgent,
                origin: key.origin,
                isLocallyAvailable: key.isLocallyAvailable
            )
        }

        for authorization in legacy.authorizations {
            authorizations.append(SSHAuthorization(
                accountID: authorization.serverID,
                keyID: authorization.keyID,
                fingerprint: authorization.fingerprint,
                remoteComment: authorization.remoteComment,
                remoteState: authorization.status == .authorized ? .authorized : .unknown,
                relationState: authorization.isDeleted ? .detached : .active,
                authorizedAt: authorization.authorizedAt,
                lastVerifiedAt: authorization.lastVerifiedAt,
                updatedAt: authorization.updatedAt,
                isDeleted: authorization.isDeleted
            ))
        }

        let migratedEndpoints = endpointsByKey.values.map { endpoint in
            var value = endpoint
            let relatedAccounts = accounts.filter { $0.endpointID == endpoint.id }
            value.isDeleted = !relatedAccounts.isEmpty && relatedAccounts.allSatisfy(\.isDeleted)
            return value
        }

        return TopologySnapshot(
            nodes: nodesByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            profiles: profiles.sorted { $0.id < $1.id },
            endpoints: migratedEndpoints.sorted { $0.id.uuidString < $1.id.uuidString },
            sshAccounts: accounts.sorted { $0.id.uuidString < $1.id.uuidString },
            sshKeys: keys.sorted { $0.id < $1.id },
            hostKeyTrusts: trustsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            authorizations: authorizations.sorted { $0.id < $1.id },
            accessVerifications: verifications.sorted { $0.id < $1.id },
            nodeAssociations: legacy.nodeAssociations,
            auditEvents: legacy.auditEvents
        )
    }

    /// Rebuilds the SSH projection from legacy mutations without discarding
    /// topology-only facts such as services, manually added endpoints, or
    /// future protocol roles that the compatibility snapshot cannot represent.
    public static func refreshed(
        from legacy: AppSnapshot,
        preserving existing: TopologySnapshot?,
        currentDeviceID: String,
        currentDeviceName: String,
        now: Date = .now
    ) -> TopologySnapshot {
        let migrated = fromLegacy(
            legacy,
            currentDeviceID: currentDeviceID,
            currentDeviceName: currentDeviceName,
            now: now
        )
        guard let existing else { return migrated }

        var result = migrated
        result.nodes = mergeByKey(migrated.nodes, existing.nodes, by: { $0.id.uuidString }) { current, previous in
            var value = current
            value.roles = Array(Set(current.roles + previous.roles)).sorted { $0.rawValue < $1.rawValue }
            if value.group.isEmpty { value.group = previous.group }
            if value.notes.isEmpty { value.notes = previous.notes }
            if value.machineConfiguration == nil { value.machineConfiguration = previous.machineConfiguration }
            return value
        }
        result.profiles = mergeByKey(migrated.profiles, existing.profiles, by: \.id) { current, previous in
            var value = current
            if value.name.isEmpty { value.name = previous.name }
            if value.tailscaleIdentity == nil { value.tailscaleIdentity = previous.tailscaleIdentity }
            return value
        }
        result.endpoints = mergeByKey(migrated.endpoints, existing.endpoints, by: { $0.id.uuidString }) { current, previous in
            var value = current
            if !previous.label.isEmpty { value.label = previous.label }
            if previous.networkScope != .unknown { value.networkScope = previous.networkScope }
            if previous.source != .migrated { value.source = previous.source }
            value.priority = previous.priority
            value.serviceID = current.serviceID ?? previous.serviceID
            return value
        }
        result.services = mergeByKey([], existing.services, by: { $0.id.uuidString }) { current, _ in current }
        result.sshAccounts = mergeByKey(migrated.sshAccounts, existing.sshAccounts, by: { $0.id.uuidString }) { current, _ in current }
        result.sshKeys = mergeByKey(migrated.sshKeys, existing.sshKeys, by: \.id) { current, previous in
            var value = current
            if value.privateKeyPath == nil { value.privateKeyPath = previous.privateKeyPath }
            value.isInAgent = current.isInAgent || previous.isInAgent
            value.isLocallyAvailable = current.isLocallyAvailable || previous.isLocallyAvailable
            return value
        }
        result.hostKeyTrusts = mergeByKey(migrated.hostKeyTrusts, existing.hostKeyTrusts, by: { $0.id.uuidString }) { current, _ in current }
        result.authorizations = mergeByKey(migrated.authorizations, existing.authorizations, by: \.id) { current, _ in current }
        result.reachabilityObservations = mergeByKey([], existing.reachabilityObservations, by: \.id) { current, _ in current }
        result.accessVerifications = mergeByKey(migrated.accessVerifications, existing.accessVerifications, by: \.id) { current, _ in current }
        result.nodeAssociations = mergeByKey(migrated.nodeAssociations, existing.nodeAssociations, by: \.id) { current, _ in current }
        result.auditEvents = mergeByKey(migrated.auditEvents, existing.auditEvents, by: { $0.id.uuidString }) { current, _ in current }
        return result
    }

    private static func mergeByKey<T>(
        _ preferred: [T],
        _ fallback: [T],
        by key: (T) -> String,
        combining: (T, T) -> T
    ) -> [T] {
        var values = Dictionary(uniqueKeysWithValues: fallback.map { (key($0), $0) })
        for value in preferred {
            let valueKey = key(value)
            values[valueKey] = values[valueKey].map { combining(value, $0) } ?? value
        }
        return values.values.sorted { key($0) < key($1) }
    }

    /// Builds the old SSH-facing view at the adapter seam. The application can
    /// continue using the existing OpenSSH and Keychain adapters while the new
    /// topology remains the single source for Graph and future use cases.
    public static func legacyProjection(
        from topology: TopologySnapshot,
        currentDeviceID: String
    ) -> AppSnapshot {
        var snapshot = AppSnapshot()
        snapshot.devices = topology.profiles.map { profile in
            Device(
                id: profile.id,
                name: profile.name,
                isCurrent: profile.id == currentDeviceID || profile.isCurrent,
                registeredAt: profile.registeredAt,
                lastActiveAt: profile.lastActiveAt,
                isRevoked: profile.isRevoked,
                tailscaleIdentity: profile.tailscaleIdentity
            )
        }
        snapshot.keys = topology.sshKeys.map { key in
            SSHKeyRecord(
                id: key.id,
                deviceID: key.deviceID,
                kind: key.kind,
                publicKey: key.publicKey,
                fingerprint: key.fingerprint,
                privateKeyPath: key.privateKeyPath,
                isInAgent: key.isInAgent,
                origin: key.origin,
                isLocallyAvailable: key.isLocallyAvailable
            )
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) })
        let endpointsByID = Dictionary(uniqueKeysWithValues: topology.endpoints.map { ($0.id, $0) })
        let verificationsByID = Dictionary(
            topology.accessVerifications
                .filter { $0.deviceID == currentDeviceID }
                .map { ($0.accountID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let trustByEndpoint = Dictionary(grouping: topology.hostKeyTrusts.filter { !$0.isDeleted }, by: \.endpointID)

        snapshot.servers = topology.sshAccounts.compactMap { account in
            guard let node = nodesByID[account.nodeID],
                  let endpoint = endpointsByID[account.endpointID] else { return nil }
            let verification = verificationsByID[account.id]
            let confirmedHostKeys = (trustByEndpoint[endpoint.id] ?? []).filter { $0.state == .confirmed }.map {
                HostKeyRecord(
                    algorithm: $0.algorithm,
                    fingerprint: $0.fingerprint,
                    knownHostsLine: $0.knownHostsLine,
                    firstConfirmedAt: $0.firstConfirmedAt,
                    lastSeenAt: $0.lastSeenAt
                )
            }.sorted { ($0.algorithm, $0.fingerprint) < ($1.algorithm, $1.fingerprint) }
            return ServerConnection(
                id: account.id,
                name: node.name,
                host: endpoint.label.isEmpty ? endpoint.address : endpoint.label,
                port: Int(endpoint.port),
                username: account.username,
                alias: account.alias,
                group: node.group,
                notes: node.notes,
                confirmedHostKeys: confirmedHostKeys,
                status: verification?.status ?? .hostKeyPending,
                statusDetail: verification?.statusDetail,
                lastCheckedAt: verification?.lastCheckedAt,
                passwordCheck: verification?.passwordCheck,
                keyCheck: verification?.keyCheck,
                machineConfiguration: node.machineConfiguration,
                machineConfigurationRefreshAttemptedAt: verification?.machineConfigurationRefreshAttemptedAt,
                createdAt: account.createdAt,
                updatedAt: account.updatedAt,
                isDeleted: account.isDeleted,
                version: account.version
            )
        }
        snapshot.authorizations = topology.authorizations.map { authorization in
            Authorization(
                serverID: authorization.accountID,
                keyID: authorization.keyID,
                fingerprint: authorization.fingerprint,
                remoteComment: authorization.remoteComment,
                status: authorization.remoteState == .authorized ? .authorized : .needsAuthorization,
                authorizedAt: authorization.authorizedAt,
                lastVerifiedAt: authorization.lastVerifiedAt,
                updatedAt: authorization.updatedAt,
                isDeleted: authorization.isDeleted,
                version: 1
            )
        }
        snapshot.nodeAssociations = topology.nodeAssociations
        snapshot.auditEvents = topology.auditEvents
        return snapshot
    }

    private static func networkScope(for address: String) -> NetworkScope {
        let normalized = TopologyStableID.normalize(address)
        if normalized.hasPrefix("100.") || normalized.hasPrefix("fd") {
            return .tailnet
        }
        if normalized.hasPrefix("10.") || normalized.hasPrefix("192.168.") || normalized.hasPrefix("172.16.") {
            return .lan
        }
        if normalized.contains(".") { return .publicNetwork }
        return .unknown
    }
}
