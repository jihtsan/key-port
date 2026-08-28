import Foundation

public struct TopologyGraphProjector: Sendable {
    public init() {}

    public func project(
        envelope: HostV6.MetadataEnvelope,
        currentDeviceID: String?,
        query: TopologyGraphQuery = TopologyGraphQuery()
    ) -> TopologyGraphSnapshot {
        let graph = envelope.synced
        let activeHosts = graph.hosts.filter { $0.deletedAt == nil }
        let activeAddresses = graph.addresses.filter { $0.deletedAt == nil }
        let activeIdentities = graph.identities.filter { $0.deletedAt == nil }
        let activeDevices = graph.devices.filter { $0.deletedAt == nil }
        let activeKeys = graph.sshKeys.filter { $0.deletedAt == nil }
        let activeServices = graph.services.filter { $0.deletedAt == nil }
        let activeAuthorizations = graph.authorizations.filter {
            $0.deletedAt == nil && $0.relationState == .active
        }
        let activeAssociations = graph.nodeAssociations.filter {
            $0.deletedAt == nil && $0.target != nil
        }

        let hostsByID = firstByID(activeHosts, key: \.id)
        let addressesByID = firstByID(activeAddresses, key: \.id)
        let identitiesByID = firstByID(activeIdentities, key: \.id)
        let devicesByID = firstByID(activeDevices, key: \.id)
        let keysByID = firstByID(activeKeys, key: \.id)

        let authorityMode = envelope.migrationProvenance.authorityManifest?.mode
        let syncStatus = syncStatus(for: authorityMode)
        let hostStatuses = Dictionary(uniqueKeysWithValues: activeHosts.map { host in
            let blockers = graph.actionBlockers(for: host.id)
            return (
                host.id,
                hostStatus(
                    host: host,
                    graph: graph,
                    addresses: activeAddresses.filter { $0.hostID == host.id },
                    blockers: blockers,
                    local: envelope.local,
                    syncStatus: syncStatus
                )
            )
        })

        let identityStatuses = Dictionary(uniqueKeysWithValues: activeIdentities.map { identity in
            (
                identity.id,
                identityStatus(
                    identity: identity,
                    hostStatus: hostStatuses[identity.hostID] ?? .unknown,
                    authorizations: activeAuthorizations.filter { $0.sshIdentityID == identity.id },
                    keysByID: keysByID,
                    local: envelope.local,
                    currentDeviceID: currentDeviceID
                )
            )
        })

        var nodes: [TopologyGraphNode] = []
        nodes.append(contentsOf: activeDevices.map { device in
            let deviceKeys = activeKeys.filter { $0.deviceID == device.id }
            let localKey = device.id == currentDeviceID
                ? localKeyStatus(for: deviceKeys, local: envelope.local)
                : .unknown
            let status = TopologyGraphStatus(
                localKey: localKey,
                sync: syncStatus,
                reasons: []
            )
            return TopologyGraphNode(
                id: .device(device.id),
                kind: .device,
                title: device.name.isEmpty ? device.id : device.name,
                subtitle: device.id == currentDeviceID ? "当前设备" : "KeyPort 设备",
                status: status,
                source: device.entityReference,
                supportingReferences: deviceKeys.map(\.entityReference)
            )
        })

        nodes.append(contentsOf: activeHosts.map { host in
            let hostAddresses = activeAddresses.filter { $0.hostID == host.id }
            return TopologyGraphNode(
                id: .host(host.id),
                kind: .host,
                title: host.name.isEmpty ? "未命名主机" : host.name,
                subtitle: hostSubtitle(host: host, addresses: hostAddresses),
                status: hostStatuses[host.id] ?? .unknown,
                source: host.entityReference,
                supportingReferences: hostAddresses.map(\.entityReference)
                    + activeIdentities.filter { $0.hostID == host.id }.map(\.entityReference)
                    + activeServices.filter { $0.hostID == host.id }.map(\.entityReference)
            )
        })

        nodes.append(contentsOf: activeServices.compactMap { service in
            guard hostsByID[service.hostID] != nil else { return nil }
            let hostStatus = hostStatuses[service.hostID] ?? .unknown
            return TopologyGraphNode(
                id: .service(service.id),
                kind: .service,
                title: service.name.isEmpty ? "未命名服务" : service.name,
                subtitle: serviceSubtitle(service, address: service.fixedAddressID.flatMap { addressesByID[$0] }),
                status: hostStatus,
                source: service.entityReference,
                supportingReferences: [
                    HostV6.EntityReference.host(service.hostID),
                    service.fixedAddressID.flatMap { addressesByID[$0]?.entityReference },
                ].compactMap { $0 }
            )
        })

        if query.includesSupportingNodes {
            nodes.append(contentsOf: activeIdentities.compactMap { identity in
                guard let host = hostsByID[identity.hostID] else { return nil }
                let address = identity.preferredAddressID.flatMap { addressesByID[$0] }
                return TopologyGraphNode(
                    id: .sshAccount(identity.id),
                    kind: .sshAccount,
                    title: identity.alias.isEmpty ? identity.username : identity.alias,
                    subtitle: "\(identity.username) · \(host.name)",
                    status: identityStatuses[identity.id] ?? .unknown,
                    source: identity.entityReference,
                    supportingReferences: [
                        HostV6.EntityReference.host(host.id),
                        address?.entityReference,
                    ].compactMap { $0 }
                )
            })
        }

        if query.includesSupportingNodes && query.includesActualNodes {
            let linkedAssociations = activeAssociations.compactMap { association -> (HostV6.NodeAssociation, HostV6.SSHIdentity, ActualNodeReference)? in
                guard association.state == .linked,
                      let target = association.target,
                      let identity = identitiesByID[association.sshIdentityID] else { return nil }
                return (association, identity, target)
            }
            nodes.append(contentsOf: Dictionary(grouping: linkedAssociations, by: { $0.2.id }).compactMap { _, values in
                guard let first = values.sorted(by: { $0.2.id < $1.2.id }).first else { return nil }
                let target = first.2
                let status = identityStatuses[first.1.id] ?? .unknown
                return TopologyGraphNode(
                    id: .actualNode(target),
                    kind: .actualNode,
                    title: target.nodeID,
                    subtitle: "\(target.provider) · \(target.tailnetKey)",
                    status: status,
                    source: nil,
                    supportingReferences: values.map { $0.0.entityReference }
                )
            })
        }

        var edges: [TopologyGraphEdge] = []
        for authorization in activeAuthorizations {
            guard let identity = identitiesByID[authorization.sshIdentityID],
                  let host = hostsByID[identity.hostID],
                  let key = keysByID[authorization.keyID],
                  let device = devicesByID[key.deviceID] else { continue }
            let status = accessStatus(
                hostStatus: hostStatuses[host.id] ?? .unknown,
                authorization: authorization,
                identity: identity,
                key: key,
                device: device,
                local: envelope.local,
                currentDeviceID: currentDeviceID
            )
            edges.append(TopologyGraphEdge(
                id: "access:\(device.id):\(host.id.uuidString.lowercased()):\(authorization.id)",
                from: .device(device.id),
                to: .host(host.id),
                kind: .deviceAccess,
                label: identity.alias.isEmpty ? identity.username : identity.alias,
                status: status,
                supportingReferences: [
                    key.entityReference,
                    authorization.entityReference,
                    identity.entityReference,
                ]
            ))
        }

        if let currentDeviceID, devicesByID[currentDeviceID] != nil {
            let currentKeys = activeKeys.filter { $0.deviceID == currentDeviceID }
            let currentKeyIDs = Set(currentKeys.map(\.id))
            let authorizedIdentityIDs = Set(activeAuthorizations.filter {
                currentKeyIDs.contains($0.keyID)
            }.map(\.sshIdentityID))
            for host in activeHosts {
                let identities = activeIdentities.filter { $0.hostID == host.id }
                let candidateIdentities = identities.filter { !authorizedIdentityIDs.contains($0.id) }
                guard !candidateIdentities.isEmpty else { continue }
                let hostStatus = hostStatuses[host.id] ?? .unknown
                let localKey = localKeyStatus(for: currentKeys, local: envelope.local)
                var reasons = hostStatus.reasons + [.candidateAccess]
                if localKey == .missing { reasons.append(.missingLocalKey) }
                let status = TopologyGraphStatus(
                    reachability: hostStatus.reachability,
                    hostTrust: hostStatus.hostTrust,
                    route: hostStatus.route,
                    localKey: localKey,
                    remoteAuthorization: .unknown,
                    verification: .unknown,
                    sync: hostStatus.sync,
                    reasons: reasons
                )
                edges.append(TopologyGraphEdge(
                    id: "candidate:\(currentDeviceID):\(host.id.uuidString.lowercased())",
                    from: .device(currentDeviceID),
                    to: .host(host.id),
                    kind: .candidateAccess,
                    label: candidateIdentities.count == 1 ? "待授权" : "待授权账户 \(candidateIdentities.count) 个",
                    isCandidate: true,
                    status: status,
                    supportingReferences: candidateIdentities.map(\.entityReference)
                ))
            }
        }

        for service in activeServices {
            guard hostsByID[service.hostID] != nil else { continue }
            edges.append(TopologyGraphEdge(
                id: "service:\(service.hostID.uuidString.lowercased()):\(service.id.uuidString.lowercased())",
                from: .host(service.hostID),
                to: .service(service.id),
                kind: .hostService,
                label: service.name,
                status: hostStatuses[service.hostID] ?? .unknown,
                supportingReferences: [service.entityReference]
                    + (service.fixedAddressID.flatMap { addressesByID[$0]?.entityReference }.map { [$0] } ?? [])
            ))
        }

        if query.includesSupportingNodes && query.includesActualNodes {
            for association in activeAssociations where association.state == .linked {
                guard let target = association.target,
                      let identity = identitiesByID[association.sshIdentityID] else { continue }
                edges.append(TopologyGraphEdge(
                    id: "node:\(identity.id.uuidString.lowercased()):\(target.id)",
                    from: .sshAccount(identity.id),
                    to: .actualNode(target),
                    kind: .sshAccountActualNode,
                    label: "节点关联",
                    status: identityStatuses[identity.id] ?? .unknown,
                    supportingReferences: [association.entityReference]
                ))
            }
        }

        let diagnostics = graph.validate(existingSSHHostAliases: []).map {
            TopologyGraphDiagnostic(code: $0.code, subject: $0.subject, referenced: $0.referenced)
        }
        let complete = TopologyGraphSnapshot(
            currentDeviceID: currentDeviceID,
            authorityMode: authorityMode,
            query: TopologyGraphQuery(
                viewMode: .allDevices,
                includesSupportingNodes: true,
                includesActualNodes: true
            ),
            nodes: nodes,
            edges: edges,
            diagnostics: diagnostics
        )
        return complete.applying(query)
    }

