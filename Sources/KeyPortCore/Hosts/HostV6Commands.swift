import Foundation

public extension HostV6 {
    struct EntityRevision: Codable, Hashable, Sendable {
        public var entity: EntityReference
        public var mutationID: UUID

        public init(entity: EntityReference, mutationID: UUID) {
            self.entity = entity
            self.mutationID = mutationID
        }
    }

    struct RevisionExpectation: Codable, Hashable, Sendable {
        public var target: EntityRevision
        public var related: [EntityRevision]

        public init(target: EntityRevision, related: [EntityRevision] = []) {
            self.target = target
            self.related = related.sorted(by: Self.sortRevisions)
        }

        private static func sortRevisions(_ left: EntityRevision, _ right: EntityRevision) -> Bool {
            entitySortKey(left.entity) < entitySortKey(right.entity)
        }
    }

    enum RevisionScope: Hashable, Sendable {
        case deleteHost(UUID)
        case deleteIdentity(UUID)
        case deleteAddress(UUID)
        case deleteService(UUID)
        case retireSSHKey(String)
        case revokeDevice(String)
        case revokeAuthorization(String)
        case resolveMergeReview(UUID)
    }

    struct CommandContext: Codable, Hashable, Sendable {
        public var commandID: UUID
        public var mutationID: UUID
        public var deviceID: String
        public var timestamp: Date
        public var expected: RevisionExpectation?

        public init(
            commandID: UUID,
            mutationID: UUID,
            deviceID: String,
            timestamp: Date,
            expected: RevisionExpectation?
        ) {
            self.commandID = commandID
            self.mutationID = mutationID
            self.deviceID = deviceID
            self.timestamp = timestamp
            self.expected = expected
        }

        func nextStamp(after stamp: SyncStamp) throws -> SyncStamp {
            try stamp.incrementing(deviceID: deviceID, mutationID: mutationID, at: timestamp)
        }
    }

    enum AddressReferencePolicy: Codable, Hashable, Sendable {
        case clear
        case replace(UUID)
    }

    enum RemoteRevocationResult: Codable, Hashable, Sendable {
        case confirmed
        case failed(OperationFailureCode)
    }

    enum SyncedRecord: Codable, Hashable, Sendable {
        case host(Host)
        case address(AccessAddress)
        case sshIdentity(SSHIdentity)
        case device(Device)
        case sshKeyRecord(SSHKeyRecord)
        case hostKeyPin(HostKeyPin)
        case knownHostsLine(KnownHostsLine)
        case service(SavedService)
        case authorization(Authorization)
        case nodeAssociation(NodeAssociation)
        case mergeReview(MergeReview)

        public var entityReference: EntityReference {
            switch self {
            case .host(let value): value.entityReference
            case .address(let value): value.entityReference
            case .sshIdentity(let value): value.entityReference
            case .device(let value): value.entityReference
            case .sshKeyRecord(let value): value.entityReference
            case .hostKeyPin(let value): value.entityReference
            case .knownHostsLine(let value): value.entityReference
            case .service(let value): value.entityReference
            case .authorization(let value): value.entityReference
            case .nodeAssociation(let value): value.entityReference
            case .mergeReview(let value): value.entityReference
            }
        }

        public var stamp: SyncStamp {
            switch self {
            case .host(let value): value.stamp
            case .address(let value): value.stamp
            case .sshIdentity(let value): value.stamp
            case .device(let value): value.stamp
            case .sshKeyRecord(let value): value.stamp
            case .hostKeyPin(let value): value.stamp
            case .knownHostsLine(let value): value.stamp
            case .service(let value): value.stamp
            case .authorization(let value): value.stamp
            case .nodeAssociation(let value): value.stamp
            case .mergeReview(let value): value.stamp
            }
        }

        func replacingStamp(_ stamp: SyncStamp) -> Self {
            switch self {
            case .host(var value):
                value.stamp = stamp
                return .host(value)
            case .address(var value):
                value.stamp = stamp
                return .address(value)
            case .sshIdentity(var value):
                value.stamp = stamp
                return .sshIdentity(value)
            case .device(var value):
                value.stamp = stamp
                return .device(value)
            case .sshKeyRecord(var value):
                value.stamp = stamp
                return .sshKeyRecord(value)
            case .hostKeyPin(var value):
                value.stamp = stamp
                return .hostKeyPin(value)
            case .knownHostsLine(var value):
                value.stamp = stamp
                return .knownHostsLine(value)
            case .service(var value):
                value.stamp = stamp
                return .service(value)
            case .authorization(var value):
                value.stamp = stamp
                return .authorization(value)
            case .nodeAssociation(var value):
                value.stamp = stamp
                return .nodeAssociation(value)
            case .mergeReview(var value):
                value.stamp = stamp
                return .mergeReview(value)
            }
        }
    }

