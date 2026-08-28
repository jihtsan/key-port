import KeyPortCore
import SwiftUI

enum HostWorkbenchListState: Equatable {
    case loading
    case empty
    case noResults
    case populated

    static func resolve(isLoading: Bool, rowCount: Int, searchText: String) -> Self {
        if isLoading { return .loading }
        if rowCount > 0 { return .populated }
        return searchText.isEmpty ? .empty : .noResults
    }
}

struct HostWorkbenchLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在加载主机")
                .font(.headline)
            Text("正在读取主机、访问地址和 SSH 身份。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在加载主机")
        .accessibilityValue("正在读取主机、访问地址和 SSH 身份")
        .accessibilityIdentifier("host-workbench-loading")
    }
}

struct HostWorkbenchListView: View {
    let model: AppModel
    let onAddAccount: (UUID) -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        @Bindable var model = model
        let rows = model.activeHostRows
        List(selection: $model.selectedHostID) {
            ForEach(rows) { row in
                HostWorkbenchListRow(
                    row: row,
                    onEdit: {
                        guard let identityID = row.identities.first?.id else { return }
                        onEdit(identityID)
                    },
                    onAddAccount: {
                        guard let identityID = row.identities.first?.id else { return }
                        onAddAccount(identityID)
                    },
                    onCopyAlias: {
                        guard let identityID = row.identities.first?.id else { return }
                        model.copyAlias(serverID: identityID)
                    }
                )
                .tag(row.id)
            }
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "名称、地址、用户、服务")
        .navigationTitle("主机")
        .onChange(of: model.selectedHostID) { _, hostID in
            guard let hostID else { return }
            model.selectHost(hostID)
        }
        .overlay {
            switch HostWorkbenchListState.resolve(
                isLoading: !model.isLoaded,
                rowCount: rows.count,
                searchText: model.searchText
            ) {
            case .loading:
                HostWorkbenchLoadingView()
            case .empty:
                ContentUnavailableView(
                    "暂无主机",
                    systemImage: "server.rack",
                    description: Text("请添加主机和首个 SSH 用户。")
                )
            case .noResults:
                ContentUnavailableView.search(text: model.searchText)
            case .populated:
                EmptyView()
            }
        }
    }
}

private struct HostWorkbenchListRow: View {
    let row: HostV6.HostWorkbenchProjection.Row
    let onEdit: () -> Void
    let onAddAccount: () -> Void
    let onCopyAlias: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.host.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(primaryAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(row.identityCount) 个身份")
                    Text("\(row.addressCount) 个地址")
                    Text("\(row.serviceCount) 个服务")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HostWorkbenchAxisLabel(axis: .reachability, value: row.axes.reachability)
                HostWorkbenchAxisLabel(axis: .sshTrust, value: row.axes.sshTrust)
                HostWorkbenchAxisLabel(axis: .accessMode, value: row.axes.accessMode)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑 SSH 身份", systemImage: "pencil")
            }
            Button(action: onAddAccount) {
                Label("添加 SSH 身份", systemImage: "person.badge.plus")
            }
            Button(action: onCopyAlias) {
                Label("复制 SSH 别名", systemImage: "doc.on.doc")
            }
        }
    }

    private var primaryAddress: String {
        guard let address = row.addresses.first?.address else { return "未配置访问地址" }
        let label = address.originalLabel.isEmpty ? address.normalizedHost : address.originalLabel
        return "\(label):\(address.sshPort)"
    }
}

struct HostWorkbenchDetailView: View {
    let row: HostV6.HostWorkbenchProjection.Row
    let model: AppModel

