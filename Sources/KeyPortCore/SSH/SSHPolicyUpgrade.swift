import Foundation

/// Explicitly upgrades one account/alias group. Does not install SSH files or create trust.
public enum SSHPolicyUpgrade {
    public static func group(for profile: SSHConnectionProfile, in topology: TopologySnapshot) -> [SSHConnectionProfile] {
        topology.activeConnectionProfiles.filter {
            $0.accountID == profile.accountID && $0.sshAlias.caseInsensitiveCompare(profile.sshAlias) == .orderedSame
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public static func apply(profileID: UUID, endpointIDs: [UUID], automatic: Bool, to topology: inout TopologySnapshot, now: Date = .now) throws -> UUID {
        guard let profile = topology.activeConnectionProfiles.first(where: { $0.id == profileID }),
              let account = topology.activeAccounts.first(where: { $0.id == profile.accountID }),
              !endpointIDs.isEmpty, endpointIDs.count <= 16, Set(endpointIDs).count == endpointIDs.count,
              endpointIDs.allSatisfy({ id in topology.activeEndpoints.contains { $0.id == id && $0.nodeID == account.nodeID && $0.protocol == .ssh && $0.serviceID == nil } }) else {
            throw SSHConnectionPlanningError.endpointNotFound
        }
        let profiles = group(for: profile, in: topology)
        // Independent devices choose the same ID regardless of their local default path.
        var canonical = profiles.first!
        let ids = Set(profiles.map(\.id))
        canonical.policyVersion = 1
        canonical.candidateEndpointIDs = endpointIDs
        canonical.routePolicy = automatic ? .automatic(networkScope: nil) : .fixed(endpointID: endpointIDs[0])
        canonical.transportPreference = .direct
        canonical.supersededProfileIDs = Array(Set(profiles.flatMap(\.supersededProfileIDs)).union(ids.subtracting([canonical.id]))).sorted { $0.uuidString < $1.uuidString }
        canonical.version = (profiles.map(\.version).max() ?? 0) + 1
        canonical.updatedAt = now
        for i in topology.sshConnectionProfiles.indices where ids.contains(topology.sshConnectionProfiles[i].id) {
            if topology.sshConnectionProfiles[i].id == canonical.id { topology.sshConnectionProfiles[i] = canonical }
            else {
                topology.sshConnectionProfiles[i].isDeleted = true
                topology.sshConnectionProfiles[i].version = canonical.version
                topology.sshConnectionProfiles[i].updatedAt = now
            }
        }
        var verifications: [String: AccessVerification] = [:]
        for var v in topology.accessVerifications {
            if let id = v.profileID, ids.contains(id) { v.profileID = canonical.id }
            if let previous = verifications[v.id], (previous.lastCheckedAt ?? .distantPast) > (v.lastCheckedAt ?? .distantPast) { continue }
            verifications[v.id] = v
        }
        topology.accessVerifications = verifications.values.sorted { $0.id < $1.id }
        return canonical.id
    }
    public static func pathID(profileID: UUID, endpointID: UUID) -> String {
        TopologyStableID.uuidV5(namespace: profileID, name: "ssh-endpoint/" + endpointID.uuidString.lowercased()).uuidString
    }
}
