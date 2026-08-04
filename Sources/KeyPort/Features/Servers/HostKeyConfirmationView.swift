import KeyPortCore
import SwiftUI

struct HostKeyConfirmationView: View {
    let keys: [HostKeyRecord]
    let previousKeys: [HostKeyRecord]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(previousKeys.isEmpty ? "Confirm Server Identity" : "Confirm Host Key Change", systemImage: previousKeys.isEmpty ? "checkmark.shield" : "exclamationmark.shield")
                .font(.title2).fontWeight(.semibold)
            Text(previousKeys.isEmpty ? "These fingerprints were returned by the current network endpoint. Compare them with a trusted source before confirming." : "The current endpoint returned different host key material. Authentication is blocked until you compare both sets with a trusted source and explicitly accept the rotation.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if !previousKeys.isEmpty {
                    fingerprintList(title: "Previously Confirmed", keys: previousKeys)
                }
                fingerprintList(title: previousKeys.isEmpty ? "Observed Fingerprints" : "Currently Observed", keys: keys)
            }
            .frame(minHeight: 170)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("I Verified These Fingerprints", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: previousKeys.isEmpty ? 620 : 820, height: 390)
    }

    private func fingerprintList(title: String, keys: [HostKeyRecord]) -> some View {
        GroupBox(title) {
            List(keys) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(key.algorithm).fontWeight(.medium)
                    Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
