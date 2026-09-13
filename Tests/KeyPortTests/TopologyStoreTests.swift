import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

final class TopologyStoreTests: XCTestCase {
    func testTopologySnapshotRoundTripsWithOwnerOnlyPermissions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-topology-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let node = Node(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
            name: "生产服务器",
            roles: [.sshHost],
            createdAt: now,
            updatedAt: now
        )
        let snapshot = TopologySnapshot(
            nodes: [node],
            endpoints: [Endpoint(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
                nodeID: node.id,
                address: "server.example.com",
                port: 22,
                protocol: .ssh,
                networkScope: .publicNetwork
            )]
        )
        let store = TopologyStore(paths: KeyPortPaths(home: home))

        let initial = try await store.load()
        XCTAssertNil(initial)
        try await store.save(snapshot)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, snapshot)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: KeyPortPaths(home: home).topologySnapshot.path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTopologyStoreKeepsPreviousSnapshotAndRecoversFromCorruptPrimary() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-topology-store-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = KeyPortPaths(home: home)
        let store = TopologyStore(paths: paths)
        let first = TopologySnapshot(nodes: [
            Node(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000011")!,
                name: "第一版",
                roles: [.sshHost],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ])
        let second = TopologySnapshot(nodes: [
            Node(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000012")!,
                name: "第二版",
                roles: [.sshHost],
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
        ])

        try await store.save(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topologySnapshotBackup.path))
        try await store.save(second)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                TopologySnapshot.self,
                from: Data(contentsOf: paths.topologySnapshotBackup)
            ),
            first
        )

        try Data("{not-json".utf8).write(to: paths.topologySnapshot, options: .atomic)
        let recovered = try await store.load()
        XCTAssertEqual(recovered, first)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.topologySnapshotBackup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
