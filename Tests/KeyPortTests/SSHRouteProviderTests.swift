import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

/// SSH 路由适配层：feature flag 默认关闭、legacy/v6 双 route 语义一致、
/// fail closed 行为与敏感 fixture 零命中扫描。
final class SSHRouteProviderTests: XCTestCase {
    private let suiteName = "keyport-ssh-route-provider-tests-\(UUID().uuidString)"
    private let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    private let passwordMarker = "FIXTURE-SECRET-PASSWORD-7f3a9c"
    private let privateKeyPathMarker = "/Users/fixture/.ssh/keyport/identities/FIXTURE-PRIVATE-KEY-1b2c3d"
    private let ssidMarker = "FIXTURE-SSID-9e8d7c"
    private let bssidMarker = "FIXTURE-BSSID-aa:bb:cc"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func server(id: UUID, alias: String, host: String = "db.example.com", username: String) -> ServerConnection {
        ServerConnection(
            id: id,
            name: alias,
            host: host,
            port: 22,
            username: username,
            alias: alias,
            confirmedHostKeys: [
                HostKeyRecord(
                    algorithm: "ssh-ed25519",
                    fingerprint: "SHA256:fixtureProvider",
                    knownHostsLine: "db.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureProviderBlob",
                    firstConfirmedAt: t0,
                    lastSeenAt: t0
                ),
            ],
            status: .authorized,
            createdAt: t0,
            updatedAt: t0
        )
    }

    // MARK: - feature flag

    func testFlagDefaultsToOffAndLegacyAdapterReturnsSameObject() {
        let servers = [server(id: UUID(), alias: "a", username: "alice")]
        XCTAssertFalse(SSHCompatFeatureFlags.isV6SSHAdapterEnabled(defaults: defaults))

        let provider = SSHCompatFeatureFlags.routeProvider(servers: servers, defaults: defaults)
        XCTAssertTrue(provider is LegacySSHRouteProvider)
        XCTAssertEqual(provider.sshRoute(for: servers[0].id), servers[0])
        XCTAssertNil(provider.blockingFailure(for: servers[0].id))
    }

    func testFlagOnSelectsV6CompatAdapterWithEquivalentRoute() {
        let servers = [server(id: UUID(), alias: "a", username: "alice")]
        defaults.set(true, forKey: SSHCompatFeatureFlags.v6SSHAdapterKey)

        let provider = SSHCompatFeatureFlags.routeProvider(servers: servers, defaults: defaults)
        XCTAssertTrue(provider is V6CompatSSHRouteProvider)
        let routed = provider.sshRoute(for: servers[0].id)
        XCTAssertEqual(routed?.id, servers[0].id)
        XCTAssertEqual(routed?.alias, servers[0].alias)
        XCTAssertEqual(routed?.username, servers[0].username)
        XCTAssertEqual(routed?.port, servers[0].port)
        XCTAssertEqual(routed?.confirmedHostKeys.map(\.knownHostsLine), servers[0].confirmedHostKeys.map(\.knownHostsLine))
    }

    /// 回滚证据：删除 flag 后立即回到 legacy adapter，v6 staging/凭据不受影响。
    func testRollbackIsJustRemovingTheFlag() {
        let servers = [server(id: UUID(), alias: "a", username: "alice")]
        defaults.set(true, forKey: SSHCompatFeatureFlags.v6SSHAdapterKey)
        XCTAssertTrue(SSHCompatFeatureFlags.routeProvider(servers: servers, defaults: defaults) is V6CompatSSHRouteProvider)
        defaults.removeObject(forKey: SSHCompatFeatureFlags.v6SSHAdapterKey)
        let provider = SSHCompatFeatureFlags.routeProvider(servers: servers, defaults: defaults)
        XCTAssertTrue(provider is LegacySSHRouteProvider)
        XCTAssertEqual(provider.sshRoute(for: servers[0].id), servers[0])
    }

    // MARK: - fail closed

