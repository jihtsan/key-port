import Foundation

public struct TopologyGraphNodeID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static func device(_ id: String) -> Self {
        Self(rawValue: "device:\(id)")
    }

    public static func host(_ id: UUID) -> Self {
        Self(rawValue: "host:\(id.uuidString.lowercased())")
    }

    public static func sshAccount(_ id: UUID) -> Self {
        Self(rawValue: "ssh-account:\(id.uuidString.lowercased())")
    }

    public static func service(_ id: UUID) -> Self {
        Self(rawValue: "service:\(id.uuidString.lowercased())")
    }

    public static func actualNode(_ reference: ActualNodeReference) -> Self {
        Self(rawValue: "actual-node:\(reference.id)")
    }
}

public enum TopologyGraphNodeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case device
    case host
    case sshAccount
    case service
    case actualNode
}

public enum TopologyGraphEdgeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case deviceAccess
    case candidateAccess
    case hostService
    case sshAccountActualNode
}

public enum TopologyGraphStatusLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case healthy
    case pending
    case unavailable
    case blocked
    case unknown
}

public enum TopologyGraphReachability: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case reachable
    case unreachable
}

public enum TopologyGraphHostTrust: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case trusted
    case pending
    case mismatch
}

public enum TopologyGraphRouteStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case available
    case unavailable
    case conflict
}

public enum TopologyGraphLocalKeyStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case available
    case agentOnly
    case missing
    case revoked
}

public enum TopologyGraphRemoteAuthorization: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case authorized
    case revoked
    case detached
}

public enum TopologyGraphVerificationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case succeeded
    case failed
    case checking
}

public enum TopologyGraphSyncStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case clean
    case conflict
    case canary
    case readOnly
    case compatibilityRollback
}

public enum TopologyGraphReason: String, Codable, CaseIterable, Hashable, Sendable {
    case hostDeleted
    case hostKeyPending
    case hostKeyMismatch
    case mergeReview
    case noRoute
    case routeConflict
    case unreachable
    case missingLocalKey
    case remoteAuthorizationPending
    case remoteAuthorizationRevoked
    case verificationPending
    case verificationFailed
    case candidateAccess
    case nodeAssociationReview
    case nodeAssociationInvalid
    case canary
    case readOnly
    case compatibilityRollback
}

public struct TopologyGraphStatus: Codable, Hashable, Sendable {
    public let level: TopologyGraphStatusLevel
    public let reachability: TopologyGraphReachability
    public let hostTrust: TopologyGraphHostTrust
    public let route: TopologyGraphRouteStatus
    public let localKey: TopologyGraphLocalKeyStatus
    public let remoteAuthorization: TopologyGraphRemoteAuthorization
    public let verification: TopologyGraphVerificationStatus
    public let sync: TopologyGraphSyncStatus
    public let reasons: [TopologyGraphReason]

    public init(
        reachability: TopologyGraphReachability = .unknown,
        hostTrust: TopologyGraphHostTrust = .unknown,
        route: TopologyGraphRouteStatus = .unknown,
        localKey: TopologyGraphLocalKeyStatus = .unknown,
        remoteAuthorization: TopologyGraphRemoteAuthorization = .unknown,
        verification: TopologyGraphVerificationStatus = .unknown,
        sync: TopologyGraphSyncStatus = .readOnly,
        reasons: [TopologyGraphReason] = []
    ) {
        self.reachability = reachability
        self.hostTrust = hostTrust
        self.route = route
        self.localKey = localKey
        self.remoteAuthorization = remoteAuthorization
        self.verification = verification
        self.sync = sync
        self.reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        self.level = Self.level(
            reachability: reachability,
            hostTrust: hostTrust,
            route: route,
            localKey: localKey,
            remoteAuthorization: remoteAuthorization,
            verification: verification,
            sync: sync,
            reasons: self.reasons
        )
    }

    public static let unknown = Self()

    private static func level(
        reachability: TopologyGraphReachability,
        hostTrust: TopologyGraphHostTrust,
        route: TopologyGraphRouteStatus,
        localKey: TopologyGraphLocalKeyStatus,
        remoteAuthorization: TopologyGraphRemoteAuthorization,
        verification: TopologyGraphVerificationStatus,
        sync: TopologyGraphSyncStatus,
        reasons: [TopologyGraphReason]
    ) -> TopologyGraphStatusLevel {
        let blockingReasons: Set<TopologyGraphReason> = [
            .hostDeleted,
            .hostKeyMismatch,
            .mergeReview,
            .routeConflict,
            .verificationFailed,
            .nodeAssociationInvalid,
        ]
        if !blockingReasons.isDisjoint(with: reasons) || sync == .conflict {
            return .blocked
        }

        let unavailableReasons: Set<TopologyGraphReason> = [
            .noRoute,
            .unreachable,
            .missingLocalKey,
            .remoteAuthorizationRevoked,
        ]
        if !unavailableReasons.isDisjoint(with: reasons)
            || route == .unavailable
            || localKey == .revoked
            || remoteAuthorization == .revoked {
            return .unavailable
        }

        let pendingReasons: Set<TopologyGraphReason> = [
            .hostKeyPending,
            .remoteAuthorizationPending,
            .verificationPending,
            .candidateAccess,
            .nodeAssociationReview,
        ]
        if !pendingReasons.isDisjoint(with: reasons)
            || hostTrust == .pending
            || verification == .checking {
            return .pending
        }

        let hasEvidence = reachability != .unknown
            || hostTrust != .unknown
            || route != .unknown
            || localKey != .unknown
            || remoteAuthorization != .unknown
            || verification != .unknown
            || sync == .clean
        return hasEvidence ? .healthy : .unknown
    }

}