    enum ModelCommand: Hashable, Sendable {
        case deleteHost(hostID: UUID, context: CommandContext)
        case deleteIdentity(identityID: UUID, context: CommandContext)
        case deleteAddress(addressID: UUID, referencePolicy: AddressReferencePolicy?, context: CommandContext)
        case deleteService(serviceID: UUID, context: CommandContext)
        case retireSSHKey(keyID: String, context: CommandContext)
        case revokeDevice(deviceID: String, context: CommandContext)
        case revokeAuthorization(
            authorizationID: String,
            remoteResult: RemoteRevocationResult,
            context: CommandContext
        )
        case resolveMergeReview(reviewID: UUID, replacement: SyncedRecord, context: CommandContext)
        case clearAuditEvents(context: CommandContext)

        public var context: CommandContext {
            switch self {
            case .deleteHost(_, let context), .deleteIdentity(_, let context),
                 .deleteAddress(_, _, let context), .deleteService(_, let context),
                 .retireSSHKey(_, let context), .revokeDevice(_, let context),
                 .revokeAuthorization(_, _, let context), .resolveMergeReview(_, _, let context),
                 .clearAuditEvents(let context):
                context
            }
        }
    }

    enum ModelCommitStatus: String, Codable, Hashable, Sendable {
        case committed
        case committedWithWarnings
        case noOp
    }

    enum PendingExternalEffect: Codable, Hashable, Sendable {
        case closeHostTunnels(UUID)
        case closeIdentityTunnels(UUID)
        case closeAddressTunnels(UUID)
        case closeServiceTunnel(UUID)
        case rebuildSSHConfig
        case rebuildKnownHosts
        case deleteCredential(UUID)
        case deletePrivateKeyMaterial(String)
    }

    struct ModelCommandResult: Codable, Hashable, Sendable {
        public var commandID: UUID
        public var mutationID: UUID
        public var status: ModelCommitStatus
        public var affectedEntities: [EntityReference]
        public var warnings: [CommittedWarningCode]
        public var pendingEffects: [PendingExternalEffect]

        public init(
            commandID: UUID,
            mutationID: UUID,
            status: ModelCommitStatus,
            affectedEntities: [EntityReference],
            warnings: [CommittedWarningCode],
            pendingEffects: [PendingExternalEffect]
        ) {
            self.commandID = commandID
            self.mutationID = mutationID
            self.status = status
            self.affectedEntities = affectedEntities.sorted { entitySortKey($0) < entitySortKey($1) }
            self.warnings = CommittedWarningCode.allCases.filter { warnings.contains($0) }
            self.pendingEffects = pendingEffects
        }
    }

    struct CommandLedger: Codable, Hashable, Sendable {
        public var results: [UUID: ModelCommandResult]

        public init(results: [UUID: ModelCommandResult] = [:]) {
            self.results = results
        }

        public static let empty = Self()
    }

    struct ModelTransition: Hashable, Sendable {
        public var envelope: MetadataEnvelope
        public var ledger: CommandLedger
        public var result: ModelCommandResult

        public init(envelope: MetadataEnvelope, ledger: CommandLedger, result: ModelCommandResult) {
            self.envelope = envelope
            self.ledger = ledger
            self.result = result
        }
    }

    enum ModelCommandError: Error, Equatable, Sendable {
        case failure(OperationFailureCode)
        case invariantFailed([InvariantViolation])
    }
}

