import XCTest
import KeyPortCore
@testable import KeyPort

@MainActor final class WorkspaceArchiveFlowTests: XCTestCase {
    private func makeStore(cloud: any CloudSyncing = SettingsCloudFixture()) throws -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try WorkspaceStore(home: root, cloud: cloud)
    }
    private func archive(for store: WorkspaceStore) throws -> (URL, TopologySnapshot) {
        let topology = TopologySnapshot(nodes: [.init(id: UUID(), name: "Imported fixture", roles: [.sshHost])])
        let url = store.paths.applicationSupport.appendingPathComponent("fixture.keyport")
        try MetadataArchiveCodec.seal(AppSnapshot(), topology: topology, password: "fixture-only", iterations: 1_000).write(to: url)
        return (url, topology)
    }
    func testReadDoesNotWriteAndCancelDiscardsDecryptedImport() async throws {
        let store = try makeStore(), (url, _) = try archive(for: store)
        let before = store.topology
        let flow = WorkspaceArchiveFlow(store: store, source: url)
        flow.password = "fixture-only"
        await flow.readImport()
        guard case .confirm = flow.step else { return XCTFail("Must require confirmation") }
        XCTAssertEqual(store.topology, before)
        XCTAssertTrue(flow.password.isEmpty)
        flow.cancel()
        XCTAssertFalse(flow.confirmImport())
        XCTAssertEqual(store.topology, before)
    }
    func testWrongPasswordCanRetryThenOnlyConfirmationMerges() async throws {
        let store = try makeStore(), (url, incoming) = try archive(for: store)
        let before = store.topology
        let flow = WorkspaceArchiveFlow(store: store, source: url)
        flow.password = "wrong"
        await flow.readImport()
        XCTAssertNotNil(flow.error)
        XCTAssertTrue(flow.password.isEmpty)
        XCTAssertEqual(store.topology, before)
        flow.password = "fixture-only"
        await flow.readImport()
        XCTAssertNil(flow.error)
        XCTAssertEqual(store.topology, before)
        XCTAssertTrue(flow.confirmImport())
        XCTAssertTrue(store.topology.nodes.contains { $0.id == incoming.nodes[0].id })
        XCTAssertFalse(flow.confirmImport(), "Cannot submit twice")
    }
    func testExportMismatchAndCancelledPickerNeverWriteAndClearPasswords() async throws {
        let flow = WorkspaceArchiveFlow(store: try makeStore())
        flow.password = "fixture-only"; flow.confirmation = "different"
        var opened = false
        let invalid = await flow.export { opened = true; return nil }
        XCTAssertFalse(invalid); XCTAssertFalse(opened)
        flow.confirmation = flow.password
        let cancelled = await flow.export { opened = true; return nil }
        XCTAssertFalse(cancelled); XCTAssertTrue(opened)
        XCTAssertTrue(flow.password.isEmpty); XCTAssertTrue(flow.confirmation.isEmpty)
        XCTAssertFalse(flow.working)
    }
    func testExportCreatesReadableEncryptedBackupAndCannotRepeat() async throws {
        let store = try makeStore()
        let url = store.paths.applicationSupport.appendingPathComponent("export.keyport")
        let flow = WorkspaceArchiveFlow(store: store)
        flow.password = "fixture-only"; flow.confirmation = flow.password
        let result = await flow.export { url }
        XCTAssertTrue(result)
        let decoded = try MetadataArchiveCodec.openPayload(Data(contentsOf: url), password: "fixture-only")
        XCTAssertNotNil(decoded.topology)
        XCTAssertTrue(flow.password.isEmpty); XCTAssertTrue(flow.confirmation.isEmpty)
        XCTAssertFalse(flow.canContinue)
    }
    func testAvailabilityCheckDoesNotSyncOrChangePreferenceAndCanRecover() async throws {
        let cloud = SettingsCloudFixture()
        let store = try makeStore(cloud: cloud)
        let enabled = store.syncEnabled
        await store.checkSyncAvailability()
        XCTAssertEqual(store.syncUnavailable, .adHocSignature)
        XCTAssertEqual(store.syncEnabled, enabled)
        await cloud.recover()
        await store.checkSyncAvailability()
        XCTAssertNil(store.syncUnavailable)
        XCTAssertFalse(store.checkingSyncAvailability)
        let calls = await cloud.syncCalls
        XCTAssertEqual(calls, 0)
    }
}

private actor SettingsCloudFixture: CloudSyncing {
    private var available = false
    private(set) var syncCalls = 0
    func recover() { available = true }
    func availability() async -> CloudSyncAvailability { available ? .available : .unavailable(.adHocSignature) }
    func synchronize(_ local: TopologySnapshot) async throws -> TopologySnapshot { syncCalls += 1; return local }
}