    private func hostStatus(
        host: HostV6.Host,
        graph: HostV6.SyncedGraph,
        addresses: [HostV6.AccessAddress],
        blockers: [HostV6.ActionBlocker],
        local: HostV6.LocalState,
        syncStatus: TopologyGraphSyncStatus
    ) -> TopologyGraphStatus {
        let pins = graph.hostKeyPins.filter { $0.hostID == host.id && $0.deletedAt == nil }
        let hostTrust: TopologyGraphHostTrust
        if pins.contains(where: { $0.state == .replaced }) {
            hostTrust = .mismatch
        } else if pins.contains(where: { $0.state == .pendingReview }) {
            hostTrust = .pending
        } else if !pins.isEmpty,
                  pins.allSatisfy({ pin in
                      pin.state == .confirmed
                      &&
                      graph.knownHostsLines.contains { $0.pinID == pin.id && $0.deletedAt == nil }
                  }) {
            hostTrust = .trusted
        } else {
            hostTrust = .pending
        }

        let route: TopologyGraphRouteStatus = addresses.contains(where: { $0.sshPort > 0 })
            ? .available
            : .unavailable
        let evidence = graphReachability(for: addresses, local: local)
        var reasons: [TopologyGraphReason] = []
        if host.deletedAt != nil { reasons.append(.hostDeleted) }
        if hostTrust == .pending { reasons.append(.hostKeyPending) }
        if hostTrust == .mismatch { reasons.append(.hostKeyMismatch) }
        if route == .unavailable { reasons.append(.noRoute) }
        if evidence == .unreachable { reasons.append(.unreachable) }
        if blockers.contains(where: { if case .mergeReview = $0 { return true }; return false }) {
            reasons.append(.mergeReview)
        }
        switch syncStatus {
        case .canary: reasons.append(.canary)
        case .readOnly: reasons.append(.readOnly)
        case .compatibilityRollback: reasons.append(.compatibilityRollback)
        case .clean, .conflict: break
        }
        if syncStatus == .conflict { reasons.append(.mergeReview) }
        return TopologyGraphStatus(
            reachability: evidence,
            hostTrust: hostTrust,
            route: route,
            sync: syncStatus,
            reasons: reasons
        )
    }

