import Foundation

public extension HostV6 {
    enum CloudV2Error: Error, Equatable, Sendable {
        case failure(OperationFailureCode)
        case unexpectedFields([String])
    }

    struct CloudPayloadDecodeResult: Hashable, Sendable {
        public var payload: CloudPayload
        public var diagnosticCodes: [OperationFailureCode]
        public var unexpectedFieldPaths: [String]

        public init(
            payload: CloudPayload,
            diagnosticCodes: [OperationFailureCode],
            unexpectedFieldPaths: [String]
        ) {
            self.payload = payload
            self.diagnosticCodes = diagnosticCodes
            self.unexpectedFieldPaths = unexpectedFieldPaths.sorted()
        }
    }

    enum CloudPayloadCodec {
        public static let maximumPayloadByteCount = 800 * 1_024

        public static func encode(
            _ envelope: MetadataEnvelope,
            maximumByteCount: Int = maximumPayloadByteCount
        ) throws -> Data {
            let data = try CanonicalJSON.encode(CloudPayload(envelope: envelope))
            guard data.count < maximumByteCount else {
                throw CloudV2Error.failure(.payloadTooLarge)
            }
            return data
        }

        public static func decode(_ data: Data) throws -> CloudPayloadDecodeResult {
            let rawObject = try JSONSerialization.jsonObject(with: data)
            let unexpectedFields = scanUnexpectedFields(in: rawObject)
            var payload = try CanonicalJSON.decode(CloudPayload.self, from: data)
            payload.synced.removeUnexpectedMergeCandidateFields()
            return CloudPayloadDecodeResult(
                payload: payload,
                diagnosticCodes: unexpectedFields.isEmpty ? [] : [.unexpectedCloudField],
                unexpectedFieldPaths: unexpectedFields
            )
        }

        public static func decodeStrict(_ data: Data) throws -> CloudPayload {
            let result = try decode(data)
            guard result.unexpectedFieldPaths.isEmpty else {
                throw CloudV2Error.unexpectedFields(result.unexpectedFieldPaths)
            }
            guard result.payload.schemaVersion == 6 else {
                throw CloudV2Error.failure(.decodeFailed)
            }
            return result.payload
        }

