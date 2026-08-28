import Foundation
import KeyPortCore
import Network
@testable import KeyPort
import XCTest

final class TunnelInfrastructureTests: XCTestCase {
    func testNetworkReservationUsesIPv4LoopbackAndReleasesItsPort() async throws {
        let reservation = try await NetworkLoopbackPortReserver().reserve()
        XCTAssertEqual(reservation.host, "127.0.0.1")
        XCTAssertGreaterThan(reservation.port, 0)

        await reservation.release()
    }

    func testNetworkReservationWaitsForCancelledListenerCallbackBeforeReturning() async throws {
        let callbackQueue = DispatchQueue(label: "KeyPortTests.listener-callback")
        let reservation = try await NetworkLoopbackPortReserver(callbackQueue: callbackQueue).reserve()
        let completion = AsyncCompletionFlag()
        var queueSuspended = true
        callbackQueue.suspend()
        defer {
            if queueSuspended { callbackQueue.resume() }
        }
        let releaseTask = Task {
            await reservation.release()
            await completion.markCompleted()
        }
        defer {
            releaseTask.cancel()
            if queueSuspended { callbackQueue.resume() }
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        let completedBeforeResume = await completion.isCompleted
        XCTAssertFalse(completedBeforeResume)

        callbackQueue.resume()
        queueSuspended = false
        for _ in 0..<100 {
            if await completion.isCompleted { break }
            await Task.yield()
        }
        let completedAfterResume = await completion.isCompleted
        XCTAssertTrue(completedAfterResume)
    }

    func testLeaseReaperExitsOnlyManagedControlPathAndRemovesLease() async throws {
        let directory = temporaryDirectory()
        let controlMaster = TestControlMasterExit()
        let store = FileTunnelLeaseStore(directory: directory, controlMasterExit: controlMaster)
        let tunnelID = UUID()
        let lease = TunnelLease(
            tunnelID: tunnelID,
            controlPath: directory.appendingPathComponent(TunnelRuntimeNaming.controlName(for: tunnelID)).path,
            brokerPID: 1234,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.save(lease)

        let result = await store.reap()
        let exitedPaths = await controlMaster.exitedPaths

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(exitedPaths, [lease.controlPath])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(TunnelRuntimeNaming.leaseName(for: tunnelID)).path
        ))
    }

    func testLeaseStoreRejectsControlPathsOutsideItsRuntimeDirectory() async throws {
        let directory = temporaryDirectory()
        let store = FileTunnelLeaseStore(directory: directory, controlMasterExit: TestControlMasterExit())
        let lease = TunnelLease(
            tunnelID: UUID(),
            controlPath: directory.deletingLastPathComponent().appendingPathComponent("outside.sock").path,
            brokerPID: nil,
            createdAt: Date()
        )

        do {
            try await store.save(lease)
            XCTFail("An unmanaged control path was accepted")
        } catch {
            XCTAssertTrue(error is TunnelLeaseStoreError)
        }
    }

    func testLeaseStoreRejectsAControlPathWhoseIDDoesNotMatchTheLease() async throws {
        let directory = temporaryDirectory()
        let store = FileTunnelLeaseStore(directory: directory, controlMasterExit: TestControlMasterExit())
        let tunnelID = UUID()
        let lease = TunnelLease(
            tunnelID: tunnelID,
            controlPath: directory.appendingPathComponent("control-other.sock").path,
            brokerPID: nil,
            createdAt: Date()
        )

        do {
            try await store.save(lease)
            XCTFail("A control path for another tunnel was accepted")
        } catch {
            XCTAssertTrue(error is TunnelLeaseStoreError)
        }
    }

    func testLeaseReaperRemovesLeaseWhenSocketAndBrokerAreBothGone() async throws {
        let directory = temporaryDirectory()
        let controlMaster = TestControlMasterExit(exitResult: false)
        let store = FileTunnelLeaseStore(
            directory: directory,
            controlMasterExit: controlMaster,
            processLiveness: TestProcessLiveness(alive: false)
        )
        let tunnelID = UUID()
        let lease = TunnelLease(
            tunnelID: tunnelID,
            controlPath: directory.appendingPathComponent(TunnelRuntimeNaming.controlName(for: tunnelID)).path,
            brokerPID: 4242,
            createdAt: Date()
        )
        try await store.save(lease)

        let result = await store.reap()

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(TunnelRuntimeNaming.leaseName(for: tunnelID)).path
        ))
    }

    func testLeaseReaperRemovesManagedSocketAfterControlMasterExit() async throws {
        let directory = temporaryDirectory()
        let controlMaster = TestControlMasterExit()
        let store = FileTunnelLeaseStore(directory: directory, controlMasterExit: controlMaster)
        let tunnelID = UUID()
        let controlPath = directory.appendingPathComponent(TunnelRuntimeNaming.controlName(for: tunnelID))
        let leasePath = directory.appendingPathComponent(TunnelRuntimeNaming.leaseName(for: tunnelID))
        let lease = TunnelLease(
            tunnelID: tunnelID,
            controlPath: controlPath.path,
            brokerPID: nil,
            createdAt: Date()
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("managed stale socket".utf8).write(to: controlPath)
        try await store.save(lease)

        let result = await store.reap()

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controlPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasePath.path))
    }

    func testLeaseReaperClosesOnlyOrphanedLeasesMatchingTheDeletionScope() async throws {
        let directory = temporaryDirectory()
        let controlMaster = TestControlMasterExit()
        let store = FileTunnelLeaseStore(directory: directory, controlMasterExit: controlMaster)
        let hostID = UUID()
        let selectedServiceID = UUID()
        let unrelatedServiceID = UUID()
        let selected = makeLease(
            directory: directory,
            ownership: TunnelLeaseOwnership(
                hostID: hostID,
                sshIdentityID: UUID(),
                sshAddressID: UUID(),
                serviceID: selectedServiceID
            )
        )
        let unrelated = makeLease(
            directory: directory,
            ownership: TunnelLeaseOwnership(
                hostID: hostID,
                sshIdentityID: UUID(),
                sshAddressID: UUID(),
                serviceID: unrelatedServiceID
            )
        )
        try await store.save(selected)
        try await store.save(unrelated)

        let result = await store.reap(matching: .service(selectedServiceID))
        let exitedPaths = await controlMaster.exitedPaths

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(exitedPaths, [selected.controlPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasePath(for: selected, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leasePath(for: unrelated, in: directory).path))
    }

    private func temporaryDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KeyPortTunnelTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeLease(
        directory: URL,
        ownership: TunnelLeaseOwnership
    ) -> TunnelLease {
        let tunnelID = UUID()
        return TunnelLease(
            tunnelID: tunnelID,
            controlPath: directory.appendingPathComponent(TunnelRuntimeNaming.controlName(for: tunnelID)).path,
            brokerPID: nil,
            createdAt: Date(),
            ownership: ownership
        )
    }

    private func leasePath(for lease: TunnelLease, in directory: URL) -> URL {
        directory.appendingPathComponent(TunnelRuntimeNaming.leaseName(for: lease.tunnelID))
    }
}

private actor AsyncCompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor TestControlMasterExit: TunnelControlMasterExiting {
    private(set) var exitedPaths: [String] = []
    private let exitResult: Bool

    init(exitResult: Bool = true) {
        self.exitResult = exitResult
    }

    func exit(controlPath: String) async -> Bool {
        exitedPaths.append(controlPath)
        return exitResult
    }
}

private struct TestProcessLiveness: TunnelProcessLiveness, Sendable {
    let alive: Bool

    func isAlive(pid: Int32) -> Bool {
        alive
    }
}
