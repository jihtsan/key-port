import KeyPortCore
import SwiftUI

struct GraphCanvasView: View {
    let snapshot: TopologyGraphSnapshot
    let nodeItems: [NodeWorkspaceItem]
    @Binding var selection: TopologyGraphNodeID?
    @State private var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = GraphCanvasLayout.size(for: snapshot, available: geometry.size)
            let positions = GraphCanvasLayout.positions(for: snapshot, size: canvasSize)

            ZStack(alignment: .bottomTrailing) {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in snapshot.edges {
                                guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                                var path = Path()
                                path.move(to: from)
                                path.addLine(to: to)
                                context.stroke(
                                    path,
                                    with: .color(edge.status.level.tint.opacity(edge.isCandidate ? 0.85 : 0.55)),
                                    style: StrokeStyle(
                                        lineWidth: edge.isCandidate ? 2 : 1.5,
                                        dash: edge.isCandidate ? [7, 5] : []
                                    )
                                )
                            }
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)

                        ForEach(snapshot.nodes) { node in
                            let selectionID = owningNodeID(for: node.id)
                            GraphNodeCard(
                                node: node,
                                item: nodeItems.first { $0.id == node.id },
                                isSelected: selection == selectionID
                            ) {
                                selection = selectionID
                            }
                            .position(positions[node.id] ?? .zero)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                    .padding(28)
                }
                .background(.regularMaterial)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = min(max(value, 0.65), 1.8)
                        }
                )

                HStack(spacing: 6) {
                    Button {
                        zoom = max(0.65, zoom - 0.1)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("缩小 Graph")

                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42)

                    Button {
                        zoom = min(1.8, zoom + 0.1)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("放大 Graph")

                    Button("重置") { zoom = 1 }
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(14)
            }
        }
    }

    private func owningNodeID(for nodeID: TopologyGraphNodeID) -> TopologyGraphNodeID {
        guard nodeID.rawValue.hasPrefix("ssh-account:") || nodeID.rawValue.hasPrefix("service:") else {
            return nodeID
        }
        return nodeItems.first { item in
            item.accountNodes.contains { $0.id == nodeID }
                || item.services.contains { $0.id == nodeID }
        }?.id ?? nodeID
    }
}

private struct GraphNodeCard: View {
    let node: TopologyGraphNode
    let item: NodeWorkspaceItem?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(node.status.level.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.title)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Circle()
                            .fill(node.status.level.tint)
                            .frame(width: 7, height: 7)
                    }
                    Text(node.kind.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let item, item.isHostNode {
                        HStack(spacing: 4) {
                            Text(item.accountCount == 1 ? "1 个 SSH 用户" : "\(item.accountCount) 个 SSH 用户")
                            if !item.services.isEmpty {
                                Text("·")
                                Text("\(item.services.count) 个服务")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else if let subtitle = node.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(width: 214, height: 96, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : node.status.level.tint.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .accessibilityLabel("\(node.title)，\(node.kind.displayTitle)，\(node.status.level.displayTitle)")
    }
}

private enum GraphCanvasLayout {
    private static let nodeWidth: CGFloat = 214
    private static let nodeHeight: CGFloat = 96
    private static let horizontalSpacing: CGFloat = 238
    private static let verticalSpacing: CGFloat = 130

    static func size(
        for snapshot: TopologyGraphSnapshot,
        available: CGSize
    ) -> CGSize {
        let columns = Dictionary(grouping: snapshot.nodes, by: column(for:))
        let maxRows = columns.values.map(\.count).max() ?? 1
        let maxColumn = columns.keys.max() ?? 0
        return CGSize(
            width: max(available.width - 20, 120 + CGFloat(maxColumn) * horizontalSpacing + nodeWidth),
            height: max(available.height - 20, 100 + CGFloat(maxRows - 1) * verticalSpacing + nodeHeight)
        )
    }

    static func positions(
        for snapshot: TopologyGraphSnapshot,
        size: CGSize
    ) -> [TopologyGraphNodeID: CGPoint] {
        let grouped = Dictionary(grouping: snapshot.nodes, by: column(for:))
        var result: [TopologyGraphNodeID: CGPoint] = [:]
        for (column, nodes) in grouped {
            let sorted = nodes.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            let totalHeight = CGFloat(max(0, sorted.count - 1)) * verticalSpacing
            let startY = max(70, (size.height - totalHeight) / 2)
            for (index, node) in sorted.enumerated() {
                result[node.id] = CGPoint(
                    x: 110 + CGFloat(column) * horizontalSpacing,
                    y: startY + CGFloat(index) * verticalSpacing
                )
            }
        }
        return result
    }

    private static func column(for node: TopologyGraphNode) -> Int {
        switch node.kind {
        case .node: node.isWorkspaceDevice ? 0 : 1
        case .device: 0
        case .sshAccount: 1
        case .host: 2
        case .actualNode: 3
        case .service: 4
        }
    }
}