    private func identityStatus(
        identity: HostV6.SSHIdentity,
        hostStatus: TopologyGraphStatus,
        authorizations: [HostV6.Authorization],
        keysByID: [String: HostV6.SSHKeyRecord],
        local: HostV6.LocalState,
        currentDeviceID: String?
    ) -> TopologyGraphStatus {
        let localState = local.identityStates.first { $0.sshIdentityID == identity.id }
        let verification: TopologyGraphVerificationStatus
        var reasons = hostStatus.reasons
        switch localState?.status {
        case .authorized: verification = .succeeded
        case .checking, .syncing: verification = .checking; reasons.append(.verificationPending)
        case .keyAuthenticationFailed, .passwordAuthenticationFailed:
            verification = .failed
            reasons.append(.verificationFailed)
        case .authorizationConflict:
            verification = .failed
            reasons.append(.verificationFailed)
        case .needsAuthorization, .missingLocalKey, .syncPending:
            verification = .unknown
            reasons.append(.remoteAuthorizationPending)
        case .hostKeyPending, .hostKeyMismatch:
            verification = .unknown
        case .unreachable, .none:
            verification = .unknown
        }

        let remoteAuthorization: TopologyGraphRemoteAuthorization
        if authorizations.contains(where: { $0.remoteState == .authorized }) {
            remoteAuthorization = .authorized
        } else if !authorizations.isEmpty && authorizations.allSatisfy({ $0.remoteState == .revoked }) {
            remoteAuthorization = .revoked
            reasons.append(.remoteAuthorizationRevoked)
        } else if !authorizations.isEmpty {
            remoteAuthorization = .unknown
            reasons.append(.remoteAuthorizationPending)
        } else {
            remoteAuthorization = .unknown
            reasons.append(.remoteAuthorizationPending)
        }

        let keys = authorizations.compactMap { keysByID[$0.keyID] }
        let localKey = keys.isEmpty || currentDeviceID == nil
            ? .unknown
            : localKeyStatus(
                for: keys.filter { $0.deviceID == currentDeviceID },
                local: local,
                unknownWhenEmpty: true
            )
        return TopologyGraphStatus(
            reachability: hostStatus.reachability,
            hostTrust: hostStatus.hostTrust,
            route: hostStatus.route,
            localKey: localKey,
            remoteAuthorization: remoteAuthorization,
            verification: verification,
            sync: hostStatus.sync,
            reasons: reasons
        )
    }

