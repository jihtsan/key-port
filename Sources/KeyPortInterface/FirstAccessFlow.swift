import Foundation
import Combine

/// Identity comes from a verified server identity, never from its current IP address.
public struct AccessAuthorizationKey: Hashable {
    public let deviceID: String
    public let serverID: String
    public let account: String
    public init(deviceID: String, serverID: String, account: String) {
        self.deviceID = deviceID; self.serverID = serverID; self.account = account
    }
}

public struct AccessHostIdentity: Equatable {
    public let serverID: String
    public let fingerprint: String
    public let needsConfirmation: Bool
    public init(serverID: String, fingerprint: String, needsConfirmation: Bool) {
        self.serverID = serverID; self.fingerprint = fingerprint; self.needsConfirmation = needsConfirmation
    }
}

public enum AccessAuthorizationStatus: Equatable { case absent, installed, unknown }
public enum AccessFlowStep: Equatable { case login, authorization, verification }
public enum AccessFlowFailure: Error, Equatable {
    case unreachable, identityMismatch, authentication, authorization, verification, authorizationUnknown
}
public enum AccessHandoff: Equatable {
    case idle, opening, opened, terminalUnavailable, copying, copied, copyFailed
}
public enum FirstAccessState: Equatable {
    case form, checkingHost, confirmHost(AccessHostIdentity), running(AccessFlowStep)
    case failed(AccessFlowFailure), cancelled, success
}

/// Only completed adapter results advance the flow. Implementations must enforce host trust,
/// idempotent authorization and cancellation at their real service boundary. The executable
/// injects either a fixture adapter or the opt-in local OpenSSH acceptance adapter.
/// Only explicitly classified, non-secret messages may cross into the user interface.
/// Raw stderr and arbitrary localized errors are intentionally excluded.
public protocol AccessFlowFailureDetailProviding: Error {
    var safeAccessFailureDetail: String { get }
}

@MainActor public protocol FirstAccessAdapter: AnyObject {
    var isSimulation: Bool { get }
    var deviceID: String { get }
    func inspectHost(address: String, port: String) async throws -> AccessHostIdentity
    func confirmHost(_ identity: AccessHostIdentity) async throws
    func login(draft: AccessFormDraft, identity: AccessHostIdentity) async throws
    func authorizationStatus(for key: AccessAuthorizationKey) async throws -> AccessAuthorizationStatus
    func authorize(_ key: AccessAuthorizationKey) async throws
    func verify(_ key: AccessAuthorizationKey, address: String, port: String) async throws
    func command(for draft: AccessFormDraft) -> String
    func openTerminal(command: String) async throws
    func copyCommand(_ command: String) async throws
    /// Must release pending credential/session resources; cancellation cannot imply rollback.
    func cancel()
}

extension FirstAccessAdapter {
    public func command(for draft: AccessFormDraft) -> String { "ssh " + draft.alias }
}

@MainActor public final class FirstAccessFlow: ObservableObject {
    @Published public private(set) var state: FirstAccessState = .form
    @Published public private(set) var draft: AccessFormDraft
    @Published public private(set) var authorization: AccessAuthorizationStatus = .absent
    @Published public private(set) var handoff: AccessHandoff = .idle
    @Published public private(set) var failureDetail: String?
    @Published public private(set) var formNotice: String?
    public let aliasDirectory: AliasDirectory
    private let adapter: any FirstAccessAdapter
    private var identity: AccessHostIdentity?
    private var authorizationRecords: [AccessAuthorizationKey: AccessAuthorizationStatus] = [:]
    private var credential = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    public var isSimulation: Bool { adapter.isSimulation }
    public var command: String { adapter.command(for: draft) }
    public var authorizationKey: AccessAuthorizationKey? {
        identity.map { AccessAuthorizationKey(deviceID: adapter.deviceID, serverID: $0.serverID, account: draft.account) }
    }

