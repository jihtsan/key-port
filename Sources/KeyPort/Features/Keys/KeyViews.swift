import KeyPortCore
import SwiftUI

struct KeyListView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedKeyItemID) {
            if !model.keyConnectionRows.isEmpty {
                Section("SSH Connections") {
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
                Section("Local Identities") {
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
        .navigationTitle("Keys")
        .onChange(of: model.selectedKeyItemID) { _, _ in model.synchronizeKeySelection() }
        .toolbar {
            Button { Task { await model.generateKey() } } label: { Label("Generate Key", systemImage: "plus") }
            Button { Task { await model.importKey() } } label: { Label("Import Key", systemImage: "square.and.arrow.down") }
            Button { Task { try? await model.refreshKeys() } } label: { Label("Scan Keys", systemImage: "arrow.clockwise") }
        }
        .overlay {
            if model.keyConnectionRows.isEmpty && model.snapshot.keys.isEmpty {
                ContentUnavailableView("No SSH Keys", systemImage: "key", description: Text("Add a server or generate an identity for this Mac."))
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
                        .help("Server password is missing from Keychain")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Available in Servers")
                }
            } else {
                Button(action: onAddToServers) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .accessibilityLabel("Add \(row.alias) to Servers")
                .help("Add \(row.alias) to Servers")
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
            Section("SSH Connection") {
                LabeledContent("Name", value: row.server.name)
                LabeledContent("SSH alias", value: row.server.alias)
                LabeledContent("Address", value: row.server.host)
                LabeledContent("Port", value: String(row.server.port))
                LabeledContent("User", value: row.server.username)
                if let item = model.devicePresence(for: row.server) {
                    LabeledContent("Device") {
                        Button(item.name) { model.showDevice(item.id) }
                    }
                }
                LabeledContent("Status") { StatusLabel(status: row.server.status) }
                Button("Show in Servers") { model.showServer(row.server.id) }
            }

            Section("Server Password") {
                if model.hasStoredPassword(serverID: row.server.id) {
                    Label("Stored in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Update Password") { model.requestPassword(for: row.server.id) }
                } else {
                    Label("Missing from Keychain", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Add Password") { model.requestPassword(for: row.server.id) }
                }
            }

            Section("Current Mac Key") {
                if let key = row.key {
                    LabeledContent("Name", value: model.keyDisplayName(key))
                    LabeledContent("Type", value: key.kind.rawValue.uppercased())
                    LabeledContent("Fingerprint") {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Authorization", value: row.authorization == nil ? "Not installed" : "Installed")
                } else {
                    Text("No local private key is available for this Mac.").foregroundStyle(.secondary)
                    Button("Generate Ed25519 Key") { Task { await model.generateKey() } }
                }
            }

            Section("Actions") {
                Button("Check Connection") {
                    model.selectedServerID = row.server.id
                    Task { await model.checkKeySelected() }
                }
                Button("Authorize This Mac") {
                    model.selectedServerID = row.server.id
                    Task { await model.authorizeSelected() }
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
            Section("SSH Connection") {
                LabeledContent("SSH name", value: connection.alias)
                LabeledContent("Address", value: connection.host)
                LabeledContent("Port", value: String(connection.port))
                LabeledContent("User", value: connection.username)
            }

            Section("Configured Identity") {
                if let key = model.key(for: connection) {
                    LabeledContent("Key", value: model.keyDisplayName(key))
                    LabeledContent("Fingerprint") {
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Label("No matching local key was found", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                }
                ForEach(connection.identityFiles, id: \.self) { path in
                    LabeledContent("Identity file", value: path)
                }
            }

            Section("Servers") {
                if let server = model.server(matching: connection) {
                    Label("Synced to Servers", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Show in Servers") { model.showServer(server.id) }
                } else {
                    Label("Not in Servers", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await model.addDiscoveredConnectionToServers(connection) }
                    } label: {
                        Label("Add to Servers", systemImage: "plus")
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
            Section("Identity") {
                LabeledContent("Name", value: model.keyDisplayName(key))
                LabeledContent("Type", value: key.kind.rawValue.uppercased())
                LabeledContent("Origin", value: key.origin.rawValue.capitalized)
            }
            Section("Device") {
                if let item = model.devicePresence(for: key) {
                    LabeledContent("Name", value: item.name)
                    Button("Show in Devices") { model.showDevice(item.id) }
                } else {
                    LabeledContent("Name", value: "Unknown device")
                }
            }
            Section("Fingerprint") {
                Text(key.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Section("Local Availability") {
                LabeledContent("Private key", value: key.privateKeyPath ?? "Not present on this Mac")
                LabeledContent("SSH Agent", value: key.isInAgent ? "Loaded" : "Not detected")
                Button("Load into SSH Agent") { Task { await model.addSelectedKeyToAgent() } }
                    .disabled(key.privateKeyPath == nil || key.isInAgent)
            }
            Section("Public Key") {
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
