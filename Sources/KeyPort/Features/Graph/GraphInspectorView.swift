import KeyPortCore
import SwiftUI

struct GraphInspectorView: View {
    let workspace: GraphWorkspaceModel
    let model: AppModel
    let onAddAccount: (UUID?) -> Void
    let onEditAccount: (UUID) -> Void

    var body: some View {
        if !workspace.isAvailable {
            ContentUnavailableView(
                "节点属性",
                systemImage: "sidebar.right",
                description: Text(workspace.unavailableMessage)
            )
        } else if let item = NodeWorkspacePresentation.item(
            for: workspace.selectedNodeID,
            model: model,
            workspace: workspace
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    summary(item)
                    accountsSection(item)
                    statusSection(item.node.status)
                    endpointsSection(item)
                    machineConfigurationSection(item)
                    tailscaleSection(item.node)
                    relationSection
                    evidenceSection(item.node)
                }
                .padding(18)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .navigationTitle("节点属性")
        } else {
            ContentUnavailableView(
                "未选择节点",
                systemImage: "cursorarrow.click",
                description: Text("从 Graph 或节点列表中选择一个节点。")
            )
        }
    }

    private func header(_ item: NodeWorkspaceItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.node.kind.systemImage)
                .font(.title2)
                .foregroundStyle(item.node.status.level.tint)
                .frame(width: 38, height: 38)
                .background(item.node.status.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.node.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if item.id == workspace.sourceSnapshot.primaryNodeID {
                        Text("当前设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if item.node.isWorkspaceDevice {
                        Text("工作区设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.node.kind.displayTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let subtitle = item.node.subtitle {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)
            GraphStatusBadge(status: item.node.status)
        }
    }

    private func summary(_ item: NodeWorkspaceItem) -> some View {
        HStack(spacing: 0) {
            NodeSummaryMetric(
                value: "\(item.accountCount)",
                title: "SSH 用户",
                systemImage: "person.2"
            )
            Divider().frame(height: 34)
            NodeSummaryMetric(
                value: "\(item.endpointCount)",
                title: "访问端点",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            Divider().frame(height: 34)
            NodeSummaryMetric(
                value: "\(item.services.count)",
                title: "服务",
                systemImage: "shippingbox"
            )
        }
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private func accountsSection(_ item: NodeWorkspaceItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH 账户")
                            .font(.headline)
                        Text("同一节点下的用户各自拥有独立别名和授权状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let sourceAccountID = item.accounts.first?.id {
                        Button {
                            onAddAccount(sourceAccountID)
                        } label: {
                            Label("添加账户", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                    }
                }

                if item.accounts.isEmpty {
                    Label("这个节点还没有可操作的 SSH 账户", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    if !item.accountNodes.isEmpty {
                        ForEach(item.accountNodes) { accountNode in
                            graphAccountFallbackRow(accountNode)
                        }
                    }
                } else {
                    ForEach(item.accounts) { account in
                        NodeAccountRow(
                            account: account,
                            model: model,
                            isSelected: model.selectedServerID == account.id,
                            onSelect: { model.selectedServerID = account.id },
                            onAddAccount: { onAddAccount(account.id) },
                            onEdit: { onEditAccount(account.id) },
                            onCopyAlias: { model.copyAlias(serverID: account.id) },
                            onAuthorize: { onAuthorize(account) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func statusSection(_ status: TopologyGraphStatus) -> some View {
        GroupBox("状态证据") {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                NodeStatusFact(title: "可达性", value: status.reachability.displayTitle)
                NodeStatusFact(title: "主机信任", value: status.hostTrust.displayTitle)
                NodeStatusFact(title: "SSH 路由", value: status.route.displayTitle)
                NodeStatusFact(title: "本机密钥", value: status.localKey.displayTitle)
                NodeStatusFact(title: "远端授权", value: status.remoteAuthorization.displayTitle)
                NodeStatusFact(title: "本机复验", value: status.verification.displayTitle)
                NodeStatusFact(title: "同步 / 写权", value: status.sync.displayTitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            if !status.reasons.isEmpty {
                Divider()
                Text(status.reasons.map(\.displayTitle).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(status.level.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func endpointsSection(_ item: NodeWorkspaceItem) -> some View {
        if !item.endpoints.isEmpty {
            GroupBox("访问端点") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.endpoints) { endpoint in
                        NodeEndpointRow(endpoint: endpoint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        } else if !item.node.endpointSummaries.isEmpty {
            GroupBox("访问端点") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.node.endpointSummaries, id: \.self) { endpoint in
                        Label(endpoint, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func machineConfigurationSection(_ item: NodeWorkspaceItem) -> some View {
        if let configuration = item.machineConfiguration {
            GroupBox("机器属性") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("主机名", value: configuration.hostname)
                    LabeledContent("操作系统", value: configuration.operatingSystem)
                    LabeledContent("内核", value: configuration.kernel)
                    LabeledContent("架构", value: configuration.architecture)
                    if let processorCount = configuration.processorCount {
                        LabeledContent("处理器", value: "\(processorCount) 核")
                    }
                    if let memoryBytes = configuration.memoryBytes {
                        LabeledContent(
                            "内存",
                            value: ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
                        )
                    }
                    LabeledContent(
                        "更新时间",
                        value: configuration.synchronizedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
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
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        LabeledContent("观测", value: identity.observationState.displayTitle)
                        if let observedAt = identity.observedAt {
                            LabeledContent(
                                "刷新时间",
                                value: observedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var relationSection: some View {
        GroupBox("关系") {
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
                                    .font(.caption)
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

    private func graphAccountFallbackRow(_ account: TopologyGraphNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                    .fontWeight(.medium)
                if let subtitle = account.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            GraphStatusBadge(status: account.status)
        }
        .padding(.vertical, 3)
    }

    private func onAuthorize(_ account: ServerConnection) {
        Task { await model.performPasswordlessPrimaryAction(serverID: account.id) }
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

private struct NodeSummaryMetric: View {
    let value: String
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct NodeStatusFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
        }
    }
}

private struct NodeEndpointRow: View {
    let endpoint: Endpoint

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: endpoint.networkScope.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.displayAddress)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text(endpoint.networkScope.displayTitle)
                    Text("·")
                    Text(endpoint.source.displayTitle)
                    if endpoint.protocol != .ssh {
                        Text("·")
                        Text(endpoint.protocol.rawValue.uppercased())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if endpoint.label != endpoint.address {
                    Text(endpoint.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private extension NetworkScope {
    var displayTitle: String {
        switch self {
        case .lan: "局域网"
        case .publicNetwork: "公网"
        case .tailnet: "Tailnet"
        case .vpn: "VPN"
        case .unknown: "范围未知"
        }
    }

    var systemImage: String {
        switch self {
        case .lan: "wifi"
        case .publicNetwork: "globe"
        case .tailnet: "network"
        case .vpn: "lock.shield"
        case .unknown: "questionmark.circle"
        }
    }
}

private extension EndpointSource {
    var displayTitle: String {
        switch self {
        case .migrated: "已迁移"
        case .manual: "手动"
        case .discovered: "自动发现"
        case .tailscale: "Tailscale 自动"
        }
    }
}

private struct NodeAccountRow: View {
    let account: ServerConnection
    let model: AppModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onAddAccount: () -> Void
    let onEdit: () -> Void
    let onCopyAlias: () -> Void
    let onAuthorize: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.username)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(account.alias)
                                .font(.caption.monospaced())
                            Text("·")
                            Text("\(account.host):\(account.port)")
                                .font(.caption.monospaced())
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            StatusLabel(status: account.status)
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)

            Button(action: onCopyAlias) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制 \(account.alias)")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑 \(account.username) 账户")

            let action = model.passwordlessPrimaryAction(for: account)
            Button(action: onAuthorize) {
                Image(systemName: action.systemImage)
            }
            .buttonStyle(.borderless)
            .help(action.help)
            .disabled(model.isBusy || action == .checking)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑账户", systemImage: "pencil")
            }
            Button(action: onAddAccount) {
                Label("添加同节点账户", systemImage: "person.badge.plus")
            }
            Button(action: onCopyAlias) {
                Label("复制 SSH 别名", systemImage: "doc.on.doc")
            }
            Divider()
            Button(action: onAuthorize) {
                let action = model.passwordlessPrimaryAction(for: account)
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(model.isBusy)
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
