import KeyPortCore
import SwiftUI

struct AuditLogListView: View {
    let model: AppModel

    var body: some View {
        List(model.snapshot.auditEvents) { event in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.action).fontWeight(.medium)
                    Spacer()
                    Text(event.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(event.category) · \(event.result)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .navigationTitle("Audit Log")
        .overlay {
            if model.snapshot.auditEvents.isEmpty {
                ContentUnavailableView("No Audit Events", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

struct AuditOverviewView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Structured Audit Log") {
                LabeledContent("Events retained", value: String(model.snapshot.auditEvents.count))
                Text("Logs contain action categories, stable target identifiers, stages, and result types. Passwords, private keys, command output, and raw authentication payloads are never recorded.")
                    .foregroundStyle(.secondary)
                Button("Clear Log", role: .destructive) { Task { await model.clearAuditLog() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audit Log")
    }
}
