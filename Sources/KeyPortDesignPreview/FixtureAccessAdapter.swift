import Foundation
import Combine
import SwiftUI
import KeyPortInterface

/// Deliberately confined to the preview executable. There are no timers, network calls,
/// subprocesses, clipboard writes, disk persistence or production service dependencies.
@MainActor final class FixtureAccessAdapter: FirstAccessAdapter, ObservableObject {
    enum Scenario: String, CaseIterable {
        case success = "首次连接成功", trusted = "已信任主机", existing = "已授权账户／新增地址"
        case unreachable = "地址不可达", mismatch = "主机身份不匹配", login = "登录失败"
        case authorization = "授权失败（未写入）", verification = "已授权但验证失败"
        case uncertain = "授权结果未知", terminal = "终端不可用", copy = "复制失败"
    }
    @Published var scenario = Scenario.success
    @Published private(set) var pending: String?
    let isSimulation = true
    let deviceID = "fixture-this-mac"
    private var continuation: CheckedContinuation<Void, Error>?
    private var installed: Set<AccessAuthorizationKey> = []
    private var trusted = false
    private(set) var installCount = 0
    func inspectHost(address: String, port: String) async throws -> AccessHostIdentity {
        if scenario == .unreachable { throw AccessFlowFailure.unreachable }
        if scenario == .mismatch { throw AccessFlowFailure.identityMismatch }
        return AccessHostIdentity(serverID: "fixture-server-1", fingerprint: "SHA256:DEMO-ONLY-NOT-A-REAL-HOST-FINGERPRINT", needsConfirmation: !trusted && scenario != .trusted && scenario != .existing)
    }
    func confirmHost(_ identity: AccessHostIdentity) async throws { trusted = true }
    func login(draft: AccessFormDraft, identity: AccessHostIdentity) async throws {
        try await wait("登录验证")
        if scenario == .login { throw AccessFlowFailure.authentication }
    }
    func authorizationStatus(for key: AccessAuthorizationKey) async throws -> AccessAuthorizationStatus {
        if scenario == .existing { installed.insert(key) }
        return installed.contains(key) ? .installed : .absent
    }
    func authorize(_ key: AccessAuthorizationKey) async throws {
        try await wait("设备授权")
        if scenario == .authorization { throw AccessFlowFailure.authorization }
        if installed.insert(key).inserted { installCount += 1 }
        if scenario == .uncertain { throw AccessFlowFailure.authorizationUnknown }
    }
    func verify(_ key: AccessAuthorizationKey, address: String, port: String) async throws {
        try await wait("免密验证")
        if scenario == .verification { throw AccessFlowFailure.verification }
    }
    func openTerminal(command: String) async throws {
        try await wait("终端交接")
        if scenario == .terminal { throw AccessFlowFailure.unreachable }
    }
    func copyCommand(_ command: String) async throws {
        try await wait("复制命令")
        if scenario == .copy { throw AccessFlowFailure.unreachable }
    }
    private func wait(_ label: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; pending = label
        }
        try Task.checkCancellation()
    }
    func complete() {
        let next = continuation; continuation = nil; pending = nil
        next?.resume()
    }
    func cancel() {
        let next = continuation; continuation = nil; pending = nil
        next?.resume(throwing: CancellationError())
    }
}

@MainActor struct FixtureAccessPreview: View {
    @StateObject private var adapter: FixtureAccessAdapter
    @StateObject private var flow: FirstAccessFlow
    let initial: AccessFormDraft
    let onClose: (AccessFormDraft) -> Void
    init(draft: AccessFormDraft, aliasDirectory: AliasDirectory, onClose: @escaping (AccessFormDraft) -> Void) {
        let adapter = FixtureAccessAdapter()
        _adapter = StateObject(wrappedValue: adapter)
        _flow = StateObject(wrappedValue: FirstAccessFlow(draft: draft, adapter: adapter, aliasDirectory: aliasDirectory))
        initial = draft; self.onClose = onClose
    }
    var body: some View {
        FirstAccessView(flow: flow, initialDraft: initial, onClose: onClose) {
            HStack(spacing: 12) {
                Menu("模拟场景：" + adapter.scenario.rawValue) {
                    ForEach(FixtureAccessAdapter.Scenario.allCases, id: \.self) { scenario in
                        Button(scenario.rawValue) { adapter.scenario = scenario }
                    }
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("模拟场景")
                if let pending = adapter.pending {
                    Button("模拟完成：" + pending) { adapter.complete() }
                        .buttonStyle(.plain).foregroundStyle(InterfaceStyle.blue)
                        .keyboardShortcut("j", modifiers: .command)
                }
            }.font(.system(size: 10))
        }
    }
}
