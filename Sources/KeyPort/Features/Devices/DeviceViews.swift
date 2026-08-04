import SwiftUI

struct DeviceListView: View {
    let model: AppModel

    var body: some View {
        List(model.snapshot.devices) { device in
            HStack(spacing: 10) {
                Image(systemName: device.isCurrent ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
                    .foregroundStyle(device.isRevoked ? .red : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    Text(device.isCurrent ? "This Mac" : device.id).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Devices")
    }
}

struct DeviceOverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Device Authorization").font(.title2).fontWeight(.semibold)
                Text("Each Mac keeps its own private key. Synced servers retain the same SSH alias while this Mac receives an independent authorization.")
                    .foregroundStyle(.secondary)
                GroupBox("This Mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Device", value: model.currentDevice?.name ?? "Unknown")
                        LabeledContent("Local keys", value: String(model.currentDeviceKeys.count))
                        LabeledContent("Servers awaiting authorization", value: String(model.activeServers.filter { $0.status == .needsAuthorization || $0.status == .syncPending }.count))
                        Button("Authorize Pending Servers") { Task { await model.authorizePendingServers() } }
                            .disabled(model.isBusy || model.activeServers.isEmpty)
                    }
                    .padding(.vertical, 5)
                }
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
        }
    }
}
