import Foundation

public struct ActualNodeReference: Codable, Hashable, Sendable {
    public let provider: String
    public let tailnetKey: String
    public let nodeID: String

    public init(provider: String = "tailscale", tailnetKey: String, nodeID: String) {
        self.provider = provider
        self.tailnetKey = Self.normalizeTailnetKey(tailnetKey)
        self.nodeID = nodeID
    }

    public var id: String { "\(provider):\(tailnetKey):\(nodeID)" }

    public static func normalizeTailnetKey(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }
}

public enum LogicalNodeName {
    public static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }
}

public enum NodeAssociationState: String, Codable, CaseIterable, Sendable {
    case unlinked
    case pendingConfirmation = "pending_confirmation"
    case linked
    case reviewRequired = "review_required"
    case invalidated
}

public enum NodeAssociationMethod: String, Codable, Sendable {
    case automatic = "auto"
    case manual
}

public enum NodeAssociationEvidence: String, Codable, CaseIterable, Sendable {
    case exactLogicalName = "exact_logical_name"
    case exactMagicDNS = "exact_magicdns"
    case exactTailscaleIP = "exact_tailscale_ip"
}

public enum NodeAssociationReason: String, Codable, CaseIterable, Sendable {
    case noMatch = "no_match"
    case multipleStrongMatches = "multiple_strong_matches"
    case weakEvidenceOnly = "weak_evidence_only"
    case proxiedRoute = "proxied_route"
    case sourceUnavailable = "source_unavailable"
    case unstableTargetIdentity = "unstable_target_identity"
    case nodeMissing = "node_missing"
    case nodeIdentityChanged = "node_identity_changed"
    case hostKeyChanged = "host_key_changed"
    case endpointConflict = "endpoint_conflict"
    case logicalNameChanged = "logical_name_changed"
    case manuallyUnlinked = "manually_unlinked"
}

public struct NodeAssociation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { testCaseNodeID }
    public let testCaseNodeID: String
    public let serverID: UUID
    public var target: ActualNodeReference?
    public var state: NodeAssociationState
    public var method: NodeAssociationMethod?
    public var autoLinkEnabled: Bool
    public var evidenceKinds: [NodeAssociationEvidence]
    public var reasonCodes: [NodeAssociationReason]
    public var confirmedAt: Date?
    public var lastVerifiedAt: Date?
    public var updatedAt: Date
    public var revision: Int

    public init(
        testCaseNodeID: String,
        serverID: UUID,
        target: ActualNodeReference? = nil,
        state: NodeAssociationState = .unlinked,
        method: NodeAssociationMethod? = nil,
        autoLinkEnabled: Bool = true,
        evidenceKinds: [NodeAssociationEvidence] = [],
        reasonCodes: [NodeAssociationReason] = [],
        confirmedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.testCaseNodeID = LogicalNodeName.normalize(testCaseNodeID)
        self.serverID = serverID
        self.target = target
        self.state = state
        self.method = method
        self.autoLinkEnabled = autoLinkEnabled
        self.evidenceKinds = evidenceKinds
        self.reasonCodes = reasonCodes
        self.confirmedAt = confirmedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public var allowsExecution: Bool {
        state == .linked && target != nil
    }
}

public struct EffectiveSSHRoute: Hashable, Sendable {
    public let hostname: String
    public let proxyJump: String?
    public let proxyCommand: String?

    public init(hostname: String, proxyJump: String? = nil, proxyCommand: String? = nil) {
        self.hostname = hostname
        self.proxyJump = proxyJump
        self.proxyCommand = proxyCommand
    }

    public var isDirect: Bool {
        Self.isDisabled(proxyJump) && Self.isDisabled(proxyCommand)
    }

    private static func isDisabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return true
        }
        return value.lowercased() == "none"
    }
}

public enum NodeAssociationSourceState: Sendable {
    case complete
    case unavailable
}

