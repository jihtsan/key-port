import KeyPortCore
import SwiftUI

struct ServerListView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        Table(model.activeServers, selection: $model.selectedServerID) {
            TableColumn("Name", value: \.name)
            TableColumn("Endpoint") { server in
                Text(server.endpoint).foregroundStyle(.secondary)
            }
            TableColumn("Password") { server in
                AuthenticationCheckLabel(check: server.passwordCheck)
            }
            .width(min: 92, ideal: 110)
            TableColumn("Key SSH") { server in
                AuthenticationCheckLabel(check: server.keyCheck)
            }
            .width(min: 92, ideal: 110)
        }
        .searchable(text: $model.searchText, prompt: "Name, address, user, group")
        .navigationTitle("Servers")
        .contextMenu(forSelectionType: UUID.self) { selection in
            if selection.count == 1, let serverID = selection.first {
                Button("Check Password SSH") { Task { await model.checkPassword(serverID: serverID) } }
                Button("Check Key SSH") { Task { await model.checkKey(serverID: serverID) } }
                Button("Copy SSH Alias") { model.copyAlias(serverID: serverID) }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.deleteServer(serverID) } }
            }
        }
        .overlay {
            if model.activeServers.isEmpty {
                ContentUnavailableView("No Servers", systemImage: "server.rack", description: Text("Add a server to begin host identity verification."))
            }
        }
    }
}

struct AuthenticationCheckLabel: View {
    let check: AuthenticationCheck?

    var body: some View {
        if let check {
            Label(check.state.title, systemImage: check.state.systemImage)
                .foregroundStyle(check.state.color)
                .lineLimit(1)
        } else {
            Label("Not checked", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct StatusLabel: View {
    let status: AuthorizationStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .foregroundStyle(status.color)
            .lineLimit(1)
    }
}

private extension AuthorizationStatus {
    var systemImage: String {
        switch self {
        case .authorized: "checkmark.circle.fill"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .hostKeyMismatch, .authorizationConflict: "exclamationmark.shield.fill"
        case .hostKeyPending: "questionmark.diamond.fill"
        case .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: "xmark.circle.fill"
        case .missingLocalKey: "key.slash"
        case .syncPending: "icloud"
        case .needsAuthorization: "key.horizontal"
        }
    }

    var color: Color {
        switch self {
        case .authorized: .green
        case .checking, .syncPending: .blue
        case .hostKeyPending, .needsAuthorization, .missingLocalKey: .orange
        case .hostKeyMismatch, .authorizationConflict, .unreachable, .passwordAuthenticationFailed, .keyAuthenticationFailed: .red
        }
    }
}

private extension AuthenticationCheckState {
    var systemImage: String {
        switch self {
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking: .blue
        case .succeeded: .green
        case .failed: .red
        case .blocked: .orange
        }
    }
}
