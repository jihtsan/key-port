import KeyPortCore
import SwiftUI

struct KeyListView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedKeyItemID) {
            if !model.keyConnectionRows.isEmpty {
                Section("SSH 连接") {
                    ForEach(model.keyConnectionRows) { row in
                        KeyConnectionListRow(
                            row: row,
                            hasPassword: row.serverRow.map { model.hasStoredPassword(serverID: $0.server.id) } ?? false,
                            onAddToServers: {
                                guard let connection = row.connection else { return }
                                model.selectedKeyItemID = row.id
                                Task { await model.addDiscoveredConnectionToServers(connection) }
                            }
                        )
                        .tag(row.id)
                    }
                }
            }

            if !model.snapshot.keys.isEmpty {
                Section("本地身份密钥") {
                    ForEach(model.snapshot.keys) { key in
                        let itemID = "identity:\(key.id)"
                        LocalIdentityListRow(
                            key: key,
                            name: model.keyDisplayName(key),
                            connection: model.connections(for: key).first
                        )
                        .tag(itemID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("密钥")
        .onChange(of: model.selectedKeyItemID) { _, _ in model.synchronizeKeySelection() }
        .toolbar {
            Button { Task { await model.generateKey() } } label: { Label("生成密钥", systemImage: "plus") }
            Button { Task { await model.importKey() } } label: { Label("导入密钥", systemImage: "square.and.arrow.down") }
            Button { Task { try? await model.refreshKeys() } } label: { Label("扫描密钥", systemImage: "arrow.clockwise") }
        }
        .overlay {
            if model.keyConnectionRows.isEmpty && model.snapshot.keys.isEmpty {
                ContentUnavailableView("暂无 SSH 密钥", systemImage: "key", description: Text("请添加服务器，或为此 Mac 生成身份密钥。"))
            }
        }
    }
}

private struct KeyConnectionListRow: View {
    let row: KeyConnectionRow
    let hasPassword: Bool
    let onAddToServers: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.alias)
                    .lineLimit(1)
                Text(verbatim: "\(row.host):\(row.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let server = row.serverRow?.server {
                if !hasPassword && server.status != .authorized {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .frame(width: 22, height: 22)
                        .help("Keychain 中缺少服务器密码")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(width: 22, height: 22)
                        .help("已添加到服务器")
                }
            } else {
                Button(action: onAddToServers) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .accessibilityLabel("将 \(row.alias) 添加到服务器")
                .help("将 \(row.alias) 添加到服务器")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        guard let serverRow = row.serverRow else { return "network" }
        return serverRow.authorization == nil ? "key.slash" : "key.horizontal.fill"
    }

    private var iconColor: Color {
        guard let serverRow = row.serverRow else { return .secondary }
        return serverRow.authorization == nil ? .secondary : .green
    }
}

private struct LocalIdentityListRow: View {
    let key: SSHKeyRecord
    let name: String
    let connection: DiscoveredSSHConnection?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: key.isLocallyAvailable ? "key.horizontal" : "key.icloud")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                if let connection {
                    Text(verbatim: "\(connection.alias) · \(connection.host):\(connection.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(key.fingerprint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct KeyServerDetailView: View {
    let row: KeyServerRow
    let model: AppModel

    var body: some View {
        Form {
            Section("SSH 连接") {
                LabeledContent("名称", value: row.server.name)
                LabeledContent("SSH 别名", value: row.server.alias)
                LabeledContent("地址", value: row.server.host)
                LabeledContent("端口", value: String(row.server.port))
                LabeledContent("用户", value: row.server.username)
                if let item = model.devicePresence(for: row.server) {
                    LabeledContent("设备") {
                        Button(item.name) { model.showDevice(item.id) }
                    }
                }
                LabeledContent("状态") { StatusLabel(status: row.server.status) }
                Button("在服务器中显示") { model.showServer(row.server.id) }
            }

            Section("服务器密码") {
                if model.hasStoredPassword(serverID: row.server.id) {
                    Label("已存储在 Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("更新密码") { model.requestPassword(for: row.server.id) }
                } else {
                    Label("Keychain 中缺少密码", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("添加密码") { model.requestPassword(for: row.server.id) }
                }
            }

            Section("当前 Mac 密钥") {
                if let key = row.key {
                    LabeledContent("名称", value: model.keyDisplayName(key))
                    LabeledContent("类型", value: key.kind.rawValue.uppercased())
                    LabeledContent("指纹") {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("授权", value: row.authorization == nil ? "未安装" : "已安装")
                } else {
                    Text("此 Mac 没有可用的本地私钥。").foregroundStyle(.secondary)
                    Button("生成 Ed25519 密钥") { Task { await model.generateKey() } }
                }
            }

            Section("操作") {
                Button("检查连接") {
                    model.selectedServerID = row.server.id
                    Task { await model.checkKeySelected() }
                }
                Button("同步 SSH 授权") {
                    model.selectedServerID = row.server.id
                    Task { await model.synchronizeSSHAuthorization(serverID: row.server.id) }
                }
                .disabled(row.key == nil || row.server.confirmedHostKeys.isEmpty || !model.hasStoredPassword(serverID: row.server.id) || model.isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row.server.name)
    }
}

struct SSHConfigConnectionDetailView: View {
    let connection: DiscoveredSSHConnection
    let model: AppModel

    var body: some View {
        Form {
            Section("SSH 连接") {
                LabeledContent("SSH 名称", value: connection.alias)
                LabeledContent("地址", value: connection.host)
                LabeledContent("端口", value: String(connection.port))
                LabeledContent("用户", value: connection.username)
            }

            Section("已配置的身份密钥") {
                if let key = model.key(for: connection) {
                    LabeledContent("密钥", value: model.keyDisplayName(key))
                    LabeledContent("指纹") {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Label("未找到匹配的本地密钥", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                }
                ForEach(connection.identityFiles, id: \.self) { path in
                    LabeledContent("身份密钥文件", value: path)
                }
            }

            Section("服务器") {
                if let server = model.server(matching: connection) {
                    Label("已同步到服务器", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("在服务器中显示") { model.showServer(server.id) }
                } else {
                    Label("尚未添加到服务器", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await model.addDiscoveredConnectionToServers(connection) }
                    } label: {
                        Label("添加到服务器", systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(connection.alias)
    }
}

struct KeyDetailView: View {
    let key: SSHKeyRecord
    let model: AppModel

    var body: some View {
        Form {
            Section("身份密钥") {
                LabeledContent("名称", value: model.keyDisplayName(key))
                LabeledContent("设备", value: model.snapshot.devices.first(where: { $0.id == key.deviceID })?.name ?? "未知设备")
                LabeledContent("类型", value: key.kind.rawValue.uppercased())
                LabeledContent("来源", value: key.origin.displayTitle)
                if let item = model.devicePresence(for: key) {
                    Button("在设备中显示：\(item.name)") { model.showDevice(item.id) }
                }
            }
            Section("指纹") {
                Text(key.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Section("本地可用性") {
                LabeledContent("私钥", value: key.privateKeyPath ?? "此 Mac 上不存在")
                LabeledContent("SSH Agent", value: key.isInAgent ? "已加载" : "未检测到")
                Button("加载到 SSH Agent") { Task { await model.addSelectedKeyToAgent() } }
                    .disabled(key.privateKeyPath == nil || key.isInAgent)
            }
            Section("公钥") {
                Text(key.publicKey).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("Authorized SSH Accounts") {
                let servers = model.authorizedServers(for: key)
                if servers.isEmpty {
                    Label("This key has no known SSH account authorizations", systemImage: "key.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text("\(server.username)@\(server.endpoint)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.showServer(server.id)
                            } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Servers")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.keyDisplayName(key))
    }
}

private extension SSHKeyOrigin {
    var displayTitle: String {
        switch self {
        case .generated: "生成"
        case .scanned: "扫描发现"
        case .imported: "导入"
        case .agent: "SSH Agent"
        }
    }
}
