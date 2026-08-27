import Foundation
import KeyPortCore

protocol HostV6AuthorityStoring: Sendable {
    func recover() async throws -> HostV6.MetadataEnvelope
    func commit(_ plan: HostV6.AuthorityCommitPlan) async throws
}

protocol HostV6MutationWorkflowJournalStoring: Sendable {
    func load() async throws -> HostV6MutationJournal?
    func save(_ journal: HostV6MutationJournal) async throws
    func remove() async throws
}

protocol HostV6MutationEffectApplying: Sendable {
    func rebuildSSHConfig(from envelope: HostV6.MetadataEnvelope) async throws
    func rebuildKnownHosts(from envelope: HostV6.MetadataEnvelope) async throws
    func deleteCredentials(_ identityIDs: [UUID]) async throws
    func deletePrivateKeyMaterial(_ keyIDs: [String], localState: HostV6.LocalState) async throws
    func synchronizeCloudV2(_ envelope: HostV6.MetadataEnvelope, mutationID: UUID) async throws
}

enum HostV6MutationPhase: String, Codable, CaseIterable, Sendable {
    case remoteActionPrepared
    case remoteResultRecorded
    case prepared
    case modelSnapshotCommitted
    case sshConfigCommitted
    case knownHostsCommitted
    case credentialCleanupCommitted
    case privateKeyCleanupCommitted
    case cloudV2Committed
}

struct HostV6MutationJournal: Codable, Equatable, Sendable {
    struct RemoteRevocation: Codable, Equatable, Sendable {
        let authorizationID: String
        var result: HostV6.RemoteRevocationResult?
    }

    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let commandID: UUID
    let mutationID: UUID
    var phase: HostV6MutationPhase
    let envelope: HostV6.MetadataEnvelope
    var ledger: HostV6.CommandLedger
    var result: HostV6.ModelCommandResult
    let envelopeHash: String
    var ledgerHash: String
    var remoteRevocation: RemoteRevocation?
    var integrityHash: String

    init(
        transition: HostV6.ModelTransition,
        remoteAuthorizationID: String? = nil
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        commandID = transition.result.commandID
        mutationID = transition.result.mutationID
        phase = remoteAuthorizationID == nil ? .prepared : .remoteActionPrepared
        envelope = transition.envelope
        ledger = transition.ledger
        result = transition.result
        envelopeHash = HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(transition.envelope))
        ledgerHash = HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(transition.ledger))
        remoteRevocation = remoteAuthorizationID.map {
            RemoteRevocation(authorizationID: $0, result: nil)
        }
        integrityHash = ""
        integrityHash = try calculatedIntegrityHash()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              commandID == result.commandID,
              mutationID == result.mutationID,
              ledger.results[commandID] == result,
              envelopeHash == HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(envelope)),
              ledgerHash == HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(ledger)),
              hasValidRemoteState,
              integrityHash == (try calculatedIntegrityHash()) else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
    }

    mutating func advance(to phase: HostV6MutationPhase) throws {
        self.phase = phase
        integrityHash = try calculatedIntegrityHash()
    }

    mutating func recordRemoteResult(_ result: HostV6.RemoteRevocationResult) throws {
        guard phase == .remoteActionPrepared, remoteRevocation != nil else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
        remoteRevocation?.result = result
        phase = .remoteResultRecorded
        integrityHash = try calculatedIntegrityHash()
    }

    mutating func prepareRecordedRemoteSuccess() throws {
        guard phase == .remoteResultRecorded,
              remoteRevocation?.result == .confirmed else {
            throw HostV6.CloudV2Error.failure(.artifactMismatch)
        }
        phase = .prepared
        integrityHash = try calculatedIntegrityHash()
    }

    mutating func setPendingWarning(
        _ warning: CommittedWarningCode,
        isPending: Bool
    ) throws {
        var warnings = Set(result.warnings)
        if isPending {
            warnings.insert(warning)
        } else {
            warnings.remove(warning)
        }
        result.warnings = CommittedWarningCode.allCases.filter { warnings.contains($0) }
        result.status = result.warnings.isEmpty ? .committed : .committedWithWarnings
        ledger.results[commandID] = result
        ledgerHash = HostV6.CanonicalJSON.sha256(try HostV6.CanonicalJSON.encode(ledger))
        integrityHash = try calculatedIntegrityHash()
    }

    private var hasValidRemoteState: Bool {
        guard let remoteRevocation else {
            return phase != .remoteActionPrepared && phase != .remoteResultRecorded
        }
        switch phase {
        case .remoteActionPrepared:
            return remoteRevocation.result == nil
        case .remoteResultRecorded:
            return remoteRevocation.result != nil
        default:
            return remoteRevocation.result == .confirmed
        }
    }

    private func calculatedIntegrityHash() throws -> String {
        try HostV6.CanonicalJSON.sha256(HostV6.CanonicalJSON.encode(IntegrityPayload(
            schemaVersion: schemaVersion,
            commandID: commandID,
            mutationID: mutationID,
            phase: phase,
            envelopeHash: envelopeHash,
            ledgerHash: ledgerHash,
            result: result,
            remoteRevocation: remoteRevocation
        )))
    }

    private struct IntegrityPayload: Codable {
        let schemaVersion: Int
        let commandID: UUID
        let mutationID: UUID
        let phase: HostV6MutationPhase
        let envelopeHash: String
        let ledgerHash: String
        let result: HostV6.ModelCommandResult
        let remoteRevocation: RemoteRevocation?
    }
}