    private func accessStatus(
        hostStatus: TopologyGraphStatus,
        authorization: HostV6.Authorization,
        identity: HostV6.SSHIdentity,
        key: HostV6.SSHKeyRecord,
        device: HostV6.Device,
        local: HostV6.LocalState,
        currentDeviceID: String?
    ) -> TopologyGraphStatus {
        var reasons = hostStatus.reasons
        let remoteAuthorization: TopologyGraphRemoteAuthorization
        switch authorization.remoteState {
        case .authorized:
            remoteAuthorization = .authorized
        case .revoked:
            remoteAuthorization = .revoked
            reasons.append(.remoteAuthorizationRevoked)
        case .unknown:
            remoteAuthorization = .unknown
            reasons.append(.remoteAuthorizationPending)
        }
        let localKey = device.id == currentDeviceID
            ? localKeyStatus(for: [key], local: local)
            : .unknown
        if device.id == currentDeviceID && localKey == .missing { reasons.append(.missingLocalKey) }
        let verification = device.id == currentDeviceID
            ? verificationStatus(for: identity.id, local: local)
            : .unknown
        if verification == .failed { reasons.append(.verificationFailed) }
        if verification == .checking { reasons.append(.verificationPending) }
        return TopologyGraphStatus(
            reachability: hostStatus.reachability,
            hostTrust: hostStatus.hostTrust,
            route: hostStatus.route,
            localKey: localKey,
            remoteAuthorization: remoteAuthorization,
            verification: verification,
            sync: hostStatus.sync,
            reasons: reasons
        )
    }