public extension HostV6.SyncedGraph {
    func revisionExpectation(for scope: HostV6.RevisionScope) throws -> HostV6.RevisionExpectation {
        let targetReference: HostV6.EntityReference
        var related: Set<HostV6.EntityReference> = []

        switch scope {
        case .deleteHost(let hostID):
            targetReference = .host(hostID)
            let identityIDs = Set(identities.filter { $0.hostID == hostID }.map(\.id))
            let pinIDs = Set(hostKeyPins.filter { $0.hostID == hostID }.map(\.id))
            related.formUnion(addresses.filter { $0.hostID == hostID }.map(\.entityReference))
            related.formUnion(identities.filter { $0.hostID == hostID }.map(\.entityReference))
            related.formUnion(hostKeyPins.filter { $0.hostID == hostID }.map(\.entityReference))
            related.formUnion(knownHostsLines.filter { pinIDs.contains($0.pinID) }.map(\.entityReference))
            related.formUnion(services.filter { $0.hostID == hostID }.map(\.entityReference))
            related.formUnion(authorizations.filter { identityIDs.contains($0.sshIdentityID) }.map(\.entityReference))
            related.formUnion(nodeAssociations.filter { identityIDs.contains($0.sshIdentityID) }.map(\.entityReference))
        case .deleteIdentity(let identityID):
            targetReference = .sshIdentity(identityID)
            related.formUnion(authorizations.filter { $0.sshIdentityID == identityID }.map(\.entityReference))
            related.formUnion(nodeAssociations.filter { $0.sshIdentityID == identityID }.map(\.entityReference))
        case .deleteAddress(let addressID):
            targetReference = .address(addressID)
            let pinIDs = Set(hostKeyPins.filter { $0.addressID == addressID }.map(\.id))
            related.formUnion(hosts.filter { $0.fixedAddressID == addressID }.map(\.entityReference))
            related.formUnion(identities.filter { $0.preferredAddressID == addressID }.map(\.entityReference))
            related.formUnion(services.filter { $0.fixedAddressID == addressID }.map(\.entityReference))
            related.formUnion(hostKeyPins.filter { $0.addressID == addressID }.map(\.entityReference))
            related.formUnion(knownHostsLines.filter { pinIDs.contains($0.pinID) }.map(\.entityReference))
        case .deleteService(let serviceID):
            targetReference = .service(serviceID)
        case .retireSSHKey(let keyID):
            targetReference = .sshKeyRecord(keyID)
            related.formUnion(authorizations.filter { $0.keyID == keyID }.map(\.entityReference))
        case .revokeDevice(let deviceID):
            targetReference = .device(deviceID)
            related.formUnion(devices.filter { $0.id != deviceID }.map(\.entityReference))
        case .revokeAuthorization(let authorizationID):
            targetReference = .authorization(authorizationID)
        case .resolveMergeReview(let reviewID):
            targetReference = .mergeReview(reviewID)
            guard let review = mergeReviews.first(where: { $0.id == reviewID }),
                  let target = entityReference(type: review.entityType, stableID: review.entityID) else {
                throw HostV6.ModelCommandError.failure(.invariantFailed)
            }
            related.insert(target)
        }

        let affectedReferences = Set([targetReference]).union(related)
        for review in mergeReviews where !review.isResolved {
            guard let target = entityReference(type: review.entityType, stableID: review.entityID) else { continue }
            if affectedReferences.contains(target) {
                related.insert(review.entityReference)
            }
        }
        related.remove(targetReference)

        guard let target = record(for: targetReference) else {
            throw HostV6.ModelCommandError.failure(.invariantFailed)
        }
        let revisions = try related.map { reference -> HostV6.EntityRevision in
            guard let record = record(for: reference) else {
                throw HostV6.ModelCommandError.failure(.invariantFailed)
            }
            return HostV6.EntityRevision(entity: reference, mutationID: record.stamp.mutationID)
        }
        return HostV6.RevisionExpectation(
            target: .init(entity: targetReference, mutationID: target.stamp.mutationID),
            related: revisions
        )
    }

    func record(for reference: HostV6.EntityReference) -> HostV6.SyncedRecord? {
        switch reference {
        case .host(let id): return hosts.first { $0.id == id }.map(HostV6.SyncedRecord.host)
        case .address(let id): return addresses.first { $0.id == id }.map(HostV6.SyncedRecord.address)
        case .sshIdentity(let id): return identities.first { $0.id == id }.map(HostV6.SyncedRecord.sshIdentity)
        case .device(let id): return devices.first { $0.id == id }.map(HostV6.SyncedRecord.device)
        case .sshKeyRecord(let id): return sshKeys.first { $0.id == id }.map(HostV6.SyncedRecord.sshKeyRecord)
        case .hostKeyPin(let id): return hostKeyPins.first { $0.id == id }.map(HostV6.SyncedRecord.hostKeyPin)
        case .knownHostsLine(let id): return knownHostsLines.first { $0.id == id }.map(HostV6.SyncedRecord.knownHostsLine)
        case .service(let id): return services.first { $0.id == id }.map(HostV6.SyncedRecord.service)
        case .authorization(let id): return authorizations.first { $0.id == id }.map(HostV6.SyncedRecord.authorization)
        case .nodeAssociation(let id): return nodeAssociations.first { $0.id == id }.map(HostV6.SyncedRecord.nodeAssociation)
        case .mergeReview(let id): return mergeReviews.first { $0.id == id }.map(HostV6.SyncedRecord.mergeReview)
        case .legacySourceRevision, .auditEvent: return nil
        }
    }