    @State private var identitiesExpanded = true
    @State private var advancedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                currentEntry
                servicesSection
                addressesSection
                identitiesSection
                advancedSection
                historySection
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle(row.host.name)
    }

    private var currentEntry: some View {
        GroupBox("当前入口与下一步") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.host.name)
                            .font(.title2.weight(.semibold))
                        Text(nextStep)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 5) {
                        HostWorkbenchAxisLabel(axis: .reachability, value: row.axes.reachability)
                        HostWorkbenchAxisLabel(axis: .sshTrust, value: row.axes.sshTrust)
                        HostWorkbenchAxisLabel(axis: .accessMode, value: row.axes.accessMode)
                    }
                }
                if let identity = row.identities.first,
                   let server = model.snapshot.servers.first(where: { $0.id == identity.id && !$0.isDeleted }) {
                    HStack(spacing: 8) {
                        Text("\(identity.username)@\(server.endpoint)")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            model.copyAlias(serverID: identity.id)
                        } label: {
                            Label("复制别名", systemImage: "doc.on.doc")
                        }
                        .help("复制 SSH 别名")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var servicesSection: some View {
        GroupBox("服务") {
            if row.services.isEmpty {
                Label("尚未保存服务", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(row.services) { service in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: service.isFavorite ? "star.fill" : "network")
                                .foregroundStyle(service.isFavorite ? .yellow : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(service.name)
                                    .fontWeight(.medium)
                                Text(serviceDescription(service))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("未验证")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addressesSection: some View {
        GroupBox("访问地址") {
            if row.addresses.isEmpty {
                Label("尚未配置访问地址", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(row.addresses) { addressRow in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: addressRow.reachability.systemImage)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(addressDescription(addressRow))
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Text(addressRow.address.source.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(addressRow.reachability.displayTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var identitiesSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $identitiesExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(row.identities) { identity in
                        identityRow(identity)
                        if identity.id != row.identities.last?.id { Divider() }
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Label("SSH 身份与安全", systemImage: "lock.shield")
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(row.identityCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func identityRow(_ identity: HostV6.SSHIdentity) -> some View {
        if let server = model.snapshot.servers.first(where: { $0.id == identity.id && !$0.isDeleted }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(identity.alias)
                            .fontWeight(.medium)
                        Text(identity.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusLabel(status: server.status)
                }
                HStack(spacing: 8) {
                    Button {
                        model.selectedServerID = server.id
                        Task { await model.checkKey(serverID: server.id) }
                    } label: {
                        Label("验证 SSH", systemImage: "checkmark.shield")
                    }
                    .disabled(model.isBusy)
                    Button {
                        model.requestPassword(for: server.id)
                    } label: {
                        Label("管理密码", systemImage: "key")
                    }
                    Button {
                        model.selectedServerID = server.id
                        Task { await model.performPasswordlessPrimaryAction(serverID: server.id) }
                    } label: {
                        Label("免密操作", systemImage: "bolt.shield")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private var advancedSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                if let identity = row.identities.first,
                   let server = model.snapshot.servers.first(where: { $0.id == identity.id && !$0.isDeleted }) {
                    ServerDetailView(server: server, model: model)
                        .frame(minHeight: 520)
                } else {
                    Text("暂无可展示的高级信息。")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } label: {
                Label("高级信息", systemImage: "slider.horizontal.3")
                    .fontWeight(.medium)
            }
        }
    }

    private var historySection: some View {
        GroupBox("最近记录") {
            if row.recentRecords.isEmpty {
                Label("暂无本机连接记录", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(row.recentRecords.prefix(10)) { record in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: record.result == .succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.action.displayTitle)
                                Text(record.endedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.accessMode?.displayTitle ?? "未记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nextStep: String {
        switch row.axes.sshTrust {
        case .pending:
            return "请先核对 Host Key，确认后才能进行 SSH 操作。"
        case .changed:
            return "Host Key 存在变化或冲突，SSH 操作已阻止。"
        case .confirmed:
            return row.axes.reachability == .reachable
                ? "当前入口可达，可以继续使用 SSH 或已保存服务。"
                : "请验证访问地址后再继续 SSH 或服务操作。"
        }
    }

    private func serviceDescription(_ service: HostV6.SavedService) -> String {
        let endpoint = service.endpoint
        let path = endpoint.path ?? ""
        return "\(service.serviceProtocol.rawValue.uppercased()) · \(endpoint.port)\(path)"
    }

    private func addressDescription(_ addressRow: HostV6.HostWorkbenchProjection.AddressRow) -> String {
        let address = addressRow.address
        let label = address.originalLabel.isEmpty ? address.normalizedHost : address.originalLabel
        return "\(label):\(address.sshPort)"
    }
}

private enum HostWorkbenchAxis {
    case reachability
    case sshTrust
    case accessMode
}

private struct HostWorkbenchAxisLabel: View {
    let axis: HostWorkbenchAxis
    let value: AnyHashable

    init(axis: HostWorkbenchAxis, value: ReachabilityState) {
        self.axis = axis
        self.value = AnyHashable(value)
    }

    init(axis: HostWorkbenchAxis, value: HostV6.HostWorkbenchProjection.SSHTrustState) {
        self.axis = axis
        self.value = AnyHashable(value)
    }

    init(axis: HostWorkbenchAxis, value: AccessMode) {
        self.axis = axis
        self.value = AnyHashable(value)
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }

    private var title: String {
        switch axis {
        case .reachability:
            switch value.base as? ReachabilityState {
            case .unknown: return "可达性未知"
            case .reachable: return "当前可达"
            case .unreachable: return "当前不可达"
            case .stale: return "可达性已过期"
            case nil: return "可达性未知"
            }
        case .sshTrust:
            switch value.base as? HostV6.HostWorkbenchProjection.SSHTrustState {
            case .pending: return "SSH 待确认"
            case .confirmed: return "SSH 已确认"
            case .changed: return "SSH 已变化"
            case nil: return "SSH 待确认"
            }
        case .accessMode:
            switch value.base as? AccessMode {
            case .direct: return "最近直连"
            case .tunnel: return "最近隧道"
            case .unavailable: return "当前不可用"
            case nil: return "访问方式未知"
            }
        }
    }

    private var systemImage: String {
        switch axis {
        case .reachability:
            switch value.base as? ReachabilityState {
            case .reachable: return "checkmark.circle"
            case .unreachable: return "xmark.circle"
            case .stale: return "clock"
            case .unknown, nil: return "questionmark.circle"
            }
        case .sshTrust:
            switch value.base as? HostV6.HostWorkbenchProjection.SSHTrustState {
            case .confirmed: return "checkmark.shield"
            case .changed: return "exclamationmark.shield"
            case .pending, nil: return "questionmark.diamond"
            }
        case .accessMode:
            switch value.base as? AccessMode {
            case .direct: return "arrow.right"
            case .tunnel: return "point.3.connected.trianglepath.dotted"
            case .unavailable, nil: return "minus.circle"
            }
        }
    }
}

private extension ReachabilityState {
    var displayTitle: String {
        switch self {
        case .unknown: "未知"
        case .reachable: "可达"
        case .unreachable: "不可达"
        case .stale: "已过期"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .reachable: "checkmark.circle"
        case .unreachable: "xmark.circle"
        case .stale: "clock"
        }
    }
}

private extension HostV6.AddressSource {
    var displayTitle: String {
        switch self {
        case .legacy: "旧模型迁移"
        case .manual: "手动添加"
        case .tailscale: "Tailscale"
        case .discovered: "发现"
        }
    }
}

private extension ConnectionAction {
    var displayTitle: String {
        switch self {
        case .addressValidation: "地址验证"
        case .serviceDiscovery: "服务发现"
        case .sshCheck: "SSH 检查"
        case .serviceOpen: "服务访问"
        case .tunnelOperation: "隧道操作"
        }
    }
}

private extension AccessMode {
    var displayTitle: String {
        switch self {
        case .direct: "直连"
        case .tunnel: "SSH 隧道"
        case .unavailable: "不可用"
        }
    }
}