    func testBlockedIdentityFailsClosedWithStableCode() {
        let identityID = UUID()
        let projection = SSHCompatProjection.Result(
            servers: [],
            blockedIdentityIDs: [identityID],
            unavailableIdentityIDs: [],
            derivedKnownHostsLines: []
        )
        let provider = V6CompatSSHRouteProvider(projection: projection)
        XCTAssertNil(provider.sshRoute(for: identityID))
        let failure = provider.blockingFailure(for: identityID)
        XCTAssertEqual(failure?.code, .concurrentConflict)
        XCTAssertEqual(failure?.recoveryAction, .resolveConflict)
    }

    func testUnavailableIdentityFailsClosedWithStableCode() {
        let identityID = UUID()
        let projection = SSHCompatProjection.Result(
            servers: [],
            blockedIdentityIDs: [],
            unavailableIdentityIDs: [identityID],
            derivedKnownHostsLines: []
        )
        let provider = V6CompatSSHRouteProvider(projection: projection)
        XCTAssertNil(provider.sshRoute(for: identityID))
        let failure = provider.blockingFailure(for: identityID)
        XCTAssertEqual(failure?.code, .identityUnavailable)
        XCTAssertEqual(failure?.stage, .sshTrust)
    }

    func testDeletedServerHasNoRoute() {
        var deleted = server(id: UUID(), alias: "gone", username: "old")
        deleted.isDeleted = true
        let provider = LegacySSHRouteProvider(servers: [deleted])
        XCTAssertNil(provider.sshRoute(for: deleted.id))
    }

    // MARK: - 敏感 fixture 扫描

    /// 密码、私钥路径、SSID、BSSID 不得进入路由视图、稳定失败或可信会话请求。
    func testSensitiveFixturesNeverAppearInAdapterArtifacts() throws {
        let identityID = UUID()
        let servers = [server(id: identityID, alias: "a", username: "alice")]
        defaults.set(true, forKey: SSHCompatFeatureFlags.v6SSHAdapterKey)
        let provider = SSHCompatFeatureFlags.routeProvider(servers: servers, defaults: defaults)

        let encoder = JSONEncoder()
        var artifacts: [String] = []
        if let routed = provider.sshRoute(for: identityID) {
            artifacts.append(String(decoding: try encoder.encode(routed), as: UTF8.self))
        }
        let blockedProvider = V6CompatSSHRouteProvider(projection: SSHCompatProjection.Result(
            servers: [], blockedIdentityIDs: [identityID], unavailableIdentityIDs: [], derivedKnownHostsLines: []
        ))
        if let failure = blockedProvider.blockingFailure(for: identityID) {
            artifacts.append(String(decoding: try encoder.encode(failure), as: UTF8.self))
        }

        // 可信会话请求同样接受扫描（参数/环境/stdin 全表面）。
        let request = TrustedSSHSession.request(
            route: servers[0],
            identityPath: privateKeyPathMarker,
            knownHostsPath: "/tmp/keyport-tests/known_hosts",
            command: .installAuthorizedKey(encodedLine: "ZW5jb2RlZA==", keyBlob: "blob"),
            limits: .sshDefault
        )
        artifacts.append(request.arguments.joined(separator: " "))
        artifacts.append(request.environment.map { "\($0)=\($1)" }.joined(separator: " "))
        artifacts.append(String(decoding: request.standardInput ?? Data(), as: UTF8.self))

        let combined = artifacts.joined(separator: "\n")
        XCTAssertFalse(combined.contains(passwordMarker), "密码不得进入适配层任何产物")
        XCTAssertFalse(combined.contains(ssidMarker), "SSID 不得进入适配层任何产物")
        XCTAssertFalse(combined.contains(bssidMarker), "BSSID 不得进入适配层任何产物")
        // 私钥路径只能以 -i 参数形式指向本机密钥定位，不得扩散到其他字段。
        let privateKeyOccurrences = combined.components(separatedBy: privateKeyPathMarker).count - 1
        XCTAssertEqual(privateKeyOccurrences, 1, "私钥路径只允许出现在 -i 参数中")
    }
}
