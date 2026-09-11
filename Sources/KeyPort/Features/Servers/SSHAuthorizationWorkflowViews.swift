import KeyPortCore
import SwiftUI

struct SSHFirstAccessProgressView: View {
    let state: SSHFirstAccessState
    let onPrimaryAction: (() -> Void)?

    private let stages: [SSHFirstAccessStage] = [
        .targetSelected,
        .hostKeyReview,
        .credentialRequired,
        .credentialVerified,
        .localKeyRequired,
        .readyToAuthorize,
        .authorizing,
        .writtenAwaitingVerification,
        .authorized,
    ]

    var body: some View {
        GroupBox("首次接入") {
            VStack(alignment: .leading, spacing: 10) {
                Text("主机身份 → 凭据 → 本机密钥 → 远端写入 → 公钥复检 → SSH 配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(stages, id: \.self) { stage in
                    stageRow(stage)
                }

                if let failureCode = state.failureCode {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: state.progressStage == .writtenAwaitingVerification ? "exclamationmark.shield.fill" : "pause.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failureCode.title)
                                .fontWeight(.medium)
                            if let recoveryAction = state.recoveryAction,
                               recoveryAction != .none {
                                Text("建议：\(recoveryAction.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let onPrimaryAction,
                   !state.isTerminal || state.stage == .writtenAwaitingVerification {
                    Button {
                        onPrimaryAction()
                    } label: {
                        Label(actionTitle, systemImage: actionSystemImage)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func stageRow(_ stage: SSHFirstAccessStage) -> some View {
        let currentRank = state.progressStage.progressRank
        let rank = stage.progressRank
        let rankCompleted: Bool
        if let rank, let currentRank {
            rankCompleted = currentRank > rank
        } else {
            rankCompleted = false
        }
        let isCompleted = rankCompleted || state.stage == .authorized
        let isCurrent = rank != nil && rank == currentRank
        let icon: String
        let tint: Color
        if isCompleted {
            icon = "checkmark.circle.fill"
            tint = .green
        } else if isCurrent {
            icon = state.stage == .blocked ? "pause.circle.fill" : stage.systemImage
            tint = state.stage == .blocked ? .orange : .blue
        } else {
            icon = "circle"
            tint = .secondary
        }

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(stage.title)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            if isCurrent {
                Spacer()
                Text(state.stage == .blocked ? "等待处理" : "当前")
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .font(.callout)
    }

    private var actionTitle: String {
        state.recoveryAction?.title
            ?? (state.stage == .authorized ? "重新检查" : "继续")
    }

    private var actionSystemImage: String {
        switch state.recoveryAction {
        case .some(.reviewHostKey): "checkmark.shield"
        case .some(.providePassword): "lock.open"
        case .some(.prepareLocalKey): "key"
        case .some(.recheck): "arrow.clockwise"
        case .some(.retry), .some(.none), nil: "arrow.right"
        }
    }
}

struct SSHAuthorizationTargetSelectionView: View {
    let model: AppModel
    let onStart: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID>

    init(model: AppModel, onStart: @escaping ([UUID]) -> Void) {
        self.model = model
        self.onStart = onStart
        _selectedIDs = State(initialValue: Set(model.pendingAuthorizationServers.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("选择要授权的 SSH 账户")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("每个目标会单独记录成功、失败或等待处理状态；成功项不会在重试时重复入队。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            List {
                Section {
                    ForEach(model.pendingAuthorizationServers) { server in
                        Toggle(isOn: binding(for: server.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name)
                                    .fontWeight(.medium)
                                Text("\(server.username)@\(server.endpoint)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    HStack {
                        Text("待处理目标")
                        Spacer()
                        Text("已选 \(selectedIDs.count) / \(model.pendingAuthorizationServers.count)")
                            .font(.caption)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("开始后只需要一次 Touch ID 或系统密码确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("开始授权（\(selectedIDs.count)）") {
                    onStart(Array(selectedIDs))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding()
        }
        .frame(width: 620, height: 560)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }
}

struct SSHAuthorizationBatchView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let plan = model.authorizationBatchPlan {
                header(plan)
                Divider()
                List(plan.items) { item in
                    itemRow(item)
                }
                .listStyle(.inset)
                Divider()
                footer(plan)
            } else {
                ContentUnavailableView("没有批量授权记录", systemImage: "rectangle.stack.badge.xmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 660, height: 590)
    }

    private func header(_ plan: SSHAuthorizationBatchPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(plan.phase.title, systemImage: phaseSystemImage(plan.phase))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(plan.terminalCount) / \(plan.totalCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(plan.terminalCount),
                total: Double(max(plan.totalCount, 1))
            )
            if let reason = plan.pauseReason {
                Label(reason.title, systemImage: "pause.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if plan.phase == .completed && plan.hasFailedItems {
                Label("可只重试失败项，成功项保持可用。", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func itemRow(_ item: SSHAuthorizationBatchItem) -> some View {
        let server = model.activeServers.first(where: { $0.id == item.targetID })
        return HStack(spacing: 10) {
            Image(systemName: item.state.systemImage)
                .foregroundStyle(color(for: item.state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(server?.name ?? "目标已不存在")
                    .fontWeight(.medium)
                if let server {
                    Text("\(server.username)@\(server.endpoint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let failureCode = item.failureCode {
                    Text(failureCode.title)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.state.title)
                    .foregroundStyle(color(for: item.state))
                if item.attemptCount > 0 {
                    Text("第 \(item.attemptCount) 次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func footer(_ plan: SSHAuthorizationBatchPlan) -> some View {
        HStack {
            if plan.phase.isActive || plan.phase == .paused {
                Button("取消本次批量授权", role: .destructive) {
                    model.cancelAuthorizationBatch()
                }
            }
            Spacer()
            if plan.phase == .paused {
                Button("继续处理") {
                    model.resumeAuthorizationBatch()
                }
                .buttonStyle(.bordered)
            }
            if plan.hasFailedItems && !plan.phase.isActive {
                Button("重试失败项") {
                    model.retryFailedAuthorizationBatch()
                }
                .buttonStyle(.borderedProminent)
            }
            Button("关闭") { dismiss() }
        }
        .padding()
    }

    private func phaseSystemImage(_ phase: SSHAuthorizationBatchPhase) -> String {
        switch phase {
        case .pending: "clock"
        case .authorizing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .cancelling: "xmark.circle"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private func color(for state: SSHAuthorizationBatchItemState) -> Color {
        switch state {
        case .pending: .secondary
        case .inProgress: .blue
        case .succeeded: .green
        case .failed: .red
        case .blocked: .orange
        case .skipped, .cancelled: .secondary
        }
    }
}
