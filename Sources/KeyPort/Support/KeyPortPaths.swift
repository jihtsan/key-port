import Foundation

struct KeyPortPaths: Sendable {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var sshDirectory: URL { home.appendingPathComponent(".ssh", isDirectory: true) }
    var keyPortDirectory: URL { sshDirectory.appendingPathComponent("keyport", isDirectory: true) }
    var identitiesDirectory: URL { keyPortDirectory.appendingPathComponent("identities", isDirectory: true) }
    var managedConfig: URL { keyPortDirectory.appendingPathComponent("config") }
    var managedConfigDerivationState: URL {
        keyPortDirectory.appendingPathComponent("config.derivation.json")
    }
    var knownHosts: URL { keyPortDirectory.appendingPathComponent("known_hosts") }
    var userConfig: URL { sshDirectory.appendingPathComponent("config") }
    var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/KeyPort", isDirectory: true)
    }
    var snapshot: URL { applicationSupport.appendingPathComponent("state-v1.json") }
    var connectionHistory: URL { applicationSupport.appendingPathComponent("history-v1.json") }
    var shadowMigrationRoot: URL {
        applicationSupport.appendingPathComponent("v6-shadow-staging", isDirectory: true)
    }
    var shadowMigrationBundlesDirectory: URL {
        shadowMigrationRoot.appendingPathComponent("bundles", isDirectory: true)
    }
    var shadowMigrationCurrentPointer: URL {
        shadowMigrationRoot.appendingPathComponent("current.json")
    }
    var stateV6: URL { applicationSupport.appendingPathComponent("state-v6.json") }
    var stateV1Compatibility: URL { applicationSupport.appendingPathComponent("state-v1-compat.json") }
    var authorityManifest: URL { applicationSupport.appendingPathComponent("authority-manifest.json") }
    var authorityC3EvidenceDirectory: URL {
        applicationSupport.appendingPathComponent("authority-c3", isDirectory: true)
    }
    var v6CommitJournal: URL { applicationSupport.appendingPathComponent("migration-journal.json") }
    var v6MutationJournal: URL { applicationSupport.appendingPathComponent("mutation-journal-v6.json") }
    var v6CommandLedger: URL { applicationSupport.appendingPathComponent("command-ledger-v6.json") }
    var v6CheckpointsDirectory: URL {
        applicationSupport.appendingPathComponent("v6-checkpoints", isDirectory: true)
    }
    var v6CommitStagingDirectory: URL {
        applicationSupport.appendingPathComponent("v6-commit-staging", isDirectory: true)
    }
    var stagedStateV6: URL { v6CommitStagingDirectory.appendingPathComponent("state-v6.next") }
    var stagedCompatibility: URL { v6CommitStagingDirectory.appendingPathComponent("state-v1-compat.next") }
    var stagedCheckpoint: URL { v6CommitStagingDirectory.appendingPathComponent("checkpoint.next") }
    var stagedManifest: URL { v6CommitStagingDirectory.appendingPathComponent("authority-manifest.next") }

    func checkpoint(for hash: String) -> URL {
        v6CheckpointsDirectory.appendingPathComponent("\(hash).json")
    }

    func prepareDirectories() throws {
        try secureDirectory(sshDirectory)
        try secureDirectory(keyPortDirectory)
        try secureDirectory(identitiesDirectory)
        try secureDirectory(applicationSupport)
    }

    func prepareShadowMigrationDirectories() throws {
        try prepareDirectories()
        try secureDirectory(shadowMigrationRoot)
        try secureDirectory(shadowMigrationBundlesDirectory)
    }

    func prepareV6AuthorityDirectories() throws {
        try prepareDirectories()
        try secureDirectory(v6CheckpointsDirectory)
        try secureDirectory(v6CommitStagingDirectory)
    }

    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
