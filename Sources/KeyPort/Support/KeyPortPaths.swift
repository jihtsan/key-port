import Foundation

struct KeyPortPaths: Sendable {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    var sshDirectory: URL { home.appendingPathComponent(".ssh", isDirectory: true) }
    var keyPortDirectory: URL { sshDirectory.appendingPathComponent("keyport", isDirectory: true) }
    var identitiesDirectory: URL { keyPortDirectory.appendingPathComponent("identities", isDirectory: true) }
    var knownHosts: URL { keyPortDirectory.appendingPathComponent("known_hosts") }
    var userConfig: URL { sshDirectory.appendingPathComponent("config") }
    var applicationSupport: URL { home.appendingPathComponent("Library/Application Support/KeyPort", isDirectory: true) }

    // Input paths for one-time migration and ownership checks; never rewritten as workspace authority.
    var managedConfig: URL { keyPortDirectory.appendingPathComponent("config") }
    var managedConfigDerivationState: URL { keyPortDirectory.appendingPathComponent("config.derivation.json") }
    var snapshot: URL { applicationSupport.appendingPathComponent("state-v1.json") }
    var snapshotBackup: URL { applicationSupport.appendingPathComponent("state-v1.json.bak") }
    var topologySnapshot: URL { applicationSupport.appendingPathComponent("topology-v1.json") }
    var topologySnapshotBackup: URL { applicationSupport.appendingPathComponent("topology-v1.json.bak") }
    var stateV6: URL { applicationSupport.appendingPathComponent("state-v6.json") }
    var authorityActivationJournal: URL { applicationSupport.appendingPathComponent("authority-activation-journal.json") }
    var v6CommitJournal: URL { applicationSupport.appendingPathComponent("migration-journal.json") }
    var v6MutationJournal: URL { applicationSupport.appendingPathComponent("mutation-journal-v6.json") }

    func prepareDirectories() throws {
        for url in [sshDirectory, keyPortDirectory, identitiesDirectory, applicationSupport] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
