import Foundation
import KeyPortCore

extension WorkspaceStore {
    func policyEndpoints(_ id: UUID) -> [UUID] {
        guard let profile = topology.activeConnectionProfiles.first(where: { $0.id == id }) else { return [] }
        var seen = Set<UUID>()
        return SSHPolicyUpgrade.group(for: profile, in: topology).flatMap { $0.candidateEndpointIDs.isEmpty ? [$0.routePolicy.fixedEndpointID].compactMap { $0 } : $0.candidateEndpointIDs }.filter { seen.insert($0).inserted }
    }
    func updatePolicy(profileID: UUID, endpoints: [UUID], automatic: Bool) throws {
        var next = document
        guard let profile = next.topology.activeConnectionProfiles.first(where: { $0.id == profileID }) else { throw WorkspaceError.configuration }
        let group = SSHPolicyUpgrade.group(for: profile, in: topology)
        let keys = Set(group.compactMap { next.pathKeys[$0.id.uuidString] })
        guard keys.count <= 1 else { throw WorkspaceError.configuration }
        let canonical = try SSHPolicyUpgrade.apply(profileID: profileID, endpointIDs: endpoints, automatic: automatic, to: &next.topology)
        next.pathKeys[canonical.uuidString] = keys.first
        // Bind existing local success only when its endpoint trust and selected account key still exist.
        for i in next.topology.accessVerifications.indices {
            let v = next.topology.accessVerifications[i]
            guard v.profileID == canonical, v.deviceID == state.deviceID, v.status == .authorized, v.policyEvidenceBinding == nil,
                  let source = group.first(where: { $0.policyVersion == nil && $0.routePolicy.fixedEndpointID == v.endpointID }),
                  let key = next.topology.sshKeys.first(where: { $0.id == document.pathKeys[source.id.uuidString] && $0.deviceID == state.deviceID }),
                  let endpoint = next.topology.activeEndpoints.first(where: { $0.id == v.endpointID }),
                  let trust = next.topology.hostKeyTrusts.first(where: { !$0.isDeleted && $0.state == .confirmed && $0.endpointID == endpoint.id && $0.algorithm == "ssh-ed25519" }) else { continue }
            next.topology.accessVerifications[i].policyEvidenceBinding = SSHPolicyCompiler.evidence(endpoint: endpoint, fingerprint: trust.fingerprint, keyFingerprint: key.fingerprint, username: next.topology.activeAccounts.first { $0.id == profile.accountID }!.username)
        }
        if let account = next.topology.activeAccounts.first(where: { $0.id == profile.accountID }), let first = endpoints.first {
            next.defaultPaths[account.nodeID.uuidString] = SSHPolicyUpgrade.pathID(profileID: canonical, endpointID: first)
        }
        if next.preferredProfilesByAccountID == nil { next.preferredProfilesByAccountID = [:] }
        next.preferredProfilesByAccountID?[profile.accountID.uuidString] = canonical
        next.version = 2
        try commit(next)
        if let first = endpoints.first { workspace.select(.path(SSHPolicyUpgrade.pathID(profileID: canonical, endpointID: first))) }
    }
    func authorizationConnection(accountID: UUID) throws -> Connection {
        let profiles = topology.activeConnectionProfiles.filter { $0.accountID == accountID }
        let selected = workspace.selectedPath.flatMap { path in state.connections.first { $0.id == path.id } }?.profileID
        let profile = profiles.first { $0.id == selected }
            ?? profiles.first { $0.id == document.preferredProfilesByAccountID?[accountID.uuidString] }
            ?? (profiles.count == 1 ? profiles.first : nil)
        guard let profile else { throw WorkspaceError.configuration }
        if profile.policyVersion == 1 {
            let plan = try SSHPolicyCompiler.compile(profile: profile, topology: topology, deviceID: state.deviceID, keyID: document.pathKeys[profile.id.uuidString])
            guard let endpoint = plan.endpoints.first, let c = state.connections.first(where: { $0.profileID == profile.id && $0.endpointID == endpoint.id }) else { throw WorkspaceError.configuration }
            return c
        }
        guard let c = state.connections.first(where: { $0.profileID == profile.id && $0.verification == "verified" }) else { throw WorkspaceError.configuration }
        return c
    }
    func legacyDiagnosticConnections() -> [Connection] {
        topology.activeConnectionProfiles.flatMap { profile in
            profile.supersededProfileIDs.compactMap { oldID in
                guard let old = topology.sshConnectionProfiles.first(where: { $0.id == oldID }), let endpoint = old.routePolicy.fixedEndpointID,
                      var row = state.connections.first(where: { $0.profileID == profile.id && $0.endpointID == endpoint && $0.verification == "verified" }) else { return nil }
                row.id = oldID.uuidString
                return row
            }
        }
    }
    func invalidateOldPolicyFiles(except generation: URL) throws {
        let root = policyInstallation.root.appendingPathComponent("generations")
        if FileManager.default.fileExists(atPath: root.path) {
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.standardizedFileURL.path != generation.standardizedFileURL.path {
                // Only hash-named generations are owned by this installer.
                guard url.lastPathComponent.count == 64, url.lastPathComponent.allSatisfy({ $0.isHexDigit }) else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
        for url in try FileManager.default.contentsOfDirectory(at: paths.keyPortDirectory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("path-") && url.pathExtension == "conf" {
            guard UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(5))) != nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}
