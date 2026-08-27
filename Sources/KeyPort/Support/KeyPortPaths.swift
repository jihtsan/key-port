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
    var knownHosts: URL { keyPortDirectory.appendingPathComponent("known_hosts") }
    var userConfig: URL { sshDirectory.appendingPathComponent("config") }
    var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/KeyPort", isDirectory: true)
    }
    var tunnelRuntimeDirectory: URL {
        applicationSupport.appendingPathComponent("tunnel-runtime", isDirectory: true)
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

    func prepareDirectories() throws {
        try secureDirectory(sshDirectory)
        try secureDirectory(keyPortDirectory)
        try secureDirectory(identitiesDirectory)
        try secureDirectory(applicationSupport)
        try secureDirectory(tunnelRuntimeDirectory)
    }

    func prepareShadowMigrationDirectories() throws {
        try prepareDirectories()
        try secureDirectory(shadowMigrationRoot)
        try secureDirectory(shadowMigrationBundlesDirectory)
    }

    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
