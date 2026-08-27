import Foundation
import KeyPortCore

enum HostV6RuntimeFeatureFlags {
    static let canaryKey = "KeyPort.hostV6CanaryEnabled"
    static let cloudV2Key = "KeyPort.hostV6CloudV2Enabled"
    static let mutationWorkflowKey = "KeyPort.hostV6MutationWorkflowEnabled"

    static func isCanaryEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: canaryKey)
    }

    static func isCloudV2Enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cloudV2Key)
    }

    static func isMutationWorkflowEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mutationWorkflowKey)
    }
}

struct HostV6Runtime {
    let metadataRepository: HostV6MutationWorkflow
}

enum HostV6RuntimeAssembly {
    static func makeIfEnabled(
        currentDeviceID: String,
        defaults: UserDefaults = .standard,
        paths: KeyPortPaths = KeyPortPaths()
    ) -> HostV6Runtime? {
        guard HostV6RuntimeFeatureFlags.isCanaryEnabled(defaults: defaults),
              HostV6RuntimeFeatureFlags.isCloudV2Enabled(defaults: defaults),
              HostV6RuntimeFeatureFlags.isMutationWorkflowEnabled(defaults: defaults) else {
            return nil
        }

        let runner = ProcessRunner()
        let authorityStore = HostV6AuthorityFileStore(paths: paths)
        let cloudCoordinator = HostV6CloudSyncCoordinator(
            transport: CloudKitV2RecordTransport(),
            currentDeviceID: currentDeviceID
        )
        let effects = ProductionHostV6MutationEffects(
            configService: SSHConfigService(runner: runner, paths: paths),
            hostKeyService: HostKeyService(runner: runner, paths: paths),
            keychainService: KeychainService(),
            cloudCoordinator: cloudCoordinator,
            authorityStore: authorityStore,
            paths: paths
        )
        let repository = HostV6MutationWorkflow(
            authorityStore: authorityStore,
            ledgerStore: HostV6CommandLedgerFileStore(paths: paths),
            journalStore: HostV6MutationJournalFileStore(paths: paths),
            effects: effects,
            existingSSHHostAliases: {
                let config = (try? String(contentsOf: paths.userConfig, encoding: .utf8)) ?? ""
                return SSHConfigGenerator.aliases(in: config)
            }
        )
        return HostV6Runtime(metadataRepository: repository)
    }
}
