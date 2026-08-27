import Foundation

public extension HostV6 {
    struct InvariantViolation: Codable, Hashable, Sendable {
        public enum Code: String, Codable, CaseIterable, Hashable, Sendable {
            case duplicateEntityID
            case missingReference
            case activeReferenceTargetsDeletedEntity
            case crossHostAddressReference
            case duplicateAlias
            case identityWithoutActiveAddress
            case duplicateConfirmedPin
            case confirmedPinWithoutActiveLine
            case keyFingerprintConflict
            case unresolvedReviewTargetsTombstone
            case invalidAuthorizationState
            case auditLimitExceeded
        }

        public var code: Code
        public var subject: EntityReference
        public var referenced: EntityReference?

        public init(code: Code, subject: EntityReference, referenced: EntityReference? = nil) {
            self.code = code
            self.subject = subject
            self.referenced = referenced
        }
    }

    enum ActionBlocker: Codable, Hashable, Sendable {
        case hostDeleted(UUID)
        case hostKeyPending(UUID)
        case mergeReview(UUID)
    }
}

public extension HostV6.SyncedGraph {
    func validate(existingSSHHostAliases: Set<String>) -> [HostV6.InvariantViolation] {
        var violations: [HostV6.InvariantViolation] = []
        let hostsByID = firstByID(hosts)
        let addressesByID = firstByID(addresses)
        let identitiesByID = firstByID(identities)
        let devicesByID = firstByID(devices)
        let keysByID = firstByID(sshKeys)
        let pinsByID = firstByID(hostKeyPins)

        appendDuplicateViolations(hosts, to: &violations)
        appendDuplicateViolations(addresses, to: &violations)
        appendDuplicateViolations(identities, to: &violations)
        appendDuplicateViolations(devices, to: &violations)
        appendDuplicateViolations(sshKeys, to: &violations)
        appendDuplicateViolations(hostKeyPins, to: &violations)
        appendDuplicateViolations(knownHostsLines, to: &violations)
        appendDuplicateViolations(services, to: &violations)
        appendDuplicateViolations(authorizations, to: &violations)
        appendDuplicateViolations(nodeAssociations, to: &violations)
        appendDuplicateViolations(mergeReviews, to: &violations)

        for host in hosts where host.deletedAt == nil {
            if let addressID = host.fixedAddressID {
                validateAddressReference(
                    addressID,
                    expectedHostID: host.id,
                    subject: host.entityReference,
                    addressesByID: addressesByID,
                    violations: &violations
                )
            }
        }

        for address in addresses where address.deletedAt == nil {
            validateActiveReference(
                subject: address.entityReference,
                target: hostsByID[address.hostID],
                targetReference: .host(address.hostID),
                violations: &violations
            )
        }

        let normalizedExistingAliases = Set(existingSSHHostAliases.map { $0.lowercased() })
        var aliases: [String: UUID] = [:]
        for identity in identities where identity.deletedAt == nil {
            validateActiveReference(
                subject: identity.entityReference,
                target: hostsByID[identity.hostID],
                targetReference: .host(identity.hostID),
                violations: &violations
            )
            if let addressID = identity.preferredAddressID {
                validateAddressReference(
                    addressID,
                    expectedHostID: identity.hostID,
                    subject: identity.entityReference,
                    addressesByID: addressesByID,
                    violations: &violations
                )
            }
            let alias = identity.alias.lowercased()
            if normalizedExistingAliases.contains(alias) || aliases.updateValue(identity.id, forKey: alias) != nil {
                violations.append(.init(code: .duplicateAlias, subject: identity.entityReference))
            }
            let hasAddress = addresses.contains {
                $0.hostID == identity.hostID && $0.deletedAt == nil && $0.sshPort > 0
            }
            if !hasAddress {
                violations.append(.init(code: .identityWithoutActiveAddress, subject: identity.entityReference))
            }
        }

        var confirmedPins: Set<String> = []
        for pin in hostKeyPins where pin.deletedAt == nil {
            validateActiveReference(
                subject: pin.entityReference,
                target: hostsByID[pin.hostID],
                targetReference: .host(pin.hostID),
                violations: &violations
            )
            validateAddressReference(
                pin.addressID,
                expectedHostID: pin.hostID,
                subject: pin.entityReference,
                addressesByID: addressesByID,
                violations: &violations
            )
            if pin.state == .confirmed {
                let key = "\(pin.addressID.uuidString.lowercased())|\(pin.algorithm.lowercased())"
                if !confirmedPins.insert(key).inserted {
                    violations.append(.init(code: .duplicateConfirmedPin, subject: pin.entityReference))
                }
                if !knownHostsLines.contains(where: { $0.pinID == pin.id && $0.deletedAt == nil }) {
                    violations.append(.init(code: .confirmedPinWithoutActiveLine, subject: pin.entityReference))
                }
            }
        }

        for line in knownHostsLines where line.deletedAt == nil {
            validateActiveReference(
                subject: line.entityReference,
                target: pinsByID[line.pinID],
                targetReference: .hostKeyPin(line.pinID),
                violations: &violations
            )
        }

        for service in services where service.deletedAt == nil {
            validateActiveReference(
                subject: service.entityReference,
                target: hostsByID[service.hostID],
                targetReference: .host(service.hostID),
                violations: &violations
            )
            if let addressID = service.fixedAddressID {
                validateAddressReference(
                    addressID,
                    expectedHostID: service.hostID,
                    subject: service.entityReference,
                    addressesByID: addressesByID,
                    violations: &violations
                )
            }
        }

        for key in sshKeys {
            guard devicesByID[key.deviceID] != nil else {
                violations.append(.init(
                    code: .missingReference,
                    subject: key.entityReference,
                    referenced: .device(key.deviceID)
                ))
                continue
            }
        }
        for group in Dictionary(grouping: sshKeys, by: \.id).values where Set(group.map(\.fingerprint)).count > 1 {
            if let key = group.first {
                violations.append(.init(code: .keyFingerprintConflict, subject: key.entityReference))
            }
        }

        for authorization in authorizations {
            if keysByID[authorization.keyID] == nil {
                violations.append(.init(
                    code: .missingReference,
                    subject: authorization.entityReference,
                    referenced: .sshKeyRecord(authorization.keyID)
                ))
            }
            guard authorization.deletedAt == nil else { continue }
            validateActiveReference(
                subject: authorization.entityReference,
                target: identitiesByID[authorization.sshIdentityID],
                targetReference: .sshIdentity(authorization.sshIdentityID),
                violations: &violations
            )
            if authorization.relationState != .active {
                violations.append(.init(code: .invalidAuthorizationState, subject: authorization.entityReference))
            }
        }
        for authorization in authorizations where authorization.deletedAt != nil {
            if authorization.relationState != .detached {
                violations.append(.init(code: .invalidAuthorizationState, subject: authorization.entityReference))
            }
        }

        for association in nodeAssociations where association.deletedAt == nil {
            validateActiveReference(
                subject: association.entityReference,
                target: identitiesByID[association.sshIdentityID],
                targetReference: .sshIdentity(association.sshIdentityID),
                violations: &violations
            )
        }

        for review in mergeReviews where review.deletedAt == nil && !review.isResolved {
            let targetLifecycle = reviewTargetLifecycle(
                entityType: review.entityType,
                entityID: review.entityID
            )
            let isConcurrentDeleteReview = review.candidates.contains(where: \.isDeleted)
                && review.candidates.contains { !$0.isDeleted }
            if targetLifecycle == .missing
                || (targetLifecycle == .deleted && !isConcurrentDeleteReview) {
                violations.append(.init(code: .unresolvedReviewTargetsTombstone, subject: review.entityReference))
            }
        }

        return violations.sorted {
            let left = "\($0.code.rawValue)|\($0.subject.entityType.rawValue)|\($0.subject.stableID)"
            let right = "\($1.code.rawValue)|\($1.subject.entityType.rawValue)|\($1.subject.stableID)"
            return left < right
        }
    }

