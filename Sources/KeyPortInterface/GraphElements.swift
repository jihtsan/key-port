import SwiftUI

struct GraphPathView: View {
    let path: ConfiguredAccessPath
    let layout: DirectGraphLayout
    let selected: Bool
    let serverAlias: String
    let select: () -> Void
    private var accessibilityText: String {
        ["路径 此 Mac 到 " + serverAlias, path.account, path.endpoint, path.verification.rawValue, path.checkedLabel].joined(separator: "，")
    }
    var body: some View {
        let curve = layout.curve(path)
        let end = layout.endpoint(path)
        Group {
            curve.stroke(path.verification.color, style: StrokeStyle(lineWidth: selected ? 3 : 1.5, dash: path.verification == .verified ? [] : [5, 4]))
                .contentShape(curve.strokedPath(StrokeStyle(lineWidth: 18)))
                .onTapGesture(perform: select).accessibilityHidden(true)
            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(path.verification.color)
                .position(x: end.x - 4, y: end.y).accessibilityHidden(true)
            Button(action: select) {
                VStack(spacing: 3) {
                    Text("直连 · " + path.account).font(.system(size: 11, weight: .medium))
                    Text(path.endpoint).font(InterfaceStyle.technical(10)).lineLimit(1)
                    Text(path.verification.rawValue).font(.system(size: 11)).lineLimit(1)
                }.foregroundStyle(path.verification.color).padding(6).frame(width: 228)
                    .background(InterfaceStyle.color(selected ? 0xEAF2FF : 0xFAFBFD), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? InterfaceStyle.blue : .clear))
            }.buttonStyle(.plain).position(layout.laneCenter(path)).accessibilityLabel(accessibilityText)
        }
    }
}

struct GraphServerView: View {
    let server: ServerNaming
    let paths: [ConfiguredAccessPath]
    let selected: Bool
    let select: () -> Void
    private var statusText: String {
        if paths.isEmpty { return "暂无访问路径 · 独立节点" }
        if paths.count == 1 { return paths[0].account + " · " + paths[0].verification.rawValue }
        return "\(paths.count) 条已配置直连路径"
    }
    private var background: Color { InterfaceStyle.color(selected ? 0xEFF5FF : paths.isEmpty ? 0xF3F5F8 : 0xFFFFFF) }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                Text(server.alias).font(InterfaceStyle.technical(15, medium: true)).lineLimit(1).help(server.alias)
                if let description = server.visibleDescription { Text(description).font(.system(size: 11)).lineLimit(1).help(description) }
                Text(statusText).font(.system(size: 11)).foregroundStyle(paths.first?.verification.color ?? Color.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).frame(width: 232, height: 100)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? InterfaceStyle.blue : InterfaceStyle.color(0xDBE2EC)))
        }.buttonStyle(.plain)
            .accessibilityLabel("节点 " + server.alias + (server.visibleDescription.map { "，" + $0 } ?? "") + "，\(paths.count) 条已配置路径")
    }
}


/// Grouping is presentation only: each configured path retains its own identity and status.
struct GraphPathGroupView: View {
    let server: ServerNaming
    let paths: [ConfiguredAccessPath]
    let layout: DirectGraphLayout
    let collapsed: Bool
    let toggle: () -> Void
    var body: some View {
        let target = layout.serverCenter(server.id)
        if collapsed {
            Path { line in
                line.move(to: CGPoint(x: 248, y: layout.deviceCenter.y))
                line.addCurve(to: CGPoint(x: 526, y: target.y),
                              control1: CGPoint(x: 310, y: layout.deviceCenter.y), control2: CGPoint(x: 460, y: target.y))
            }.stroke(InterfaceStyle.muted, lineWidth: 2).accessibilityHidden(true)
            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(InterfaceStyle.muted)
                .position(x: 522, y: target.y).accessibilityHidden(true)
        }
        Button(action: toggle) {
            VStack(spacing: 5) {
                Text(collapsed ? "\(paths.count) 条路径 · 展开" : "收起 \(paths.count) 条路径").font(.system(size: 12, weight: .medium))
                if collapsed { Text(paths.verificationSummary).font(.system(size: 11)) }
            }.foregroundStyle(InterfaceStyle.ink).padding(10).frame(width: 228)
                .background(InterfaceStyle.color(0xEDF0F2), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .position(x: collapsed ? 382 : 642, y: collapsed ? target.y : target.y + 76)
            .accessibilityLabel((collapsed ? "展开" : "收起") + "路径组 " + server.alias + "，" + paths.verificationSummary)
    }
}

extension Array where Element == ConfiguredAccessPath {
    var verificationSummary: String {
        let verified = filter { $0.verification == .verified }.count
        let pending = filter { $0.verification == .pending }.count
        let failed = filter { $0.verification == .failed }.count
        return "\(verified) 已验证 / \(pending) 待验证 / \(failed) 失败"
    }
}
