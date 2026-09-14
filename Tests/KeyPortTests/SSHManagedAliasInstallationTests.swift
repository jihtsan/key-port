import Foundation
import XCTest
import KeyPortCore
@testable import KeyPort

final class SSHManagedAliasInstallationTests: XCTestCase {
    private func fixture(_ content: String = "") throws -> SSHConfigService.AliasInstallation {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("KeyPort alias space \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let installation = SSHConfigService.AliasInstallation(home: home)
        try Data(content.utf8).write(to: installation.userConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: installation.userConfig.path)
        return installation
    }
    private func entry(_ alias: String = "tencent-cloud", host: String = "example.test") -> SSHConfigEntry {
        .init(server: .init(name: "测试", host: host, port: 2222, username: "ubuntu", alias: alias), identityPath: "/tmp/key with spaces")
    }
    private func install(_ installation: SSHConfigService.AliasInstallation, entries: [SSHConfigEntry]? = nil) throws {
        try installation.install(entries: entries ?? [entry()], knownHosts: installation.home.appendingPathComponent("known hosts"))
    }
    func testRoundTripOrderPermissionsAndIdempotence() throws {
        let original = "# preserve bytes\nHost unrelated\n  HostName unrelated.test\n  Port 2200" // no trailing newline
        let i = try fixture(original)
        try install(i)
        let first = try Data(contentsOf: i.userConfig)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).hasSuffix(original))
        let count = try FileManager.default.contentsOfDirectory(atPath: i.directory.path).count
        try install(i)
        XCTAssertEqual(try Data(contentsOf: i.userConfig), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: i.directory.path).count, count)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: i.userConfig.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        try install(i, entries: [])
        XCTAssertEqual(try String(contentsOf: i.userConfig), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.managed.path))
    }
    func testOpenSSHActuallyParsesIncludeWithSpacesAndPreservesUnrelated() async throws {
        let i = try fixture("Host unrelated\n HostName original.test\n User other\n")
        try install(i)
        for (alias, expected) in [("tencent-cloud", "hostname example.test"), ("unrelated", "hostname original.test")] {
            let result = try await ProcessExecutor().execute(.init(executable: "/usr/bin/ssh", arguments: ["-G", "-F", i.userConfig.path, alias], limits: .sshDefault))
            XCTAssertTrue(result.succeeded, String(decoding: result.stderr, as: UTF8.self))
            let output = String(decoding: result.stdout, as: UTF8.self)
            XCTAssertTrue(output.contains(expected))
            if alias == "tencent-cloud" {
                XCTAssertTrue(output.contains("user ubuntu")); XCTAssertTrue(output.contains("port 2222"))
                XCTAssertTrue(output.contains("identityfile /tmp/key with spaces"))
                XCTAssertTrue(output.contains("userknownhostsfile " + i.home.appendingPathComponent("known hosts").path), output)
            }
        }
    }
    func testLiteralCaseWildcardAndNegationConflicts() throws {
        for pattern in ["tencent-cloud", "TENCENT-CLOUD", "tencent-*", "*", "tencent-clou?", "other tencent-cloud"] {
            let i = try fixture("Host \(pattern)\n HostName old.test\n")
            let original = try Data(contentsOf: i.userConfig)
            XCTAssertThrowsError(try install(i), pattern)
            XCTAssertEqual(try Data(contentsOf: i.userConfig), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: i.managed.path))
        }
        let excluded = try fixture("Host * !tencent-cloud\n User old\n")
        try install(excluded)
    }
    func testRecursiveRelativeAndQuotedGlobIncludeConflict() throws {
        let i = try fixture("Include \"nested files/*.conf\"\nHost unrelated\n HostName original.test\n")
        let directory = i.home.appendingPathComponent(".ssh/nested files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Include second.conf\n".utf8).write(to: directory.appendingPathComponent("first.conf"))
        try Data("Host TENCENT-CLOUD\n HostName old.test\n".utf8).write(to: i.home.appendingPathComponent(".ssh/second.conf"))
        XCTAssertThrowsError(try install(i))
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.managed.path))
    }
    func testMatchGlobalAndIncludeCyclesFailClosed() throws {
        for content in ["Match exec true\n User old\n", "ProxyCommand unsafe\n", "Include config\n"] {
            let i = try fixture(content)
            XCTAssertThrowsError(try install(i))
            XCTAssertEqual(try String(contentsOf: i.userConfig), content)
        }
    }
    func testRenameUpdateAndDeletedManagedFileRepair() async throws {
        let i = try fixture()
        try install(i)
        try install(i, entries: [entry("new-alias", host: "new.test")])
        let config = try String(contentsOf: i.managed)
        XCTAssertFalse(config.contains("tencent-cloud")); XCTAssertTrue(config.contains("new.test"))
        try FileManager.default.removeItem(at: i.managed)
        try install(i, entries: [entry("new-alias", host: "new.test")])
        XCTAssertEqual(try String(contentsOf: i.managed), config)
    }
    func testFailureAtEveryWriteRestoresBothFilesAndAllowsRetry() throws {
        for position in 0...2 {
            var i = try fixture("Host unrelated\n HostName before.test\n")
            try install(i)
            let user = try Data(contentsOf: i.userConfig), managed = try Data(contentsOf: i.managed)
            i.beforeWrite = { index in if index == position { throw CocoaError(.fileWriteNoPermission) } }
            XCTAssertThrowsError(try install(i, entries: [entry("renamed")]))
            XCTAssertEqual(try Data(contentsOf: i.userConfig), user)
            XCTAssertEqual(try Data(contentsOf: i.managed), managed)
            i.beforeWrite = nil
            try install(i, entries: [entry("renamed")])
        }
    }
    func testInterruptedTransactionCanRecoverAfterExternalConflictIsResolved() throws {
        var i = try fixture("Host unrelated\n HostName original.test\n")
        try install(i)
        let originalUser = try Data(contentsOf: i.userConfig)
        let originalManaged = try Data(contentsOf: i.managed)
        let external = Data("# concurrent edit\n".utf8)
        let config = i.userConfig
        i.beforeWrite = { index in
            if index == 2 { try external.write(to: config); throw CocoaError(.fileWriteNoPermission) }
        }
        XCTAssertThrowsError(try install(i, entries: [entry("renamed")]))
        XCTAssertEqual(try Data(contentsOf: config), external)
        XCTAssertTrue(FileManager.default.fileExists(atPath: i.directory.appendingPathComponent("transaction.json").path))
        // Represents the user preserving/resolving the concurrent change before a later launch.
        try originalUser.write(to: config)
        let restarted = SSHConfigService.AliasInstallation(home: i.home)
        try install(restarted)
        XCTAssertEqual(try Data(contentsOf: i.managed), originalManaged)
        XCTAssertEqual(try Data(contentsOf: config), originalUser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.directory.appendingPathComponent("transaction.json").path))
    }
    func testExternalManagedEditAndMovedIncludeArePreserved() throws {
        let i = try fixture()
        try install(i)
        let changed = "# user edited\n" + (try String(contentsOf: i.managed))
        try Data(changed.utf8).write(to: i.managed)
        XCTAssertThrowsError(try install(i))
        XCTAssertEqual(try String(contentsOf: i.managed), changed)
        let j = try fixture(); try install(j)
        let moved = "Host other\n" + (try String(contentsOf: j.userConfig))
        try Data(moved.utf8).write(to: j.userConfig)
        XCTAssertThrowsError(try install(j))
        XCTAssertEqual(try String(contentsOf: j.userConfig), moved)
    }
    func testSymlinkConfigAndDuplicateAliasesRejected() throws {
        let i = try fixture()
        try FileManager.default.removeItem(at: i.userConfig)
        let target = i.home.appendingPathComponent("original")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: i.userConfig, withDestinationURL: target)
        XCTAssertThrowsError(try install(i))
        XCTAssertEqual(try String(contentsOf: target), "original")
        let j = try fixture()
        XCTAssertThrowsError(try install(j, entries: [entry(), entry("TENCENT-CLOUD")]))
    }
}
