import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class UnifiedTopologyAppModelTests: XCTestCase {
    func testDefaultRuntimeMigratesLegacyServerIntoGraph() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyport-unified-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let currentDeviceID = "device-unified-runtime"
        let defaultsSuite = "KeyPort.UnifiedTopologyAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(currentDeviceID, forKey: "KeyPort.deviceID")

        var legacy = AppSnapshot()
        legacy.devices = [Device(id: currentDeviceID, name: "测试 Mac", isCurrent: true)]
        legacy.servers = [ServerConnection(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            name: "测试服务器",
            host: "server.example.com",
            username: "root",
            alias: "test-server"
        )]
        let paths = KeyPortPaths(home: home)
        try await SnapshotStore(paths: paths).save(legacy)

        let model = AppModel(paths: paths, defaults: defaults)
        await model.load()

        XCTAssertTrue(model.graphWorkspace.isAvailable)
        XCTAssertTrue(model.graphWorkspace.usesUnifiedTopology)
        XCTAssertTrue(model.graphWorkspace.snapshot.nodes.contains(where: {
            $0.kind == .node && $0.title == "测试服务器"
        }))
        XCTAssertTrue(model.graphWorkspace.snapshot.edges.contains(where: {
            $0.kind == .candidateAccess
        }))
        let stored = try await TopologyStore(paths: paths).load()
        XCTAssertNotNil(stored)
    }
}
