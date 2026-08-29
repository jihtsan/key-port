import Foundation

/// Defines the CloudKit representation of the unified topology.
///
/// The cloud payload contains shared, non-secret topology metadata. Local
/// observations and device-only credentials are removed before encoding and
/// restored from the local snapshot after the cloud merge.
public enum TopologyCloudMetadataSnapshotPolicy {
    public static func sanitized(_ snapshot: TopologySnapshot) -> TopologySnapshot {
        var result = snapshot
        result.schemaVersion = TopologySnapshot.currentSchemaVersion
        result.nodes = snapshot.nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        result.profiles = snapshot.profiles.map { profile in
            var value = profile
            value.isCurrent = false
            // Keep the required Codable field valid without exporting local
            // activity from this Mac.
            value.lastActiveAt = profile.registeredAt
            value.tailscaleIdentity = nil
            return value
        }.sorted { $0.id < $1.id }
        result.endpoints = snapshot.endpoints.sorted { $0.id.uuidString < $1.id.uuidString }
        result.services = snapshot.services.sorted { $0.id.uuidString < $1.id.uuidString }
        result.tailscaleNodes = snapshot.tailscaleNodes.sorted { $0.id < $1.id }
        result.tailscaleObservations = []
        result.sshAccounts = snapshot.sshAccounts.sorted { $0.id.uuidString < $1.id.uuidString }
        result.sshKeys = snapshot.sshKeys.map(sanitizedKey).sorted { $0.id < $1.id }
        result.hostKeyTrusts = snapshot.hostKeyTrusts.sorted { $0.id.uuidString < $1.id.uuidString }
        result.authorizations = snapshot.authorizations.map { authorization in
            var value = authorization
            value.lastVerifiedAt = nil
            return value
        }.sorted { $0.id < $1.id }
        result.reachabilityObservations = []
        result.accessVerifications = []
        // The former logical-name-to-actual-node association is a local
        // compatibility artifact. TailscaleNodeIdentity is now the canonical
        // cross-device identity relation.
        result.nodeAssociations = []
        result.auditEvents = []
        return result
    }

    public static func merge(
        local: TopologySnapshot,
        remote: TopologySnapshot
    ) -> TopologySnapshot {
        let local = sanitized(local)
        let remote = sanitized(remote)
        var result = TopologySnapshot(schemaVersion: max(local.schemaVersion, remote.schemaVersion))
        result.nodes = mergeByID(local.nodes + remote.nodes, id: \.id, prefer: preferNode)
        result.profiles = mergeByID(local.profiles + remote.profiles, id: \.id, prefer: preferProfile)
        result.endpoints = mergeByID(local.endpoints + remote.endpoints, id: \.id) { candidate, existing in
            var value = existing
            if !candidate.label.isEmpty { value.label = candidate.label }
            if !candidate.address.isEmpty { value.address = candidate.address }
            value.serviceID = candidate.serviceID ?? existing.serviceID
            value.priority = min(candidate.priority, existing.priority)
            value.isDeleted = candidate.isDeleted || existing.isDeleted
            return value
        }
        result.services = mergeByID(local.services + remote.services, id: \.id) { candidate, existing in
            var value = existing
            if !candidate.name.isEmpty { value.name = candidate.name }
            value.endpointIDs = Array(Set(candidate.endpointIDs + existing.endpointIDs)).sorted {
                $0.uuidString < $1.uuidString
            }
            value.isFavorite = candidate.isFavorite || existing.isFavorite
            value.isDeleted = candidate.isDeleted || existing.isDeleted
            return value
        }
        result.tailscaleNodes = mergeByID(
            local.tailscaleNodes + remote.tailscaleNodes,
            id: \.id,
            prefer: preferTailscaleNode
        )
        result.sshAccounts = mergeByID(local.sshAccounts + remote.sshAccounts, id: \.id, prefer: preferSSHAccount)
        result.sshKeys = mergeByID(local.sshKeys + remote.sshKeys, id: \.id) { candidate, existing in
            candidate.publicKey.isEmpty && !existing.publicKey.isEmpty ? existing : candidate
        }
        result.hostKeyTrusts = mergeByID(local.hostKeyTrusts + remote.hostKeyTrusts, id: \.id) { candidate, existing in
            candidate.lastSeenAt >= existing.lastSeenAt ? candidate : existing
        }
        result.authorizations = mergeByID(
            local.authorizations + remote.authorizations,
            id: \.id,
            prefer: preferAuthorization
        )
        sortStableArrays(&result)
        return result
    }

