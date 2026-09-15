import Foundation

public struct SSHPolicyExecutionPlan: Sendable {
    public let profile: SSHConnectionProfile
    public let nodeID: UUID
    public let username: String
    public let key: SSHKey
    public let endpoints: [Endpoint]
    public let knownHostsLines: [String]
    public var hostKeyAlias: String { "keyport-node-" + nodeID.uuidString.lowercased() }
}

public enum SSHPolicyCompiler {
    public enum Failure: Error { case invalidPolicy, missingKey, missingAuthorization, identityConflict, noVerifiedCandidates }
    public static func evidence(endpoint: Endpoint, fingerprint: String, keyFingerprint: String, username: String) -> String {
        HostV6.CanonicalJSON.sha256(Data("\(endpoint.id)|\(endpoint.address)|\(endpoint.port)|\(fingerprint)|\(keyFingerprint)|\(username)".utf8))
    }
    public static func compile(profile: SSHConnectionProfile, topology: TopologySnapshot, deviceID: String, keyID: String?) throws -> SSHPolicyExecutionPlan {
        guard !profile.isDeleted, profile.policyVersion == 1,
              let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }),
              topology.activeNodes.contains(where: { $0.id == account.nodeID }),
              !profile.candidateEndpointIDs.isEmpty else { throw Failure.invalidPolicy }
        guard let key = topology.sshKeys.first(where: { $0.id == keyID && $0.deviceID == deviceID && $0.privateKeyPath != nil && $0.isLocallyAvailable }) else { throw Failure.missingKey }
        guard topology.authorizations.contains(where: { !$0.isDeleted && $0.accountID == account.id && $0.fingerprint == key.fingerprint && $0.remoteState == .authorized && $0.relationState == .active }) else { throw Failure.missingAuthorization }
        let desired = try SSHRoutePolicyResolver.endpoints(for: profile, nodeID: account.nodeID, in: topology)
        let candidateIDs = Set(desired.map(\.id))
        guard !topology.accessVerifications.contains(where: { $0.deviceID == deviceID && $0.accountID == account.id && $0.status == .hostKeyMismatch && $0.endpointID.map(candidateIDs.contains) == true }) else { throw Failure.identityConflict }
        let nodeEndpoints = Set(topology.activeEndpoints.filter { $0.nodeID == account.nodeID }.map(\.id))
        let trusts = topology.hostKeyTrusts.filter { !$0.isDeleted && $0.state == .confirmed && $0.algorithm == "ssh-ed25519" && nodeEndpoints.contains($0.endpointID) }
        guard Set(trusts.map(\.fingerprint)).count <= 1 else { throw Failure.identityConflict }
        var endpoints: [Endpoint] = [], lines = Set<String>()
        let hostAlias = "keyport-node-" + account.nodeID.uuidString.lowercased()
        for endpoint in desired {
            guard let trust = trusts.first(where: { $0.endpointID == endpoint.id }),
                  let parsed = PublicKeyParser.parse(trust.knownHostsLine), parsed.fingerprint == trust.fingerprint,
                  topology.accessVerifications.contains(where: { $0.accountID == account.id && $0.profileID == profile.id && $0.endpointID == endpoint.id && $0.deviceID == deviceID && $0.status == .authorized && $0.policyEvidenceBinding == evidence(endpoint: endpoint, fingerprint: trust.fingerprint, keyFingerprint: key.fingerprint, username: account.username) }) else { continue }
            endpoints.append(endpoint)
            lines.insert("\(hostAlias) \(parsed.type) \(parsed.blob)")
            lines.insert(trust.knownHostsLine)
        }
        guard !endpoints.isEmpty else { throw Failure.noVerifiedCandidates }
        return .init(profile: profile, nodeID: account.nodeID, username: account.username, key: key, endpoints: endpoints, knownHostsLines: lines.sorted())
    }
}

/// Only structured, locally installed commands can enter strict SSH configuration.
public struct SSHRelayCommand: Hashable, Sendable {
    public let executable: String
    public let manifest: String
    public let profileID: UUID
    public let hostKeyAlias: String
    public init(executable: String, manifest: String, profileID: UUID, hostKeyAlias: String) {
        self.executable = executable; self.manifest = manifest; self.profileID = profileID; self.hostKeyAlias = hostKeyAlias
    }
    public func rendered() throws -> String {
        func quote(_ value: String) throws -> String {
            guard value.hasPrefix("/"), !value.contains(where: { $0.isNewline || $0 == "%" || $0 == "\0" || $0 == "\"" || $0 == "\\" }) else { throw SSHPolicyCompiler.Failure.invalidPolicy }
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        guard hostKeyAlias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), !hostKeyAlias.isEmpty else { throw SSHPolicyCompiler.Failure.invalidPolicy }
        return "\(try quote(executable)) --config \(try quote(manifest)) --profile-id \(profileID.uuidString) --forward-host %h --forward-port %p"
    }
}
