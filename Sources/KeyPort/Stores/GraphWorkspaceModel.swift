import KeyPortCore
import Observation

@MainActor
@Observable
final class GraphWorkspaceModel {
    var viewMode: TopologyGraphQuery.ViewMode = .currentDevice {
        didSet { rebuildVisibleSnapshot() }
    }
    var searchText = "" {
        didSet { rebuildVisibleSnapshot() }
    }
    var onlyIssues = false {
        didSet { rebuildVisibleSnapshot() }
    }
    var includesSupportingNodes = false {
        didSet { rebuildVisibleSnapshot() }
    }
    var includesActualNodes = false {
        didSet { rebuildVisibleSnapshot() }
    }
    var showsServices = true {
        didSet { rebuildVisibleSnapshot() }
    }
    var selectedNodeID: TopologyGraphNodeID?

    private(set) var snapshot = TopologyGraphSnapshot.empty
    private(set) var sourceSnapshot = TopologyGraphSnapshot.empty
    private(set) var isAvailable = false
    private(set) var unavailableMessage = "Host v6 Graph 尚未加载。"
    private(set) var currentDeviceID: String?

    private let projector: TopologyGraphProjector

    init(projector: TopologyGraphProjector = TopologyGraphProjector()) {
        self.projector = projector
    }

    var query: TopologyGraphQuery {
        TopologyGraphQuery(
            viewMode: viewMode,
            searchText: searchText,
            onlyIssues: onlyIssues,
            includesSupportingNodes: includesSupportingNodes,
            includesActualNodes: includesActualNodes,
            showsServices: showsServices
        )
    }

    var selectedNode: TopologyGraphNode? {
        guard let selectedNodeID else { return nil }
        return sourceSnapshot.nodes.first { $0.id == selectedNodeID }
    }

    var selectedEdges: [TopologyGraphEdge] {
        guard let selectedNodeID else { return [] }
        return sourceSnapshot.edges
            .filter { $0.from == selectedNodeID || $0.to == selectedNodeID }
            .sorted { $0.id < $1.id }
    }

    var connectedNodes: [TopologyGraphNode] {
        let connectedIDs = Set(selectedEdges.map { edge in
            edge.from == selectedNodeID ? edge.to : edge.from
        })
        return sourceSnapshot.nodes
            .filter { connectedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.kind.rawValue == rhs.kind.rawValue
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : lhs.kind.rawValue < rhs.kind.rawValue
            }
    }

    var authorityMode: HostV6.AuthorityMode? {
        sourceSnapshot.authorityMode
    }

    func update(envelope: HostV6.MetadataEnvelope?, currentDeviceID: String?) {
        self.currentDeviceID = currentDeviceID
            ?? envelope?.local.deviceStates.first(where: \.isCurrent)?.deviceID
        guard let envelope else {
            isAvailable = false
            unavailableMessage = "Host v6 Graph 尚未启用；当前仍使用兼容工作区。"
            sourceSnapshot = .empty
            snapshot = .empty
            selectedNodeID = nil
            return
        }

        isAvailable = true
        unavailableMessage = ""
        let sourceQuery = TopologyGraphQuery(
            viewMode: .allDevices,
            includesSupportingNodes: true,
            includesActualNodes: true,
            showsServices: true
        )
        sourceSnapshot = projector.project(
            envelope: envelope,
            currentDeviceID: self.currentDeviceID,
            query: sourceQuery
        )
        rebuildVisibleSnapshot(selectDefault: true)
    }

    func select(_ nodeID: TopologyGraphNodeID?) {
        selectedNodeID = nodeID
    }

    private func rebuildVisibleSnapshot(selectDefault: Bool = false) {
        guard isAvailable else {
            snapshot = .empty
            return
        }
        snapshot = sourceSnapshot.applying(query)
        if let selectedNodeID,
           !snapshot.nodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
        if selectDefault, selectedNodeID == nil {
            selectedNodeID = snapshot.nodes.first(where: { $0.id == .device(currentDeviceID ?? "") })?.id
                ?? snapshot.nodes.first?.id
        }
    }
}
