import KeyPortCore
import SwiftUI

struct NodeAssociationEditorView: View {
    let server: ServerConnection
    let model: AppModel
    let existingAssociation: NodeAssociation?
    @Environment(\.dismiss) private var dismiss
    @State private var testCaseNodeID: String
    @State private var selectedTargetID: String
    @State private var observedRevision: Int?

    init(server: ServerConnection, model: AppModel, existingAssociation: NodeAssociation? = nil) {
        self.server = server
        self.model = model
        self.existingAssociation = existingAssociation
        _testCaseNodeID = State(initialValue: existingAssociation?.testCaseNodeID ?? "")
        _selectedTargetID = State(initialValue: existingAssociation?.target?.id ?? "")
        _observedRevision = State(initialValue: existingAssociation?.revision)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Test Case 节点关联")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Test Case 节点 ID", text: $testCaseNodeID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(existingAssociation != nil)

                Picker("实际 Tailscale 节点", selection: $selectedTargetID) {
                    Text("请选择").tag("")
                    ForEach(model.stableAssociationTargets, id: \.target.id) { item in
                        Text(item.node.name).tag(item.target.id)
                    }
                }
            }
            .formStyle(.grouped)

            if model.tailscaleStatus == nil {
                Label("Tailscale 状态不可用，现有映射会保留，但无法验证或选择新目标。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if model.stableAssociationTargets.isEmpty {
                Label("当前快照没有带真实 nodeId 的可关联节点。", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
            }

            Text("Test Case 节点 ID 必须由上游提供。KeyPort 不会从主机名、IP、SSH alias 或其他弱线索生成该 ID。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let candidates = model.candidates(for: normalizedTestCaseNodeID)
            if !candidates.isEmpty {
                GroupBox("匹配候选") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { candidate in
                            HStack {
                                Text(candidate.node.name)
                                Spacer()
                                Text(candidate.evidenceKinds.map(\.candidateTitle).joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            Spacer()

            HStack {
                if let existingAssociation {
                    if existingAssociation.autoLinkEnabled {
                        Button("解除关联", role: .destructive) {
                            Task {
                                await model.unlinkNodeAssociation(
                                    testCaseNodeID: existingAssociation.testCaseNodeID,
                                    expectedRevision: observedRevision ?? existingAssociation.revision
                                )
                                dismiss()
                            }
                        }
                        .disabled(model.isBusy)
                    } else {
                        Button("恢复自动匹配") {
                            Task {
                                await model.resumeAutomaticNodeAssociation(
                                    testCaseNodeID: existingAssociation.testCaseNodeID,
                                    expectedRevision: observedRevision ?? existingAssociation.revision
                                )
                                dismiss()
                            }
                        }
                        .disabled(model.isBusy)
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("自动评估") {
                    Task {
                        if let updated = await model.evaluateNodeAssociation(
                            testCaseNodeID: testCaseNodeID,
                            serverID: server.id,
                            expectedRevision: observedRevision
                        ) {
                            observedRevision = updated.revision
                        }
                    }
                }
                .disabled(normalizedTestCaseNodeID.isEmpty || model.isBusy)
                Button(existingAssociation?.target == nil ? "人工关联" : "改绑") {
                    guard let target = selectedTarget else { return }
                    Task {
                        if await model.confirmNodeAssociation(
                            testCaseNodeID: testCaseNodeID,
                            serverID: server.id,
                            target: target,
                            expectedRevision: observedRevision
                        ) != nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    normalizedTestCaseNodeID.isEmpty
                        || selectedTarget == nil
                        || model.isBusy
                )
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 390)
    }

    private var selectedTarget: ActualNodeReference? {
        model.stableAssociationTargets.first { $0.target.id == selectedTargetID }?.target
    }

    private var normalizedTestCaseNodeID: String {
        testCaseNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension NodeAssociationEvidence {
    var candidateTitle: String {
        switch self {
        case .exactMagicDNS: "MagicDNS 精确一致"
        case .exactTailscaleIP: "Tailscale IP 精确一致"
        }
    }
}
