import Foundation
import KeyPortCore

/// The display projection for one top-level node.
///
/// A node owns its access facts in the UI. SSH accounts remain stable
/// `ServerConnection` records so existing Keychain, authorization, and SSH
/// actions keep their account-level identity.
struct NodeWorkspaceItem: Identifiable {
    let node: TopologyGraphNode
    let accounts: [ServerConnection]
    let accountNodes: [TopologyGraphNode]
    let services: [TopologyGraphNode]
    let machineConfiguration: RemoteMachineConfiguration?

    var id: TopologyGraphNodeID { node.id }

    var isHostNode: Bool {
        node.kind == .node || node.kind == .host
    }

    var accountCount: Int {
        max(accounts.count, accountNodes.count)
    }

    var endpointCount: Int {
        node.endpointSummaries.count
    }
}

@MainActor
enum NodeWorkspacePresentation {
    static func items(
        model: AppModel,
        workspace: GraphWorkspaceModel
    ) -> [NodeWorkspaceItem] {
        let source = workspace.sourceSnapshot
        let visibleNodes = snapshot(model: model, workspace: workspace).nodes.filter(isPrimaryNode)

        return visibleNodes.map { node in
            let accountNodes = source.nodes.filter { account in
                account.kind == .sshAccount && belongs(account, to: node)
            }
            let services = services(for: node, in: source)
            let nodeAccounts = accounts(for: node, accountNodes: accountNodes, model: model)
            return NodeWorkspaceItem(
                node: node,
                accounts: nodeAccounts,
                accountNodes: accountNodes,
                services: services,
                machineConfiguration: machineConfiguration(
                    for: node,
                    accounts: nodeAccounts,
                    model: model
                )
            )
        }
    }

    /// Returns the graph snapshot used by the node-centric surfaces.
    ///
    /// `TopologyGraphSnapshot` deliberately keeps supporting SSH accounts out
    /// of the default node query. When a user searches for an account, the
    /// account itself therefore cannot provide context to the node list. Add
    /// only its owning node back into the visible snapshot so account search
    /// still lands on the correct node without changing the graph authority.
    static func snapshot(
        model: AppModel,
        workspace: GraphWorkspaceModel
    ) -> TopologyGraphSnapshot {
        let base = workspace.snapshot
        let source = workspace.sourceSnapshot
        let normalizedSearch = workspace.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !normalizedSearch.isEmpty else { return base }

        let sourcePrimaryNodes = source.nodes.filter(isPrimaryNode)
        let accountMatchedNodeIDs = Set(
            sourcePrimaryNodes.compactMap { node -> TopologyGraphNodeID? in
                let accountNodes = source.nodes.filter { account in
                    account.kind == .sshAccount && belongs(account, to: node)
                }
                let graphAccountMatches = accountNodes.contains {
                    searchableValues(for: $0).contains { value in
                        value.localizedLowercase.contains(normalizedSearch)
                    }
                }
                let serverAccountMatches = accounts(
                    for: node,
                    accountNodes: accountNodes,
                    model: model
                ).contains { server in
                    searchableValues(for: server).contains { value in
                        value.localizedLowercase.contains(normalizedSearch)
                    }
                }
                guard graphAccountMatches || serverAccountMatches else { return nil }
                guard isAllowedPrimaryNode(node, workspace: workspace, source: source) else {
                    return nil
                }
                if workspace.onlyIssues {
                    let nodeHasIssue = node.status.level != .healthy && node.status.level != .unknown
                    let accountHasIssue = accountNodes.contains {
                        $0.status.level != .healthy && $0.status.level != .unknown
                    }
                    guard nodeHasIssue || accountHasIssue else { return nil }
                }
                return node.id
            }
        )

        let baseIDs = Set(base.nodes.map(\.id))
        let addedNodeIDs = accountMatchedNodeIDs.subtracting(baseIDs)
        guard !addedNodeIDs.isEmpty else { return base }

        var nodes = base.nodes
        nodes.append(contentsOf: sourcePrimaryNodes.filter { addedNodeIDs.contains($0.id) })
        nodes.sort { lhs, rhs in
            let leftKey = (lhs.kind.rawValue, lhs.title.localizedLowercase, lhs.id.rawValue)
            let rightKey = (rhs.kind.rawValue, rhs.title.localizedLowercase, rhs.id.rawValue)
            return leftKey < rightKey
        }

        var edges = base.edges
        let edgeIDs = Set(edges.map(\.id))
        let visibleIDs = Set(nodes.map(\.id))
        edges.append(contentsOf: source.edges.filter { edge in
            visibleIDs.contains(edge.from)
                && visibleIDs.contains(edge.to)
                && !edgeIDs.contains(edge.id)
        })
        edges.sort { $0.id < $1.id }

        return TopologyGraphSnapshot(
            schemaVersion: base.schemaVersion,
            currentDeviceID: base.currentDeviceID,
            primaryNodeID: base.primaryNodeID,
            authorityMode: base.authorityMode,
            query: base.query,
            nodes: nodes,
            edges: edges,
            diagnostics: base.diagnostics
        )
    }

    static func item(
        for nodeID: TopologyGraphNodeID?,
        model: AppModel,
        workspace: GraphWorkspaceModel
    ) -> NodeWorkspaceItem? {
        guard let nodeID else { return nil }
        return items(model: model, workspace: workspace).first { $0.id == nodeID }
    }