    public static func restoringLocalState(
        in merged: TopologySnapshot,
        from local: TopologySnapshot
    ) -> TopologySnapshot {
        var result = merged
        let localProfiles = Dictionary(uniqueKeysWithValues: local.profiles.map { ($0.id, $0) })
        result.profiles = result.profiles.map { profile in
            guard let localProfile = localProfiles[profile.id] else { return profile }
            var value = profile
            value.isCurrent = localProfile.isCurrent
            value.lastActiveAt = localProfile.lastActiveAt
            value.tailscaleIdentity = localProfile.tailscaleIdentity
            return value
        }

        let localKeys = Dictionary(uniqueKeysWithValues: local.sshKeys.map { ($0.id, $0) })
        result.sshKeys = result.sshKeys.map { key in
            guard let localKey = localKeys[key.id] else { return key }
            var value = key
            value.privateKeyPath = localKey.privateKeyPath
            value.isInAgent = localKey.isInAgent
            value.isLocallyAvailable = localKey.isLocallyAvailable
            return value
        }
        result.tailscaleObservations = local.tailscaleObservations.sorted { $0.id < $1.id }
        result.reachabilityObservations = local.reachabilityObservations.sorted { $0.id < $1.id }
        result.accessVerifications = local.accessVerifications.sorted { $0.id < $1.id }
        result.nodeAssociations = local.nodeAssociations.sorted { $0.id < $1.id }
        result.auditEvents = local.auditEvents
        sortStableArrays(&result)
        return result
    }

    private static func sortStableArrays(_ snapshot: inout TopologySnapshot) {
        snapshot.nodes.sort { $0.id.uuidString < $1.id.uuidString }
        snapshot.profiles.sort { $0.id < $1.id }
        snapshot.endpoints.sort { $0.id.uuidString < $1.id.uuidString }
        snapshot.services.sort { $0.id.uuidString < $1.id.uuidString }
        snapshot.tailscaleNodes.sort { $0.id < $1.id }
        snapshot.tailscaleObservations.sort { $0.id < $1.id }
        snapshot.sshAccounts.sort { $0.id.uuidString < $1.id.uuidString }
        snapshot.sshKeys.sort { $0.id < $1.id }
        snapshot.hostKeyTrusts.sort { $0.id.uuidString < $1.id.uuidString }
        snapshot.authorizations.sort { $0.id < $1.id }
        snapshot.reachabilityObservations.sort { $0.id < $1.id }
        snapshot.accessVerifications.sort { $0.id < $1.id }
        snapshot.nodeAssociations.sort { $0.id < $1.id }
    }

    private static func sanitizedKey(_ key: SSHKey) -> SSHKey {
        var value = key
        value.privateKeyPath = nil
        value.isInAgent = false
        value.isLocallyAvailable = false
        return value
    }

    private static func preferNode(_ candidate: Node, over existing: Node) -> Node {
        var value = candidate.updatedAt >= existing.updatedAt ? candidate : existing
        value.roles = Array(Set(candidate.roles + existing.roles)).sorted { $0.rawValue < $1.rawValue }
        if value.name.isEmpty { value.name = candidate.name.isEmpty ? existing.name : candidate.name }
        if value.group.isEmpty { value.group = candidate.group.isEmpty ? existing.group : candidate.group }
        if value.notes.isEmpty { value.notes = candidate.notes.isEmpty ? existing.notes : candidate.notes }
        value.createdAt = min(candidate.createdAt, existing.createdAt)
        value.isDeleted = candidate.isDeleted || existing.isDeleted
        return value
    }

    private static func preferProfile(
        _ candidate: WorkspaceDeviceProfile,
        over existing: WorkspaceDeviceProfile
    ) -> WorkspaceDeviceProfile {
        var value = candidate.registeredAt >= existing.registeredAt ? candidate : existing
        value.isCurrent = false
        value.isRevoked = candidate.isRevoked || existing.isRevoked
        return value
    }

    private static func preferTailscaleNode(
        _ candidate: TailscaleNodeIdentity,
        over existing: TailscaleNodeIdentity
    ) -> TailscaleNodeIdentity {
        candidate.updatedAt >= existing.updatedAt ? candidate : existing
    }

    private static func preferSSHAccount(
        _ candidate: SSHAccount,
        over existing: SSHAccount
    ) -> SSHAccount {
        if candidate.version != existing.version {
            return candidate.version > existing.version ? candidate : existing
        }
        return candidate.updatedAt >= existing.updatedAt ? candidate : existing
    }

    private static func preferAuthorization(
        _ candidate: SSHAuthorization,
        over existing: SSHAuthorization
    ) -> SSHAuthorization {
        if candidate.isDeleted != existing.isDeleted {
            return candidate.isDeleted ? candidate : existing
        }
        return candidate.updatedAt >= existing.updatedAt ? candidate : existing
    }

    private static func mergeByID<Value, ID: Hashable>(
        _ values: [Value],
        id: KeyPath<Value, ID>,
        prefer: (Value, Value) -> Value = { candidate, _ in candidate }
    ) -> [Value] {
        var result: [ID: Value] = [:]
        for value in values {
            let key = value[keyPath: id]
            if let existing = result[key] {
                result[key] = prefer(value, existing)
            } else {
                result[key] = value
            }
        }
        return Array(result.values)
    }
}
