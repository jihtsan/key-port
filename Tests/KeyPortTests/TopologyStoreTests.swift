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
}