        private static func scanUnexpectedFields(in object: Any) -> [String] {
            guard let root = object as? [String: Any] else { return [] }
            var result: [String] = []
            appendUnexpectedKeys(
                in: root,
                allowed: ["schemaVersion", "synced", "migrationProvenance"],
                path: "",
                result: &result
            )
            if let synced = root["synced"] as? [String: Any] {
                appendUnexpectedKeys(
                    in: synced,
                    allowed: Set(SyncedGraph.cloudCodingKeys),
                    path: "synced",
                    result: &result
                )
                scanEntities(synced["hosts"], allowed: hostKeys, path: "synced.hosts[]", result: &result)
                scanEntities(synced["addresses"], allowed: addressKeys, path: "synced.addresses[]", result: &result)
                scanEntities(synced["identities"], allowed: identityKeys, path: "synced.identities[]", result: &result)
                scanEntities(synced["devices"], allowed: deviceKeys, path: "synced.devices[]", result: &result)
                scanEntities(synced["sshKeys"], allowed: sshKeyKeys, path: "synced.sshKeys[]", result: &result)
                scanEntities(synced["hostKeyPins"], allowed: pinKeys, path: "synced.hostKeyPins[]", result: &result)
                scanEntities(synced["knownHostsLines"], allowed: lineKeys, path: "synced.knownHostsLines[]", result: &result)
                scanEntities(synced["services"], allowed: serviceKeys, path: "synced.services[]", result: &result)
                scanEntities(synced["authorizations"], allowed: authorizationKeys, path: "synced.authorizations[]", result: &result)
                scanEntities(synced["nodeAssociations"], allowed: nodeKeys, path: "synced.nodeAssociations[]", result: &result)
                scanEntities(synced["mergeReviews"], allowed: reviewKeys, path: "synced.mergeReviews[]", result: &result)
                scanNestedObjects(
                    in: synced["hosts"],
                    field: "machineConfiguration",
                    allowed: machineConfigurationKeys,
                    path: "synced.hosts[].machineConfiguration",
                    result: &result
                )
                scanNestedObjects(
                    in: synced["devices"],
                    field: "tailscaleIdentity",
                    allowed: tailscaleIdentityKeys,
                    path: "synced.devices[].tailscaleIdentity",
                    result: &result
                )
                scanNestedObjects(
                    in: synced["services"],
                    field: "endpoint",
                    allowed: serviceEndpointKeys,
                    path: "synced.services[].endpoint",
                    result: &result
                )
                scanServiceBinds(synced["services"], result: &result)
                scanKnownHostsLineSources(synced["knownHostsLines"], result: &result)
                scanNestedObjects(
                    in: synced["nodeAssociations"],
                    field: "target",
                    allowed: actualNodeReferenceKeys,
                    path: "synced.nodeAssociations[].target",
                    result: &result
                )
                scanMergeReviewCandidates(synced["mergeReviews"], result: &result)
            }
            if let provenance = root["migrationProvenance"] as? [String: Any] {
                appendUnexpectedKeys(
                    in: provenance,
                    allowed: ["legacySources", "authorityManifest"],
                    path: "migrationProvenance",
                    result: &result
                )
                scanEntities(
                    provenance["legacySources"],
                    allowed: legacySourceKeys,
                    path: "migrationProvenance.legacySources[]",
                    result: &result
                )
                scanEntityReferenceFields(
                    in: provenance["legacySources"],
                    field: "derivedEntityIDs",
                    path: "migrationProvenance.legacySources[].derivedEntityIDs[]",
                    result: &result
                )
                if let manifest = provenance["authorityManifest"] as? [String: Any] {
                    appendUnexpectedKeys(
                        in: manifest,
                        allowed: authorityManifestKeys,
                        path: "migrationProvenance.authorityManifest",
                        result: &result
                    )
                    scanEntityReferences(
                        manifest["notRepresentable"],
                        path: "migrationProvenance.authorityManifest.notRepresentable[]",
                        result: &result
                    )
                }
            }
            return Array(Set(result)).sorted()
        }

        private static func scanEntities(
            _ value: Any?,
            allowed: Set<String>,
            path: String,
            result: inout [String]
        ) {
            guard let entities = value as? [[String: Any]] else { return }
            for entity in entities {
                appendUnexpectedKeys(in: entity, allowed: allowed, path: path, result: &result)
                if let stamp = entity["stamp"] as? [String: Any] {
                    appendUnexpectedKeys(
                        in: stamp,
                        allowed: ["vector", "mutationID", "updatedAt"],
                        path: "\(path).stamp",
                        result: &result
                    )
                }
            }
        }

        private static func scanNestedObjects(
            in value: Any?,
            field: String,
            allowed: Set<String>,
            path: String,
            result: inout [String]
        ) {
            guard let entities = value as? [[String: Any]] else { return }
            for entity in entities {
                guard let nested = entity[field] as? [String: Any] else { continue }
                appendUnexpectedKeys(in: nested, allowed: allowed, path: path, result: &result)
            }
        }

        private static func scanMergeReviewCandidates(_ value: Any?, result: inout [String]) {
            guard let reviews = value as? [[String: Any]] else { return }
            for review in reviews {
                let allowedSummaryFields = mergeCandidateKeys(entityType: review["entityType"] as? String)
                guard let candidates = review["candidates"] as? [[String: Any]] else { continue }
                for candidate in candidates {
                    appendUnexpectedKeys(
                        in: candidate,
                        allowed: mergeCandidateKeys,
                        path: "synced.mergeReviews[].candidates[]",
                        result: &result
                    )
                    guard let fields = candidate["summaryFields"] as? [String: Any] else { continue }
                    appendUnexpectedKeys(
                        in: fields,
                        allowed: allowedSummaryFields,
                        path: "synced.mergeReviews[].candidates[].summaryFields",
                        result: &result
                    )
                }
            }
        }

