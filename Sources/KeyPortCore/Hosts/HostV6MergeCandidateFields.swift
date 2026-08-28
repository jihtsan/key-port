import Foundation

public extension HostV6.Host {
    var mergeCandidateFields: [String: String] {
        var fields = [
            "name": name,
            "group": group,
            "fixedAddressID": candidateUUID(fixedAddressID),
            "createdAt": candidateDate(createdAt),
        ]
        if let machineConfiguration {
            fields["machine.hostname"] = machineConfiguration.hostname
            fields["machine.operatingSystem"] = machineConfiguration.operatingSystem
            fields["machine.kernel"] = machineConfiguration.kernel
            fields["machine.architecture"] = machineConfiguration.architecture
            fields["machine.processorCount"] = machineConfiguration.processorCount.map(String.init) ?? ""
            fields["machine.memoryBytes"] = machineConfiguration.memoryBytes.map(String.init) ?? ""
            fields["machine.synchronizedAt"] = candidateDate(machineConfiguration.synchronizedAt)
        }
        return fields
    }
}

public extension HostV6.AccessAddress {
    var mergeCandidateFields: [String: String] {
        [
            "hostID": candidateUUID(hostID),
            "normalizedHost": normalizedHost,
            "sshPort": String(sshPort),
            "originalLabel": originalLabel,
            "source": source.rawValue,
            "sortOrder": String(sortOrder),
        ]
    }
}

public extension HostV6.SSHIdentity {
    var mergeCandidateFields: [String: String] {
        [
            "hostID": candidateUUID(hostID),
            "username": username,
            "alias": alias,
            "preferredAddressID": candidateUUID(preferredAddressID),
            "createdAt": candidateDate(createdAt),
        ]
    }
}

public extension HostV6.Device {
    var mergeCandidateFields: [String: String] {
        [
            "name": name,
            "registeredAt": candidateDate(registeredAt),
            "lastActiveAt": candidateDate(lastActiveAt),
            "tailscale.nodeID": tailscaleIdentity?.nodeID ?? "",
            "tailscale.dnsName": tailscaleIdentity?.dnsName ?? "",
            "tailscale.addresses": tailscaleIdentity?.addresses.sorted().joined(separator: ",") ?? "",
        ]
    }
}

public extension HostV6.SSHKeyRecord {
    var mergeCandidateFields: [String: String] {
        [
            "deviceID": deviceID,
            "kind": kind.rawValue,
            "publicKey": publicKey,
            "fingerprint": fingerprint,
            "origin": origin.rawValue,
        ]
    }
}

public extension HostV6.HostKeyPin {
    var mergeCandidateFields: [String: String] {
        [
            "hostID": candidateUUID(hostID),
            "addressID": candidateUUID(addressID),
            "algorithm": algorithm,
            "fingerprint": fingerprint,
            "state": state.rawValue,
            "firstConfirmedAt": candidateDate(firstConfirmedAt),
            "lastSeenAt": candidateDate(lastSeenAt),
            "replacedAt": candidateDate(replacedAt),
        ]
    }
}

public extension HostV6.KnownHostsLine {
    var mergeCandidateFields: [String: String] {
        [
            "pinID": candidateUUID(pinID),
            "rawLine": rawLine,
            "sourceKind": source.candidateKind,
            "sourceID": candidateUUID(source.id),
            "duplicateOrdinal": String(duplicateOrdinal),
        ]
    }
}

public extension HostV6.SavedService {
    var mergeCandidateFields: [String: String] {
        [
            "hostID": candidateUUID(hostID),
            "name": name,
            "protocol": serviceProtocol.rawValue,
            "bind": endpoint.bind.candidateValue,
            "port": String(endpoint.port),
            "path": endpoint.path ?? "",
            "isFavorite": String(isFavorite),
            "fixedAddressID": candidateUUID(fixedAddressID),
        ]
    }
}

public extension HostV6.Authorization {
    var mergeCandidateFields: [String: String] {
        [
            "sshIdentityID": candidateUUID(sshIdentityID),
            "keyID": keyID,
            "fingerprint": fingerprint,
            "remoteComment": remoteComment,
            "remoteState": remoteState.rawValue,
            "relationState": relationState.rawValue,
            "authorizedAt": candidateDate(authorizedAt),
            "lastVerifiedAt": candidateDate(lastVerifiedAt),
        ]
    }
}

public extension HostV6.NodeAssociation {
    var mergeCandidateFields: [String: String] {
        [
            "sshIdentityID": candidateUUID(sshIdentityID),
            "target": target?.id ?? "",
            "state": state.rawValue,
            "method": method?.rawValue ?? "",
            "autoLinkEnabled": String(autoLinkEnabled),
        ]
    }
}

public extension HostV6.MergeReview {
    var mergeCandidateFields: [String: String] {
        [
            "entityType": entityType.rawValue,
            "entityID": entityID,
            "candidateMutationIDs": candidates.map(\.mutationID.uuidString).sorted().joined(separator: ","),
            "isBlocking": String(isBlocking),
            "resolvedAt": candidateDate(resolvedAt),
            "resolutionMutationID": candidateUUID(resolutionMutationID),
            "resolutionReason": resolutionReason?.rawValue ?? "",
        ]
    }
}

public extension HostV6.LegacySourceRevision {
    var mergeCandidateFields: [String: String] {
        [
            "legacyKind": legacyKind,
            "legacyID": legacyID,
            "revision": String(revision),
            "digest": digest,
            "sourceDeleted": String(sourceDeleted),
            "derivedEntityIDs": derivedEntityIDs.map(candidateReference).sorted().joined(separator: ","),
        ]
    }
}

private extension HostV6.KnownHostsLineSource {
    var candidateKind: String {
        switch self {
        case .legacyIdentity: "legacyIdentity"
        case .operation: "operation"
        }
    }
}

private extension HostV6.ListenerBind {
    var candidateValue: String {
        switch self {
        case .loopbackV4: "loopbackV4"
        case .loopbackV6: "loopbackV6"
        case .wildcardV4: "wildcardV4"
        case .wildcardV6: "wildcardV6"
        case .specific(let address): "specific:\(address.family.rawValue):\(address.value)"
        }
    }
}

private func candidateDate(_ value: Date?) -> String {
    value.map { String($0.timeIntervalSince1970) } ?? ""
}

private func candidateUUID(_ value: UUID?) -> String {
    value?.uuidString.lowercased() ?? ""
}

private func candidateReference(_ value: HostV6.EntityReference) -> String {
    "\(value.entityType.rawValue):\(value.stableID)"
}
