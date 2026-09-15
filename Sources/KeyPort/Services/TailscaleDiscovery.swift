import Foundation
import KeyPortCore
import KeyPortInterface

struct TailscaleDiscovery {
    enum Failure: LocalizedError {
        case unavailable, failed, stopped(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "未找到 Tailscale。请安装并登录 Tailscale 后重新检测。"
            case .failed: return "无法读取 Tailscale 状态。请确认客户端正在运行，然后重新检测。"
            case .stopped(let state): return "Tailscale 尚未连接（\(state)）。请在 Tailscale 中登录并连接后重试。"
            }
        }
    }
    static var executablePaths: [String] {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tailscale.app/Contents/MacOS/Tailscale").path,
         "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    }
    static func detect(executor: any ProcessExecuting = ProcessExecutor(), executable: String? = nil) async throws -> TailscaleStatus {
        guard let path = executable ?? executablePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw Failure.unavailable }
        let result = try await executor.execute(.init(executable: path, arguments: ["status", "--json"], environment: ["TERM": "dumb", "SHLVL": "1"], limits: .sshDefault))
        try Task.checkCancellation()
        guard result.succeeded else { throw Failure.failed }
        let status = try TailscaleStatusParser.parse(result.stdout)
        guard status.backendState.caseInsensitiveCompare("Running") == .orderedSame else { throw Failure.stopped(status.backendState) }
        return status
    }
    static func addresses(for node: TailscaleNode) -> [String] {
        var seen = Set<String>()
        return ([node.dnsName].compactMap { $0 } + node.addresses).filter {
            AccessFormDraft.isValidHost($0) && seen.insert($0.lowercased()).inserted
        }
    }
    static func apply(addresses selected: [String], node: TailscaleNode, to draft: inout AccessFormDraft) {
        let valid = Set(addresses(for: node))
        let selected = selected.filter { valid.contains($0) }
        guard let first = selected.first else { return }
        if draft.address.isEmpty { apply(address: first, node: node, to: &draft) }
        var seen = Set(draft.addresses.map { $0.lowercased() })
        draft.additionalAddresses.append(contentsOf: selected.filter { seen.insert($0.lowercased()).inserted })
    }
    static func apply(address: String, node: TailscaleNode, to draft: inout AccessFormDraft) {
        guard addresses(for: node).contains(address) else { return }
        draft.address = address
        if draft.editingEntryID == nil {
            if draft.description.isEmpty { draft.description = node.name }
            if draft.alias.isEmpty { draft.alias = KeyPortNaming.alias(group: "Tailscale", name: node.name) }
        }
    }
}