    private func verificationStatus(
        for identityID: UUID,
        local: HostV6.LocalState
    ) -> TopologyGraphVerificationStatus {
        switch local.identityStates.first(where: { $0.sshIdentityID == identityID })?.status {
        case .authorized: .succeeded
        case .checking, .syncing: .checking
        case .keyAuthenticationFailed, .passwordAuthenticationFailed: .failed
        default: .unknown
        }
    }

    private func localKeyStatus(
        for keys: [HostV6.SSHKeyRecord],
        local: HostV6.LocalState,
        unknownWhenEmpty: Bool = false
    ) -> TopologyGraphLocalKeyStatus {
        guard !keys.isEmpty else { return unknownWhenEmpty ? .unknown : .missing }
        let states = keys.compactMap { key in local.keyStates.first { $0.keyID == key.id } }
        if states.contains(where: \.isLocallyAvailable) { return .available }
        if states.contains(where: \.isInAgent) { return .agentOnly }
        if states.isEmpty || states.allSatisfy({ !$0.isLocallyAvailable && !$0.isInAgent }) { return .missing }
        return .unknown
    }

    private func graphReachability(
        for addresses: [HostV6.AccessAddress],
        local: HostV6.LocalState
    ) -> TopologyGraphReachability {
        let addressIDs = Set(addresses.map(\.id))
        let evidence = local.reachabilityEvidence.filter { addressIDs.contains($0.addressID) }
        guard !evidence.isEmpty else { return .unknown }
        return evidence.contains(where: \.wasReachable) ? .reachable : .unreachable
    }

    private func syncStatus(for mode: HostV6.AuthorityMode?) -> TopologyGraphSyncStatus {
        switch mode {
        case .v6Authoritative: .clean
        case .v6Canary, .legacyAuthoritative: .canary
        case .compatibilityRollback: .compatibilityRollback
        case nil: .readOnly
        }
    }

    private func hostSubtitle(
        host: HostV6.Host,
        addresses: [HostV6.AccessAddress]
    ) -> String? {
        if let address = addresses.sorted(by: { $0.sortOrder < $1.sortOrder }).first {
            return "\(address.normalizedHost):\(address.sshPort)"
        }
        if !host.group.isEmpty { return host.group }
        return nil
    }

    private func serviceSubtitle(
        _ service: HostV6.SavedService,
        address: HostV6.AccessAddress?
    ) -> String {
        let endpoint = "\(service.serviceProtocol.rawValue.uppercased()) :\(service.endpoint.port)"
        if let address { return "\(address.normalizedHost) · \(endpoint)" }
        return endpoint
    }

    private func firstByID<Entity, ID: Hashable>(
        _ values: [Entity],
        key: (Entity) -> ID
    ) -> [ID: Entity] {
        var result: [ID: Entity] = [:]
        for value in values {
            result[key(value)] = result[key(value)] ?? value
        }
        return result
    }
}
