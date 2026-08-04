import KeyPortCore
import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerDraft
    let title: String
    let onCheckPassword: ((ServerDraft) -> Void)?
    let onSave: (ServerDraft) -> Void

    init(
        title: String,
        initialDraft: ServerDraft = ServerDraft(),
        onCheckPassword: ((ServerDraft) -> Void)? = nil,
        onSave: @escaping (ServerDraft) -> Void
    ) {
        self.title = title
        _draft = State(initialValue: initialDraft)
        self.onCheckPassword = onCheckPassword
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading).padding([.top, .horizontal])
            Form {
                Section("Connection") {
                    TextField("Name", text: $draft.name)
                        .onChange(of: draft.name) { _, _ in draft.updateSuggestedAlias() }
                    TextField("Host or IP", text: $draft.host)
                    TextField("User", text: $draft.username)
                    TextField("Group", text: $draft.group)
                        .onChange(of: draft.group) { _, _ in draft.updateSuggestedAlias() }
                    TextField("SSH alias", text: $draft.alias)
                        .textContentType(.URL)
                        .onChange(of: draft.alias) { _, _ in draft.noteAliasEdit() }
                    Stepper("Port: \(draft.port)", value: $draft.port, in: 1...65535)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let onCheckPassword {
                    Button {
                        onCheckPassword(draft)
                    } label: {
                        Label("Check Password SSH", systemImage: "lock")
                    }
                    .disabled(!isValid)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(title == "Add Server" ? "Save and Check" : "Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 540, height: 430)
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.username.trimmingCharacters(in: .whitespaces).isEmpty &&
        KeyPortNaming.isValidAlias(draft.alias)
    }
}