    func actionBlockers(for hostID: UUID) -> [HostV6.ActionBlocker] {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return [] }
        var blockers: Set<HostV6.ActionBlocker> = []
        if host.deletedAt != nil {
            blockers.insert(.hostDeleted(hostID))
        }
        for pin in hostKeyPins where pin.hostID == hostID && pin.deletedAt == nil && pin.state == .pendingReview {
            blockers.insert(.hostKeyPending(pin.id))
        }
        for review in mergeReviews where review.deletedAt == nil && !review.isResolved && review.isBlocking {
            if reviewAffectsHost(review, hostID: hostID) {
                blockers.insert(.mergeReview(review.id))
            }
        }
        return blockers.sorted { String(describing: $0) < String(describing: $1) }
    }

    private func reviewAffectsHost(_ review: HostV6.MergeReview, hostID: UUID) -> Bool {
        if owningHostID(entityType: review.entityType, entityID: review.entityID) == hostID {
            return true
        }
        let keyIDs: Set<String>
        switch review.entityType {
        case .device:
            keyIDs = Set(sshKeys.lazy.filter { $0.deviceID == review.entityID }.map(\.id))
        case .sshKeyRecord:
            keyIDs = [review.entityID]
        default:
            return false
        }
        let hostIdentityIDs = Set(identities.lazy.filter { $0.hostID == hostID }.map(\.id))
        return authorizations.contains {
            keyIDs.contains($0.keyID) && hostIdentityIDs.contains($0.sshIdentityID)
        }
    }

    private func owningHostID(entityType: HostV6.EntityType, entityID: String) -> UUID? {
        switch entityType {
        case .host:
            return UUID(uuidString: entityID)
        case .address:
            return UUID(uuidString: entityID).flatMap { id in addresses.first { $0.id == id }?.hostID }
        case .sshIdentity:
            return UUID(uuidString: entityID).flatMap { id in identities.first { $0.id == id }?.hostID }
        case .hostKeyPin:
            return UUID(uuidString: entityID).flatMap { id in hostKeyPins.first { $0.id == id }?.hostID }
        case .service:
            return UUID(uuidString: entityID).flatMap { id in services.first { $0.id == id }?.hostID }
        case .authorization:
            return authorizations.first { $0.id == entityID }.flatMap { authorization in
                identities.first { $0.id == authorization.sshIdentityID }?.hostID
            }
        case .nodeAssociation:
            return nodeAssociations.first { $0.id == entityID }.flatMap { association in
                identities.first { $0.id == association.sshIdentityID }?.hostID
            }
        case .knownHostsLine:
            return UUID(uuidString: entityID).flatMap { id in
                knownHostsLines.first { $0.id == id }.flatMap { line in
                    hostKeyPins.first { $0.id == line.pinID }?.hostID
                }
            }
        case .device, .sshKeyRecord, .mergeReview, .legacySourceRevision, .auditEvent:
            return nil
        }
    }

    private func reviewTargetLifecycle(
        entityType: HostV6.EntityType,
        entityID: String
    ) -> ReviewTargetLifecycle {
        switch entityType {
        case .host:
            return lifecycle(UUID(uuidString: entityID), in: hosts)
        case .address:
            return lifecycle(UUID(uuidString: entityID), in: addresses)
        case .sshIdentity:
            return lifecycle(UUID(uuidString: entityID), in: identities)
        case .device:
            return lifecycle(entityID, in: devices)
        case .sshKeyRecord:
            return lifecycle(entityID, in: sshKeys)
        case .hostKeyPin:
            return lifecycle(UUID(uuidString: entityID), in: hostKeyPins)
        case .knownHostsLine:
            return lifecycle(UUID(uuidString: entityID), in: knownHostsLines)
        case .service:
            return lifecycle(UUID(uuidString: entityID), in: services)
        case .authorization:
            return lifecycle(entityID, in: authorizations)
        case .nodeAssociation:
            return lifecycle(entityID, in: nodeAssociations)
        case .mergeReview:
            return lifecycle(UUID(uuidString: entityID), in: mergeReviews)
        case .legacySourceRevision:
            return .active
        case .auditEvent:
            return .missing
        }
    }
}

