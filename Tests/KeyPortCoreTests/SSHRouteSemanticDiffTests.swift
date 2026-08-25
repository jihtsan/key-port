import Foundation
import XCTest
@testable import KeyPortCore

/// 验收证据：对同一 fixture，legacy route 与 v6 兼容投影 route 渲染出的
/// managed SSH config 经真实 `/usr/bin/ssh -G` 展开后，alias、hostname（DNS 语义）、
/// port、user、identityfile、userknownhostsfile 关键字段完全一致。
final class SSHRouteSemanticDiffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_787_000_100)

    private let ed25519Line = "db.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureSemanticDiffEd25519Blob"
    private let rsaLine = "db.example.com ssh-rsa AAAAB3NzaC1yc2EAAAAFixtureSemanticDiffRsaBlob"

    private func key(_ line: String, _ algorithm: String) -> HostKeyRecord {
        HostKeyRecord(
            algorithm: algorithm,
            fingerprint: "SHA256:fixture-\(algorithm)",
            knownHostsLine: line,
            firstConfirmedAt: t0,
            lastSeenAt: t1
        )
    }

    private func makeServers() -> [ServerConnection] {
        let keys = [key(ed25519Line, "ssh-ed25519"), key(rsaLine, "ssh-rsa")]
        return [
            ServerConnection(
                id: UUID(uuidString: "11110000-0000-4000-8000-000000000001")!,
                name: "db-alice", host: "DB.Example.COM.", port: 22, username: "alice",
                alias: "kp-diff-alice", group: "prod", confirmedHostKeys: keys,
                status: .authorized, createdAt: t0, updatedAt: t1
            ),
            ServerConnection(
                id: UUID(uuidString: "22220000-0000-4000-8000-000000000002")!,
                name: "db-bob", host: "db.example.com", port: 22, username: "bob",
                alias: "kp-diff-bob", group: "prod", confirmedHostKeys: keys,
                status: .authorized, createdAt: t1, updatedAt: t1
            ),
            ServerConnection(
                id: UUID(uuidString: "33330000-0000-4000-8000-000000000003")!,
                name: "other", host: "other.internal", port: 2222, username: "ops",
                alias: "kp-diff-ops", group: "prod", confirmedHostKeys: keys,
                status: .needsAuthorization, createdAt: t0, updatedAt: t1
            ),
        ]
    }

    func testLegacyAndV6RoutesProduceSemanticallyIdenticalSSHConfig() throws {
        let servers = makeServers()
        let identityPath = "/tmp/keyport-fixture-identity"

        let legacyEntries = servers.map { SSHConfigEntry(server: $0, identityPath: identityPath) }
        let legacyConfig = SSHConfigGenerator.managedConfig(entries: legacyEntries)

        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let projection = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)
        XCTAssertEqual(projection.servers.count, servers.count)
        let v6Entries = projection.servers.map { SSHConfigEntry(server: $0, identityPath: identityPath) }
        let v6Config = SSHConfigGenerator.managedConfig(entries: v6Entries)

        // 渲染结果确定性：重复投影不新增 alias。
        XCTAssertEqual(
            Set(SSHConfigGenerator.aliases(in: legacyConfig)),
            Set(SSHConfigGenerator.aliases(in: v6Config))
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-ssh-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let legacyConfigURL = temporaryDirectory.appendingPathComponent("legacy-config")
        let v6ConfigURL = temporaryDirectory.appendingPathComponent("v6-config")
        try legacyConfig.write(to: legacyConfigURL, atomically: true, encoding: .utf8)
        try v6Config.write(to: v6ConfigURL, atomically: true, encoding: .utf8)

        for alias in ["kp-diff-alice", "kp-diff-bob", "kp-diff-ops"] {
            let legacyRoute = try sshEffectiveRoute(alias: alias, config: legacyConfigURL)
            let v6Route = try sshEffectiveRoute(alias: alias, config: v6ConfigURL)
            XCTAssertEqual(legacyRoute.alias, v6Route.alias)
            // hostname 按 DNS 语义比较（大小写与尾点不构成语义差异）。
            XCTAssertEqual(
                legacyRoute.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(),
                v6Route.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            )
            XCTAssertEqual(legacyRoute.port, v6Route.port)
            XCTAssertEqual(legacyRoute.username, v6Route.username)
            XCTAssertEqual(legacyRoute.identityFiles, v6Route.identityFiles)
            XCTAssertEqual(legacyRoute.proxyJump, v6Route.proxyJump)
            XCTAssertEqual(legacyRoute.proxyCommand, v6Route.proxyCommand)
        }

        // known_hosts 派生文件：legacy sorted(unique) 与 v6 来源行派生完全相等。
        let legacyKnownHosts = Array(Set(servers.flatMap(\.confirmedHostKeys).map(\.knownHostsLine))).sorted()
        XCTAssertEqual(projection.derivedKnownHostsLines, legacyKnownHosts)

        // userknownhostsfile 指令在两条 route 中一致（生成器固定输出）。
        for alias in ["kp-diff-alice", "kp-diff-bob", "kp-diff-ops"] {
            let legacyKnownHostsOption = try sshGOption("userknownhostsfile", alias: alias, config: legacyConfigURL)
            let v6KnownHostsOption = try sshGOption("userknownhostsfile", alias: alias, config: v6ConfigURL)
            XCTAssertEqual(legacyKnownHostsOption, v6KnownHostsOption)
        }
    }

    /// 运行真实 `/usr/bin/ssh -G` 并用现有 `SSHConfigDiscoveryParser` 解析。
    private func sshEffectiveRoute(alias: String, config: URL) throws -> DiscoveredSSHConnection {
        let output = try runSSHG(arguments: ["-G", "-F", config.path, alias])
        guard let route = SSHConfigDiscoveryParser.parse(alias: alias, output: output) else {
            XCTFail("ssh -G 输出无法解析：\(alias)")
            throw NSError(domain: "SSHRouteSemanticDiffTests", code: 1)
        }
        return route
    }

    private func sshGOption(_ option: String, alias: String, config: URL) throws -> String? {
        let output = try runSSHG(arguments: ["-G", "-F", config.path, alias])
        return output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first { $0.lowercased().hasPrefix("\(option) ") }
            .map { String($0.dropFirst(option.count + 1)) }
    }

    private func runSSHG(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("ssh -G 退出码非零：\(process.terminationStatus)")
            throw NSError(domain: "SSHRouteSemanticDiffTests", code: 2)
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
