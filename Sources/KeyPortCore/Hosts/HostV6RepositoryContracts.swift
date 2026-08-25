import Foundation

public protocol HostV6Clock: Sendable {
    func now() -> Date
}

public protocol HostV6UUIDGenerating: Sendable {
    func nextUUID() -> UUID
}

public protocol HostV6DeviceIDProviding: Sendable {
    func currentDeviceID() -> String
}

public protocol HostV6MetadataBytesStoring: Sendable {
    func load() async throws -> Data?
    func atomicReplace(with data: Data) async throws
}

public protocol HostV6MutationJournalStoring: Sendable {
    func loadLedger() async throws -> HostV6.CommandLedger
    func atomicReplaceLedger(_ ledger: HostV6.CommandLedger) async throws
}

public protocol HostV6PlatformCapabilityProviding: Sendable {
    func supports(_ capability: HostV6.PlatformCapability) -> Bool
}

public protocol HostV6MetadataRepositoryPort: Sendable {
    func snapshot() async throws -> HostV6.MetadataEnvelope
    func transact(_ command: HostV6.ModelCommand) async throws -> HostV6.ModelCommandResult
}

public protocol HostV6HostRepositoryPort: Sendable {
    func aggregate(hostID: UUID) async throws -> HostV6.HostAggregate?
    func deleteHost(hostID: UUID, context: HostV6.CommandContext) async throws -> HostV6.ModelCommandResult
    func deleteIdentity(identityID: UUID, context: HostV6.CommandContext) async throws -> HostV6.ModelCommandResult
    func deleteAddress(
        addressID: UUID,
        referencePolicy: HostV6.AddressReferencePolicy?,
        context: HostV6.CommandContext
    ) async throws -> HostV6.ModelCommandResult
    func deleteService(serviceID: UUID, context: HostV6.CommandContext) async throws -> HostV6.ModelCommandResult
}

public protocol HostV6CredentialInventoryRepositoryPort: Sendable {
    func devices() async throws -> [HostV6.Device]
    func keys() async throws -> [HostV6.SSHKeyRecord]
    func retireSSHKey(keyID: String, context: HostV6.CommandContext) async throws -> HostV6.ModelCommandResult
    func revokeDevice(deviceID: String, context: HostV6.CommandContext) async throws -> HostV6.ModelCommandResult
}

public extension HostV6 {
    enum PlatformCapability: String, Codable, CaseIterable, Hashable, Sendable {
        case atomicFileReplace
        case cloudMetadataV2
        case keychain
        case managedSSHConfig
        case managedKnownHosts
    }

    struct RepositoryEnvironment: Sendable {
        public let clock: any HostV6Clock
        public let uuidGenerator: any HostV6UUIDGenerating
        public let deviceIDProvider: any HostV6DeviceIDProviding
        public let metadataStore: any HostV6MetadataBytesStoring
        public let mutationJournalStore: any HostV6MutationJournalStoring
        public let platformCapabilities: any HostV6PlatformCapabilityProviding

        public init(
            clock: any HostV6Clock,
            uuidGenerator: any HostV6UUIDGenerating,
            deviceIDProvider: any HostV6DeviceIDProviding,
            metadataStore: any HostV6MetadataBytesStoring,
            mutationJournalStore: any HostV6MutationJournalStoring,
            platformCapabilities: any HostV6PlatformCapabilityProviding
        ) {
            self.clock = clock
            self.uuidGenerator = uuidGenerator
            self.deviceIDProvider = deviceIDProvider
            self.metadataStore = metadataStore
            self.mutationJournalStore = mutationJournalStore
            self.platformCapabilities = platformCapabilities
        }

        public func makeCommandContext(expected: RevisionExpectation?) -> CommandContext {
            CommandContext(
                commandID: uuidGenerator.nextUUID(),
                mutationID: uuidGenerator.nextUUID(),
                deviceID: deviceIDProvider.currentDeviceID(),
                timestamp: clock.now(),
                expected: expected
            )
        }
    }

    struct HostAggregate: Hashable, Sendable {
        public var host: Host
        public var addresses: [AccessAddress]
        public var identities: [SSHIdentity]
        public var pins: [HostKeyPin]
        public var knownHostsLines: [KnownHostsLine]
        public var services: [SavedService]
        public var authorizations: [Authorization]
        public var nodeAssociations: [NodeAssociation]

        public init(
            host: Host,
            addresses: [AccessAddress],
            identities: [SSHIdentity],
            pins: [HostKeyPin],
            knownHostsLines: [KnownHostsLine],
            services: [SavedService],
            authorizations: [Authorization],
            nodeAssociations: [NodeAssociation]
        ) {
            self.host = host
            self.addresses = addresses
            self.identities = identities
            self.pins = pins
            self.knownHostsLines = knownHostsLines
            self.services = services
            self.authorizations = authorizations
            self.nodeAssociations = nodeAssociations
        }
    }
}

public extension HostV6.SyncedGraph {
    func aggregate(hostID: UUID) -> HostV6.HostAggregate? {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
        let hostIdentities = identities.filter { $0.hostID == hostID }
        let identityIDs = Set(hostIdentities.map(\.id))
        let hostPins = hostKeyPins.filter { $0.hostID == hostID }
        let pinIDs = Set(hostPins.map(\.id))
        return HostV6.HostAggregate(
            host: host,
            addresses: addresses.filter { $0.hostID == hostID },
            identities: hostIdentities,
            pins: hostPins,
            knownHostsLines: knownHostsLines.filter { pinIDs.contains($0.pinID) },
            services: services.filter { $0.hostID == hostID },
            authorizations: authorizations.filter { identityIDs.contains($0.sshIdentityID) },
            nodeAssociations: nodeAssociations.filter { identityIDs.contains($0.sshIdentityID) }
        )
    }
}