public extension HostV6.MetadataEnvelope {
    func validate(existingSSHHostAliases: Set<String>) -> [HostV6.InvariantViolation] {
        var violations = synced.validate(existingSSHHostAliases: existingSSHHostAliases)
        appendDuplicateViolations(migrationProvenance.legacySources, to: &violations)
        let hostIDs = Set(synced.hosts.map(\.id))
        let identityIDs = Set(synced.identities.map(\.id))
        let deviceIDs = Set(synced.devices.map(\.id))
        let keyIDs = Set(synced.sshKeys.map(\.id))
        let addressIDs = Set(synced.addresses.map(\.id))

        for annotation in local.hostAnnotations where !hostIDs.contains(annotation.hostID) {
            violations.append(.init(
                code: .missingReference,
                subject: .sshIdentity(annotation.legacyIdentityID),
                referenced: .host(annotation.hostID)
            ))
        }
        for state in local.identityStates where !identityIDs.contains(state.sshIdentityID) {
            violations.append(.init(
                code: .missingReference,
                subject: .sshIdentity(state.sshIdentityID),
                referenced: .sshIdentity(state.sshIdentityID)
            ))
        }
        for state in local.deviceStates where !deviceIDs.contains(state.deviceID) {
            violations.append(.init(
                code: .missingReference,
                subject: .device(state.deviceID),
                referenced: .device(state.deviceID)
            ))
        }
        for state in local.keyStates where !keyIDs.contains(state.keyID) {
            violations.append(.init(
                code: .missingReference,
                subject: .sshKeyRecord(state.keyID),
                referenced: .sshKeyRecord(state.keyID)
            ))
        }
        for evidence in local.reachabilityEvidence where !addressIDs.contains(evidence.addressID) {
            violations.append(.init(
                code: .missingReference,
                subject: .address(evidence.addressID),
                referenced: .address(evidence.addressID)
            ))
        }
        if local.auditEvents.count > 1_000, let first = local.auditEvents.first {
            violations.append(.init(code: .auditLimitExceeded, subject: .auditEvent(first.id)))
        }
        for group in Dictionary(grouping: local.auditEvents, by: \.id).values where group.count > 1 {
            if let first = group.first {
                violations.append(.init(code: .duplicateEntityID, subject: .auditEvent(first.id)))
            }
        }
        for review in synced.mergeReviews
        where review.deletedAt == nil && !review.isResolved && review.entityType == .legacySourceRevision {
            let source = migrationProvenance.legacySources.first { $0.id == review.entityID }
            let isConcurrentDeleteReview = review.candidates.contains(where: \.isDeleted)
                && review.candidates.contains { !$0.isDeleted }
            if source == nil || (source?.deletedAt != nil && !isConcurrentDeleteReview) {
                violations.append(.init(
                    code: .unresolvedReviewTargetsTombstone,
                    subject: review.entityReference
                ))
            }
        }
        return violations.sorted {
            let left = "\($0.code.rawValue)|\($0.subject.entityType.rawValue)|\($0.subject.stableID)"
            let right = "\($1.code.rawValue)|\($1.subject.entityType.rawValue)|\($1.subject.stableID)"
            return left < right
        }
    }
}