actor HostV6MutationWorkflow: HostV6MetadataRepositoryPort {
    private let authorityStore: any HostV6AuthorityStoring
    private let ledgerStore: any HostV6MutationJournalStoring
    private let journalStore: any HostV6MutationWorkflowJournalStoring
    private let effects: any HostV6MutationEffectApplying
    private let existingSSHHostAliases: @Sendable () async throws -> Set<String>

    init(
        authorityStore: any HostV6AuthorityStoring,
        ledgerStore: any HostV6MutationJournalStoring,
        journalStore: any HostV6MutationWorkflowJournalStoring,
        effects: any HostV6MutationEffectApplying,
        existingSSHHostAliases: @escaping @Sendable () async throws -> Set<String>
    ) {
        self.authorityStore = authorityStore
        self.ledgerStore = ledgerStore
        self.journalStore = journalStore
        self.effects = effects
        self.existingSSHHostAliases = existingSSHHostAliases
    }

    func snapshot() async throws -> HostV6.MetadataEnvelope {
        _ = try await recoverPendingMutation()
        return try await authorityStore.recover()
    }

    func transact(_ command: HostV6.ModelCommand) async throws -> HostV6.ModelCommandResult {
        if case .revokeAuthorization = command {
            throw HostV6.ModelCommandError.failure(.remoteExecutionFailed)
        }
        if let recovered = try await recoverPendingMutation(),
           try await journalStore.load() != nil {
            guard recovered.commandID == command.context.commandID else {
                throw HostV6.ModelCommandError.failure(.concurrentConflict)
            }
            return recovered
        }
        let ledger = try await ledgerStore.loadLedger()
        if let recorded = ledger.results[command.context.commandID] {
            return recorded
        }

        let envelope = try await authorityStore.recover()
        try HostV6.AuthorityController.authorizeMetadataMutation(in: envelope)
        let transition = try HostV6.ModelReducer.reduce(
            command,
            envelope: envelope,
            ledger: ledger,
            existingSSHHostAliases: try await existingSSHHostAliases()
        )
        var journal = try HostV6MutationJournal(transition: transition)
        try await journalStore.save(journal)

        if transition.result.status == .noOp {
            try await ledgerStore.atomicReplaceLedger(transition.ledger)
            try await journalStore.remove()
            return transition.result
        }
        return try await finish(&journal)
    }

    func revokeAuthorization(
        authorizationID: String,
        context: HostV6.CommandContext,
        remoteAction: @Sendable () async -> HostV6.RemoteRevocationResult
    ) async throws -> HostV6.ModelCommandResult {
        if var pending = try await journalStore.load() {
            if pending.commandID == context.commandID,
               pending.remoteRevocation?.authorizationID == authorizationID {
                return try await resumeAuthorizationRevocation(
                    &pending,
                    remoteAction: remoteAction
                )
            } else {
                let recovered = try await recoverPendingMutation()
                if try await journalStore.load() != nil {
                    throw HostV6.ModelCommandError.failure(.concurrentConflict)
                }
                if let recovered, recovered.commandID == context.commandID {
                    return recovered
                }
            }
        }

        let ledger = try await ledgerStore.loadLedger()
        if let recorded = ledger.results[context.commandID] {
            return recorded
        }
        let envelope = try await authorityStore.recover()
        try HostV6.AuthorityController.authorizeMetadataMutation(in: envelope)
        let transition = try HostV6.ModelReducer.reduce(
            .revokeAuthorization(
                authorizationID: authorizationID,
                remoteResult: .confirmed,
                context: context
            ),
            envelope: envelope,
            ledger: ledger,
            existingSSHHostAliases: try await existingSSHHostAliases()
        )
        if transition.result.status == .noOp {
            try await ledgerStore.atomicReplaceLedger(transition.ledger)
            return transition.result
        }
        var journal = try HostV6MutationJournal(
            transition: transition,
            remoteAuthorizationID: authorizationID
        )
        try await journalStore.save(journal)
        return try await resumeAuthorizationRevocation(
            &journal,
            remoteAction: remoteAction
        )
    }

    @discardableResult
    func recoverPendingMutation() async throws -> HostV6.ModelCommandResult? {
        guard var journal = try await journalStore.load() else { return nil }
        try journal.validate()
        if journal.phase == .remoteActionPrepared {
            throw HostV6.ModelCommandError.failure(.remoteExecutionFailed)
        }
        if journal.phase == .remoteResultRecorded {
            guard let remoteResult = journal.remoteRevocation?.result else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            switch remoteResult {
            case .confirmed:
                try journal.prepareRecordedRemoteSuccess()
                try await journalStore.save(journal)
            case .failed(let code):
                try await journalStore.remove()
                throw HostV6.ModelCommandError.failure(code)
            }
        }
        if journal.result.status == .noOp {
            try await ledgerStore.atomicReplaceLedger(journal.ledger)
            try await journalStore.remove()
            return journal.result
        }
        return try await finish(&journal)
    }

    private func resumeAuthorizationRevocation(
        _ journal: inout HostV6MutationJournal,
        remoteAction: @Sendable () async -> HostV6.RemoteRevocationResult
    ) async throws -> HostV6.ModelCommandResult {
        if journal.phase == .remoteActionPrepared {
            let remoteResult = await remoteAction()
            try journal.recordRemoteResult(remoteResult)
            try await journalStore.save(journal)
        }
        if journal.phase == .remoteResultRecorded {
            guard let remoteResult = journal.remoteRevocation?.result else {
                throw HostV6.CloudV2Error.failure(.artifactMismatch)
            }
            switch remoteResult {
            case .confirmed:
                try journal.prepareRecordedRemoteSuccess()
                try await journalStore.save(journal)
            case .failed(let code):
                try await journalStore.remove()
                throw HostV6.ModelCommandError.failure(code)
            }
        }
        return try await finish(&journal)
    }

    private func finish(
        _ journal: inout HostV6MutationJournal
    ) async throws -> HostV6.ModelCommandResult {
        if journal.phase == .prepared {
            let plan = try HostV6.AuthorityController.recordMutation(
                journal.mutationID,
                in: journal.envelope
            )
            try await authorityStore.commit(plan)
            try await ledgerStore.atomicReplaceLedger(journal.ledger)
            try await advance(&journal, to: .modelSnapshotCommitted)
        }
        if journal.phase == .modelSnapshotCommitted {
            let shouldRebuildSSHConfig = journal.result.pendingEffects.contains(.rebuildSSHConfig)
            if let warning = try await performCommittedStep(
                &journal,
                nextPhase: .sshConfigCommitted,
                warning: .derivedConfigOutOfDate,
                operation: {
                    if shouldRebuildSSHConfig {
                        try await self.effects.rebuildSSHConfig(
                            from: try await self.authorityStore.recover()
                        )
                    }
                }
            ) {
                return warning
            }
        }
        if journal.phase == .sshConfigCommitted {
            let shouldRebuildKnownHosts = journal.result.pendingEffects.contains(.rebuildKnownHosts)
            if let warning = try await performCommittedStep(
                &journal,
                nextPhase: .knownHostsCommitted,
                warning: .derivedConfigOutOfDate,
                operation: {
                    if shouldRebuildKnownHosts {
                        try await self.effects.rebuildKnownHosts(
                            from: try await self.authorityStore.recover()
                        )
                    }
                }
            ) {
                return warning
            }
        }
        if journal.phase == .knownHostsCommitted {
            let identityIDs = credentialIDs(in: journal.result)
            if let warning = try await performCommittedStep(
                &journal,
                nextPhase: .credentialCleanupCommitted,
                warning: .credentialCleanupPending,
                operation: {
                    if !identityIDs.isEmpty {
                        try await self.effects.deleteCredentials(identityIDs)
                    }
                }
            ) {
                return warning
            }
        }
        if journal.phase == .credentialCleanupCommitted {
            let keyIDs = privateKeyIDs(in: journal.result)
            if let warning = try await performCommittedStep(
                &journal,
                nextPhase: .privateKeyCleanupCommitted,
                warning: .keyMaterialCleanupPending,
                operation: {
                    if !keyIDs.isEmpty {
                        try await self.effects.deletePrivateKeyMaterial(
                            keyIDs,
                            localState: (try await self.authorityStore.recover()).local
                        )
                    }
                }
            ) {
                return warning
            }
        }
        if journal.phase == .privateKeyCleanupCommitted {
            let shouldSynchronizeCloud = !journal.result.affectedEntities.isEmpty
            let mutationID = journal.mutationID
            if let warning = try await performCommittedStep(
                &journal,
                nextPhase: .cloudV2Committed,
                warning: .cleanupPending,
                operation: {
                    if shouldSynchronizeCloud {
                        try await self.effects.synchronizeCloudV2(
                            try await self.authorityStore.recover(),
                            mutationID: mutationID
                        )
                    }
                }
            ) {
                return warning
            }
        }
        do {
            try journal.setPendingWarning(.cleanupPending, isPending: false)
            try await journalStore.save(journal)
            try await ledgerStore.atomicReplaceLedger(journal.ledger)
            try await journalStore.remove()
            return journal.result
        } catch {
            return try await recordPendingWarning(&journal, .cleanupPending)
        }
    }

    private func advance(
        _ journal: inout HostV6MutationJournal,
        to phase: HostV6MutationPhase,
        clearing warning: CommittedWarningCode? = nil
    ) async throws {
        try journal.advance(to: phase)
        if let warning {
            try journal.setPendingWarning(warning, isPending: false)
        }
        try await journalStore.save(journal)
        try await ledgerStore.atomicReplaceLedger(journal.ledger)
    }

    private func performCommittedStep(
        _ journal: inout HostV6MutationJournal,
        nextPhase: HostV6MutationPhase,
        warning: CommittedWarningCode,
        operation: () async throws -> Void
    ) async throws -> HostV6.ModelCommandResult? {
        do {
            try await operation()
            try await advance(&journal, to: nextPhase, clearing: warning)
            return nil
        } catch {
            return try await recordPendingWarning(&journal, warning)
        }
    }

    private func recordPendingWarning(
        _ journal: inout HostV6MutationJournal,
        _ warning: CommittedWarningCode
    ) async throws -> HostV6.ModelCommandResult {
        try journal.setPendingWarning(warning, isPending: true)
        try await journalStore.save(journal)
        try await ledgerStore.atomicReplaceLedger(journal.ledger)
        return journal.result
    }

    private func credentialIDs(in result: HostV6.ModelCommandResult) -> [UUID] {
        result.pendingEffects.compactMap { effect in
            guard case .deleteCredential(let identityID) = effect else { return nil }
            return identityID
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private func privateKeyIDs(in result: HostV6.ModelCommandResult) -> [String] {
        result.pendingEffects.compactMap { effect in
            guard case .deletePrivateKeyMaterial(let keyID) = effect else { return nil }
            return keyID
        }.sorted()
    }
}

extension HostV6AuthorityFileStore: HostV6AuthorityStoring {}
