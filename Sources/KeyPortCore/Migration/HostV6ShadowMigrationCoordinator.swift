import Foundation

public protocol HostV6ShadowCredentialInspecting: Sendable {
    func accountState(for accountID: String) async -> HostV6.KeychainAccountState
}

public protocol HostV6ShadowArtifactInspecting: Sendable {
    func protectedArtifactHashes() async throws -> [String: String]
}

public protocol HostV6ShadowStagingStoring: Sendable {
    func previousStateData() async throws -> Data?
    func atomicPublish(stateData: Data, reportData: Data) async throws
}

public extension HostV6 {
    struct ShadowMigrationCoordinator: Sendable {
        public let engine: ShadowMigrationEngine
        public let credentialInspector: any HostV6ShadowCredentialInspecting
        public let artifactInspector: any HostV6ShadowArtifactInspecting
        public let stagingStore: any HostV6ShadowStagingStoring

        public init(
            engine: ShadowMigrationEngine,
            credentialInspector: any HostV6ShadowCredentialInspecting,
            artifactInspector: any HostV6ShadowArtifactInspecting,
            stagingStore: any HostV6ShadowStagingStoring
        ) {
            self.engine = engine
            self.credentialInspector = credentialInspector
            self.artifactInspector = artifactInspector
            self.stagingStore = stagingStore
        }

        public func stage(
            legacyData: Data,
            existingSSHHostAliases: Set<String>
        ) async throws -> ShadowMigrationBundle {
            let accountIDs = try engine.legacyIdentityAccountIDs(from: legacyData)
            let accountsBefore = await inspectAccounts(accountIDs)
            let artifactsBefore: [String: String]
            do {
                artifactsBefore = try await artifactInspector.protectedArtifactHashes()
            } catch {
                throw stagingError(objectID: "protected-artifacts", detail: "initialInspectionFailed")
            }
            if let snapshotHash = artifactsBefore["state-v1.json"],
               snapshotHash != CanonicalJSON.sha256(legacyData) {
                throw stagingError(objectID: "state-v1", detail: "legacyInputHashMismatch")
            }

            let previousState: Data?
            do {
                previousState = try await stagingStore.previousStateData()
            } catch {
                throw stagingError(objectID: "v6-shadow-staging", detail: "previousStateReadFailed")
            }

            _ = try engine.prepare(
                legacyData: legacyData,
                previousStateData: previousState,
                inspection: ShadowMigrationInspection(
                    keychainAccountsBefore: accountsBefore,
                    keychainAccountsAfter: accountsBefore,
                    artifactHashesBefore: artifactsBefore,
                    artifactHashesAfter: artifactsBefore,
                    existingSSHHostAliases: existingSSHHostAliases
                )
            )

            let accountsAfter = await inspectAccounts(accountIDs)
            let artifactsAfter: [String: String]
            do {
                artifactsAfter = try await artifactInspector.protectedArtifactHashes()
            } catch {
                throw stagingError(objectID: "protected-artifacts", detail: "finalInspectionFailed")
            }
            let bundle = try engine.prepare(
                legacyData: legacyData,
                previousStateData: previousState,
                inspection: ShadowMigrationInspection(
                    keychainAccountsBefore: accountsBefore,
                    keychainAccountsAfter: accountsAfter,
                    artifactHashesBefore: artifactsBefore,
                    artifactHashesAfter: artifactsAfter,
                    existingSSHHostAliases: existingSSHHostAliases
                )
            )

            do {
                try await stagingStore.atomicPublish(
                    stateData: bundle.stateData,
                    reportData: bundle.reportData
                )
            } catch let error as ShadowMigrationError {
                throw error
            } catch {
                throw stagingError(objectID: "v6-shadow-staging", detail: "atomicPublishFailed")
            }
            return bundle
        }

        private func inspectAccounts(_ accountIDs: [String]) async -> [String: KeychainAccountState] {
            var result: [String: KeychainAccountState] = [:]
            for accountID in accountIDs {
                result[accountID] = await credentialInspector.accountState(for: accountID)
            }
            return result
        }

        private func stagingError(objectID: String, detail: String) -> ShadowMigrationError {
            ShadowMigrationError(
                failure: StableOperationFailure(
                    stage: .migration,
                    objectID: objectID,
                    code: .artifactMismatch,
                    recoveryAction: .reload
                ),
                detailCode: detail
            )
        }
    }
}