    mutating func replace(_ record: HostV6.SyncedRecord) -> Bool {
        switch record {
        case .host(let value): return replaceEntity(value, in: &hosts)
        case .address(let value): return replaceEntity(value, in: &addresses)
        case .sshIdentity(let value): return replaceEntity(value, in: &identities)
        case .device(let value): return replaceEntity(value, in: &devices)
        case .sshKeyRecord(let value): return replaceEntity(value, in: &sshKeys)
        case .hostKeyPin(let value): return replaceEntity(value, in: &hostKeyPins)
        case .knownHostsLine(let value): return replaceEntity(value, in: &knownHostsLines)
        case .service(let value): return replaceEntity(value, in: &services)
        case .authorization(let value): return replaceEntity(value, in: &authorizations)
        case .nodeAssociation(let value): return replaceEntity(value, in: &nodeAssociations)
        case .mergeReview(let value): return replaceEntity(value, in: &mergeReviews)
        }
    }

    private func entityReference(type: HostV6.EntityType, stableID: String) -> HostV6.EntityReference? {
        switch type {
        case .host: return UUID(uuidString: stableID).map(HostV6.EntityReference.host)
        case .address: return UUID(uuidString: stableID).map(HostV6.EntityReference.address)
        case .sshIdentity: return UUID(uuidString: stableID).map(HostV6.EntityReference.sshIdentity)
        case .device: return .device(stableID)
        case .sshKeyRecord: return .sshKeyRecord(stableID)
        case .hostKeyPin: return UUID(uuidString: stableID).map(HostV6.EntityReference.hostKeyPin)
        case .knownHostsLine: return UUID(uuidString: stableID).map(HostV6.EntityReference.knownHostsLine)
        case .service: return UUID(uuidString: stableID).map(HostV6.EntityReference.service)
        case .authorization: return .authorization(stableID)
        case .nodeAssociation: return .nodeAssociation(stableID)
        case .mergeReview: return UUID(uuidString: stableID).map(HostV6.EntityReference.mergeReview)
        case .legacySourceRevision: return .legacySourceRevision(stableID)
        case .auditEvent: return UUID(uuidString: stableID).map(HostV6.EntityReference.auditEvent)
        }
    }
}

public extension HostV6 {
    enum ModelReducer {
        public static func reduce(
            _ command: ModelCommand,
            envelope: MetadataEnvelope,
            ledger: CommandLedger,
            existingSSHHostAliases: Set<String>
        ) throws -> ModelTransition {
            let context = command.context
            if let recorded = ledger.results[context.commandID] {
                return ModelTransition(envelope: envelope, ledger: ledger, result: recorded)
            }

            var nextEnvelope = envelope
            let result = try apply(command, envelope: &nextEnvelope)
            let violations = nextEnvelope.validate(existingSSHHostAliases: existingSSHHostAliases)
            guard violations.isEmpty else {
                throw ModelCommandError.invariantFailed(violations)
            }
            var nextLedger = ledger
            nextLedger.results[context.commandID] = result
            return ModelTransition(envelope: nextEnvelope, ledger: nextLedger, result: result)
        }

        private static func apply(
            _ command: ModelCommand,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            switch command {
            case .deleteHost(let hostID, let context):
                return try deleteHost(hostID, context: context, envelope: &envelope)
            case .deleteIdentity(let identityID, let context):
                return try deleteIdentity(identityID, context: context, envelope: &envelope)
            case .deleteAddress(let addressID, let referencePolicy, let context):
                return try deleteAddress(addressID, policy: referencePolicy, context: context, envelope: &envelope)
            case .deleteService(let serviceID, let context):
                return try deleteService(serviceID, context: context, envelope: &envelope)
            case .retireSSHKey(let keyID, let context):
                return try retireSSHKey(keyID, context: context, envelope: &envelope)
            case .revokeDevice(let deviceID, let context):
                return try revokeDevice(deviceID, context: context, envelope: &envelope)
            case .revokeAuthorization(let authorizationID, let remoteResult, let context):
                return try revokeAuthorization(
                    authorizationID,
                    remoteResult: remoteResult,
                    context: context,
                    envelope: &envelope
                )
            case .resolveMergeReview(let reviewID, let replacement, let context):
                return try resolveMergeReview(
                    reviewID,
                    replacement: replacement,
                    context: context,
                    envelope: &envelope
                )
            case .clearAuditEvents(let context):
                return clearAuditEvents(context: context, envelope: &envelope)
            }
        }

