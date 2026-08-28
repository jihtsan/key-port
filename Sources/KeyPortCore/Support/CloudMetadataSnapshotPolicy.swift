import Foundation

public enum CloudMetadataSnapshotPolicy {
    public static func sanitized(_ snapshot: AppSnapshot) -> AppSnapshot {
        var result = AppSnapshot()
        result.schemaVersion = snapshot.schemaVersion
        result.servers = snapshot.servers.map(sanitizedServer).sorted(by: serverOrder)
        result.devices = snapshot.devices.map(sanitizedDevice).sorted { $0.id < $1.id }
        result.keys = snapshot.keys.map(sanitizedKey).sorted { $0.fingerprint < $1.fingerprint }
        result.authorizations = snapshot.authorizations.sorted { $0.id < $1.id }
        result.nodeAssociations = NodeAssociationMerger.merge(snapshot.nodeAssociations)
        result.auditEvents = []
        return result
    }

    public static func merge(local: AppSnapshot, remote: AppSnapshot) -> AppSnapshot {
        let local = sanitized(local)
        let remote = sanitized(remote)
        var result = AppSnapshot()
        result.schemaVersion = max(local.schemaVersion, remote.schemaVersion)
        result.servers = mergeByID(local.servers + remote.servers, id: \.id, prefer: preferServer)
            .sorted(by: serverOrder)
        result.devices = mergeByID(local.devices + remote.devices, id: \.id, prefer: preferDevice)
            .sorted { $0.id < $1.id }
        result.keys = mergeByID(local.keys + remote.keys, id: \.fingerprint) { candidate, existing in
            existing.publicKey.isEmpty && !candidate.publicKey.isEmpty
        }
        .sorted { $0.fingerprint < $1.fingerprint }
        result.authorizations = mergeByID(
            local.authorizations + remote.authorizations,
            id: \.id,
            prefer: preferAuthorization
        )
        .sorted { $0.id < $1.id }
        result.nodeAssociations = NodeAssociationMerger.merge(local.nodeAssociations + remote.nodeAssociations)
        return result
    }

    public static func restoringLocalState(in merged: AppSnapshot, from local: AppSnapshot) -> AppSnapshot {
        var result = merged
        var localServers: [UUID: ServerConnection] = [:]
        var localKeys: [String: SSHKeyRecord] = [:]
        for server in local.servers { localServers[server.id] = server }
        for key in local.keys { localKeys[key.fingerprint] = key }

        result.servers = result.servers.map { server in
            guard let localServer = localServers[server.id] else { return server }
            var value = server
            value.notes = localServer.notes
            value.status = localServer.status
            value.statusDetail = localServer.statusDetail
            value.lastCheckedAt = localServer.lastCheckedAt
            value.passwordCheck = localServer.passwordCheck
            value.keyCheck = localServer.keyCheck
            value.machineConfigurationRefreshAttemptedAt = localServer.machineConfigurationRefreshAttemptedAt
            return value
        }

        result.keys = result.keys.map { key in
            guard let localKey = localKeys[key.fingerprint] else { return key }
            var value = key
            value.id = localKey.id
            value.deviceID = localKey.deviceID
            value.privateKeyPath = localKey.privateKeyPath
            value.isInAgent = localKey.isInAgent
            value.origin = localKey.origin
            value.isLocallyAvailable = localKey.isLocallyAvailable
            return value
        }

        result.authorizations = result.authorizations.map { authorization in
            guard let localKey = localKeys[authorization.fingerprint] else { return authorization }
            var value = authorization
            value.keyID = localKey.id
            return value
        }
        result.auditEvents = local.auditEvents
        return result
    }

    private static func sanitizedServer(_ server: ServerConnection) -> ServerConnection {
        let hostKeys = mergeByID(server.confirmedHostKeys, id: \.id) { candidate, existing in
            candidate.lastSeenAt > existing.lastSeenAt
        }
        .sorted { $0.id < $1.id }

        return ServerConnection(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            alias: server.alias,
            group: server.group,
            notes: "",
            confirmedHostKeys: hostKeys,
            status: .syncPending,
            statusDetail: nil,
            lastCheckedAt: nil,
            passwordCheck: nil,
            keyCheck: nil,
            machineConfiguration: server.machineConfiguration,
            machineConfigurationRefreshAttemptedAt: nil,
            createdAt: server.createdAt,
            updatedAt: server.updatedAt,
            isDeleted: server.isDeleted,
            version: server.version
        )
    }

    private static func sanitizedDevice(_ device: Device) -> Device {
        Device(
            id: device.id,
            name: device.name,
            isCurrent: false,
            registeredAt: device.registeredAt,
            lastActiveAt: device.lastActiveAt,
            isRevoked: device.isRevoked,
            tailscaleIdentity: device.tailscaleIdentity
        )
    }

    private static func sanitizedKey(_ key: SSHKeyRecord) -> SSHKeyRecord {
        SSHKeyRecord(
            id: key.id,
            deviceID: key.deviceID,
            kind: key.kind,
            publicKey: key.publicKey,
            fingerprint: key.fingerprint,
            privateKeyPath: nil,
            isInAgent: false,
            origin: key.origin,
            isLocallyAvailable: false
        )
    }

    private static func preferServer(_ candidate: ServerConnection, over existing: ServerConnection) -> Bool {
        if candidate.version != existing.version { return candidate.version > existing.version }
        if candidate.isDeleted != existing.isDeleted { return candidate.isDeleted }
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        return false
    }

    private static func preferDevice(_ candidate: Device, over existing: Device) -> Bool {
        if candidate.isRevoked != existing.isRevoked { return candidate.isRevoked }
        if candidate.lastActiveAt != existing.lastActiveAt { return candidate.lastActiveAt > existing.lastActiveAt }
        return false
    }

    private static func preferAuthorization(_ candidate: Authorization, over existing: Authorization) -> Bool {
        if candidate.version != existing.version { return candidate.version > existing.version }
        if candidate.isDeleted != existing.isDeleted { return candidate.isDeleted }
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        return false
    }

    private static func serverOrder(_ lhs: ServerConnection, _ rhs: ServerConnection) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func mergeByID<Value, ID: Hashable>(
        _ values: [Value],
        id: KeyPath<Value, ID>,
        prefer: (Value, Value) -> Bool
    ) -> [Value] {
        var result: [ID: Value] = [:]
        for value in values {
            let key = value[keyPath: id]
            if let existing = result[key] {
                result[key] = prefer(value, existing) ? value : existing
            } else {
                result[key] = value
            }
        }
        return Array(result.values)
    }
}