        private static func scanKnownHostsLineSources(_ value: Any?, result: inout [String]) {
            guard let lines = value as? [[String: Any]] else { return }
            for line in lines {
                scanAssociatedValueEnum(
                    line["source"],
                    payloadKeys: knownHostsLineSourcePayloadKeys,
                    path: "synced.knownHostsLines[].source",
                    result: &result
                )
            }
        }

        private static func scanServiceBinds(_ value: Any?, result: inout [String]) {
            guard let services = value as? [[String: Any]] else { return }
            for service in services {
                guard let endpoint = service["endpoint"] as? [String: Any] else { continue }
                scanAssociatedValueEnum(
                    endpoint["bind"],
                    payloadKeys: listenerBindPayloadKeys,
                    path: "synced.services[].endpoint.bind",
                    result: &result
                )
                guard let bind = endpoint["bind"] as? [String: Any],
                      let specific = bind["specific"] as? [String: Any],
                      let address = specific["_0"] as? [String: Any] else { continue }
                appendUnexpectedKeys(
                    in: address,
                    allowed: ipAddressKeys,
                    path: "synced.services[].endpoint.bind.specific._0",
                    result: &result
                )
            }
        }

        private static func scanEntityReferenceFields(
            in value: Any?,
            field: String,
            path: String,
            result: inout [String]
        ) {
            guard let entities = value as? [[String: Any]] else { return }
            for entity in entities {
                scanEntityReferences(entity[field], path: path, result: &result)
            }
        }

        private static func scanEntityReferences(_ value: Any?, path: String, result: inout [String]) {
            guard let references = value as? [[String: Any]] else { return }
            for reference in references {
                scanAssociatedValueEnum(
                    reference,
                    payloadKeys: entityReferencePayloadKeys,
                    path: path,
                    result: &result
                )
            }
        }

        private static func scanAssociatedValueEnum(
            _ value: Any?,
            payloadKeys: [String: Set<String>],
            path: String,
            result: inout [String]
        ) {
            guard let encoded = value as? [String: Any] else { return }
            appendUnexpectedKeys(in: encoded, allowed: Set(payloadKeys.keys), path: path, result: &result)
            for (caseName, allowed) in payloadKeys {
                guard let payload = encoded[caseName] as? [String: Any] else { continue }
                appendUnexpectedKeys(
                    in: payload,
                    allowed: allowed,
                    path: "\(path).\(caseName)",
                    result: &result
                )
            }
        }

        private static func appendUnexpectedKeys(
            in object: [String: Any],
            allowed: Set<String>,
            path: String,
            result: inout [String]
        ) {
            for key in object.keys where !allowed.contains(key) {
                result.append(path.isEmpty ? key : "\(path).\(key)")
            }
        }