public struct TopologyGraphNode: Identifiable, Codable, Hashable, Sendable {
    public let id: TopologyGraphNodeID
    public let kind: TopologyGraphNodeKind
    public let title: String
    public let subtitle: String?
    public let status: TopologyGraphStatus
    public let source: HostV6.EntityReference?
    public let supportingReferences: [HostV6.EntityReference]

    public init(
        id: TopologyGraphNodeID,
        kind: TopologyGraphNodeKind,
        title: String,
        subtitle: String? = nil,
        status: TopologyGraphStatus = .unknown,
        source: HostV6.EntityReference? = nil,
        supportingReferences: [HostV6.EntityReference] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.source = source
        self.supportingReferences = supportingReferences.sorted(by: Self.sortReferences)
    }

    private static func sortReferences(
        _ left: HostV6.EntityReference,
        _ right: HostV6.EntityReference
    ) -> Bool {
        let leftKey = "\(left.entityType.rawValue):\(left.stableID)"
        let rightKey = "\(right.entityType.rawValue):\(right.stableID)"
        return leftKey < rightKey
    }
}

public struct TopologyGraphEdge: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let from: TopologyGraphNodeID
    public let to: TopologyGraphNodeID
    public let kind: TopologyGraphEdgeKind
    public let label: String
    public let isCandidate: Bool
    public let status: TopologyGraphStatus
    public let supportingReferences: [HostV6.EntityReference]

    public init(
        id: String,
        from: TopologyGraphNodeID,
        to: TopologyGraphNodeID,
        kind: TopologyGraphEdgeKind,
        label: String,
        isCandidate: Bool = false,
        status: TopologyGraphStatus = .unknown,
        supportingReferences: [HostV6.EntityReference] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.label = label
        self.isCandidate = isCandidate
        self.status = status
        self.supportingReferences = supportingReferences.sorted {
            "\($0.entityType.rawValue):\($0.stableID)" < "\($1.entityType.rawValue):\($1.stableID)"
        }
    }
}

public struct TopologyGraphDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let code: HostV6.InvariantViolation.Code
    public let subject: HostV6.EntityReference
    public let referenced: HostV6.EntityReference?

    public init(
        code: HostV6.InvariantViolation.Code,
        subject: HostV6.EntityReference,
        referenced: HostV6.EntityReference?
    ) {
        self.code = code
        self.subject = subject
        self.referenced = referenced
        let referencedID = referenced?.stableID ?? ""
        self.id = "\(code.rawValue):\(subject.entityType.rawValue):\(subject.stableID):\(referencedID)"
    }
}

public struct TopologyGraphQuery: Codable, Hashable, Sendable {
    public enum ViewMode: String, Codable, CaseIterable, Hashable, Sendable {
        case currentDevice
        case allDevices
        case services
    }

    public var viewMode: ViewMode
    public var searchText: String
    public var onlyIssues: Bool
    public var includesSupportingNodes: Bool
    public var includesActualNodes: Bool
    public var showsServices: Bool

    public init(
        viewMode: ViewMode = .currentDevice,
        searchText: String = "",
        onlyIssues: Bool = false,
        includesSupportingNodes: Bool = false,
        includesActualNodes: Bool = false,
        showsServices: Bool = true
    ) {
        self.viewMode = viewMode
        self.searchText = searchText
        self.onlyIssues = onlyIssues
        self.includesSupportingNodes = includesSupportingNodes
        self.includesActualNodes = includesActualNodes
        self.showsServices = showsServices
    }
}

