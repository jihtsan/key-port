import KeyPortCore
import SwiftUI

struct GraphActivityListView: View {
    let model: AppModel

    var body: some View {
        List {
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("有操作正在进行")
                        .foregroundStyle(.secondary)
                }
            }

            if model.graphWorkspace.isAvailable && !model.graphWorkspace.snapshot.diagnostics.isEmpty {
                Section("Graph 诊断") {
                    ForEach(model.graphWorkspace.snapshot.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.code.rawValue)
                                .fontWeight(.medium)
                            Text("\(diagnostic.subject.entityType.rawValue) · \(diagnostic.subject.stableID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("本机活动") {
                ForEach(model.snapshot.auditEvents.sorted { $0.timestamp > $1.timestamp }) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(graphActivityAction(event.action))
                                .fontWeight(.medium)
                            Spacer()
                            Text(event.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(event.category) · \(graphActivityResult(event.result))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("活动")
        .overlay {
            if !model.isBusy && model.snapshot.auditEvents.isEmpty && model.graphWorkspace.snapshot.diagnostics.isEmpty {
                ContentUnavailableView("暂无活动", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

private func graphActivityAction(_ action: String) -> String {
    switch action {
    case "load": "加载应用状态"
    case "create": "创建"
    case "update": "更新"
    case "delete": "删除"
    case "sync": "同步"
    case "install": "启用密钥访问"
    case "key-check": "检测密钥访问"
    default: action
    }
}

private func graphActivityResult(_ result: String) -> String {
    switch result {
    case "success", "succeeded": "成功"
    case "failed": "失败"
    case "unavailable": "不可用"
    default: result
    }
}