        private static let hostKeys: Set<String> = [
            "id", "name", "group", "machineConfiguration", "fixedAddressID", "createdAt", "stamp", "deletedAt",
        ]
        private static let addressKeys: Set<String> = [
            "id", "hostID", "normalizedHost", "sshPort", "originalLabel", "source", "sortOrder", "stamp", "deletedAt",
        ]
        private static let identityKeys: Set<String> = [
            "id", "hostID", "username", "alias", "preferredAddressID", "createdAt", "stamp", "deletedAt",
        ]
        private static let deviceKeys: Set<String> = [
            "id", "name", "registeredAt", "lastActiveAt", "tailscaleIdentity", "stamp", "deletedAt",
        ]
        private static let sshKeyKeys: Set<String> = [
            "id", "deviceID", "kind", "publicKey", "fingerprint", "origin", "stamp", "deletedAt",
        ]
        private static let pinKeys: Set<String> = [
            "id", "hostID", "addressID", "algorithm", "fingerprint", "state", "firstConfirmedAt",
            "lastSeenAt", "replacedAt", "stamp", "deletedAt",
        ]
        private static let lineKeys: Set<String> = [
            "id", "pinID", "rawLine", "source", "duplicateOrdinal", "stamp", "deletedAt",
        ]
        private static let serviceKeys: Set<String> = [
            "id", "hostID", "name", "serviceProtocol", "endpoint", "isFavorite", "fixedAddressID", "stamp", "deletedAt",
        ]
        private static let authorizationKeys: Set<String> = [
            "sshIdentityID", "keyID", "fingerprint", "remoteComment", "remoteState", "relationState",
            "authorizedAt", "lastVerifiedAt", "stamp", "deletedAt",
        ]
        private static let nodeKeys: Set<String> = [
            "id", "sshIdentityID", "target", "state", "method", "autoLinkEnabled", "stamp", "deletedAt",
        ]
        private static let reviewKeys: Set<String> = [
            "id", "entityType", "entityID", "candidates", "isBlocking", "resolvedAt",
            "resolutionMutationID", "resolutionReason", "stamp", "deletedAt",
        ]
        private static let legacySourceKeys: Set<String> = [
            "id", "legacyKind", "legacyID", "revision", "digest", "sourceDeleted", "derivedEntityIDs", "stamp", "deletedAt",
        ]
        private static let authorityManifestKeys: Set<String> = [
            "mode", "v1Hash", "v6Hash", "compatibilityHash", "checkpointHash", "acknowledgedDeviceIDs",
            "cloudChangeTag", "firstV6MutationID", "codeVersion", "notRepresentable",
        ]
        private static let machineConfigurationKeys: Set<String> = [
            "hostname", "operatingSystem", "kernel", "architecture", "processorCount", "memoryBytes",
            "synchronizedAt",
        ]
        private static let mergeCandidateKeys: Set<String> = [
            "mutationID", "vector", "isDeleted", "summaryFields",
        ]
        private static let tailscaleIdentityKeys: Set<String> = ["nodeID", "dnsName", "addresses"]
        private static let serviceEndpointKeys: Set<String> = ["bind", "port", "path"]
        private static let actualNodeReferenceKeys: Set<String> = ["provider", "tailnetKey", "nodeID"]
        private static let ipAddressKeys: Set<String> = ["value", "family"]
        private static let knownHostsLineSourcePayloadKeys: [String: Set<String>] = [
            "legacyIdentity": ["_0"],
            "operation": ["_0"],
        ]
        private static let listenerBindPayloadKeys: [String: Set<String>] = [
            "loopbackV4": [],
            "loopbackV6": [],
            "wildcardV4": [],
            "wildcardV6": [],
            "specific": ["_0"],
        ]
        private static let entityReferencePayloadKeys = Dictionary(
            uniqueKeysWithValues: EntityType.allCases.map { ($0.rawValue, Set(["_0"])) }
        )

        fileprivate static func mergeCandidateKeys(entityType: String?) -> Set<String> {
            switch entityType.flatMap(EntityType.init(rawValue:)) {
            case .host:
                return [
                    "name", "group", "fixedAddressID", "createdAt", "machine.hostname",
                    "machine.operatingSystem", "machine.kernel", "machine.architecture",
                    "machine.processorCount", "machine.memoryBytes", "machine.synchronizedAt",
                ]
            case .address:
                return ["hostID", "normalizedHost", "sshPort", "originalLabel", "source", "sortOrder"]
            case .sshIdentity:
                return ["hostID", "username", "alias", "preferredAddressID", "createdAt"]
            case .device:
                return [
                    "name", "registeredAt", "lastActiveAt", "tailscale.nodeID", "tailscale.dnsName",
                    "tailscale.addresses",
                ]
            case .sshKeyRecord:
                return ["deviceID", "kind", "publicKey", "fingerprint", "origin"]
            case .hostKeyPin:
                return [
                    "hostID", "addressID", "algorithm", "fingerprint", "state", "firstConfirmedAt",
                    "lastSeenAt", "replacedAt",
                ]
            case .knownHostsLine:
                return ["pinID", "rawLine", "sourceKind", "sourceID", "duplicateOrdinal"]
            case .service:
                return ["hostID", "name", "protocol", "bind", "port", "path", "isFavorite", "fixedAddressID"]
            case .authorization:
                return [
                    "sshIdentityID", "keyID", "fingerprint", "remoteComment", "remoteState",
                    "relationState", "authorizedAt", "lastVerifiedAt",
                ]
            case .nodeAssociation:
                return ["sshIdentityID", "target", "state", "method", "autoLinkEnabled"]
            case .mergeReview:
                return [
                    "entityType", "entityID", "candidateMutationIDs", "isBlocking", "resolvedAt",
                    "resolutionMutationID", "resolutionReason",
                ]
            case .legacySourceRevision:
                return ["legacyKind", "legacyID", "revision", "digest", "sourceDeleted", "derivedEntityIDs"]
            case .auditEvent, .none:
                return []
            }
        }
    }

