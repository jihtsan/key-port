import KeyPortCore
import SwiftUI

struct GraphInspectorView: View {
    let workspace: GraphWorkspaceModel

    var body: some View {
        if !workspace.isAvailable {
            ContentUnavailableView(
                "Graph Inspector",
                systemImage: "sidebar.right",
                description: Text(workspace.unavailableMessage)
            )
        } else if let node = workspace.selectedNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(node)
                    statusSection(node.status)
                    tailscaleSection(node)
                    endpointSection(node)
                    relationSection
                    evidenceSection(node)
                }
                .padding(20)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .navigationTitle("详情")
        } else {
            ContentUnavailableView(
                "未选择节点",
                systemImage: "cursorarrow.click",
                description: Text("从 Graph 或节点列表中选择一个节点。")
            )
        }
    }

    private func header(_ node: TopologyGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: node.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(node.status.level.tint)
                Text(node.title)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            Text(node.kind.displayTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let subtitle = node.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            GraphStatusBadge(status: node.status)
        }
    }

    private func statusSection(_ status: TopologyGraphStatus) -> some View {
        GroupBox("状态证据") {
            VStack(alignment: .leading, spacing: 9) {
                statusRow("可达性", status.reachability.displayTitle)
                statusRow("主机信任", status.hostTrust.displayTitle)
                statusRow("SSH 路由", status.route.displayTitle)
                statusRow("本机密钥", status.localKey.displayTitle)
                statusRow("远端授权", status.remoteAuthorization.displayTitle)
                statusRow("本机复验", status.verification.displayTitle)
                statusRow("同步/写权", status.sync.displayTitle)
                if !status.reasons.isEmpty {
                    Divider()
                    Text(status.reasons.map(\.displayTitle).joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(status.level.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func tailscaleSection(_ node: TopologyGraphNode) -> some View {
        if !node.tailscaleIdentities.isEmpty {
            GroupBox("Tailscale") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(node.tailscaleIdentities) { identity in
                        if identity.id != node.tailscaleIdentities.first?.id {
                            Divider()
                        }
                        LabeledContent("Tailnet", value: identity.tailnetKey)
                        LabeledContent("Node ID", value: identity.tailscaleNodeID)
                        if let magicDNS = identity.magicDNS {
                            LabeledContent("MagicDNS", value: magicDNS)
                        }
                        if !identity.addresses.isEmpty {
                            LabeledContent("Tailscale IP") {
                                Text(identity.addresses.joined(separator: "\n"))
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                        }
                        if let operatingSystem = identity.operatingSystem {
                            LabeledContent("系统", value: operatingSystem)
                        }
                        LabeledContent("本机观测", value: identity.observationState.displayTitle)
                        if let observedAt = identity.observedAt {
                            LabeledContent(
                                "刷新时间",
                                value: observedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        if let lastSeenAt = identity.lastSeenAt {
                            LabeledContent(
                                "最近在线",
                                value: lastSeenAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func endpointSection(_ node: TopologyGraphNode) -> some View {
        if !node.endpointSummaries.isEmpty {
            GroupBox("访问端点") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(node.endpointSummaries, id: \.self) { endpoint in
                        Label(endpoint, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var relationSection: some View {
        GroupBox("关联") {
            VStack(alignment: .leading, spacing: 9) {
                if workspace.selectedEdges.isEmpty {
                    Text("暂无已投影关系")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspace.selectedEdges) { edge in
                        let other = edge.from == workspace.selectedNodeID ? edge.to : edge.from
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: edge.isCandidate ? "arrow.triangle.branch" : "arrow.right")
                                .foregroundStyle(edge.status.level.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(edge.label.isEmpty ? edge.kind.displayTitle : edge.label)
                                    .fontWeight(.medium)
                                Text(workspace.sourceSnapshot.nodes.first { $0.id == other }?.title ?? other.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if edge.isCandidate {
                                Text("候选")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func evidenceSection(_ node: TopologyGraphNode) -> some View {
        GroupBox("事实链") {
            VStack(alignment: .leading, spacing: 7) {
                if let source = node.source {
                    referenceRow(source)
                }
                ForEach(node.supportingReferences, id: \.self) { reference in
                    referenceRow(reference)
                }
                if node.source == nil && node.supportingReferences.isEmpty {
                    Text("没有可展开的支持实体")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func referenceRow(_ reference: HostV6.EntityReference) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reference.entityType.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reference.stableID)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
    }
}

private extension TopologyGraphReason {
    var displayTitle: String {
        switch self {
        case .hostDeleted: "主机已删除"
        case .hostKeyPending: "主机身份待确认"
        case .hostKeyMismatch: "主机身份不匹配"
        case .mergeReview: "存在同步冲突"
        case .noRoute: "没有可用路由"
        case .routeConflict: "路由冲突"
        case .unreachable: "最近不可达"
        case .missingLocalKey: "缺少本机密钥"
        case .remoteAuthorizationPending: "远端授权待确认"
        case .remoteAuthorizationRevoked: "远端授权已撤销"
        case .verificationPending: "本机复验待完成"
        case .verificationFailed: "本机复验失败"
        case .candidateAccess: "当前设备候选访问"
        case .nodeAssociationReview: "节点关联待审核"
        case .nodeAssociationInvalid: "节点关联无效"
        case .canary: "Canary 只读"
        case .readOnly: "只读模式"
        case .compatibilityRollback: "兼容回滚"
        }
    }
}

private extension TopologyGraphEdgeKind {
    var displayTitle: String {
        switch self {
        case .nodeAccess: "节点访问节点"
        case .deviceAccess: "设备访问主机"
        case .candidateAccess: "候选访问"
        case .hostService: "主机承载服务"
        case .sshAccountActualNode: "账户关联实际节点"
        case .tailscalePeer: "Tailscale 节点"
        }
    }
}
