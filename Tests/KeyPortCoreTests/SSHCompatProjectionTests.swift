import Foundation
import XCTest
@testable import KeyPortCore

/// 切片 C：v6 <-> legacy SSH 兼容投影的行为与回环证据。
final class SSHCompatProjectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_787_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_787_000_100)
    private let t2 = Date(timeIntervalSince1970: 1_787_000_200)

    private let serverAID = UUID(uuidString: "aaaa0000-0000-4000-8000-000000000001")!
    private let serverBID = UUID(uuidString: "bbbb0000-0000-4000-8000-000000000002")!
    private let serverCID = UUID(uuidString: "cccc0000-0000-4000-8000-000000000003")!
    private let serverDID = UUID(uuidString: "dddd0000-0000-4000-8000-000000000004")!

    private let ed25519Line = "db.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEd25519KeyBlobForCompatProjectionTests"
    private let ed25519Fingerprint = "SHA256:fixtureEd25519FingerprintForCompatProjection"
    private let rsaLine = "db.example.com ssh-rsa AAAAB3NzaC1yc2EAAAAFixtureRsaKeyBlobForCompatProjectionTests"
    private let rsaFingerprint = "SHA256:fixtureRsaFingerprintForCompatProjection"

    // MARK: - Fixtures

    private func makeServer(
        id: UUID,
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        alias: String,
        keys: [HostKeyRecord],
        status: AuthorizationStatus = .authorized,
        notes: String = "",
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool = false,
        version: Int = 3
    ) -> ServerConnection {
        ServerConnection(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            alias: alias,
            group: "prod",
            notes: notes,
            confirmedHostKeys: keys,
            status: status,
            statusDetail: "detail-\(alias)",
            lastCheckedAt: updatedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            version: version
        )
    }

    private func ed25519Record(lastSeenAt: Date) -> HostKeyRecord {
        HostKeyRecord(
            algorithm: "ssh-ed25519",
            fingerprint: ed25519Fingerprint,
            knownHostsLine: ed25519Line,
            firstConfirmedAt: t0,
            lastSeenAt: lastSeenAt
        )
    }

    private func rsaRecord(lastSeenAt: Date) -> HostKeyRecord {
        HostKeyRecord(
            algorithm: "ssh-rsa",
            fingerprint: rsaFingerprint,
            knownHostsLine: rsaLine,
            firstConfirmedAt: t0,
            lastSeenAt: lastSeenAt
        )
    }

    /// 同端点双账号（字面大小写/尾点不同）+ 无密钥账号 + 已删除账号。
    private func makeFixtureServers() -> [ServerConnection] {
        [
            makeServer(
                id: serverAID, name: "db-alice", host: "DB.Example.COM.", username: "alice",
                alias: "db-alice", keys: [ed25519Record(lastSeenAt: t1), rsaRecord(lastSeenAt: t1)],
                notes: "alice 备注", createdAt: t0, updatedAt: t1
            ),
            makeServer(
                id: serverBID, name: "db-bob", host: "db.example.com", username: "bob",
                alias: "db-bob", keys: [ed25519Record(lastSeenAt: t1), rsaRecord(lastSeenAt: t1)],
                createdAt: t1, updatedAt: t1
            ),
            makeServer(
                id: serverDID, name: "db-nokey", host: "db.example.com", username: "carol",
                alias: "db-carol", keys: [], status: .hostKeyPending,
                createdAt: t1, updatedAt: t1
            ),
            makeServer(
                id: serverCID, name: "gone", host: "gone.example.com", username: "old",
                alias: "gone", keys: [ed25519Record(lastSeenAt: t2)],
                createdAt: t0, updatedAt: t2, isDeleted: true
            ),
        ]
    }

    // MARK: - 回环：v5 -> v6 -> legacy 路由字段完全相等

    func testRoundTripPreservesRouteFieldsAliasKeychainAndHostKeys() {
        let servers = makeFixtureServers()
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)

        // 墓碑 identity 不进入路由视图。
        XCTAssertEqual(Set(result.servers.map(\.id)), [serverAID, serverBID, serverDID])
        XCTAssertTrue(result.blockedIdentityIDs.isEmpty)
        XCTAssertTrue(result.unavailableIdentityIDs.isEmpty)

        let legacyByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        // 架构 6.5：兼容视图带“所选地址的全部活跃 Pin 来源行”；同端点多账号
        // 共享同一地址信任集（ADR-5），per-identity 多重集合 = 该地址活跃来源行全集。
        let activeLegacy = servers.filter { !$0.isDeleted }
        for projected in result.servers {
            let legacy = legacyByID[projected.id]!
            // identity ID 原样继承 => Keychain account（id 小写 UUID）定位不变。
            XCTAssertEqual(projected.id, legacy.id)
            XCTAssertEqual(
                HostV6SSHCompatProjection.keychainAccount(for: projected.id),
                legacy.id.uuidString.lowercased()
            )
            XCTAssertEqual(projected.alias, legacy.alias)
            XCTAssertEqual(projected.port, legacy.port)
            XCTAssertEqual(projected.username, legacy.username)
            XCTAssertEqual(projected.group, legacy.group)
            let endpointKey = HostV6.StableID.legacyEndpointKey(host: legacy.host, port: UInt16(clamping: legacy.port))
            let expectedKeys = activeLegacy
                .filter { HostV6.StableID.legacyEndpointKey(host: $0.host, port: UInt16(clamping: $0.port)) == endpointKey }
                .flatMap(\.confirmedHostKeys)
            XCTAssertEqual(
                Multiset(projected.confirmedHostKeys.map { "\($0.algorithm)|\($0.fingerprint)|\($0.knownHostsLine)" }),
                Multiset(expectedKeys.map { "\($0.algorithm)|\($0.fingerprint)|\($0.knownHostsLine)" })
            )
            XCTAssertEqual(projected.status, legacy.status)
            XCTAssertEqual(projected.statusDetail, legacy.statusDetail)
            XCTAssertEqual(projected.lastCheckedAt, legacy.lastCheckedAt)
            XCTAssertEqual(projected.isDeleted, false)
        }

        // 代表账号的 hostname 字面值原样保留；同端点另一账号归一到同一地址（语义等价）。
        XCTAssertEqual(result.servers.first { $0.id == serverAID }?.host, "DB.Example.COM.")
        let projectedB = result.servers.first { $0.id == serverBID }!
        XCTAssertEqual(
            projectedB.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(),
            legacyByID[serverBID]!.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        )
        // 备注经 LocalHostAnnotation 按来源 identity 还原。
        XCTAssertEqual(result.servers.first { $0.id == serverAID }?.notes, "alice 备注")
        // known_hosts 派生文件与 legacy 的 sorted(unique) 口径一致。
        let legacyDerived = Array(Set(servers.flatMap(\.confirmedHostKeys).map(\.knownHostsLine))).sorted()
        XCTAssertEqual(result.derivedKnownHostsLines, legacyDerived)
    }

    func testAssemblyIsDeterministic() {
        let servers = makeFixtureServers()
        let first = LegacySSHCompatAssembly.assemble(servers: servers)
        let second = LegacySSHCompatAssembly.assemble(servers: servers.shuffled())
        XCTAssertEqual(first, second)
    }

    /// ADR-5：同地址多账号的信任状态在 v6 统一为一份 Pin；来源行 provenance 不丢。
    func testDivergentLegacyTrustSetsUnifyPerAddressButKeepProvenance() {
        var servers = makeFixtureServers()
        // legacy B 只确认 ed25519（与 A 漂移）。
        servers[1] = makeServer(
            id: serverBID, name: "db-bob", host: "db.example.com", username: "bob",
            alias: "db-bob", keys: [ed25519Record(lastSeenAt: t1)],
            createdAt: t1, updatedAt: t1
        )
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)

        // 派生 known_hosts 仍等于 legacy 全集 sorted(unique)。
        let legacyDerived = Array(Set(servers.flatMap(\.confirmedHostKeys).map(\.knownHostsLine))).sorted()
        XCTAssertEqual(result.derivedKnownHostsLines, legacyDerived)
        // 同地址统一信任：A 与 B 投影出相同的 confirmed 集合（逻辑 Pin 合并）。
        let keysA = result.servers.first { $0.id == serverAID }!.confirmedHostKeys
        let keysB = result.servers.first { $0.id == serverBID }!.confirmedHostKeys
        XCTAssertEqual(Set(keysA.map(\.id)), Set(keysB.map(\.id)))
        // 但 B 的来源行 provenance 仍以 B 为 source 独立存在。
        let bLines = assembly.graph.knownHostsLines.filter { $0.source.id == serverBID && $0.deletedAt == nil }
        XCTAssertEqual(bLines.count, 1)
        XCTAssertEqual(bLines.first?.rawLine, ed25519Line)
    }

    /// 完全相同 rawLine 的多重来源按 duplicateOrdinal 保留（架构 5.1）。
    func testDuplicateRawLinesKeepMultiplicityWithOrdinals() {
        var servers = makeFixtureServers()
        servers[0] = makeServer(
            id: serverAID, name: "db-alice", host: "DB.Example.COM.", username: "alice",
            alias: "db-alice",
            keys: [ed25519Record(lastSeenAt: t1), ed25519Record(lastSeenAt: t1), rsaRecord(lastSeenAt: t1)],
            createdAt: t0, updatedAt: t1
        )
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)

        let aLines = assembly.graph.knownHostsLines
            .filter { $0.source.id == serverAID && $0.rawLine == ed25519Line }
            .sorted { $0.duplicateOrdinal < $1.duplicateOrdinal }
        XCTAssertEqual(aLines.map(\.duplicateOrdinal), [0, 1])
        XCTAssertEqual(Set(aLines.map(\.id)).count, 2, "数组重排不影响 line ID；两条重复来源各自稳定")

        // 重复行不改变派生文件（sorted unique），但 provenance 保留两条。
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)
        XCTAssertEqual(result.derivedKnownHostsLines.filter { $0 == ed25519Line }.count, 1)
    }

    // MARK: - 信任 fail closed

    private func makeHandBuiltGraph(
        pinState: HostV6.HostKeyPinState,
        addressSource: HostV6.AddressSource = .legacy,
        blockingReview: Bool = false
    ) -> (HostV6.SyncedGraph, HostV6.LocalState, UUID) {
        let servers = [
            makeServer(
                id: serverAID, name: "db-alice", host: "db.example.com", username: "alice",
                alias: "db-alice", keys: [ed25519Record(lastSeenAt: t1)],
                createdAt: t0, updatedAt: t1
            ),
        ]
        var assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        assembly.graph.hostKeyPins[0].state = pinState
        assembly.graph.addresses[0].source = addressSource
        if blockingReview {
            let identity = assembly.graph.identities[0]
            assembly.graph.mergeReviews.append(HostV6.MergeReview(
                id: UUID(uuidString: "eeee0000-0000-4000-8000-000000000001")!,
                entityType: .sshIdentity,
                entityID: identity.id.uuidString.lowercased(),
                candidates: [],
                isBlocking: true,
                stamp: identity.stamp
            ))
        }
        return (assembly.graph, assembly.local, serverAID)
    }

    func testPendingReviewPinBlocksWholeHostEvenForTailscaleSourcedAddress() {
        // Host Key 冲突不能被地址来源（Tailscale）绕过：fail closed 在 Host 级生效。
        let (graph, local, identityID) = makeHandBuiltGraph(pinState: .pendingReview, addressSource: .tailscale)
        let result = HostV6SSHCompatProjection.project(graph: graph, local: local)
        let projected = result.servers.first { $0.id == identityID }
        XCTAssertEqual(projected?.status, .hostKeyMismatch)
    }

    func testIdentityWithoutConfirmedPinProjectsAsHostKeyPending() {
        let servers = [
            makeServer(
                id: serverDID, name: "nokey", host: "db.example.com", username: "carol",
                alias: "db-carol", keys: [], status: .authorized,
                createdAt: t0, updatedAt: t1
            ),
        ]
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)
        // 即使 local 状态存的是 authorized，没有 confirmed Pin 也必须 fail closed 到 hostKeyPending。
        XCTAssertEqual(result.servers.first { $0.id == serverDID }?.status, .hostKeyPending)
    }

    func testBlockingMergeReviewExcludesIdentityFromRoutes() {
        let (graph, local, identityID) = makeHandBuiltGraph(pinState: .confirmed, blockingReview: true)
        let result = HostV6SSHCompatProjection.project(graph: graph, local: local)
        XCTAssertTrue(result.servers.isEmpty)
        XCTAssertEqual(result.blockedIdentityIDs, [identityID])
    }

    func testResolvedMergeReviewDoesNotBlock() {
        let (graph, local, identityID) = makeHandBuiltGraph(pinState: .confirmed, blockingReview: true)
        var resolvedGraph = graph
        resolvedGraph.mergeReviews[0].resolvedAt = t2
        let result = HostV6SSHCompatProjection.project(graph: resolvedGraph, local: local)
        XCTAssertEqual(result.servers.map(\.id), [identityID])
        XCTAssertTrue(result.blockedIdentityIDs.isEmpty)
    }

    func testIdentityWithoutActiveAddressIsUnavailable() {
        let (graph, local, identityID) = makeHandBuiltGraph(pinState: .confirmed)
        var noAddress = graph
        noAddress.addresses[0].deletedAt = t2
        let result = HostV6SSHCompatProjection.project(graph: noAddress, local: local)
        XCTAssertTrue(result.servers.isEmpty)
        XCTAssertEqual(result.unavailableIdentityIDs, [identityID])
    }

    func testDanglingPreferredAddressReferenceFailsClosedWithoutDowngrade() {
        let (graph, local, identityID) = makeHandBuiltGraph(pinState: .confirmed)
        var dangling = graph
        // 身份级首选指向不存在的地址：不降级到 Host 级或其他活跃地址（架构 7.1）。
        dangling.identities[0].preferredAddressID = UUID(uuidString: "ffff0000-0000-4000-8000-000000000009")!
        let result = HostV6SSHCompatProjection.project(graph: dangling, local: local)
        XCTAssertTrue(result.servers.isEmpty)
        XCTAssertEqual(result.unavailableIdentityIDs, [identityID])
    }

    func testTombstonedIdentityExcludedButPinSurvivesWhileOtherContributorActive() {
        var servers = makeFixtureServers()
        // B 墓碑化：Host/Address/Pin 仍由 A 支撑而保持 active（架构 6.3.7）。
        servers[1] = makeServer(
            id: serverBID, name: "db-bob", host: "db.example.com", username: "bob",
            alias: "db-bob", keys: [ed25519Record(lastSeenAt: t1), rsaRecord(lastSeenAt: t1)],
            createdAt: t1, updatedAt: t2, isDeleted: true
        )
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)

        XCTAssertFalse(result.servers.contains { $0.id == serverBID })
        XCTAssertEqual(assembly.graph.hosts.filter { $0.deletedAt == nil }.count, 1)
        // 同端点 Pin 由 A 的活跃来源支撑而保持 active；C 所在端点的 Pin 随来源全部墓碑而墓碑。
        let dbAddressID = assembly.graph.addresses.first { $0.normalizedHost == "db.example.com" }!.id
        XCTAssertTrue(assembly.graph.hostKeyPins.filter { $0.addressID == dbAddressID }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(assembly.graph.hostKeyPins.filter { $0.addressID != dbAddressID }.allSatisfy { $0.deletedAt != nil })
        // B 的来源行带墓碑，但派生文件仍包含该行（A 的同文来源仍 active）。
        XCTAssertTrue(result.derivedKnownHostsLines.contains(ed25519Line))
        let bLines = assembly.graph.knownHostsLines.filter { $0.source.id == serverBID }
        XCTAssertTrue(bLines.allSatisfy { $0.deletedAt != nil })
    }

    // MARK: - 敏感信息扫描

    func testProjectionArtifactsContainNoSecretsOrLocalOnlyFields() throws {
        let markerPassword = "FIXTURE-SECRET-PASSWORD-7f3a9c"
        let markerPrivateKeyPath = "/Users/fixture/.ssh/keyport/identities/FIXTURE-PRIVATE-KEY-1b2c3d"
        var servers = makeFixtureServers()
        servers[0].notes = "常规备注，不含秘密"
        let assembly = LegacySSHCompatAssembly.assemble(servers: servers)
        let result = HostV6SSHCompatProjection.project(graph: assembly.graph, local: assembly.local)

        let encoder = JSONEncoder()
        let artifacts: [Data] = [
            try encoder.encode(result.servers),
            try encoder.encode(result.derivedKnownHostsLines),
            try encoder.encode(assembly.graph),
        ]
        for artifact in artifacts {
            let text = String(decoding: artifact, as: UTF8.self)
            XCTAssertFalse(text.contains(markerPassword), "密码不得进入投影产物")
            XCTAssertFalse(text.contains(markerPrivateKeyPath), "私钥路径不得进入投影产物")
        }
    }
}

/// 简单多重集合比较辅助。
private struct Multiset<Element: Hashable>: Equatable {
    var counts: [Element: Int]
    init(_ elements: [Element]) {
        counts = Dictionary(elements.map { ($0, 1) }, uniquingKeysWith: +)
    }
}
