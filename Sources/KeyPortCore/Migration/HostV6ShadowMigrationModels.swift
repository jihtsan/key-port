import CryptoKit
import Foundation

public extension HostV6 {
    enum KeychainAccountState: String, Codable, CaseIterable, Hashable, Sendable {
        case missing
        case local
        case synchronizable
    }

    struct ShadowMigrationInspection: Hashable, Sendable {
        public var keychainAccountsBefore: [String: KeychainAccountState]
        public var keychainAccountsAfter: [String: KeychainAccountState]
        public var artifactHashesBefore: [String: String]
        public var artifactHashesAfter: [String: String]
        public var existingSSHHostAliases: Set<String>

        public init(
            keychainAccountsBefore: [String: KeychainAccountState],
            keychainAccountsAfter: [String: KeychainAccountState],
            artifactHashesBefore: [String: String],
            artifactHashesAfter: [String: String],
            existingSSHHostAliases: Set<String>
        ) {
            self.keychainAccountsBefore = keychainAccountsBefore
            self.keychainAccountsAfter = keychainAccountsAfter
            self.artifactHashesBefore = artifactHashesBefore
            self.artifactHashesAfter = artifactHashesAfter
            self.existingSSHHostAliases = existingSSHHostAliases
        }
    }

    struct ShadowMigrationCountReport: Codable, Hashable, Sendable {
        public var hosts: Int
        public var addresses: Int
        public var identities: Int
        public var devices: Int
        public var sshKeys: Int
        public var hostKeyPins: Int
        public var knownHostsLines: Int
        public var authorizations: Int
        public var nodeAssociations: Int
        public var auditEvents: Int
        public var mergeReviews: Int
        public var legacySources: Int

        public init(envelope: MetadataEnvelope) {
            hosts = envelope.synced.hosts.count
            addresses = envelope.synced.addresses.count
            identities = envelope.synced.identities.count
            devices = envelope.synced.devices.count
            sshKeys = envelope.synced.sshKeys.count
            hostKeyPins = envelope.synced.hostKeyPins.count
            knownHostsLines = envelope.synced.knownHostsLines.count
            authorizations = envelope.synced.authorizations.count
            nodeAssociations = envelope.synced.nodeAssociations.count
            auditEvents = envelope.local.auditEvents.count
            mergeReviews = envelope.synced.mergeReviews.count
            legacySources = envelope.migrationProvenance.legacySources.count
        }
    }

    struct ShadowMigrationProofReport: Codable, Hashable, Sendable {
        public var identityIDsUnchanged: Bool
        public var deviceIDsUnchanged: Bool
        public var keyIDsUnchanged: Bool
        public var authorizationIDsUnchanged: Bool
        public var nodeAssociationIDsUnchanged: Bool
        public var auditEventsUnchanged: Bool
        public var keychainAccountsUnchanged: Bool
        public var sshAliasesUnchanged: Bool
        public var knownHostsProvenancePreserved: Bool
        public var renderedKnownHostsUnchanged: Bool
        public var referencesValid: Bool
        public var protectedArtifactsUnchanged: Bool

        public var allPassed: Bool {
            identityIDsUnchanged
                && deviceIDsUnchanged
                && keyIDsUnchanged
                && authorizationIDsUnchanged
                && nodeAssociationIDsUnchanged
                && auditEventsUnchanged
                && keychainAccountsUnchanged
                && sshAliasesUnchanged
                && knownHostsProvenancePreserved
                && renderedKnownHostsUnchanged
                && referencesValid
                && protectedArtifactsUnchanged
        }
    }

    struct ShadowMigrationSourceReport: Codable, Hashable, Sendable {
        public var id: String
        public var revision: UInt64
        public var digest: String
        public var sourceDeleted: Bool
        public var vector: [String: UInt64]
        public var derivedEntityIDs: [EntityReference]

        public init(_ source: LegacySourceRevision) {
            id = source.id
            revision = source.revision
            digest = source.digest
            sourceDeleted = source.sourceDeleted
            vector = source.stamp.vector
            derivedEntityIDs = source.derivedEntityIDs
        }
    }

    struct ShadowMigrationArtifactReport: Codable, Hashable, Sendable {
        public var before: [String: String]
        public var after: [String: String]
    }

    struct ShadowMigrationIDContinuityReport: Codable, Hashable, Sendable {
        public var legacyIdentityIDs: [String]
        public var v6IdentityIDs: [String]
        public var legacyDeviceIDs: [String]
        public var v6DeviceIDs: [String]
        public var legacyKeyIDs: [String]
        public var v6KeyIDs: [String]
        public var legacyNodeAssociationIDs: [String]
        public var v6NodeAssociationIDs: [String]
    }

    struct ShadowMigrationReferenceReport: Codable, Hashable, Sendable {
        public var violationCount: Int
        public var keyToDevice: [String: String]
        public var authorizationToIdentity: [String: String]
        public var authorizationToKey: [String: String]
        public var nodeAssociationToIdentity: [String: String]
    }

    struct ShadowMigrationKeychainReport: Codable, Hashable, Sendable {
        public var accountsBefore: [String: KeychainAccountState]
        public var accountsAfter: [String: KeychainAccountState]
        public var queryAccountIDs: [String]
        public var writeCallCount: Int
    }