        private static func deleteHost(
            _ hostID: UUID,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let hostIndex = envelope.synced.hosts.firstIndex(where: { $0.id == hostID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.hosts[hostIndex].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .deleteHost(hostID), graph: envelope.synced)

            let identityIDs = Set(envelope.synced.identities.filter { $0.hostID == hostID }.map(\.id))
            let pinIDs = Set(envelope.synced.hostKeyPins.filter { $0.hostID == hostID }.map(\.id))
            let hasRemoteAuthorization = envelope.synced.authorizations.contains {
                identityIDs.contains($0.sshIdentityID) && $0.remoteState != .revoked
            }
            var deletionTargets: Set<EntityReference> = [.host(hostID)]
            deletionTargets.formUnion(
                envelope.synced.addresses.lazy.filter { $0.hostID == hostID }.map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.identities.lazy.filter { $0.hostID == hostID }.map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.hostKeyPins.lazy.filter { $0.hostID == hostID }.map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.knownHostsLines.lazy.filter { pinIDs.contains($0.pinID) }.map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.services.lazy.filter { $0.hostID == hostID }.map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.authorizations.lazy
                    .filter { identityIDs.contains($0.sshIdentityID) }
                    .map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.nodeAssociations.lazy
                    .filter { identityIDs.contains($0.sshIdentityID) }
                    .map(\.entityReference)
            )
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.hosts[hostIndex], context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.addresses, where: { $0.hostID == hostID }, context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.identities, where: { $0.hostID == hostID }, context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.hostKeyPins, where: { $0.hostID == hostID }, context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.knownHostsLines, where: { pinIDs.contains($0.pinID) }, context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.services, where: { $0.hostID == hostID }, context: context, affected: &affected)
            try detachAuthorizations(
                &envelope.synced.authorizations,
                where: { identityIDs.contains($0.sshIdentityID) },
                context: context,
                affected: &affected
            )
            try tombstoneAll(
                &envelope.synced.nodeAssociations,
                where: { identityIDs.contains($0.sshIdentityID) },
                context: context,
                affected: &affected
            )
            try resolveReviewsForDeletedTargets(
                graph: &envelope.synced,
                targets: deletionTargets,
                context: context,
                affected: &affected
            )

            var effects: [PendingExternalEffect] = [.closeHostTunnels(hostID), .rebuildSSHConfig, .rebuildKnownHosts]
            effects.append(contentsOf: identityIDs.sorted { $0.uuidString < $1.uuidString }.map(PendingExternalEffect.deleteCredential))
            return committed(
                context,
                affected: affected,
                warnings: hasRemoteAuthorization ? [.remoteAuthorizationMayRemain] : [],
                effects: effects
            )
        }

        private static func deleteIdentity(
            _ identityID: UUID,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.identities.firstIndex(where: { $0.id == identityID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.identities[index].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .deleteIdentity(identityID), graph: envelope.synced)
            let hasRemoteAuthorization = envelope.synced.authorizations.contains {
                $0.sshIdentityID == identityID && $0.remoteState != .revoked
            }
            var deletionTargets: Set<EntityReference> = [.sshIdentity(identityID)]
            deletionTargets.formUnion(
                envelope.synced.authorizations.lazy
                    .filter { $0.sshIdentityID == identityID }
                    .map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.nodeAssociations.lazy
                    .filter { $0.sshIdentityID == identityID }
                    .map(\.entityReference)
            )
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.identities[index], context: context, affected: &affected)
            try detachAuthorizations(
                &envelope.synced.authorizations,
                where: { $0.sshIdentityID == identityID },
                context: context,
                affected: &affected
            )
            try tombstoneAll(
                &envelope.synced.nodeAssociations,
                where: { $0.sshIdentityID == identityID },
                context: context,
                affected: &affected
            )
            try resolveReviewsForDeletedTargets(
                graph: &envelope.synced,
                targets: deletionTargets,
                context: context,
                affected: &affected
            )
            return committed(
                context,
                affected: affected,
                warnings: hasRemoteAuthorization ? [.remoteAuthorizationMayRemain] : [],
                effects: [.closeIdentityTunnels(identityID), .rebuildSSHConfig, .deleteCredential(identityID)]
            )
        }