public struct NodeAssociationCandidate: Identifiable, Hashable, Sendable {
    public let target: ActualNodeReference
    public let node: TailscaleNode
    public let evidenceKinds: [NodeAssociationEvidence]
    public var id: String { target.id }
}

public struct NodeAssociationEvaluation: Sendable {
    public let association: NodeAssociation
    public let candidates: [NodeAssociationCandidate]
}

public struct LogicalNameMatchContext: Hashable, Sendable {
    public let serverName: String
    public let matchingServerCount: Int

    public init(serverName: String, matchingServerCount: Int) {
        self.serverName = serverName
        self.matchingServerCount = matchingServerCount
    }
}

public enum NodeAssociationMutationError: LocalizedError, Equatable, Sendable {
    case invalidTestCaseNodeID
    case invalidTarget
    case serverConflict
    case revisionConflict(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidTestCaseNodeID: "Test Case 节点 ID 不能为空。"
        case .invalidTarget: "所选节点缺少稳定的 Tailscale nodeId 或 tailnet 标识。"
        case .serverConflict: "此 Test Case 节点已关联到另一个 SSH 账户。"
        case .revisionConflict: "关联记录已在其他位置更新，请刷新后重试。"
        }
    }
}

public enum NodeAssociationEngine {
    public static func evaluate(
        testCaseNodeID: String,
        serverID: UUID,
        route: EffectiveSSHRoute,
        status: TailscaleStatus?,
        sourceState: NodeAssociationSourceState,
        logicalNameContext: LogicalNameMatchContext? = nil,
        existing: NodeAssociation? = nil,
        hostKeyChanged: Bool = false,
        now: Date = .now
    ) throws -> NodeAssociationEvaluation {
        let logicalID = LogicalNodeName.normalize(testCaseNodeID)
        guard !logicalID.isEmpty else { throw NodeAssociationMutationError.invalidTestCaseNodeID }

        var association = existing ?? NodeAssociation(testCaseNodeID: logicalID, serverID: serverID, updatedAt: now)
        guard association.serverID == serverID else { throw NodeAssociationMutationError.serverConflict }
        guard sourceState == .complete, let status else {
            applyState(
                association.state,
                reasons: [.sourceUnavailable],
                to: &association,
                now: now,
                incrementsRevision: existing != nil
            )
            return NodeAssociationEvaluation(association: association, candidates: [])
        }

        if hostKeyChanged, association.target != nil {
            association = reviewRequired(association, reason: .hostKeyChanged, now: now)
            return NodeAssociationEvaluation(association: association, candidates: [])
        }

        let candidates = candidates(
            logicalID: logicalID,
            route: route,
            status: status,
            logicalNameContext: logicalNameContext
        )
        if let target = association.target {
            if association.method == .automatic, !route.isDirect {
                association = reviewRequired(association, reason: .proxiedRoute, now: now)
                return NodeAssociationEvaluation(association: association, candidates: candidates)
            }
            if status.nodes.contains(where: { $0.stableNodeID == target.nodeID }) {
                if association.evidenceKinds.contains(.exactLogicalName) {
                    guard logicalNameContext?.matchingServerCount == 1,
                          LogicalNodeName.normalize(logicalNameContext?.serverName ?? "") == logicalID,
                          candidates.count == 1,
                          candidates.first?.target == target,
                          candidates.first?.evidenceKinds.contains(.exactLogicalName) == true else {
                        association = reviewRequired(association, reason: .logicalNameChanged, now: now)
                        return NodeAssociationEvaluation(association: association, candidates: candidates)
                    }
                }
                if association.method == .automatic,
                   !candidates.contains(where: { $0.target == target }) {
                    applyState(
                        .reviewRequired,
                        reasons: [.endpointConflict],
                        to: &association,
                        now: now,
                        incrementsRevision: true
                    )
                    return NodeAssociationEvaluation(association: association, candidates: candidates)
                }
                association.state = .linked
                association.reasonCodes = []
                association.lastVerifiedAt = now
                association.updatedAt = now
                return NodeAssociationEvaluation(association: association, candidates: candidates)
            }

            applyState(
                .reviewRequired,
                reasons: candidates.isEmpty ? [.nodeMissing] : [.nodeIdentityChanged],
                to: &association,
                now: now,
                incrementsRevision: true
            )
            return NodeAssociationEvaluation(association: association, candidates: candidates)
        }

        guard association.autoLinkEnabled else {
            association.state = .invalidated
            association.reasonCodes = [.manuallyUnlinked]
            return NodeAssociationEvaluation(association: association, candidates: candidates)
        }
        guard route.isDirect else {
            applyState(
                .pendingConfirmation,
                reasons: [.proxiedRoute],
                to: &association,
                now: now,
                incrementsRevision: existing != nil
            )
            return NodeAssociationEvaluation(association: association, candidates: candidates)
        }

        if let logicalNameContext,
           LogicalNodeName.normalize(logicalNameContext.serverName) == logicalID,
           logicalNameContext.matchingServerCount > 1 {
            applyState(
                .pendingConfirmation,
                reasons: [.multipleStrongMatches],
                to: &association,
                now: now,
                incrementsRevision: existing != nil
            )
            return NodeAssociationEvaluation(association: association, candidates: candidates)
        }

        if candidates.count == 1, let candidate = candidates.first {
            association.target = candidate.target
            association.state = .linked
            association.method = .automatic
            association.evidenceKinds = candidate.evidenceKinds
            association.reasonCodes = []
            association.confirmedAt = now
            association.lastVerifiedAt = now
            association.updatedAt = now
            association.revision += existing == nil ? 0 : 1
        } else if candidates.count > 1 {
            applyState(
                .pendingConfirmation,
                reasons: [.multipleStrongMatches],
                to: &association,
                now: now,
                incrementsRevision: existing != nil
            )
        } else {
            applyState(
                .unlinked,
                reasons: [.noMatch],
                to: &association,
                now: now,
                incrementsRevision: existing != nil
            )
        }
        return NodeAssociationEvaluation(association: association, candidates: candidates)
    }