    private static func accounts(
        for node: TopologyGraphNode,
        accountNodes: [TopologyGraphNode],
        model: AppModel
    ) -> [ServerConnection] {
        let activeServers = model.activeServers

        // The unified topology is the most precise relationship source. It
        // keeps the node/account boundary independent from address changes.
        if let nodeID = node.id.uuid,
           model.topology.nodes.contains(where: { $0.id == nodeID }) {
            let accountIDs = Set(
                model.topology.sshAccounts
                    .filter { $0.nodeID == nodeID && !$0.isDeleted }
                    .map(\.id)
            )
            return sorted(activeServers.filter { accountIDs.contains($0.id) })
        }

        // In the Host v6 shadow view, account graph nodes carry a host
        // supporting reference. Their stable IDs are still the legacy account
        // IDs, so actions can safely reuse the existing AppModel entry points.
        let accountIDs = Set(accountNodes.compactMap(accountID(from:)))
        if !accountIDs.isEmpty {
            return sorted(activeServers.filter { accountIDs.contains($0.id) })
        }

        // Keep the compatibility presentation useful while a topology
        // snapshot is being rebuilt. This fallback is deliberately strict:
        // exact node names first, then an exact endpoint token.
        let exactNameMatches = activeServers.filter {
            normalize($0.name) == normalize(node.title)
        }
        if !exactNameMatches.isEmpty {
            return sorted(exactNameMatches)
        }

        let searchableValues = node.endpointSummaries + [node.subtitle ?? ""]
        let endpointMatches = activeServers.filter { server in
            searchableValues.contains { value in
                normalize(value).contains(normalize(server.host))
            }
        }
        return sorted(endpointMatches)
    }

    private static func services(
        for node: TopologyGraphNode,
        in snapshot: TopologyGraphSnapshot
    ) -> [TopologyGraphNode] {
        let serviceIDs = Set(snapshot.edges.compactMap { edge -> TopologyGraphNodeID? in
            guard edge.kind == .hostService else { return nil }
            if edge.from == node.id { return edge.to }
            if edge.to == node.id { return edge.from }
            return nil
        })
        return snapshot.nodes
            .filter { serviceIDs.contains($0.id) && $0.kind == .service }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func belongs(
        _ account: TopologyGraphNode,
        to node: TopologyGraphNode
    ) -> Bool {
        let hostIDs = Set([
            node.source?.stableID,
            node.id.uuid?.uuidString.lowercased(),
        ].compactMap { $0 })

        if account.supportingReferences.contains(where: { reference in
            reference.entityType == .host && hostIDs.contains(reference.stableID)
        }) {
            return true
        }

        // Unified topology account nodes intentionally stay lightweight. The
        // node name in their subtitle is only used as a display fallback.
        guard let subtitle = account.subtitle else { return false }
        let components = subtitle
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return components.dropFirst().first == node.title
    }

    private static func isPrimaryNode(_ node: TopologyGraphNode) -> Bool {
        node.kind == .node || node.kind == .host || node.kind == .device
    }

    private static func isAllowedPrimaryNode(
        _ node: TopologyGraphNode,
        workspace: GraphWorkspaceModel,
        source: TopologyGraphSnapshot
    ) -> Bool {
        if workspace.viewMode == .services, node.kind == .device {
            return false
        }
        guard workspace.viewMode == .currentDevice else { return true }
        if let currentDeviceID = source.currentDeviceID {
            if node.kind == .device {
                return node.id == .device(currentDeviceID)
            }
            return !node.isWorkspaceDevice || node.id == source.primaryNodeID
        }
        return !node.isWorkspaceDevice
    }

    private static func searchableValues(for account: TopologyGraphNode) -> [String] {
        [account.title, account.subtitle ?? ""] + account.endpointSummaries
    }

    private static func searchableValues(for server: ServerConnection) -> [String] {
        [server.name, server.host, server.username, server.alias, server.group, server.endpoint]
    }

    private static func machineConfiguration(
        for node: TopologyGraphNode,
        accounts: [ServerConnection],
        model: AppModel
    ) -> RemoteMachineConfiguration? {
        if let nodeID = node.id.uuid,
           let configuration = model.topology.nodes.first(where: { $0.id == nodeID })?.machineConfiguration {
            return configuration
        }
        return accounts.compactMap(\.machineConfiguration).first
    }

    private static func accountID(from node: TopologyGraphNode) -> UUID? {
        if let stableID = node.source?.stableID,
           let id = UUID(uuidString: stableID) {
            return id
        }
        let prefix = "ssh-account:"
        guard node.id.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(node.id.rawValue.dropFirst(prefix.count)))
    }

    private static func sorted(_ accounts: [ServerConnection]) -> [ServerConnection] {
        accounts.sorted { lhs, rhs in
            let usernameOrder = lhs.username.localizedCaseInsensitiveCompare(rhs.username)
            if usernameOrder != .orderedSame {
                return usernameOrder == .orderedAscending
            }
            return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

private extension TopologyGraphNodeID {
    var uuid: UUID? {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        return UUID(uuidString: String(rawValue[rawValue.index(after: separator)...]))
    }
}