public struct TopologyGraphSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let currentDeviceID: String?
    public let authorityMode: HostV6.AuthorityMode?
    public let query: TopologyGraphQuery
    public let nodes: [TopologyGraphNode]
    public let edges: [TopologyGraphEdge]
    public let diagnostics: [TopologyGraphDiagnostic]

    public init(
        schemaVersion: Int = 1,
        currentDeviceID: String?,
        authorityMode: HostV6.AuthorityMode?,
        query: TopologyGraphQuery,
        nodes: [TopologyGraphNode],
        edges: [TopologyGraphEdge],
        diagnostics: [TopologyGraphDiagnostic] = []
    ) {
        self.schemaVersion = schemaVersion
        self.currentDeviceID = currentDeviceID
        self.authorityMode = authorityMode
        self.query = query
        self.nodes = nodes
        self.edges = edges
        self.diagnostics = diagnostics.sorted { $0.id < $1.id }
    }

    public static let empty = Self(
        currentDeviceID: nil,
        authorityMode: nil,
        query: TopologyGraphQuery(),
        nodes: [],
        edges: []
    )

    public func applying(_ query: TopologyGraphQuery) -> Self {
        let visibleKinds: Set<TopologyGraphNodeKind>
        switch query.viewMode {
        case .currentDevice, .allDevices:
            visibleKinds = Set([
                .device,
                .host,
                query.showsServices ? .service : nil,
                query.includesSupportingNodes ? .sshAccount : nil,
                query.includesSupportingNodes && query.includesActualNodes ? .actualNode : nil,
            ].compactMap { $0 })
        case .services:
            visibleKinds = Set([
                .host,
                query.showsServices ? .service : nil,
                query.includesSupportingNodes ? .sshAccount : nil,
                query.includesSupportingNodes && query.includesActualNodes ? .actualNode : nil,
            ].compactMap { $0 })
        }

        var ids = Set(nodes.filter { visibleKinds.contains($0.kind) }.map(\.id))
        if query.viewMode == .currentDevice {
            if let currentDeviceID {
                let currentDeviceNodeID = TopologyGraphNodeID.device(currentDeviceID)
                ids = ids.filter { !$0.rawValue.hasPrefix("device:") || $0 == currentDeviceNodeID }

                if query.includesSupportingNodes {
                    let currentDeviceEdges = edges.filter {
                        $0.from == currentDeviceNodeID || $0.to == currentDeviceNodeID
                    }
                    let accountIDs = Set(currentDeviceEdges.flatMap { edge in
                        edge.supportingReferences.compactMap { reference -> TopologyGraphNodeID? in
                            guard case .sshIdentity(let identityID) = reference else { return nil }
                            return .sshAccount(identityID)
                        }
                    })
                    ids = ids.filter { nodeID in
                        !nodeID.rawValue.hasPrefix("ssh-account:") || accountIDs.contains(nodeID)
                    }
                    let actualNodeIDs = Set(edges.filter {
                        $0.kind == .sshAccountActualNode && accountIDs.contains($0.from)
                    }.map(\.to))
                    ids = ids.filter { nodeID in
                        !nodeID.rawValue.hasPrefix("actual-node:") || actualNodeIDs.contains(nodeID)
                    }
                } else {
                    ids = ids.filter { !$0.rawValue.hasPrefix("device:") || $0 == currentDeviceNodeID }
                }
            } else {
                ids = ids.filter { !$0.rawValue.hasPrefix("device:") }
                if query.includesSupportingNodes {
                    ids = ids.filter {
                        !$0.rawValue.hasPrefix("ssh-account:") && !$0.rawValue.hasPrefix("actual-node:")
                    }
                }
            }
        }

        let normalizedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        if !normalizedSearch.isEmpty {
            let matches = Set(nodes.filter { node in
                node.title.localizedLowercase.contains(normalizedSearch)
                    || node.subtitle?.localizedLowercase.contains(normalizedSearch) == true
            }.map(\.id))
            ids = contextIDs(for: matches, within: ids)
        }

        if query.onlyIssues {
            let issueIDs = Set(nodes.filter { node in
                switch node.status.level {
                case .healthy, .unknown: return false
                case .pending, .unavailable, .blocked: return true
                }
            }.map(\.id))
            ids = contextIDs(for: issueIDs, within: ids)
        }

        let filteredNodes = nodes
            .filter { ids.contains($0.id) }
            .sorted(by: Self.sortNodes)
        let filteredEdges = edges
            .filter { ids.contains($0.from) && ids.contains($0.to) }
            .sorted { $0.id < $1.id }
        return Self(
            schemaVersion: schemaVersion,
            currentDeviceID: currentDeviceID,
            authorityMode: authorityMode,
            query: query,
            nodes: filteredNodes,
            edges: filteredEdges,
            diagnostics: diagnostics
        )
    }

    private func contextIDs(
        for matches: Set<TopologyGraphNodeID>,
        within ids: Set<TopologyGraphNodeID>
    ) -> Set<TopologyGraphNodeID> {
        guard !matches.isEmpty else { return [] }
        var result = matches.intersection(ids)
        for edge in edges where matches.contains(edge.from) || matches.contains(edge.to) {
            if ids.contains(edge.from) { result.insert(edge.from) }
            if ids.contains(edge.to) { result.insert(edge.to) }
        }
        return result
    }

    private static func sortNodes(_ left: TopologyGraphNode, _ right: TopologyGraphNode) -> Bool {
        let kindOrder: [TopologyGraphNodeKind: Int] = [
            .device: 0,
            .host: 1,
            .sshAccount: 2,
            .service: 3,
            .actualNode: 4,
        ]
        let leftKey = (kindOrder[left.kind, default: 99], left.title.localizedLowercase, left.id.rawValue)
        let rightKey = (kindOrder[right.kind, default: 99], right.title.localizedLowercase, right.id.rawValue)
        return leftKey < rightKey
    }
}