    public static func confirm(
        _ association: NodeAssociation,
        target: ActualNodeReference,
        expectedRevision: Int,
        validTargets: Set<ActualNodeReference>,
        now: Date = .now
    ) throws -> NodeAssociation {
        try requireRevision(association, expectedRevision: expectedRevision)
        guard validTargets.contains(target), !target.tailnetKey.isEmpty, !target.nodeID.isEmpty else {
            throw NodeAssociationMutationError.invalidTarget
        }
        if association.target == target,
           association.state == .linked,
           association.method == .manual,
           association.autoLinkEnabled,
           association.evidenceKinds.isEmpty,
           association.reasonCodes.isEmpty {
            return association
        }
        var result = association
        result.target = target
        result.state = .linked
        result.method = .manual
        result.autoLinkEnabled = true
        result.evidenceKinds = []
        result.reasonCodes = []
        result.confirmedAt = now
        result.lastVerifiedAt = now
        result.updatedAt = now
        result.revision += 1
        return result
    }

    public static func unlink(
        _ association: NodeAssociation,
        expectedRevision: Int,
        now: Date = .now
    ) throws -> NodeAssociation {
        try requireRevision(association, expectedRevision: expectedRevision)
        if association.target == nil,
           association.state == .invalidated,
           association.method == nil,
           !association.autoLinkEnabled,
           association.evidenceKinds.isEmpty,
           association.reasonCodes == [.manuallyUnlinked] {
            return association
        }
        var result = association
        result.target = nil
        result.state = .invalidated
        result.method = nil
        result.autoLinkEnabled = false
        result.evidenceKinds = []
        result.reasonCodes = [.manuallyUnlinked]
        result.lastVerifiedAt = nil
        result.updatedAt = now
        result.revision += 1
        return result
    }

