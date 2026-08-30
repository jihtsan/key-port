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

    /// The network condition a user should satisfy before trying this endpoint.
    /// This is a stable requirement label, not a live reachability result.
    public var requirementTitle: String {
        switch self {
        case .lan: "需要同一局域网"
        case .publicNetwork: "需要公网可达"
        case .tailnet: "需要 Tailscale 在线"
        case .vpn: "需要 VPN 通道"
        case .unknown: "网络要求未声明"
        }
    }
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
    public var username: String
    public var label: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool
    public var version: Int

    public init(
        id: UUID,
        nodeID: UUID,
        username: String,
        label: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isDeleted: Bool = false,
        version: Int = 1
    ) {
        self.id = id
        self.nodeID = nodeID
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.version = version
    }
}

/// A transient compatibility command used when a legacy connection profile is
/// created from a Node. The account is resolved from the profile's username.
public struct SSHConnectionProfileNodeBinding: Hashable, Sendable {
    public let profileID: UUID
    public let nodeID: UUID
    public let endpointID: UUID?

    public init(profileID: UUID, nodeID: UUID, endpointID: UUID? = nil) {
        self.profileID = profileID
        self.nodeID = nodeID
        self.endpointID = endpointID
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
    public var profileID: UUID?
    public var endpointID: UUID?
    public var transport: SSHConnectionTransport?
    public var networkEpoch: UInt64?
    public var status: AuthorizationStatus
    public var statusDetail: String?
    public var lastCheckedAt: Date?
    public var passwordCheck: AuthenticationCheck?
    public var keyCheck: AuthenticationCheck?
    public var machineConfigurationRefreshAttemptedAt: Date?

    public var id: String {
        let planSubject = profileID?.uuidString.lowercased() ?? "account"
        return "\(deviceID):\(accountID.uuidString.lowercased()):\(planSubject)"
    }

    public init(
        accountID: UUID,
        deviceID: String,
        profileID: UUID? = nil,
        endpointID: UUID? = nil,
        transport: SSHConnectionTransport? = nil,
        networkEpoch: UInt64? = nil,
        status: AuthorizationStatus,
        statusDetail: String? = nil,
        lastCheckedAt: Date? = nil,
        passwordCheck: AuthenticationCheck? = nil,
        keyCheck: AuthenticationCheck? = nil,
        machineConfigurationRefreshAttemptedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.profileID = profileID
        self.endpointID = endpointID
        self.transport = transport
        self.networkEpoch = networkEpoch
        self.status = status
        self.statusDetail = statusDetail
        self.lastCheckedAt = lastCheckedAt
        self.passwordCheck = passwordCheck
        self.keyCheck = keyCheck
        self.machineConfigurationRefreshAttemptedAt = machineConfigurationRefreshAttemptedAt
    }
}

private struct LegacySSHAccountV2: Decodable {
    var id: UUID
    var nodeID: UUID
    var endpointID: UUID
    var username: String
    var alias: String
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var version: Int
}

public struct TopologySnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var nodes: [Node]
    public var profiles: [WorkspaceDeviceProfile]
    public var endpoints: [Endpoint]
    public var services: [Service]
    public var tailscaleNodes: [TailscaleNodeIdentity]
    public var tailscaleObservations: [TailscaleNodeObservation]
    public var sshAccounts: [SSHAccount]
    public var sshConnectionProfiles: [SSHConnectionProfile]
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
        tailscaleNodes: [TailscaleNodeIdentity] = [],
        tailscaleObservations: [TailscaleNodeObservation] = [],
        sshAccounts: [SSHAccount] = [],
        sshConnectionProfiles: [SSHConnectionProfile] = [],
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
        self.tailscaleNodes = tailscaleNodes
        self.tailscaleObservations = tailscaleObservations
        self.sshAccounts = sshAccounts
        self.sshConnectionProfiles = sshConnectionProfiles
        self.sshKeys = sshKeys
        self.hostKeyTrusts = hostKeyTrusts
        self.authorizations = authorizations
        self.reachabilityObservations = reachabilityObservations
        self.accessVerifications = accessVerifications
        self.nodeAssociations = nodeAssociations
        self.auditEvents = auditEvents
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case nodes
        case profiles
        case endpoints
        case services
        case tailscaleNodes
        case tailscaleObservations
        case sshAccounts
        case sshConnectionProfiles
        case sshKeys
        case hostKeyTrusts
        case authorizations
        case reachabilityObservations
        case accessVerifications
        case nodeAssociations
        case auditEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = max(decodedSchemaVersion, Self.currentSchemaVersion)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        profiles = try container.decodeIfPresent([WorkspaceDeviceProfile].self, forKey: .profiles) ?? []
        endpoints = try container.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
        services = try container.decodeIfPresent([Service].self, forKey: .services) ?? []
        tailscaleNodes = try container.decodeIfPresent(
            [TailscaleNodeIdentity].self,
            forKey: .tailscaleNodes
        ) ?? []
        tailscaleObservations = try container.decodeIfPresent(
            [TailscaleNodeObservation].self,
            forKey: .tailscaleObservations
        ) ?? []
        var legacyAccountIDMap: [UUID: UUID] = [:]
        if decodedSchemaVersion < 3 {
            let legacyAccounts = try container.decodeIfPresent(
                [LegacySSHAccountV2].self,
                forKey: .sshAccounts
            ) ?? []
            var accountsByID: [UUID: SSHAccount] = [:]
            sshConnectionProfiles = []
            for legacy in legacyAccounts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let accountID = TopologyStableID.sshAccount(
                    nodeID: legacy.nodeID,
                    username: legacy.username
                )
                legacyAccountIDMap[legacy.id] = accountID
                if var existing = accountsByID[accountID] {
                    existing.createdAt = min(existing.createdAt, legacy.createdAt)
                    existing.updatedAt = max(existing.updatedAt, legacy.updatedAt)
                    existing.isDeleted = existing.isDeleted && legacy.isDeleted
                    existing.version = max(existing.version, legacy.version)
                    accountsByID[accountID] = existing
                } else {
                    accountsByID[accountID] = SSHAccount(
                        id: accountID,
                        nodeID: legacy.nodeID,
                        username: legacy.username,
                        createdAt: legacy.createdAt,
                        updatedAt: legacy.updatedAt,
                        isDeleted: legacy.isDeleted,
                        version: legacy.version
                    )
                }
                sshConnectionProfiles.append(SSHConnectionProfile(
                    id: legacy.id,
                    accountID: accountID,
                    sshAlias: legacy.alias,
                    routePolicy: .fixed(endpointID: legacy.endpointID),
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt,
                    isDeleted: legacy.isDeleted,
                    version: legacy.version
                ))
            }
            sshAccounts = accountsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        } else {
            sshAccounts = try container.decodeIfPresent([SSHAccount].self, forKey: .sshAccounts) ?? []
            sshConnectionProfiles = try container.decodeIfPresent(
                [SSHConnectionProfile].self,
                forKey: .sshConnectionProfiles
            ) ?? []
        }
        sshKeys = try container.decodeIfPresent([SSHKey].self, forKey: .sshKeys) ?? []
        hostKeyTrusts = try container.decodeIfPresent([SSHHostKeyTrust].self, forKey: .hostKeyTrusts) ?? []
        authorizations = try container.decodeIfPresent([SSHAuthorization].self, forKey: .authorizations) ?? []
        reachabilityObservations = try container.decodeIfPresent(
            [ReachabilityObservation].self,
            forKey: .reachabilityObservations
        ) ?? []
        accessVerifications = try container.decodeIfPresent(
            [AccessVerification].self,
            forKey: .accessVerifications
        ) ?? []
        if !legacyAccountIDMap.isEmpty {
            authorizations = Self.remapLegacyAuthorizations(
                authorizations,
                accountIDMap: legacyAccountIDMap
            )
            accessVerifications = Self.remapLegacyVerifications(
                accessVerifications,
                profiles: sshConnectionProfiles,
                accountIDMap: legacyAccountIDMap
            )
        }
        nodeAssociations = try container.decodeIfPresent([NodeAssociation].self, forKey: .nodeAssociations) ?? []
        auditEvents = try container.decodeIfPresent([AuditEvent].self, forKey: .auditEvents) ?? []
    }

    fileprivate static func remapLegacyAuthorizations(
        _ values: [SSHAuthorization],
        accountIDMap: [UUID: UUID]
    ) -> [SSHAuthorization] {
        var byID: [String: SSHAuthorization] = [:]
        for var value in values {
            value.accountID = accountIDMap[value.accountID] ?? value.accountID
            if let existing = byID[value.id] {
                byID[value.id] = value.updatedAt >= existing.updatedAt ? value : existing
            } else {
                byID[value.id] = value
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    fileprivate static func remapLegacyVerifications(
        _ values: [AccessVerification],
        profiles: [SSHConnectionProfile],
        accountIDMap: [UUID: UUID]
    ) -> [AccessVerification] {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var byID: [String: AccessVerification] = [:]
        for var value in values {
            let legacyID = value.accountID
            value.accountID = accountIDMap[legacyID] ?? legacyID
            value.profileID = value.profileID ?? profilesByID[legacyID]?.id
            value.endpointID = value.endpointID ?? profilesByID[legacyID]?.routePolicy.fixedEndpointID
            value.transport = value.transport ?? .direct
            if let existing = byID[value.id] {
                let valueDate = value.lastCheckedAt ?? .distantPast
                let existingDate = existing.lastCheckedAt ?? .distantPast
                byID[value.id] = valueDate >= existingDate ? value : existing
            } else {
                byID[value.id] = value
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    public static let empty = Self()

    public var activeNodes: [Node] { nodes.filter { !$0.isDeleted } }
    public var activeEndpoints: [Endpoint] { endpoints.filter { !$0.isDeleted } }
    public var activeAccounts: [SSHAccount] { sshAccounts.filter { !$0.isDeleted } }
    public var activeConnectionProfiles: [SSHConnectionProfile] {
        sshConnectionProfiles.filter { !$0.isDeleted }
    }
    public var activeTailscaleNodes: [TailscaleNodeIdentity] {
        tailscaleNodes.filter { !$0.isDeleted }
    }

    /// Active node-level endpoints owned by a Node.
    public func endpoints(
        for nodeID: UUID,
        endpointProtocol: EndpointProtocol? = nil
    ) -> [Endpoint] {
        activeEndpoints
            .filter {
                $0.nodeID == nodeID
                    && $0.serviceID == nil
                    && (endpointProtocol == nil || $0.protocol == endpointProtocol)
            }
            .sorted {
                ($0.priority, $0.networkScope.rawValue, $0.displayAddress, $0.id.uuidString)
                    < ($1.priority, $1.networkScope.rawValue, $1.displayAddress, $1.id.uuidString)
            }
    }

    /// Active SSH accounts that belong to a Node.
    public func accounts(for nodeID: UUID) -> [SSHAccount] {
        activeAccounts
            .filter { $0.nodeID == nodeID }
            .sorted {
                ($0.label.localizedLowercase, $0.username.localizedLowercase, $0.id.uuidString)
                    < ($1.label.localizedLowercase, $1.username.localizedLowercase, $1.id.uuidString)
            }
    }

    public func connectionProfiles(for accountID: UUID) -> [SSHConnectionProfile] {
        activeConnectionProfiles
            .filter { $0.accountID == accountID }
            .sorted {
                ($0.sshAlias.localizedLowercase, $0.id.uuidString)
                    < ($1.sshAlias.localizedLowercase, $1.id.uuidString)
            }
    }

    public func connectionProfiles(forNodeID nodeID: UUID) -> [SSHConnectionProfile] {
        let accountIDs = Set(accounts(for: nodeID).map(\.id))
        return activeConnectionProfiles
            .filter { accountIDs.contains($0.accountID) }
            .sorted {
                ($0.sshAlias.localizedLowercase, $0.id.uuidString)
                    < ($1.sshAlias.localizedLowercase, $1.id.uuidString)
            }
    }

    public func connectionProfile(id: UUID) -> SSHConnectionProfile? {
        activeConnectionProfiles.first { $0.id == id }
    }

    /// Active external identities currently bound to a Node.
    public func tailscaleIdentities(for nodeID: UUID) -> [TailscaleNodeIdentity] {
        activeTailscaleNodes
            .filter { $0.keyPortNodeID == nodeID }
            .sorted { $0.id < $1.id }
    }

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

    public static func node(forTailscale tailnetKey: String, nodeID: String) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "node/tailscale/\(TailscaleNodeIdentity.normalizeTailnetKey(tailnetKey))/\(nodeID.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
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

    /// Stable ID for a node-level access endpoint.
    ///
    /// Service endpoints historically use `endpoint(...)`. Keeping a separate
    /// namespace lets a node and one of its services share the same address,
    /// port, and protocol without either record being retyped by discovery.
    public static func nodeEndpoint(
        nodeID: UUID,
        address: String,
        port: UInt16,
        protocol: EndpointProtocol
    ) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "node-endpoint/\(nodeID.uuidString.lowercased())/\(normalize(address))/\(port)/\(`protocol`.rawValue)"
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

    public static func sshAccount(nodeID: UUID, username: String) -> UUID {
        uuidV5(
            namespace: namespace,
            name: "ssh-account/\(nodeID.uuidString.lowercased())/\(normalize(username))"
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
        var accountsByID: [UUID: SSHAccount] = [:]
        var connectionProfiles: [SSHConnectionProfile] = []
        var legacyProfileToAccountID: [UUID: UUID] = [:]
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
                let accountID = TopologyStableID.sshAccount(
                    nodeID: nodeID,
                    username: record.username
                )
                legacyProfileToAccountID[record.id] = accountID
                if var account = accountsByID[accountID] {
                    account.createdAt = min(account.createdAt, record.createdAt)
                    account.updatedAt = max(account.updatedAt, record.updatedAt)
                    account.isDeleted = account.isDeleted && record.isDeleted
                    account.version = max(account.version, record.version)
                    accountsByID[accountID] = account
                } else {
                    accountsByID[accountID] = SSHAccount(
                        id: accountID,
                        nodeID: nodeID,
                        username: record.username,
                        createdAt: record.createdAt,
                        updatedAt: record.updatedAt,
                        isDeleted: record.isDeleted,
                        version: record.version
                    )
                }
                connectionProfiles.append(SSHConnectionProfile(
                    id: record.id,
                    accountID: accountID,
                    sshAlias: record.alias,
                    routePolicy: .fixed(endpointID: endpointID),
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    isDeleted: record.isDeleted,
                    version: record.version
                ))
                verifications.append(AccessVerification(
                    accountID: accountID,
                    deviceID: currentDeviceID,
                    profileID: record.id,
                    endpointID: endpointID,
                    transport: .direct,
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
            guard let accountID = legacyProfileToAccountID[authorization.serverID] else { continue }
            authorizations.append(SSHAuthorization(
                accountID: accountID,
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
            let relatedProfiles = connectionProfiles.filter {
                $0.routePolicy.fixedEndpointID == endpoint.id
            }
            value.isDeleted = !relatedProfiles.isEmpty && relatedProfiles.allSatisfy(\.isDeleted)
            return value
        }

        let accounts = accountsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        authorizations = TopologySnapshot.remapLegacyAuthorizations(authorizations, accountIDMap: [:])
        verifications = TopologySnapshot.remapLegacyVerifications(
            verifications,
            profiles: connectionProfiles,
            accountIDMap: [:]
        )

        return TopologySnapshot(
            nodes: nodesByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            profiles: profiles.sorted { $0.id < $1.id },
            endpoints: migratedEndpoints.sorted { $0.id.uuidString < $1.id.uuidString },
            sshAccounts: accounts.sorted { $0.id.uuidString < $1.id.uuidString },
            sshConnectionProfiles: connectionProfiles.sorted { $0.id.uuidString < $1.id.uuidString },
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
        now: Date = .now,
        profileBindings: [SSHConnectionProfileNodeBinding] = []
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
        result.tailscaleNodes = mergeByKey(
            migrated.tailscaleNodes,
            existing.tailscaleNodes,
            by: \.id
        ) { current, previous in
            var value = current
            if value.displayName.isEmpty { value.displayName = previous.displayName }
            if value.hostName == nil { value.hostName = previous.hostName }
            if value.magicDNS == nil { value.magicDNS = previous.magicDNS }
            if value.addresses.isEmpty { value.addresses = previous.addresses }
            if value.operatingSystem == nil { value.operatingSystem = previous.operatingSystem }
            value.updatedAt = max(value.updatedAt, previous.updatedAt)
            value.isDeleted = current.isDeleted && previous.isDeleted
            return value
        }
        // Tailscale observations are local to each observing device and must
        // survive legacy projection refreshes without entering the cloud
        // metadata merge.
        result.tailscaleObservations = mergeByKey(
            [],
            existing.tailscaleObservations,
            by: \.id
        ) { current, _ in current }
        result.sshAccounts = mergeByKey(migrated.sshAccounts, existing.sshAccounts, by: { $0.id.uuidString }) { current, previous in
            var value = current
            if value.label.isEmpty { value.label = previous.label }
            value.createdAt = min(current.createdAt, previous.createdAt)
            value.updatedAt = max(current.updatedAt, previous.updatedAt)
            value.version = max(current.version, previous.version)
            value.isDeleted = current.isDeleted && previous.isDeleted
            return value
        }
        result.sshConnectionProfiles = mergeByKey(
            migrated.sshConnectionProfiles,
            existing.sshConnectionProfiles,
            by: { $0.id.uuidString }
        ) { current, previous in
            var value = current
            let currentUsername = migrated.sshAccounts.first(where: { $0.id == current.accountID })?.username
            let previousUsername = existing.sshAccounts.first(where: { $0.id == previous.accountID })?.username
            if currentUsername == previousUsername {
                value.accountID = previous.accountID
            }
            value.transportPreference = previous.transportPreference
            if let previousEndpointID = previous.routePolicy.fixedEndpointID,
               let currentEndpointID = current.routePolicy.fixedEndpointID,
               let previousEndpoint = existing.endpoint(id: previousEndpointID),
               let currentEndpoint = migrated.endpoint(id: currentEndpointID),
               sameEndpointCoordinate(previousEndpoint, currentEndpoint) {
                value.routePolicy = previous.routePolicy
            } else if case .automatic = previous.routePolicy {
                value.routePolicy = previous.routePolicy
            }
            return value
        }
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
        result.accessVerifications = mergeByKey(
            migrated.accessVerifications,
            existing.accessVerifications,
            by: \.id
        ) { current, previous in
            var value = current
            value.profileID = previous.profileID ?? current.profileID
            value.endpointID = previous.endpointID ?? current.endpointID
            value.transport = previous.transport ?? current.transport
            value.networkEpoch = previous.networkEpoch ?? current.networkEpoch
            return value
        }
        result.nodeAssociations = mergeByKey(migrated.nodeAssociations, existing.nodeAssociations, by: \.id) { current, _ in current }
        result.auditEvents = mergeByKey(migrated.auditEvents, existing.auditEvents, by: { $0.id.uuidString }) { current, _ in current }
        reattachLegacyAccountsToTailscaleNodes(in: &result, preserving: existing)
        applyExplicitProfileBindings(profileBindings, in: &result)
        normalizeAccountIdentities(in: &result)
        removeOrphanedMigratedRecords(from: migrated, in: &result)
        return result
    }

    private static func sameEndpointCoordinate(_ lhs: Endpoint, _ rhs: Endpoint) -> Bool {
        lhs.serviceID == rhs.serviceID
            && lhs.port == rhs.port
            && lhs.protocol == rhs.protocol
            && TopologyStableID.normalize(lhs.address) == TopologyStableID.normalize(rhs.address)
    }

    /// Applies the Node and endpoint selected by the connection editor after
    /// legacy records have been projected. A binding moves one profile; the
    /// account is then coalesced by target Node and username.
    private static func applyExplicitProfileBindings(
        _ bindings: [SSHConnectionProfileNodeBinding],
        in topology: inout TopologySnapshot
    ) {
        for binding in bindings {
            guard let profileIndex = topology.sshConnectionProfiles.firstIndex(where: {
                      $0.id == binding.profileID && !$0.isDeleted
                  }),
                  let sourceAccount = topology.sshAccounts.first(where: {
                      $0.id == topology.sshConnectionProfiles[profileIndex].accountID
                  }),
                  let targetNodeIndex = topology.nodes.firstIndex(where: { $0.id == binding.nodeID && !$0.isDeleted }),
                  let sourceEndpoint = topology.sshConnectionProfiles[profileIndex].routePolicy.fixedEndpointID
                    .flatMap({ topology.endpoint(id: $0) })
                    ?? topology.endpoints(for: sourceAccount.nodeID, endpointProtocol: .ssh).first else {
                continue
            }

            let requestedEndpoint = binding.endpointID.flatMap { endpointID in
                topology.endpoints.first {
                    $0.id == endpointID
                        && !$0.isDeleted
                        && $0.nodeID == binding.nodeID
                        && $0.serviceID == nil
                        && $0.protocol == .ssh
                }
            }
            let matchingEndpoint = requestedEndpoint ?? topology.endpoints.first { endpoint in
                !endpoint.isDeleted
                    && endpoint.nodeID == binding.nodeID
                    && endpoint.serviceID == nil
                    && endpoint.protocol == sourceEndpoint.protocol
                    && endpoint.port == sourceEndpoint.port
                    && TopologyStableID.normalize(endpoint.address)
                        == TopologyStableID.normalize(sourceEndpoint.address)
            }

            let targetEndpointID: UUID
            if let matchingEndpoint {
                targetEndpointID = matchingEndpoint.id
            } else {
                targetEndpointID = TopologyStableID.nodeEndpoint(
                    nodeID: binding.nodeID,
                    address: sourceEndpoint.address,
                    port: sourceEndpoint.port,
                    protocol: sourceEndpoint.protocol
                )
                var movedEndpoint = sourceEndpoint
                movedEndpoint.id = targetEndpointID
                movedEndpoint.nodeID = binding.nodeID
                movedEndpoint.serviceID = nil
                movedEndpoint.isDeleted = false
                if movedEndpoint.source == .migrated {
                    movedEndpoint.source = .manual
                }
                if let existingEndpointIndex = topology.endpoints.firstIndex(where: { $0.id == targetEndpointID }) {
                    topology.endpoints[existingEndpointIndex] = movedEndpoint
                } else {
                    topology.endpoints.append(movedEndpoint)
                }
            }

            if let targetEndpointIndex = topology.endpoints.firstIndex(where: { $0.id == targetEndpointID }) {
                topology.endpoints[targetEndpointIndex].isDeleted = false
                topology.endpoints[targetEndpointIndex].nodeID = binding.nodeID
                topology.endpoints[targetEndpointIndex].serviceID = nil
            }

            let sourceNodeID = sourceAccount.nodeID
            let sourceEndpointID = sourceEndpoint.id
            let targetAccountID = TopologyStableID.sshAccount(
                nodeID: binding.nodeID,
                username: sourceAccount.username
            )
            if let targetAccountIndex = topology.sshAccounts.firstIndex(where: { $0.id == targetAccountID }) {
                topology.sshAccounts[targetAccountIndex].isDeleted = false
                if topology.sshAccounts[targetAccountIndex].label.isEmpty {
                    topology.sshAccounts[targetAccountIndex].label = sourceAccount.label
                }
                topology.sshAccounts[targetAccountIndex].updatedAt = max(
                    topology.sshAccounts[targetAccountIndex].updatedAt,
                    sourceAccount.updatedAt
                )
            } else {
                var targetAccount = sourceAccount
                targetAccount.id = targetAccountID
                targetAccount.nodeID = binding.nodeID
                targetAccount.isDeleted = false
                topology.sshAccounts.append(targetAccount)
            }
            topology.sshConnectionProfiles[profileIndex].accountID = targetAccountID
            topology.sshConnectionProfiles[profileIndex].routePolicy = .fixed(endpointID: targetEndpointID)

            if sourceEndpointID != targetEndpointID,
               let targetEndpoint = topology.endpoints.first(where: { $0.id == targetEndpointID }),
               sameEndpointCoordinate(sourceEndpoint, targetEndpoint) {
                moveHostKeyTrusts(
                    from: sourceEndpointID,
                    to: targetEndpointID,
                    in: &topology
                )
            }

            var targetNode = topology.nodes[targetNodeIndex]
            targetNode.roles = Array(Set(targetNode.roles + [.sshHost])).sorted { $0.rawValue < $1.rawValue }
            if sourceNodeID != binding.nodeID,
               let sourceNode = topology.nodes.first(where: { $0.id == sourceNodeID }) {
                if targetNode.name.isEmpty { targetNode.name = sourceNode.name }
                if targetNode.group.isEmpty { targetNode.group = sourceNode.group }
                if targetNode.notes.isEmpty { targetNode.notes = sourceNode.notes }
                if targetNode.machineConfiguration == nil {
                    targetNode.machineConfiguration = sourceNode.machineConfiguration
                }
                targetNode.createdAt = min(targetNode.createdAt, sourceNode.createdAt)
                targetNode.updatedAt = max(targetNode.updatedAt, sourceNode.updatedAt)
            }
            targetNode.isDeleted = false
            topology.nodes[targetNodeIndex] = targetNode
        }
    }

    private static func moveHostKeyTrusts(
        from sourceEndpointID: UUID,
        to targetEndpointID: UUID,
        in topology: inout TopologySnapshot
    ) {
        for trustIndex in topology.hostKeyTrusts.indices where topology.hostKeyTrusts[trustIndex].endpointID == sourceEndpointID {
            let trust = topology.hostKeyTrusts[trustIndex]
            let duplicate = topology.hostKeyTrusts.indices.contains { index in
                index != trustIndex
                    && topology.hostKeyTrusts[index].endpointID == targetEndpointID
                    && topology.hostKeyTrusts[index].algorithm == trust.algorithm
                    && topology.hostKeyTrusts[index].fingerprint == trust.fingerprint
                    && !topology.hostKeyTrusts[index].isDeleted
            }
            if duplicate {
                topology.hostKeyTrusts[trustIndex].isDeleted = true
            } else {
                topology.hostKeyTrusts[trustIndex].endpointID = targetEndpointID
                topology.hostKeyTrusts[trustIndex].id = TopologyStableID.hostKeyTrust(
                    endpointID: targetEndpointID,
                    algorithm: trust.algorithm,
                    fingerprint: trust.fingerprint
                )
            }
        }
    }

    /// Enforces the canonical account identity `(Node, normalized username)`
    /// after imports and explicit profile moves, then rewrites account-level
    /// authorization and local verification references exactly once.
    private static func normalizeAccountIdentities(in topology: inout TopologySnapshot) {
        var accountIDMap: [UUID: UUID] = [:]
        var accountsByID: [UUID: SSHAccount] = [:]
        for account in topology.sshAccounts {
            let canonicalID = TopologyStableID.sshAccount(
                nodeID: account.nodeID,
                username: account.username
            )
            accountIDMap[account.id] = canonicalID
            var value = account
            value.id = canonicalID
            if var existing = accountsByID[canonicalID] {
                if existing.label.isEmpty { existing.label = value.label }
                existing.createdAt = min(existing.createdAt, value.createdAt)
                existing.updatedAt = max(existing.updatedAt, value.updatedAt)
                existing.version = max(existing.version, value.version)
                existing.isDeleted = existing.isDeleted && value.isDeleted
                accountsByID[canonicalID] = existing
            } else {
                accountsByID[canonicalID] = value
            }
        }
        for index in topology.sshConnectionProfiles.indices {
            topology.sshConnectionProfiles[index].accountID = accountIDMap[
                topology.sshConnectionProfiles[index].accountID
            ] ?? topology.sshConnectionProfiles[index].accountID
        }
        topology.sshAccounts = accountsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        topology.authorizations = TopologySnapshot.remapLegacyAuthorizations(
            topology.authorizations,
            accountIDMap: accountIDMap
        )
        topology.accessVerifications = TopologySnapshot.remapLegacyVerifications(
            topology.accessVerifications,
            profiles: topology.sshConnectionProfiles,
            accountIDMap: accountIDMap
        )
    }

    /// A legacy projection can temporarily recreate the old address-owned
    /// Node after an account has already been attached to a Node. Tombstone
    /// that generated shell only when no active fact still depends on it.
    /// Account-only records that never came from the legacy projection must
    /// survive until the user creates their first connection profile.
    private static func removeOrphanedMigratedRecords(
        from migrated: TopologySnapshot,
        in topology: inout TopologySnapshot
    ) {
        let referencedAccountIDs = Set(topology.activeConnectionProfiles.map(\.accountID))
        let migratedNodeIDs = Set(migrated.activeAccounts.map(\.nodeID))
        let migratedAccountIDs = Set(migrated.sshAccounts.map(\.id))

        for accountIndex in topology.sshAccounts.indices
            where migratedAccountIDs.contains(topology.sshAccounts[accountIndex].id)
                && !referencedAccountIDs.contains(topology.sshAccounts[accountIndex].id) {
            topology.sshAccounts[accountIndex].isDeleted = true
        }

        for sourceNodeID in migratedNodeIDs {
            let migratedEndpointIDs = Set(migrated.endpoints(for: sourceNodeID, endpointProtocol: .ssh).map(\.id))
            for endpointIndex in topology.endpoints.indices
                where migratedEndpointIDs.contains(topology.endpoints[endpointIndex].id) {
                let endpoint = topology.endpoints[endpointIndex]
                if !profileUsesEndpoint(endpoint, in: topology) {
                    topology.endpoints[endpointIndex].isDeleted = true
                }
            }

            let hasAccounts = topology.activeAccounts.contains { $0.nodeID == sourceNodeID }
            let hasServices = topology.services.contains { $0.nodeID == sourceNodeID && !$0.isDeleted }
            let hasEndpoints = topology.activeEndpoints.contains { $0.nodeID == sourceNodeID }
            if !hasAccounts && !hasServices && !hasEndpoints,
               let nodeIndex = topology.nodes.firstIndex(where: { $0.id == sourceNodeID }) {
                topology.nodes[nodeIndex].isDeleted = true
            }
        }
    }

    private static func profileUsesEndpoint(
        _ endpoint: Endpoint,
        in topology: TopologySnapshot
    ) -> Bool {
        let accountsByID = Dictionary(uniqueKeysWithValues: topology.activeAccounts.map { ($0.id, $0) })
        return topology.activeConnectionProfiles.contains { profile in
            guard let account = accountsByID[profile.accountID], account.nodeID == endpoint.nodeID else {
                return false
            }
            switch profile.routePolicy {
            case .fixed(let endpointID):
                return endpointID == endpoint.id
            case .automatic(let scope):
                return scope == nil || scope == endpoint.networkScope
            }
        }
    }

    /// Reconnects a legacy SSH account to a Tailscale-backed Node when the
    /// account's node-level SSH address is an exact, unique Tailscale match.
    /// Public DNS/IP addresses deliberately do not participate in this step.
    private static func reattachLegacyAccountsToTailscaleNodes(
        in topology: inout TopologySnapshot,
        preserving existing: TopologySnapshot
    ) {
        let identities = existing.activeTailscaleNodes.filter { identity in
            topology.nodes.contains { $0.id == identity.keyPortNodeID && !$0.isDeleted }
        }
        guard !identities.isEmpty else { return }

        let targetNodeIDs = Set(identities.map(\.keyPortNodeID))
        let sourceNodeIDs = Set(topology.activeAccounts.map(\.nodeID))
            .subtracting(targetNodeIDs)
            .sorted { $0.uuidString < $1.uuidString }

        for sourceNodeID in sourceNodeIDs {
            let sourceEndpoints = topology.activeEndpoints.filter {
                $0.nodeID == sourceNodeID
                    && $0.serviceID == nil
                    && $0.protocol == .ssh
            }
            guard !sourceEndpoints.isEmpty,
                  !topology.services.contains(where: { $0.nodeID == sourceNodeID && !$0.isDeleted }) else {
                continue
            }

            let candidateNodeIDs = Set(sourceEndpoints.flatMap { endpoint in
                identities
                    .filter { $0.matches(host: endpoint.address) }
                    .map(\.keyPortNodeID)
            })
            guard candidateNodeIDs.count == 1,
                  let targetNodeID = candidateNodeIDs.first,
                  targetNodeID != sourceNodeID,
                  topology.nodes.contains(where: { $0.id == targetNodeID && !$0.isDeleted }) else {
                continue
            }

            var endpointRemaps: [UUID: UUID] = [:]
            for endpoint in sourceEndpoints {
                let targetEndpointID = topology.activeEndpoints.first(where: { candidate in
                    candidate.nodeID == targetNodeID
                        && candidate.serviceID == nil
                        && candidate.protocol == endpoint.protocol
                        && candidate.port == endpoint.port
                        && TailscaleHostIdentity.normalize(candidate.address)
                            == TailscaleHostIdentity.normalize(endpoint.address)
                })?.id ?? TopologyStableID.nodeEndpoint(
                    nodeID: targetNodeID,
                    address: endpoint.address,
                    port: endpoint.port,
                    protocol: endpoint.protocol
                )

                endpointRemaps[endpoint.id] = targetEndpointID
                if !topology.endpoints.contains(where: { $0.id == targetEndpointID }) {
                    var movedEndpoint = endpoint
                    movedEndpoint.id = targetEndpointID
                    movedEndpoint.nodeID = targetNodeID
                    if identities.contains(where: { $0.keyPortNodeID == targetNodeID && $0.matches(host: endpoint.address) }) {
                        movedEndpoint.networkScope = .tailnet
                        if movedEndpoint.source == .migrated {
                            movedEndpoint.source = .tailscale
                        }
                    }
                    topology.endpoints.append(movedEndpoint)
                }
            }

            let sourceAccountIDs = Set(topology.sshAccounts
                .filter { $0.nodeID == sourceNodeID && !$0.isDeleted }
                .map(\.id))
            for accountIndex in topology.sshAccounts.indices
                where sourceAccountIDs.contains(topology.sshAccounts[accountIndex].id) {
                topology.sshAccounts[accountIndex].nodeID = targetNodeID
            }
            for profileIndex in topology.sshConnectionProfiles.indices
                where sourceAccountIDs.contains(topology.sshConnectionProfiles[profileIndex].accountID) {
                guard let sourceEndpointID = topology.sshConnectionProfiles[profileIndex].routePolicy.fixedEndpointID,
                      let targetEndpointID = endpointRemaps[sourceEndpointID] else {
                    continue
                }
                topology.sshConnectionProfiles[profileIndex].routePolicy = .fixed(endpointID: targetEndpointID)
            }

            for trustIndex in topology.hostKeyTrusts.indices {
                guard let targetEndpointID = endpointRemaps[topology.hostKeyTrusts[trustIndex].endpointID] else {
                    continue
                }
                let trust = topology.hostKeyTrusts[trustIndex]
                let duplicate = topology.hostKeyTrusts.indices.contains { index in
                    index != trustIndex
                        && topology.hostKeyTrusts[index].endpointID == targetEndpointID
                        && topology.hostKeyTrusts[index].algorithm == trust.algorithm
                        && topology.hostKeyTrusts[index].fingerprint == trust.fingerprint
                        && !topology.hostKeyTrusts[index].isDeleted
                }
                if duplicate {
                    topology.hostKeyTrusts[trustIndex].isDeleted = true
                } else {
                    topology.hostKeyTrusts[trustIndex].endpointID = targetEndpointID
                    topology.hostKeyTrusts[trustIndex].id = TopologyStableID.hostKeyTrust(
                        endpointID: targetEndpointID,
                        algorithm: trust.algorithm,
                        fingerprint: trust.fingerprint
                    )
                }
            }

            for endpointIndex in topology.endpoints.indices
                where topology.endpoints[endpointIndex].nodeID == sourceNodeID
                    && topology.endpoints[endpointIndex].serviceID == nil
                    && topology.endpoints[endpointIndex].protocol == .ssh {
                topology.endpoints[endpointIndex].isDeleted = true
            }

            if let sourceIndex = topology.nodes.firstIndex(where: { $0.id == sourceNodeID }),
               let targetIndex = topology.nodes.firstIndex(where: { $0.id == targetNodeID }) {
                let source = topology.nodes[sourceIndex]
                var target = topology.nodes[targetIndex]
                target.roles = Array(Set(target.roles + source.roles)).sorted { $0.rawValue < $1.rawValue }
                if target.name.isEmpty { target.name = source.name }
                if target.group.isEmpty { target.group = source.group }
                if target.notes.isEmpty { target.notes = source.notes }
                if target.machineConfiguration == nil {
                    target.machineConfiguration = source.machineConfiguration
                }
                target.createdAt = min(target.createdAt, source.createdAt)
                target.updatedAt = max(target.updatedAt, source.updatedAt)
                target.isDeleted = false
                if !target.roles.contains(.sshHost) {
                    target.roles.append(.sshHost)
                    target.roles.sort { $0.rawValue < $1.rawValue }
                }
                topology.nodes[targetIndex] = target
                topology.nodes[sourceIndex].isDeleted = true
            }
        }

        topology.nodes.sort { $0.id.uuidString < $1.id.uuidString }
        topology.endpoints.sort { $0.id.uuidString < $1.id.uuidString }
        topology.sshAccounts.sort { $0.id.uuidString < $1.id.uuidString }
        topology.sshConnectionProfiles.sort { $0.id.uuidString < $1.id.uuidString }
        topology.hostKeyTrusts.sort { $0.id.uuidString < $1.id.uuidString }
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
        let accountsByID = Dictionary(uniqueKeysWithValues: topology.sshAccounts.map { ($0.id, $0) })
        let verificationsByAccountID = Dictionary(
            grouping: topology.accessVerifications.filter { $0.deviceID == currentDeviceID },
            by: \.accountID
        )
        let trustByEndpoint = Dictionary(grouping: topology.hostKeyTrusts.filter { !$0.isDeleted }, by: \.endpointID)

        snapshot.servers = topology.sshConnectionProfiles.compactMap { profile in
            guard let account = accountsByID[profile.accountID],
                  let node = nodesByID[account.nodeID] else { return nil }
            let endpoint: Endpoint?
            switch profile.routePolicy {
            case .fixed(let endpointID):
                endpoint = endpointsByID[endpointID]
            case .automatic(let scope):
                endpoint = topology.endpoints
                    .filter {
                        $0.nodeID == account.nodeID
                            && $0.serviceID == nil
                            && $0.protocol == .ssh
                            && !$0.isDeleted
                            && (scope == nil || $0.networkScope == scope)
                    }
                    .sorted {
                        ($0.priority, $0.id.uuidString) < ($1.priority, $1.id.uuidString)
                    }
                    .first
            }
            guard let endpoint else { return nil }
            let verification = verificationsByAccountID[account.id]?
                .sorted {
                    let lhsMatches = $0.profileID == profile.id
                    let rhsMatches = $1.profileID == profile.id
                    if lhsMatches != rhsMatches { return lhsMatches }
                    return ($0.lastCheckedAt ?? .distantPast) > ($1.lastCheckedAt ?? .distantPast)
                }
                .first
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
                id: profile.id,
                name: node.name,
                host: endpoint.address,
                port: Int(endpoint.port),
                username: account.username,
                alias: profile.sshAlias,
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
                createdAt: profile.createdAt,
                updatedAt: max(account.updatedAt, profile.updatedAt),
                isDeleted: account.isDeleted || profile.isDeleted,
                version: max(account.version, profile.version)
            )
        }
        let profilesByAccountID = Dictionary(grouping: topology.sshConnectionProfiles, by: \.accountID)
        snapshot.authorizations = topology.authorizations.flatMap { authorization in
            (profilesByAccountID[authorization.accountID] ?? []).map { profile in
                Authorization(
                    serverID: profile.id,
                    keyID: authorization.keyID,
                    fingerprint: authorization.fingerprint,
                    remoteComment: authorization.remoteComment,
                    status: authorization.remoteState == .authorized ? .authorized : .needsAuthorization,
                    authorizedAt: authorization.authorizedAt,
                    lastVerifiedAt: authorization.lastVerifiedAt,
                    updatedAt: authorization.updatedAt,
                    isDeleted: authorization.isDeleted || profile.isDeleted,
                    version: 1
                )
            }
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
