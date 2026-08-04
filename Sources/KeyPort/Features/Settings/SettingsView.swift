import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("KeyPort.clipboardClearSeconds") private var clipboardClearSeconds = 30.0
    @AppStorage("KeyPort.cloudSyncEnabled") private var cloudSyncEnabled = false
    @AppStorage("KeyPort.defaultPasswordSync") private var defaultPasswordSync = false
    @State private var archivePassword = ""

    var body: some View {
        TabView {
            Form {
                Section("Device") {
                    LabeledContent("Current device", value: model.currentDevice?.name ?? "Not registered")
                    LabeledContent("Device ID", value: model.currentDevice?.id ?? "Unavailable")
                }
                Section("SSH Files") {
                    LabeledContent("Managed config", value: "~/.ssh/keyport/config")
                    LabeledContent("Known hosts", value: "~/.ssh/keyport/known_hosts")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Metadata") {
                    Toggle("Sync non-secret metadata with iCloud", isOn: $cloudSyncEnabled)
                    LabeledContent("Status", value: model.cloudState.title)
                    Button("Sync Now") { Task { await model.synchronizeCloud() } }
                        .disabled(!cloudSyncEnabled || model.isBusy)
                }
                Section("Passwords") {
                    Toggle("Default to iCloud Keychain for new passwords", isOn: $defaultPasswordSync)
                        .disabled(!model.canSynchronizePasswords)
                    if !model.canSynchronizePasswords {
                        Label("iCloud Keychain sync is unavailable in this build", systemImage: "icloud.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Server passwords are Keychain items and are never included in CloudKit metadata.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Sync", systemImage: "icloud") }

            Form {
                Section("Local Authentication") {
                    Text("Password access and batch authorization require Touch ID or the Mac login password.")
                }
                Section("Clipboard") {
                    Stepper("Clear copied secrets after \(Int(clipboardClearSeconds)) seconds", value: $clipboardClearSeconds, in: 10...120, step: 10)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Security", systemImage: "lock.shield") }

            Form {
                Section("Encrypted Metadata Archive") {
                    SecureField("Recovery password", text: $archivePassword)
                    HStack {
                        Button("Export") { Task { await model.exportMetadata(password: archivePassword) } }
                        Button("Import") { Task { await model.importMetadata(password: archivePassword) } }
                    }
                    .disabled(archivePassword.isEmpty || model.isBusy)
                }
                Section("Contents") {
                    LabeledContent("Included", value: "Servers, aliases, public keys, devices, authorizations")
                    LabeledContent("Excluded", value: "Passwords, private keys, local paths, audit log")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Archive", systemImage: "archivebox") }
        }
        .padding(10)
        .onAppear {
            if !model.canSynchronizePasswords {
                defaultPasswordSync = false
            }
        }
    }
}