        private static func deleteAddress(
            _ addressID: UUID,
            policy: AddressReferencePolicy?,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.addresses.firstIndex(where: { $0.id == addressID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.addresses[index].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .deleteAddress(addressID), graph: envelope.synced)
            let address = envelope.synced.addresses[index]
            let isReferenced = envelope.synced.hosts.contains { $0.deletedAt == nil && $0.fixedAddressID == addressID }
                || envelope.synced.identities.contains { $0.deletedAt == nil && $0.preferredAddressID == addressID }
                || envelope.synced.services.contains { $0.deletedAt == nil && $0.fixedAddressID == addressID }
            if isReferenced && policy == nil {
                throw ModelCommandError.failure(.addressStillReferenced)
            }
            let remainingAddresses = envelope.synced.addresses.filter {
                $0.hostID == address.hostID && $0.id != addressID && $0.deletedAt == nil
            }
            if remainingAddresses.isEmpty,
               envelope.synced.identities.contains(where: { $0.hostID == address.hostID && $0.deletedAt == nil }) {
                throw ModelCommandError.failure(.lastAddressForActiveIdentity)
            }
            var replacementID: UUID?
            if case .replace(let candidate)? = policy {
                guard candidate != addressID,
                      remainingAddresses.contains(where: { $0.id == candidate }) else {
                    throw ModelCommandError.failure(.invalidAddress)
                }
                replacementID = candidate
            }

            let pinIDs = Set(envelope.synced.hostKeyPins.filter { $0.addressID == addressID }.map(\.id))
            var deletionTargets: Set<EntityReference> = [.address(addressID)]
            deletionTargets.formUnion(
                envelope.synced.hostKeyPins.lazy
                    .filter { $0.addressID == addressID }
                    .map(\.entityReference)
            )
            deletionTargets.formUnion(
                envelope.synced.knownHostsLines.lazy
                    .filter { pinIDs.contains($0.pinID) }
                    .map(\.entityReference)
            )
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.addresses[index], context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.hostKeyPins, where: { $0.addressID == addressID }, context: context, affected: &affected)
            try tombstoneAll(&envelope.synced.knownHostsLines, where: { pinIDs.contains($0.pinID) }, context: context, affected: &affected)
            try updateAddressReferences(
                in: &envelope.synced,
                from: addressID,
                to: replacementID,
                context: context,
                affected: &affected
            )
            try resolveReviewsForDeletedTargets(
                graph: &envelope.synced,
                targets: deletionTargets,
                context: context,
                affected: &affected
            )
            return committed(
                context,
                affected: affected,
                effects: [.closeAddressTunnels(addressID), .rebuildKnownHosts]
            )
        }

        private static func deleteService(
            _ serviceID: UUID,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.services.firstIndex(where: { $0.id == serviceID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.services[index].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .deleteService(serviceID), graph: envelope.synced)
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.services[index], context: context, affected: &affected)
            try resolveReviewsForDeletedTargets(graph: &envelope.synced, targets: affected, context: context, affected: &affected)
            return committed(context, affected: affected, effects: [.closeServiceTunnel(serviceID)])
        }

        private static func retireSSHKey(
            _ keyID: String,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.sshKeys.firstIndex(where: { $0.id == keyID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.sshKeys[index].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .retireSSHKey(keyID), graph: envelope.synced)
            if envelope.synced.authorizations.contains(where: { $0.keyID == keyID && $0.remoteState != .revoked }) {
                throw ModelCommandError.failure(.keyStillAuthorized)
            }
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.sshKeys[index], context: context, affected: &affected)
            try resolveReviewsForDeletedTargets(graph: &envelope.synced, targets: affected, context: context, affected: &affected)
            return committed(context, affected: affected, effects: [.deletePrivateKeyMaterial(keyID)])
        }

