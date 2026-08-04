import KeyPortCore
import SwiftUI

struct ServerDetailView: View {
    let server: ServerConnection
    let model: AppModel
    @State private var pendingRevocationID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name).font(.title2).fontWeight(.semibold)
                        Text("\(server.username)@\(server.endpoint)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Key authorization")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        StatusLabel(status: server.status)
                    }
                }

                GroupBox("Connection") {
                    VStack(spacing: 10) {
                        LabeledContent("SSH alias") {
                            HStack(spacing: 6) {
                                Text(server.alias).monospaced()
                                Button { model.copySelectedAlias() } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("Copy SSH alias")
                            }
                        }
                        LabeledContent("Group", value: server.group.isEmpty ? "None" : server.group)
                    }
                    .padding(.vertical, 5)
                }

                GroupBox("Server Password") {
                    HStack {
                        if model.hasStoredPassword(serverID: server.id) {
                            Label("Stored in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Update Password") { model.requestPassword(for: server.id) }
                        } else {
                            Label("Missing from Keychain", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Spacer()
                            Button("Add Password") { model.requestPassword(for: server.id) }
                        }
                    }
                    .padding(.vertical, 5)
                }

                GroupBox("Authentication Checks") {
                    VStack(spacing: 12) {
                        AuthenticationCheckRow(
                            title: "Password SSH",
                            check: server.passwordCheck,
                            buttonTitle: "Check Password SSH",
                            systemImage: "lock",
                            isDisabled: model.isBusy
                        ) {
                            Task { await model.checkPasswordSelected() }
                        }
                        Divider()
                        AuthenticationCheckRow(
                            title: "Key SSH",
                            check: server.keyCheck,
                            buttonTitle: "Check Key SSH",
                            systemImage: "key.horizontal",
                            isDisabled: model.isBusy
                        ) {
                            Task { await model.checkKeySelected() }
                        }
                    }
                    .padding(.vertical, 5)
                }

                GroupBox("Host Identity") {
                    if server.confirmedHostKeys.isEmpty {
                        Label("No host key has been confirmed", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(server.confirmedHostKeys) { key in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key.algorithm).font(.callout).fontWeight(.medium)
                                    Text(key.fingerprint).font(.caption).monospaced().textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }

                GroupBox("Current Mac") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let key = model.key(for: server) {
                            LabeledContent("Key", value: model.keyDisplayName(key))
                            LabeledContent("Fingerprint") { Text(key.fingerprint).font(.caption).monospaced().textSelection(.enabled) }
                        } else {
                            Text("No local private key is available.").foregroundStyle(.secondary)
                            Button("Generate Ed25519 Key") { Task { await model.generateKey() } }
                        }

                        if let detail = server.statusDetail {
                            Divider()
                            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }

                GroupBox("Device Authorizations") {
                    let authorizations = model.snapshot.authorizations.filter { $0.serverID == server.id }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(authorizations.isEmpty ? "No KeyPort authorizations have been read." : "\(authorizations.count) KeyPort authorization(s)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { Task { await model.refreshRemoteAuthorizations(serverID: server.id) } }
                                .disabled(server.status != .authorized || model.isBusy)
                        }
                        ForEach(authorizations) { authorization in
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(authorization.remoteComment).font(.callout).lineLimit(1)
                                    Text(authorization.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    pendingRevocationID = authorization.id
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Revoke this exact public key fingerprint")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(server.name)
        .confirmationDialog("Revoke this device key from the server?", isPresented: Binding(
            get: { pendingRevocationID != nil },
            set: { if !$0 { pendingRevocationID = nil } }
        )) {
            Button("Revoke Authorization", role: .destructive) {
                guard let id = pendingRevocationID else { return }
                pendingRevocationID = nil
                Task { await model.revokeAuthorization(id) }
            }
            Button("Cancel", role: .cancel) { pendingRevocationID = nil }
        } message: {
            Text("KeyPort will remove only the line whose public key fingerprint matches exactly. Unknown keys are preserved.")
        }
    }
}

private struct AuthenticationCheckRow: View {
    let title: String
    let check: AuthenticationCheck?
    let buttonTitle: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                AuthenticationCheckLabel(check: check)
                Button(action: action) {
                    Label(buttonTitle, systemImage: systemImage)
                }
                .labelStyle(.iconOnly)
                .help(buttonTitle)
                .disabled(isDisabled)
            }
            if let check {
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let checkedAt = check.checkedAt {
                    Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