    struct CloudPayload: Codable, Hashable, Sendable {
        public var schemaVersion: Int
        public var synced: SyncedGraph
        public var migrationProvenance: MigrationProvenance

        public init(envelope: MetadataEnvelope) {
            schemaVersion = envelope.schemaVersion
            synced = envelope.synced
            synced.removeUnexpectedMergeCandidateFields()
            migrationProvenance = envelope.migrationProvenance
        }

        public func restoringLocalState(from localEnvelope: MetadataEnvelope) -> MetadataEnvelope {
            MetadataEnvelope(
                schemaVersion: schemaVersion,
                synced: synced,
                local: localEnvelope.local,
                migrationProvenance: migrationProvenance
            )
        }

    }

    struct ArchiveAuthenticationCheck: Codable, Hashable, Sendable {
        public var state: AuthenticationCheckState
        public var checkedAt: Date?

        public init(_ value: AuthenticationCheck) {
            state = value.state
            checkedAt = value.checkedAt
        }
    }

    struct ArchiveSSHIdentityState: Identifiable, Codable, Hashable, Sendable {
        public var sshIdentityID: UUID
        public var status: AuthorizationStatus
        public var lastCheckedAt: Date?
        public var passwordCheck: ArchiveAuthenticationCheck?
        public var keyCheck: ArchiveAuthenticationCheck?
        public var machineConfigurationRefreshAttemptedAt: Date?
        public var id: UUID { sshIdentityID }

        public init(_ value: LocalSSHIdentityState) {
            sshIdentityID = value.sshIdentityID
            status = value.status
            lastCheckedAt = value.lastCheckedAt
            passwordCheck = value.passwordCheck.map(ArchiveAuthenticationCheck.init)
            keyCheck = value.keyCheck.map(ArchiveAuthenticationCheck.init)
            machineConfigurationRefreshAttemptedAt = value.machineConfigurationRefreshAttemptedAt
        }
    }

    struct ArchiveLocalState: Codable, Hashable, Sendable {
        public var hostAnnotations: [LocalHostAnnotation]
        public var identityStates: [ArchiveSSHIdentityState]

        public init(local: LocalState) {
            hostAnnotations = local.hostAnnotations
            identityStates = local.identityStates.map(ArchiveSSHIdentityState.init)
        }
    }

    struct ArchivePayload: Codable, Hashable, Sendable {
        public var containerVersion: Int
        public var schemaVersion: Int
        public var synced: SyncedGraph
        public var local: ArchiveLocalState
        public var migrationProvenance: MigrationProvenance

        public init(envelope: MetadataEnvelope) {
            containerVersion = 2
            schemaVersion = envelope.schemaVersion
            synced = envelope.synced
            synced.removeUnexpectedMergeCandidateFields()
            local = ArchiveLocalState(local: envelope.local)
            migrationProvenance = envelope.migrationProvenance
        }
    }
}

private extension HostV6.SyncedGraph {
    mutating func removeUnexpectedMergeCandidateFields() {
        for reviewIndex in mergeReviews.indices {
            let allowed = HostV6.CloudPayloadCodec.mergeCandidateKeys(
                entityType: mergeReviews[reviewIndex].entityType.rawValue
            )
            for candidateIndex in mergeReviews[reviewIndex].candidates.indices {
                mergeReviews[reviewIndex].candidates[candidateIndex].summaryFields =
                    mergeReviews[reviewIndex].candidates[candidateIndex].summaryFields.filter {
                        allowed.contains($0.key)
                    }
            }
        }
    }
}
