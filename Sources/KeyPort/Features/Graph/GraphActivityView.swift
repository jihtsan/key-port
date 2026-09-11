import KeyPortCore
import SwiftUI

enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case inProgress
    case failed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inProgress: "进行中"
        case .failed: "失败"
        case .all: "全部"
        }
    }

    func matches(_ event: AuditEvent) -> Bool {
        switch self {
        case .inProgress:
            return false
        case .failed:
            return event.level != .info || Self.failureResults.contains(event.result)
        case .all:
            return true
        }
    }

    private static let failureResults: Set<String> = [
        "failed",
        "rejected",
        "unavailable",
        "missing-password",
        "missing-key",
        "not-authorized",
        "pending-confirmation",
        "mismatch-blocked",
        "rejected-during-authorization",
    ]
}

struct GraphActivityListView: View {
    let model: AppModel
    @Binding var selectedEventID: UUID?
    @State private var filter: ActivityFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $filter) {
                ForEach(ActivityFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $selectedEventID) {
                if filter != .failed, model.isBusy {
                    Section("当前任务") {
                        ActivityProgressRow(
                            title: "正在处理操作",
                            subtitle: "完成后会写入活动记录。",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                }

                if filter != .failed, let plan = activeBatchPlan {
                    Section("批量授权") {
                        ActivityProgressRow(
                            title: plan.phase.title,
                            subtitle: "已完成 \(plan.terminalCount) / \(plan.totalCount)，成功 \(plan.succeededCount)，待处理 \(plan.pendingCount)",
                            systemImage: plan.phase == .paused ? "pause.circle.fill" : "rectangle.stack"
                        )
                    }
                }

                if filter == .inProgress {
                    if !model.isBusy && activeBatchPlan == nil {
                        Text("当前没有进行中的任务。")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                } else if visibleEvents.isEmpty {
                    Text(filter == .failed ? "没有失败记录。" : "暂无活动记录。")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Section("历史记录") {
                        ForEach(visibleEvents) { event in
                            ActivityEventRow(event: event)
                                .tag(event.id)
                        }
                    }
                }

                if filter == .all,
                   model.graphWorkspace.isAvailable,
                   !model.graphWorkspace.snapshot.diagnostics.isEmpty {
                    Section("诊断") {
                        ForEach(model.graphWorkspace.snapshot.diagnostics) { diagnostic in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(diagnostic.code.rawValue)
                                    .fontWeight(.medium)
                                Text("\(diagnostic.subject.entityType.rawValue) · \(diagnostic.subject.stableID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("活动")
        .onAppear { synchronizeSelection() }
        .onChange(of: filter) { _, _ in synchronizeSelection() }
        .onChange(of: model.snapshot.auditEvents) { _, _ in synchronizeSelection() }
        .overlay {
            if filter != .inProgress,
               visibleEvents.isEmpty,
               !model.isBusy,
               activeBatchPlan == nil,
               !(filter == .all && !model.graphWorkspace.snapshot.diagnostics.isEmpty) {
                ContentUnavailableView(
                    filter == .failed ? "没有失败记录" : "暂无活动",
                    systemImage: filter == .failed ? "checkmark.circle" : "clock.arrow.circlepath"
                )
            }
        }
    }

    private var visibleEvents: [AuditEvent] {
        model.snapshot.auditEvents
            .filter { filter.matches($0) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var activeBatchPlan: SSHAuthorizationBatchPlan? {
        guard let plan = model.authorizationBatchPlan, !plan.isFinished else { return nil }
        return plan
    }

    private func synchronizeSelection() {
        guard let selectedEventID,
              visibleEvents.contains(where: { $0.id == selectedEventID }) else {
            self.selectedEventID = visibleEvents.first?.id
            return
        }
    }
}

private struct ActivityProgressRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ActivityEventRow: View {
    let event: AuditEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.level.systemImage)
                .foregroundStyle(event.level.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.localizedAction)
                        .fontWeight(.medium)
                    Spacer()
                    Text(event.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(event.localizedCategory) · \(event.localizedResult)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ActivityDetailView: View {
    let model: AppModel
    let selectedEventID: UUID?

    var body: some View {
        if let event = selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: event.level.systemImage)
                            .font(.title2)
                            .foregroundStyle(event.level.tint)
                            .frame(width: 42, height: 42)
                            .background(event.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.localizedAction)
                                .font(.title3.weight(.semibold))
                            Text(event.localizedResult)
                                .foregroundStyle(event.level.tint)
                        }
                    }

                    GroupBox("审计详情") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("分类", value: event.localizedCategory)
                            LabeledContent("操作", value: event.localizedAction)
                            LabeledContent("结果", value: event.localizedResult)
                            LabeledContent("级别", value: event.level.title)
                            LabeledContent("时间", value: event.timestamp.formatted(date: .abbreviated, time: .standard))
                            if let targetID = event.targetID {
                                LabeledContent("目标标识", value: targetID)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }

                    Text("活动记录只保存分类、稳定目标标识、阶段和结果类型，不包含密码、私钥、命令输出或原始身份验证数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .navigationTitle("活动详情")
        } else {
            Form {
                Section("活动") {
                    LabeledContent("历史记录", value: String(model.snapshot.auditEvents.count))
                    LabeledContent("失败记录", value: String(model.snapshot.auditEvents.filter { ActivityFilter.failed.matches($0) }.count))
                    Text("选择一条活动记录以查看结构化详情。")
                        .foregroundStyle(.secondary)
                    Button("清除活动记录", role: .destructive) {
                        Task { await model.clearAuditLog() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("活动")
        }
    }

    private var selectedEvent: AuditEvent? {
        guard let selectedEventID else { return nil }
        return model.snapshot.auditEvents.first { $0.id == selectedEventID }
    }
}

private extension AuditEvent.Level {
    var title: String {
        switch self {
        case .info: "信息"
        case .warning: "提醒"
        case .error: "错误"
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