    public init(draft: AccessFormDraft, adapter: any FirstAccessAdapter, aliasDirectory: AliasDirectory = .init()) {
        var safeDraft = draft; safeDraft.password = ""
        self.draft = safeDraft; self.adapter = adapter; self.aliasDirectory = aliasDirectory
    }
    public func submit(_ input: AccessFormDraft) {
        guard state == .form, input.validationMessage(in: aliasDirectory) == nil else { return }
        invalidate()
        draft = input; draft.password = ""; credential = input.password
        authorization = .absent
        identity = nil; handoff = .idle; formNotice = nil
        state = .checkingHost
        let token = generation
        task = Task { [weak self] in await self?.inspect(token) }
    }
    private func inspect(_ token: UUID) async {
        do {
            let host = try await adapter.inspectHost(address: draft.address, port: draft.port)
            guard current(token) else { return }
            identity = host
            if let key = authorizationKey { authorization = authorizationRecords[key] ?? .absent }
            if host.needsConfirmation { state = .confirmHost(host) }
            else { await execute(token) }
        } catch { fail(error, fallback: .unreachable, token: token) }
    }
    public func confirmHost() {
        guard case .confirmHost(let host) = state else { return }
        state = .checkingHost
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await adapter.confirmHost(host)
                guard current(token) else { return }
                await execute(token)
            } catch { fail(error, fallback: .identityMismatch, token: token) }
        }
    }
    private func execute(_ token: UUID) async {
        guard let identity, let key = authorizationKey, current(token) else { return }
        var fallback = AccessFlowFailure.authentication
        do {
            state = .running(.login)
            var input = draft; input.password = credential
            defer { input.password = "" }
            try await adapter.login(draft: input, identity: identity)
            input.password = ""
            guard current(token) else { return }
            credential = ""
            fallback = .authorization
            state = .running(.authorization)
            let status = try await adapter.authorizationStatus(for: key)
            guard current(token) else { return }
            recordAuthorization(status, for: key)
            guard status != .unknown else { throw AccessFlowFailure.authorizationUnknown }
            if status == .absent {
                // Once installation begins, cancellation/error cannot promise no remote effect.
                recordAuthorization(.unknown, for: key)
                try await adapter.authorize(key)
                guard current(token) else { return }
                recordAuthorization(.installed, for: key)
            }
            fallback = .verification
            state = .running(.verification)
            try await adapter.verify(key, address: draft.address, port: draft.port)
            guard current(token) else { return }
            state = .success
        } catch { fail(error, fallback: fallback, token: token) }
    }
    public func cancel() {
        let oldState = state
        guard oldState != .form && oldState != .success else { return }
        invalidate()
        switch oldState {
        case .checkingHost, .confirmHost, .running(.login):
            state = .form; formNotice = "已取消；非敏感输入已保留，密码已清空。"
        default: state = .cancelled
        }
    }
    public func edit() {
        guard state != .success else { return }
        invalidate(); state = .form
        formNotice = authorization == .absent ? "非敏感输入已保留；密码已清空。" : "授权可能已存在；下次先核对，不会直接重复安装公钥。密码已清空。"
    }
    public func retry() {
        switch state {
        case .failed(.identityMismatch): return // no bypass button for identity changes
        case .failed, .cancelled:
            // Even partial success goes through host identity + login again. Existing-key mode
            // needs no password; password mode returns to the same form for a fresh credential.
            if !draft.existingKey { edit(); return }
            let input = draft
            edit(); submit(input)
        default: break
        }
    }
    public func performHandoff(copy: Bool = false) {
        guard state == .success, handoff != .opening, handoff != .copying else { return }
        handoff = copy ? .copying : .opening
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if copy { try await adapter.copyCommand(command) }
                else { try await adapter.openTerminal(command: command) }
                guard current(token) else { return }
                handoff = copy ? .copied : .opened
            } catch {
                guard current(token) else { return }
                handoff = copy ? .copyFailed : .terminalUnavailable
            }
        }
    }
    public func retainForm(_ input: AccessFormDraft) {
        guard state == .form else { return }
        draft = input; draft.password = ""
    }
    public func close() { invalidate() }
    private func invalidate() {
        failureDetail = nil
        generation = UUID(); task?.cancel(); task = nil
        adapter.cancel(); credential = ""; draft.password = ""
    }
    private func recordAuthorization(_ status: AccessAuthorizationStatus, for key: AccessAuthorizationKey) {
        authorizationRecords[key] = status; authorization = status
    }
    private func current(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }
    private func fail(_ error: Error, fallback: AccessFlowFailure, token: UUID) {
        guard current(token) else { return }
        credential = ""; draft.password = ""
        failureDetail = (error as? any AccessFlowFailureDetailProviding)?.safeAccessFailureDetail
        state = .failed((error as? AccessFlowFailure) ?? fallback)
        adapter.cancel()
    }
}
