import AppKit
import Foundation
import KeyPortCore
import KeyPortInterface

/// Bridges the approved flow to existing OpenSSH/key/AskPass services. No fixture transitions.
@MainActor final class OpenSSHFirstAccessAdapter: FirstAccessAdapter {
    let isSimulation = false
    var deviceID: String { store.state.deviceID }
    private let store: AccessPilotStore
    private let runner: ProcessRunner
    private let ssh: OpenSSHService
    private let keyService: SSHKeyService
    private let expectedServerID: String?
    private var epoch = UUID()
    private var observed: AccessPilotStore.Trust?
    private var server: ServerConnection?
    private var key: SSHKeyRecord?
    private var password = Data()
    private(set) var connectionID: String?
    private var handoffCommand = ""

    init(store: AccessPilotStore, expectedServerID: String? = nil, executor: any ProcessExecuting = ProcessExecutor(), askPassPath: String? = nil) {
        self.store = store; self.expectedServerID = expectedServerID
        let runner = ProcessRunner(executor: executor); self.runner = runner
        ssh = OpenSSHService(runner: runner, paths: store.paths,
            askPassPath: askPassPath ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyPortAskPass").path,
            isolatedConfiguration: true)
        keyService = SSHKeyService(runner: runner, paths: store.paths)
    }
    func inspectHost(address: String, port: String) async throws -> AccessHostIdentity {
        let token = epoch
        var draft = AccessFormDraft(); draft.alias = "validation"; draft.address = address; draft.port = port; draft.account = "validation"; draft.existingKey = true
        guard draft.validationMessage == nil, AccessPilotStore.safeConfigValue(address), let number = Int(port) else { throw AccessFlowFailure.unreachable }
        connectionID = store.state.connections.first {
            (expectedServerID == nil || $0.serverID == expectedServerID) && $0.address == address && $0.port == number
        }?.id
        let result = try await runner.run("/usr/bin/ssh-keyscan", arguments: ["-T", "5", "-t", "ed25519", "-p", port, address])
        try check(token)
        let keys = result.stdout.split(separator: "\n").compactMap { line -> HostKeyRecord? in
            guard !line.hasPrefix("#"), let parsed = PublicKeyParser.parse(String(line)), parsed.type == "ssh-ed25519" else { return nil }
            // Do not trust the endpoint text returned by the scanner; bind key material ourselves.
            let name = number == 22 ? address : "[\(address)]:\(number)"
            return .init(algorithm: parsed.type, fingerprint: parsed.fingerprint, knownHostsLine: "\(name) \(parsed.type) \(parsed.blob)")
        }
        guard let hostKey = keys.first, Set(keys.map(\.fingerprint)).count == 1 else { throw AccessFlowFailure.unreachable }
        let endpointTrust = store.state.trusts.first { $0.address == address && $0.port == number }
        let serverID = expectedServerID ?? endpointTrust?.serverID ?? UUID().uuidString
        let nodeTrusts = store.state.trusts.filter { $0.serverID == serverID }
        guard endpointTrust.map({ $0.key.fingerprint == hostKey.fingerprint && $0.serverID == serverID }) ?? true,
              nodeTrusts.allSatisfy({ $0.key.fingerprint == hostKey.fingerprint }) else { throw AccessFlowFailure.identityMismatch }
        observed = .init(serverID: serverID, address: address, port: number, key: hostKey)
        let needsConfirmation = endpointTrust == nil
        if !needsConfirmation { try store.trust(observed!) }
        return .init(serverID: serverID, fingerprint: hostKey.fingerprint, needsConfirmation: needsConfirmation)
    }
    func confirmHost(_ identity: AccessHostIdentity) async throws {
        try Task.checkCancellation()
        guard let observed, observed.serverID == identity.serverID, observed.key.fingerprint == identity.fingerprint else { throw AccessFlowFailure.identityMismatch }
        try store.trust(observed)
    }
    func login(draft input: AccessFormDraft, identity: AccessHostIdentity) async throws {
        let token = epoch
        var validationInput = input; validationInput.editingEntryID = identity.serverID
        guard let observed, identity.serverID == observed.serverID,
              store.state.trusts.contains(where: { $0.serverID == observed.serverID && $0.address == observed.address && $0.port == observed.port && $0.key.fingerprint == identity.fingerprint }),
              validationInput.validationMessage(in: store.aliases) == nil, AccessPilotStore.safeConfigValue(input.account),
              input.account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else { throw AccessFlowFailure.authentication }
        try store.installation.validateAlias(input.alias)
        var draft = input; draft.password = ""
        let selectedKey: SSHKeyRecord
        if draft.existingKey && !draft.privateKeyPath.isEmpty {
            let path = draft.privateKeyPath
            guard path.hasPrefix("/"), AccessPilotStore.safeConfigValue(path), FileManager.default.fileExists(atPath: path),
                  let line = try? String(contentsOfFile: path + ".pub", encoding: .utf8), let parsed = PublicKeyParser.parse(line) else { throw AccessPilotError.missingKey }
            selectedKey = store.state.keys.first(where: { $0.privateKeyPath == path && $0.fingerprint == parsed.fingerprint })
                ?? .init(id: parsed.fingerprint, deviceID: deviceID, kind: parsed.type == "ssh-ed25519" ? .ed25519 : .other,
                    publicKey: line.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: parsed.fingerprint, privateKeyPath: path,
                    isInAgent: false, origin: .scanned, isLocallyAvailable: true)
            try store.addKey(selectedKey)
        } else if let keyID = store.state.connections.first(where: { $0.serverID == observed.serverID && $0.account == draft.account })?.keyID,
                  let existing = store.state.keys.first(where: { $0.id == keyID }) { selectedKey = existing }
        else if let existing = store.state.keys.first(where: { $0.origin == .generated }) { selectedKey = existing }
        else {
            guard !draft.existingKey else { throw AccessPilotError.missingKey }
            selectedKey = try await keyService.generate(device: .init(id: deviceID, name: "KeyPort Access Pilot", isCurrent: true))
            try check(token); try store.addKey(selectedKey)
        }
        try check(token)
        let route = ServerConnection(name: draft.description, host: observed.address, port: observed.port, username: draft.account, alias: draft.alias, confirmedHostKeys: [observed.key])
        connectionID = try store.save(draft: draft, serverID: observed.serverID, key: selectedKey)
        server = route; key = selectedKey
        if draft.existingKey {
            guard try await ssh.testPublicKey(server: route, key: selectedKey) else { throw AccessFlowFailure.authentication }
        } else {
            password = Data(input.password.utf8)
            guard try await ssh.testPassword(server: route, passwordData: password) else { throw AccessFlowFailure.authentication }
        }
        try check(token)
    }
    func authorizationStatus(for authorization: AccessAuthorizationKey) async throws -> AccessAuthorizationStatus {
        let token = epoch
        let (route, key) = try session(authorization)
        let installed: Bool
        if try await ssh.testPublicKey(server: route, key: key) { installed = true }
        else {
            guard !password.isEmpty else { throw AccessFlowFailure.authorizationUnknown }
            installed = try await ssh.containsPublicKey(server: route, key: key, passwordData: password)
        }
        try check(token)
        let status: AccessAuthorizationStatus = installed ? .installed : .absent
        try store.record(status, serverID: authorization.serverID, account: authorization.account, keyID: key.id)
        return status
    }
    func authorize(_ authorization: AccessAuthorizationKey) async throws {
        let token = epoch
        let (route, key) = try session(authorization)
        guard !password.isEmpty else { throw AccessFlowFailure.authorizationUnknown }
        try store.record(.unknown, serverID: authorization.serverID, account: authorization.account, keyID: key.id)
        defer { clearPassword() }
        try await ssh.installPublicKey(server: route, key: key, passwordData: password)
        try check(token)
        try store.record(.installed, serverID: authorization.serverID, account: authorization.account, keyID: key.id)
    }
    func verify(_ authorization: AccessAuthorizationKey, address: String, port: String) async throws {
        let token = epoch
        defer { clearPassword() }
        let (route, key) = try session(authorization)
        guard route.host == address, route.port == Int(port), let connectionID else { throw AccessFlowFailure.verification }
        guard try await ssh.testPublicKey(server: route, key: key) else { throw AccessFlowFailure.verification }
        try check(token)
        guard let connection = store.state.connections.first(where: { $0.id == connectionID }) else { throw AccessPilotError.storage }
        try store.checked(connectionID, success: true)
        handoffCommand = try store.command(for: connection)
    }
    func recordFailure(_ failure: AccessFlowFailure) throws {
        if let connectionID { try store.checked(connectionID, success: false, unreachable: failure == .unreachable) }
    }
    func command(for draft: AccessFormDraft) -> String { handoffCommand }
    func openTerminal(command: String) async throws {
        guard !command.isEmpty, command == handoffCommand else { throw AccessPilotError.terminal }
        try await Self.handoff(command, directory: store.paths.applicationSupport)
    }
    static func handoff(_ command: String, directory: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw AccessPilotError.terminal }
        let url = directory.appendingPathComponent("terminal-\(UUID().uuidString).command")
        // This file contains only a quoted SSH invocation, never a password or key material.
        try Data(("#!/bin/sh\nexec " + command + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
    }
    func copyCommand(_ command: String) async throws {
        guard !command.isEmpty, command == handoffCommand else { throw AccessPilotError.terminal }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(command, forType: .string) else { throw AccessPilotError.terminal }
    }
    func cancel() { epoch = UUID(); clearPassword(); server = nil; key = nil; observed = nil }
    private func clearPassword() { password.resetBytes(in: password.indices); password.removeAll(keepingCapacity: false) }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard token == epoch else { throw CancellationError() } }
    private func session(_ authorization: AccessAuthorizationKey) throws -> (ServerConnection, SSHKeyRecord) {
        guard authorization.deviceID == deviceID, authorization.serverID == observed?.serverID,
              let server, server.username == authorization.account, let key else { throw AccessFlowFailure.identityMismatch }
        return (server, key)
    }
}

// SSHServiceError messages are locally classified strings, never raw server stderr.
extension SSHServiceError: AccessFlowFailureDetailProviding {
    var safeAccessFailureDetail: String { errorDescription ?? "SSH 操作未完成。" }
}

extension SSHConfigService.AliasInstallation.Failure: AccessFlowFailureDetailProviding {
    var safeAccessFailureDetail: String { message }
}
