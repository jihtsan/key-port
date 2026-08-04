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
    var snapshot: URL { applicationSupport.appendingPathComponent("state-v1.json") }

    func prepareDirectories() throws {
        try secureDirectory(sshDirectory)
        try secureDirectory(keyPortDirectory)
        try secureDirectory(identitiesDirectory)
        try secureDirectory(applicationSupport)
    }

    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
