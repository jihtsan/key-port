import KeyPortCore
import SwiftUI

struct NodeEndpointEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let nodeName: String
    let onSave: (NodeEndpointDraft) async throws -> Void

    @State private var draft: NodeEndpointDraft
    @State private var portText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        nodeName: String,
        initialDraft: NodeEndpointDraft = NodeEndpointDraft(),
        onSave: @escaping (NodeEndpointDraft) async throws -> Void
    ) {
        self.nodeName = nodeName
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
        _portText = State(initialValue: String(initialDraft.port))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("为 \(nodeName) 添加访问地址")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal])

            Form {
                Section("SSH 端点") {
                    TextField("地址或 IP", text: $draft.address)
                    TextField("显示名称（可选）", text: $draft.label)
                    TextField("端口", text: $portText)
                        .frame(width: 120)
                        .onChange(of: portText) { _, value in
                            let digits = value.filter(\.isNumber)
                            if digits != value { portText = digits }
                            draft.port = Int(digits) ?? 0
                        }
                }

                Section("网络要求") {
                    Picker("访问范围", selection: $draft.networkScope) {
                        ForEach(NetworkScope.allCases, id: \.self) { scope in
                            Text(scope.requirementTitle).tag(scope)
                        }
                    }
                    Text("网络要求描述使用这个地址前需要满足的条件，不代表当前实时可达状态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .disabled(isSaving)
                Button("保存地址") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 390)
    }

    private var isValid: Bool {
        !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(draft.port)
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                isSaving = false
                saveError = UserFacingText.localizedError(error)
            }
        }
    }
}
