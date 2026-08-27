import AppKit
import Foundation
import KeyPortCore
import ObjectiveC.runtime
@testable import KeyPort
import XCTest

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    func testObjectiveCDefaultInitializerCreatesAnAppDelegate() {
        let allocated = class_createInstance(AppDelegate.self, 0)
        let initialized = (allocated as AnyObject).perform(#selector(NSObject.init))

        XCTAssertNotNil(initialized)
    }

    func testApplicationTerminationReturnsLaterAndClosesRegistryBeforeReply() async throws {
        let broker = TestLifecycleBroker()
        let registry = TunnelRegistry(
            serviceAccessEnabled: true,
            portReserver: TestLifecyclePortAllocator(),
            brokerLauncher: broker,
            leaseStore: TestLifecycleLeaseStore()
        )
        let handle = try await registry.open(makeRequest())
        let delegate = AppDelegate(tunnelRegistry: registry)

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        for _ in 0..<100 {
            if await registry.state(for: handle.id) == .closed(.applicationTermination) {
                break
            }
            await Task.yield()
        }
        let state = await registry.state(for: handle.id)
        let closeCount = await broker.closeCount
        XCTAssertEqual(state, .closed(.applicationTermination))
        XCTAssertEqual(closeCount, 1)
    }

    private func makeRequest() -> TunnelRequest {
        TunnelRequest(
            operationID: UUID(),
            serviceID: UUID(),
            hostID: UUID(),
            sshIdentityID: UUID(),
            sshAddressID: UUID(),
            serviceProtocol: .tcp,
            sshHost: "ssh.example.test",
            sshPort: 22,
            username: "admin",
            identityPath: "/Users/test/.ssh/id",
            knownHostsPath: "/Users/test/.ssh/known_hosts",
            remote: RemoteServiceEndpoint(bind: .loopbackV4, port: 8080),
            networkEpoch: 0
        )
    }
}

private actor TestLifecyclePortAllocator: LoopbackPortReserving {
    func reserve() async throws -> any LoopbackPortReservation {
        TestLifecycleReservation()
    }
}

private final class TestLifecycleReservation: LoopbackPortReservation, @unchecked Sendable {
    let host = "127.0.0.1"
    let port: UInt16 = 41030

    func release() async {}
}

private actor TestLifecycleBroker: TunnelBrokerLaunching {
    private(set) var closeCount = 0

    func launch(_ configuration: TunnelBrokerConfiguration) async throws -> any TunnelBrokerSession {
        TestLifecycleSession(onClose: { [weak self] in await self?.recordClose() })
    }

    private func recordClose() {
        closeCount += 1
    }
}

private actor TestLifecycleSession: TunnelBrokerSession {
    private let onClose: @Sendable () async -> Void

    init(onClose: @escaping @Sendable () async -> Void) {
        self.onClose = onClose
    }

    func verifyTarget() async throws {}
    func close() async -> CleanupStatus {
        await onClose()
        return .completed
    }
}

private actor TestLifecycleLeaseStore: TunnelLeaseStore {
    func save(_ lease: TunnelLease) async throws {}
    func remove(_ lease: TunnelLease) async throws {}
    func reap() async -> CleanupStatus { .notNeeded }
    func reap(matching scope: TunnelCleanupScope) async -> CleanupStatus { .notNeeded }
}