    public static func resumeAutomaticMatching(
        _ association: NodeAssociation,
        expectedRevision: Int,
        now: Date = .now
    ) throws -> NodeAssociation {
        try requireRevision(association, expectedRevision: expectedRevision)
        if association.target == nil,
           association.state == .unlinked,
           association.autoLinkEnabled,
           association.reasonCodes.isEmpty {
            return association
        }
        var result = association
        result.state = .unlinked
        result.autoLinkEnabled = true
        result.reasonCodes = []
        result.updatedAt = now
        result.revision += 1
        return result
    }

    public static func target(for node: TailscaleNode, status: TailscaleStatus) -> ActualNodeReference? {
        guard let nodeID = node.stableNodeID,
              let tailnetKey = status.tailnetKey,
              !tailnetKey.isEmpty else { return nil }
        return ActualNodeReference(tailnetKey: tailnetKey, nodeID: nodeID)
    }

    public static func reviewRequired(
        _ association: NodeAssociation,
        reason: NodeAssociationReason,
        now: Date = .now
    ) -> NodeAssociation {
        var result = association
        applyState(
            .reviewRequired,
            reasons: [reason],
            to: &result,
            now: now,
            incrementsRevision: true
        )
        return result
    }

    private static func candidates(
        logicalID: String,
        route: EffectiveSSHRoute,
        status: TailscaleStatus,
        logicalNameContext: LogicalNameMatchContext?
    ) -> [NodeAssociationCandidate] {
        guard let tailnetKey = status.tailnetKey else { return [] }
        let serverNameMatches = logicalNameContext?.matchingServerCount == 1
            && LogicalNodeName.normalize(logicalNameContext?.serverName ?? "") == logicalID
        return status.nodes.compactMap { node in
            guard let nodeID = node.stableNodeID else { return nil }
            var evidenceKinds: [NodeAssociationEvidence] = []
            if serverNameMatches,
               LogicalNodeName.normalize(node.hostName ?? "") == logicalID {
                evidenceKinds.append(.exactLogicalName)
            }
            if let match = node.addressMatch(for: route.hostname) {
                evidenceKinds.append(match == .tailscaleMagicDNS ? .exactMagicDNS : .exactTailscaleIP)
            }
            guard !evidenceKinds.isEmpty else { return nil }
            return NodeAssociationCandidate(
                target: ActualNodeReference(tailnetKey: tailnetKey, nodeID: nodeID),
                node: node,
                evidenceKinds: evidenceKinds
            )
        }
    }

    private static func requireRevision(_ association: NodeAssociation, expectedRevision: Int) throws {
        guard association.revision == expectedRevision else {
            throw NodeAssociationMutationError.revisionConflict(expected: expectedRevision, actual: association.revision)
        }
    }

    private static func applyState(
        _ state: NodeAssociationState,
        reasons: [NodeAssociationReason],
        to association: inout NodeAssociation,
        now: Date,
        incrementsRevision: Bool
    ) {
        guard association.state != state || association.reasonCodes != reasons else { return }
        association.state = state
        association.reasonCodes = reasons
        association.updatedAt = now
        if incrementsRevision { association.revision += 1 }
    }
}

public enum NodeAssociationMerger {
    public static func merge(_ values: [NodeAssociation]) -> [NodeAssociation] {
        var result: [String: NodeAssociation] = [:]
        for value in values {
            guard let existing = result[value.testCaseNodeID] else {
                result[value.testCaseNodeID] = value
                continue
            }
            if value.revision > existing.revision
                || (value.revision == existing.revision && value.updatedAt > existing.updatedAt) {
                result[value.testCaseNodeID] = value
            }
        }
        return result.values.sorted { $0.testCaseNodeID < $1.testCaseNodeID }
    }
}