private func firstByID<Entity: Identifiable>(_ values: [Entity]) -> [Entity.ID: Entity] where Entity.ID: Hashable {
    Dictionary(grouping: values, by: \.id).compactMapValues(\.first)
}

private func appendDuplicateViolations<Entity: HostV6SyncedEntity>(
    _ values: [Entity],
    to violations: inout [HostV6.InvariantViolation]
) where Entity.ID: Hashable {
    for group in Dictionary(grouping: values, by: \.id).values where group.count > 1 {
        if let entity = group.first {
            violations.append(.init(code: .duplicateEntityID, subject: entity.entityReference))
        }
    }
}

private func validateActiveReference<Target: HostV6SyncedEntity>(
    subject: HostV6.EntityReference,
    target: Target?,
    targetReference: HostV6.EntityReference,
    violations: inout [HostV6.InvariantViolation]
) {
    guard let target else {
        violations.append(.init(code: .missingReference, subject: subject, referenced: targetReference))
        return
    }
    if target.deletedAt != nil {
        violations.append(.init(
            code: .activeReferenceTargetsDeletedEntity,
            subject: subject,
            referenced: targetReference
        ))
    }
}

private func validateAddressReference(
    _ addressID: UUID,
    expectedHostID: UUID,
    subject: HostV6.EntityReference,
    addressesByID: [UUID: HostV6.AccessAddress],
    violations: inout [HostV6.InvariantViolation]
) {
    guard let address = addressesByID[addressID] else {
        violations.append(.init(code: .missingReference, subject: subject, referenced: .address(addressID)))
        return
    }
    if address.deletedAt != nil {
        violations.append(.init(
            code: .activeReferenceTargetsDeletedEntity,
            subject: subject,
            referenced: .address(addressID)
        ))
    } else if address.hostID != expectedHostID {
        violations.append(.init(code: .crossHostAddressReference, subject: subject, referenced: .address(addressID)))
    }
}

private enum ReviewTargetLifecycle {
    case active
    case deleted
    case missing
}

private func lifecycle<Entity: HostV6SyncedEntity>(
    _ id: Entity.ID?,
    in values: [Entity]
) -> ReviewTargetLifecycle where Entity.ID: Equatable {
    guard let id, let value = values.first(where: { $0.id == id }) else { return .missing }
    return value.deletedAt == nil ? .active : .deleted
}
