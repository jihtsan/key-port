import XCTest
@testable import KeyPortCore

final class DiscoveryCoordinatorTests: XCTestCase {
    func testStartingSameHostCancelsPreviousSessionBeforeRunningReplacement() async throws {
        let coordinator = DiscoveryCoordinator()
        let started = DiscoveryStartCounter()
        let hostID = UUID(uuidString: "11110000-0000-4000-8000-000000000001")!
        let firstID = UUID(uuidString: "22220000-0000-4000-8000-000000000001")!
        let secondID = UUID(uuidString: "22220000-0000-4000-8000-000000000002")!

        let first = Task {
            try await coordinator.discover(hostID: hostID, operationID: firstID) {
                await started.mark()
                try await Task.sleep(for: .seconds(60))
                return DiscoveryResult(candidates: [])
            }
        }
        await started.waitForNext()

        let replacement = Task {
            try await coordinator.discover(hostID: hostID, operationID: secondID) {
                await started.mark()
                return DiscoveryResult(candidates: [])
            }
        }
        await started.waitForNext()

        _ = try await replacement.value
        do {
            _ = try await first.value
            XCTFail("同 Host 的旧发现必须被取消")
        } catch is CancellationError {
            XCTFail("协调器应将取消收敛为稳定的会话取消错误")
        } catch let error as DiscoveryCoordinatorError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("旧发现返回了非预期错误：\(error)")
        }
    }

    func testThirdConcurrentHostIsRejectedAtGlobalCapacity() async throws {
        let coordinator = DiscoveryCoordinator()
        let started = DiscoveryStartCounter()
        let first = Task {
            try await coordinator.discover(
                hostID: UUID(uuidString: "11110000-0000-4000-8000-000000000011")!,
                operationID: UUID(uuidString: "33330000-0000-4000-8000-000000000011")!
            ) {
                await started.mark()
                try await Task.sleep(for: .seconds(60))
                return DiscoveryResult(candidates: [])
            }
        }
        let second = Task {
            try await coordinator.discover(
                hostID: UUID(uuidString: "11110000-0000-4000-8000-000000000012")!,
                operationID: UUID(uuidString: "33330000-0000-4000-8000-000000000012")!
            ) {
                await started.mark()
                try await Task.sleep(for: .seconds(60))
                return DiscoveryResult(candidates: [])
            }
        }
        await started.waitForNext()
        await started.waitForNext()

        do {
            _ = try await coordinator.discover(
                hostID: UUID(uuidString: "11110000-0000-4000-8000-000000000013")!,
                operationID: UUID(uuidString: "33330000-0000-4000-8000-000000000013")!
            ) {
                XCTFail("达到全局上限后不得启动第三个发现")
                return DiscoveryResult(candidates: [])
            }
            XCTFail("达到全局上限后必须拒绝第三个发现")
        } catch let error as DiscoveryCoordinatorError {
            XCTAssertEqual(error, .capacityReached)
        }

        first.cancel()
        second.cancel()
        _ = try? await first.value
        _ = try? await second.value
    }

    func testCancellationCannotReturnAResultFromAnOperationThatIgnoresCancellation() async throws {
        let coordinator = DiscoveryCoordinator()
        let started = CancellationIgnoringOperationSignal()
        let operation = Task {
            try await coordinator.discover(
                hostID: UUID(uuidString: "11110000-0000-4000-8000-000000000021")!,
                operationID: UUID(uuidString: "33330000-0000-4000-8000-000000000021")!
            ) {
                await started.markStarted()
                return await withTaskCancellationHandler {
                    await started.waitForRelease()
                } onCancel: {
                    Task { await started.markCancellationRequested() }
                }
            }
        }
        await started.waitUntilStarted()

        let cancellation = Task {
            await coordinator.cancel(operationID: UUID(uuidString: "33330000-0000-4000-8000-000000000021")!)
        }
        await started.waitUntilCancellationRequested()
        await started.release()
        await cancellation.value

        do {
            _ = try await operation.value
            XCTFail("取消后即使 operation 忽略取消，也不得返回成功结果")
        } catch let error as DiscoveryCoordinatorError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}

private actor CancellationIgnoringOperationSignal {
    private var started = false
    private var released = false
    private var cancellationRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
    }

    func markCancellationRequested() {
        cancellationRequested = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilCancellationRequested() async {
        if cancellationRequested { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func waitForRelease() async -> DiscoveryResult {
        while !released {
            await Task.yield()
        }
        return DiscoveryResult(candidates: [])
    }
}

private actor DiscoveryStartCounter {
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var count = 0

    func mark() {
        if let waiter = pendingWaiters.first {
            pendingWaiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }

    func waitForNext() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(continuation)
        }
    }
}