        private static func revokeDevice(
            _ deviceID: String,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.devices.firstIndex(where: { $0.id == deviceID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.devices[index].deletedAt != nil { return noOp(context) }
            try verify(context, scope: .revokeDevice(deviceID), graph: envelope.synced)
            let isCurrent = envelope.local.deviceStates.contains { $0.deviceID == deviceID && $0.isCurrent }
            let hasTakeover = envelope.synced.devices.contains { $0.id != deviceID && $0.deletedAt == nil }
            if isCurrent && !hasTakeover {
                throw ModelCommandError.failure(.authorityGateFailed)
            }
            var affected: Set<EntityReference> = []
            try tombstone(&envelope.synced.devices[index], context: context, affected: &affected)
            try resolveReviewsForDeletedTargets(graph: &envelope.synced, targets: affected, context: context, affected: &affected)
            return committed(context, affected: affected)
        }

        private static func revokeAuthorization(
            _ authorizationID: String,
            remoteResult: RemoteRevocationResult,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let index = envelope.synced.authorizations.firstIndex(where: { $0.id == authorizationID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            if envelope.synced.authorizations[index].deletedAt != nil,
               envelope.synced.authorizations[index].remoteState == .revoked {
                return noOp(context)
            }
            try verify(context, scope: .revokeAuthorization(authorizationID), graph: envelope.synced)
            if case .failed(let code) = remoteResult {
                throw ModelCommandError.failure(code)
            }
            var affected: Set<EntityReference> = []
            envelope.synced.authorizations[index].remoteState = .revoked
            envelope.synced.authorizations[index].relationState = .detached
            envelope.synced.authorizations[index].deletedAt =
                envelope.synced.authorizations[index].deletedAt ?? context.timestamp
            envelope.synced.authorizations[index].stamp = try context.nextStamp(
                after: envelope.synced.authorizations[index].stamp
            )
            affected.insert(envelope.synced.authorizations[index].entityReference)
            try resolveReviewsForDeletedTargets(graph: &envelope.synced, targets: affected, context: context, affected: &affected)
            return committed(context, affected: affected)
        }

        private static func resolveMergeReview(
            _ reviewID: UUID,
            replacement: SyncedRecord,
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) throws -> ModelCommandResult {
            guard let reviewIndex = envelope.synced.mergeReviews.firstIndex(where: { $0.id == reviewID }) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            let review = envelope.synced.mergeReviews[reviewIndex]
            if review.isResolved { return noOp(context) }
            try verify(context, scope: .resolveMergeReview(reviewID), graph: envelope.synced)
            guard replacement.entityReference.entityType == review.entityType,
                  replacement.entityReference.stableID == review.entityID,
                  review.candidates.contains(where: { $0.mutationID == replacement.stamp.mutationID }) else {
                throw ModelCommandError.failure(.concurrentConflict)
            }
            let joined = review.candidates.reduce(into: [String: UInt64]()) { result, candidate in
                result = SyncStamp.join(result, candidate.vector)
            }
            let base = SyncStamp(vector: joined, mutationID: replacement.stamp.mutationID, updatedAt: context.timestamp)
            let resolutionStamp = try context.nextStamp(after: base)
            let resolvedRecord = replacement.replacingStamp(resolutionStamp)
            guard envelope.synced.replace(resolvedRecord) else {
                throw ModelCommandError.failure(.invariantFailed)
            }
            envelope.synced.mergeReviews[reviewIndex].resolvedAt = context.timestamp
            envelope.synced.mergeReviews[reviewIndex].resolutionMutationID = context.mutationID
            envelope.synced.mergeReviews[reviewIndex].resolutionReason = .userSelected
            envelope.synced.mergeReviews[reviewIndex].isBlocking = false
            envelope.synced.mergeReviews[reviewIndex].stamp = resolutionStamp
            let affected: Set<EntityReference> = [replacement.entityReference, .mergeReview(reviewID)]
            return committed(context, affected: affected)
        }

        private static func clearAuditEvents(
            context: CommandContext,
            envelope: inout MetadataEnvelope
        ) -> ModelCommandResult {
            guard !envelope.local.auditEvents.isEmpty else { return noOp(context) }
            envelope.local.auditEvents = []
            return committed(context, affected: [])
        }

        private static func verify(
            _ context: CommandContext,
            scope: RevisionScope,
            graph: SyncedGraph
        ) throws {
            guard let expected = context.expected,
                  let current = try? graph.revisionExpectation(for: scope),
                  expected == current else {
                throw ModelCommandError.failure(.staleRevision)
            }
        }

        private static func committed(
            _ context: CommandContext,
            affected: Set<EntityReference>,
            warnings: [CommittedWarningCode] = [],
            effects: [PendingExternalEffect] = []
        ) -> ModelCommandResult {
            ModelCommandResult(
                commandID: context.commandID,
                mutationID: context.mutationID,
                status: warnings.isEmpty ? .committed : .committedWithWarnings,
                affectedEntities: Array(affected),
                warnings: warnings,
                pendingEffects: effects
            )
        }

        private static func noOp(_ context: CommandContext) -> ModelCommandResult {
            ModelCommandResult(
                commandID: context.commandID,
                mutationID: context.mutationID,
                status: .noOp,
                affectedEntities: [],
                warnings: [],
                pendingEffects: []
            )
        }
    }
}

private func tombstone<Entity: HostV6SyncedEntity>(
    _ entity: inout Entity,
    context: HostV6.CommandContext,
    affected: inout Set<HostV6.EntityReference>
) throws {
    guard entity.deletedAt == nil else { return }
    entity.deletedAt = context.timestamp
    entity.stamp = try context.nextStamp(after: entity.stamp)
    affected.insert(entity.entityReference)
}

private func tombstoneAll<Entity: HostV6SyncedEntity>(
    _ entities: inout [Entity],
    where predicate: (Entity) -> Bool,
    context: HostV6.CommandContext,
    affected: inout Set<HostV6.EntityReference>
) throws {
    for index in entities.indices where predicate(entities[index]) {
        try tombstone(&entities[index], context: context, affected: &affected)
    }
}

private func detachAuthorizations(
    _ authorizations: inout [HostV6.Authorization],
    where predicate: (HostV6.Authorization) -> Bool,
    context: HostV6.CommandContext,
    affected: inout Set<HostV6.EntityReference>
) throws {
    for index in authorizations.indices where predicate(authorizations[index]) {
        authorizations[index].relationState = .detached
        try tombstone(&authorizations[index], context: context, affected: &affected)
    }
}

private func updateAddressReferences(
    in graph: inout HostV6.SyncedGraph,
    from addressID: UUID,
    to replacementID: UUID?,
    context: HostV6.CommandContext,
    affected: inout Set<HostV6.EntityReference>
) throws {
    for index in graph.hosts.indices where graph.hosts[index].fixedAddressID == addressID && graph.hosts[index].deletedAt == nil {
        graph.hosts[index].fixedAddressID = replacementID
        graph.hosts[index].stamp = try context.nextStamp(after: graph.hosts[index].stamp)
        affected.insert(graph.hosts[index].entityReference)
    }
    for index in graph.identities.indices where graph.identities[index].preferredAddressID == addressID && graph.identities[index].deletedAt == nil {
        graph.identities[index].preferredAddressID = replacementID
        graph.identities[index].stamp = try context.nextStamp(after: graph.identities[index].stamp)
        affected.insert(graph.identities[index].entityReference)
    }
    for index in graph.services.indices where graph.services[index].fixedAddressID == addressID && graph.services[index].deletedAt == nil {
        graph.services[index].fixedAddressID = replacementID
        graph.services[index].stamp = try context.nextStamp(after: graph.services[index].stamp)
        affected.insert(graph.services[index].entityReference)
    }
}

private func resolveReviewsForDeletedTargets(
    graph: inout HostV6.SyncedGraph,
    targets: Set<HostV6.EntityReference>,
    context: HostV6.CommandContext,
    affected: inout Set<HostV6.EntityReference>
) throws {
    for index in graph.mergeReviews.indices {
        let review = graph.mergeReviews[index]
        guard !review.isResolved,
              targets.contains(where: {
                  $0.entityType == review.entityType && $0.stableID == review.entityID
              }) else { continue }
        graph.mergeReviews[index].resolvedAt = context.timestamp
        graph.mergeReviews[index].resolutionMutationID = context.mutationID
        graph.mergeReviews[index].resolutionReason = .resolvedByTargetDeletion
        graph.mergeReviews[index].isBlocking = false
        graph.mergeReviews[index].stamp = try context.nextStamp(after: review.stamp)
        affected.insert(graph.mergeReviews[index].entityReference)
    }
}

private func replaceEntity<Entity: Identifiable>(_ value: Entity, in values: inout [Entity]) -> Bool where Entity.ID: Equatable {
    guard let index = values.firstIndex(where: { $0.id == value.id }) else { return false }
    values[index] = value
    return true
}

private func entitySortKey(_ reference: HostV6.EntityReference) -> String {
    "\(reference.entityType.rawValue)|\(reference.stableID)"
}
