import Foundation
import XCTest
import KeyPortCore
@testable import KeyPort

final class ManagedSSHPolicyInstallationTests: XCTestCase {
    func testImmutableGenerationReuseTamperRejectionAndActivationRollback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let i = ManagedSSHPolicyInstallation(home: home)
        let entry = SSHConfigEntry(server: .init(name: "Test", host: "192.0.2.1", username: "user", alias: "fixture"), identityPath: "/tmp/key")
        let a = try i.prepare(plans: [], directEntries: [entry], knownHostsLines: ["first"])
        let b = try i.prepare(plans: [], directEntries: [entry], knownHostsLines: ["first"])
        XCTAssertEqual(a.knownHosts, b.knownHosts)
        var install = ManagedAliasInstallation(home: home)
        try install.install(entries: a.entries, knownHosts: a.knownHosts)
        let original = try Data(contentsOf: install.managed)
        let c = try i.prepare(plans: [], directEntries: [entry], knownHostsLines: ["second"])
        install.beforeWrite = { if $0 == 1 { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try install.install(entries: c.entries, knownHosts: c.knownHosts))
        XCTAssertEqual(try Data(contentsOf: install.managed), original)
        try Data("tampered".utf8).write(to: a.knownHosts)
        XCTAssertThrowsError(try i.prepare(plans: [], directEntries: [entry], knownHostsLines: ["first"]))
    }
}