    struct ShadowMigrationSSHReport: Codable, Hashable, Sendable {
        public var aliasesBefore: [String: String]
        public var aliasesAfter: [String: String]
        public var provenanceCountBefore: Int
        public var provenanceCountAfter: Int
        public var provenanceSHA256Before: String
        public var provenanceSHA256After: String
        public var renderedKnownHostsLineCountBefore: Int
        public var renderedKnownHostsLineCountAfter: Int
        public var renderedKnownHostsSHA256Before: String
        public var renderedKnownHostsSHA256After: String
    }

    struct ShadowMigrationAuthorizationReport: Codable, Hashable, Sendable {
        public var legacyToV6: [String: String]
        public var identityReferences: [String: String]
        public var keyReferences: [String: String]
    }

    struct ShadowMigrationCausalityReport: Codable, Hashable, Sendable {
        public var sourceVectors: [String: [String: UInt64]]
        public var sourceDigests: [String: String]
        public var mergeReviewIDs: [UUID]
    }

    struct ShadowMigrationAllowListReport: Codable, Hashable, Sendable {
        public var cloudSHA256: String
        public var archiveSHA256: String
        public var cloudByteCount: Int
        public var archiveByteCount: Int
        public var cloudAuditEventCount: Int
        public var archiveAuditEventCount: Int
        public var forbiddenMatchCounts: [String: Int]
    }

    enum ShadowMigrationResult: String, Codable, CaseIterable, Hashable, Sendable {
        case lossless
    }

    struct ShadowMigrationReport: Codable, Hashable, Sendable {
        public var reportVersion: Int
        public var legacySchemaVersion: Int
        public var resultSchemaVersion: Int
        public var authorityMode: AuthorityMode
        public var result: ShadowMigrationResult
        public var inputSHA256: String
        public var stateSHA256: String
        public var counts: ShadowMigrationCountReport
        public var proofs: ShadowMigrationProofReport
        public var idContinuity: ShadowMigrationIDContinuityReport
        public var references: ShadowMigrationReferenceReport
        public var keychain: ShadowMigrationKeychainReport
        public var ssh: ShadowMigrationSSHReport
        public var authorizations: ShadowMigrationAuthorizationReport
        public var causality: ShadowMigrationCausalityReport
        public var allowList: ShadowMigrationAllowListReport
        public var legacySources: [ShadowMigrationSourceReport]
        public var ignoredStaleSourceIDs: [String]
        public var mergeReviewIDs: [UUID]
        public var artifacts: ShadowMigrationArtifactReport

        public init(
            legacySchemaVersion: Int,
            inputSHA256: String,
            stateSHA256: String,
            envelope: MetadataEnvelope,
            proofs: ShadowMigrationProofReport,
            idContinuity: ShadowMigrationIDContinuityReport,
            references: ShadowMigrationReferenceReport,
            keychain: ShadowMigrationKeychainReport,
            ssh: ShadowMigrationSSHReport,
            authorizations: ShadowMigrationAuthorizationReport,
            causality: ShadowMigrationCausalityReport,
            allowList: ShadowMigrationAllowListReport,
            ignoredStaleSourceIDs: [String],
            artifacts: ShadowMigrationArtifactReport
        ) {
            reportVersion = 1
            self.legacySchemaVersion = legacySchemaVersion
            resultSchemaVersion = envelope.schemaVersion
            authorityMode = .legacyAuthoritative
            result = .lossless
            self.inputSHA256 = inputSHA256
            self.stateSHA256 = stateSHA256
            counts = ShadowMigrationCountReport(envelope: envelope)
            self.proofs = proofs
            self.idContinuity = idContinuity
            self.references = references
            self.keychain = keychain
            self.ssh = ssh
            self.authorizations = authorizations
            self.causality = causality
            self.allowList = allowList
            legacySources = envelope.migrationProvenance.legacySources
                .map(ShadowMigrationSourceReport.init)
                .sorted { $0.id < $1.id }
            self.ignoredStaleSourceIDs = ignoredStaleSourceIDs.sorted()
            mergeReviewIDs = envelope.synced.mergeReviews.map(\.id).sorted {
                $0.uuidString < $1.uuidString
            }
            self.artifacts = artifacts
        }
    }

    struct ShadowMigrationBundle: Hashable, Sendable {
        public var envelope: MetadataEnvelope
        public var report: ShadowMigrationReport
        public var stateData: Data
        public var reportData: Data

        public init(
            envelope: MetadataEnvelope,
            report: ShadowMigrationReport,
            stateData: Data,
            reportData: Data
        ) {
            self.envelope = envelope
            self.report = report
            self.stateData = stateData
            self.reportData = reportData
        }
    }

    struct ShadowMigrationError: Error, Codable, Equatable, Sendable {
        public var failure: StableOperationFailure
        public var detailCode: String

        public init(failure: StableOperationFailure, detailCode: String) {
            self.failure = failure
            self.detailCode = detailCode
        }
    }

    enum CanonicalJSON {
        public static func encode<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(format(date))
            }
            return try encoder.encode(value)
        }

        public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard let date = parseDate(value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unsupported ISO-8601 date"
                    )
                }
                return date
            }
            return try decoder.decode(type, from: data)
        }

        public static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func format(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: date)
        }

        private static func parseDate(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            return wholeSeconds.date(from: value)
        }
    }
}
