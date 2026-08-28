import Foundation
import KeyPortCore
@testable import KeyPort
import XCTest

@MainActor
final class ListenerDiscoveryAppModelTests: XCTestCase {
    private let serverID = UUID(uuidString: "12340000-0000-4000-8000-000000000101")!
    private let hostKey = HostKeyRecord(
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:fixture-app-model-host",
        knownHostsLine: "app-model.example ssh-ed25519 AAAAFixtureAppModelHost",
        firstConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    func testDiscoveryFeatureFlagDefaultsToDisabled() {
        let defaults = makeDefaults()

        XCTAssertFalse(DiscoveryFeatureFlags.isEnabled(defaults: defaults))
    }

    func testDisabledDiscoveryDoesNotStartSSHOrChangeSnapshot() async throws {
        let defaults = makeDefaults()
        let executor = AppModelDiscoveryFakeExecutor()
        let adapter = RecordingListenerDiscoveryAdapter(result: sampleResult())
        let model = AppModel(
            defaults: defaults,
            discoveryExecutor: executor,
            discoveryAdapter: adapter
        )
        let server = makeServer()
        let key = makeKey()
        model.snapshot.servers = [server]
        model.snapshot.devices = [makeDevice()]
        model.snapshot.keys = [key]
        let serversBefore = model.snapshot.servers
        let auditBefore = model.snapshot.auditEvents

        do {
            _ = try await model.discoverListeners(for: server.id)
            XCTFail("关闭 discoveryEnabled 时不得执行发现")
        } catch let error as ListenerDiscoveryTriggerError {
            XCTAssertEqual(error, .featureDisabled)
        }

        XCTAssertEqual(executor.requests.count, 0)
        XCTAssertEqual(adapter.discoverCount, 0)
        XCTAssertEqual(model.snapshot.servers, serversBefore)
        XCTAssertEqual(model.snapshot.auditEvents, auditBefore)
        XCTAssertTrue(model.listenerDiscoveryResults.isEmpty)
        _ = key
    }

    func testExplicitDiscoveryStoresOnlyInMemoryCandidatesWithoutChangingServices() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DiscoveryFeatureFlags.discoveryEnabledKey)
        let executor = AppModelDiscoveryFakeExecutor(responses: [successfulExecution()])
        let expected = sampleResult()
        let adapter = RecordingListenerDiscoveryAdapter(result: expected)
        let model = AppModel(
            defaults: defaults,
            discoveryExecutor: executor,
            discoveryAdapter: adapter
        )
        let server = makeServer()
        model.snapshot.servers = [server]
        model.snapshot.devices = [makeDevice()]
        model.snapshot.keys = [makeKey()]
        let serversBefore = model.snapshot.servers
        let devicesBefore = model.snapshot.devices
        let keysBefore = model.snapshot.keys
        let auditBefore = model.snapshot.auditEvents

        let result = try await model.discoverListeners(for: server.id)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(model.listenerDiscoveryResults[server.id], expected)
        XCTAssertEqual(executor.requests.count, 1, "发现前只应执行一次可信公钥认证探针")
        XCTAssertEqual(adapter.discoverCount, 1)
        XCTAssertEqual(model.snapshot.servers, serversBefore)
        XCTAssertEqual(model.snapshot.devices, devicesBefore)
        XCTAssertEqual(model.snapshot.keys, keysBefore)
        XCTAssertEqual(model.snapshot.auditEvents, auditBefore)
    }

    func testCancelledDiscoveryDoesNotStoreCandidates() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DiscoveryFeatureFlags.discoveryEnabledKey)
        let executor = AppModelDiscoveryFakeExecutor(responses: [successfulExecution()])
        let adapter = RecordingListenerDiscoveryAdapter(
            result: sampleResult(),
            waitsForCancellation: true
        )
        let model = AppModel(
            defaults: defaults,
            discoveryExecutor: executor,
            discoveryAdapter: adapter
        )
        let server = makeServer()
        model.snapshot.servers = [server]
        model.snapshot.devices = [makeDevice()]
        model.snapshot.keys = [makeKey()]
        let task = Task { try await model.discoverListeners(for: server.id) }
        await adapter.waitUntilStarted()

        await model.cancelListenerDiscovery(for: server.id)

        do {
            _ = try await task.value
            XCTFail("取消后的发现不得返回成功候选")
        } catch let error as DiscoveryCoordinatorError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(model.listenerDiscoveryResults.isEmpty)
        XCTAssertEqual(model.snapshot.servers, [server])
    }

    func testDisablingDiscoveryDiscardsExistingInMemoryCandidates() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DiscoveryFeatureFlags.discoveryEnabledKey)
        let executor = AppModelDiscoveryFakeExecutor(responses: [successfulExecution()])
        let model = AppModel(
            defaults: defaults,
            discoveryExecutor: executor,
            discoveryAdapter: RecordingListenerDiscoveryAdapter(result: sampleResult())
        )
        let server = makeServer()
        model.snapshot.servers = [server]
        model.snapshot.devices = [makeDevice()]
        model.snapshot.keys = [makeKey()]

        _ = try await model.discoverListeners(for: server.id)
        XCTAssertFalse(model.listenerDiscoveryResults.isEmpty)

        model.setDiscoveryEnabled(false)

        XCTAssertFalse(model.discoveryEnabled)
        XCTAssertTrue(model.listenerDiscoveryResults.isEmpty)
        XCTAssertFalse(DiscoveryFeatureFlags.isEnabled(defaults: defaults))
    }

    func testDisablingAndReenablingDiscoveryCannotStoreLateResult() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DiscoveryFeatureFlags.discoveryEnabledKey)
        let executor = AppModelDiscoveryFakeExecutor(responses: [successfulExecution()])
        let gate = DiscoveryReleaseGate()
        let adapter = LateResultListenerDiscoveryAdapter(
            result: sampleResult(),
            gate: gate
        )
        let model = AppModel(
            defaults: defaults,
            discoveryExecutor: executor,
            discoveryAdapter: adapter
        )
        let server = makeServer()
        model.snapshot.servers = [server]
        model.snapshot.devices = [makeDevice()]
        model.snapshot.keys = [makeKey()]

        let task = Task { try await model.discoverListeners(for: server.id) }
        await adapter.waitUntilStarted()

        model.setDiscoveryEnabled(false)
        model.setDiscoveryEnabled(true)
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("重新启用后，关闭前启动的发现不得返回或写回旧候选")
        } catch let error as DiscoveryCoordinatorError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(model.listenerDiscoveryResults.isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyPort.ListenerDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeServer() -> ServerConnection {
        ServerConnection(
            id: serverID,
            name: "discovery-host",
            host: "app-model.example",
            port: 22,
            username: "alice",
            alias: "discovery-alice",
            confirmedHostKeys: [hostKey],
            status: .authorized
        )
    }

    private func makeDevice() -> Device {
        Device(id: "device-app-model", name: "Test Mac", isCurrent: true)
    }

    private func makeKey() -> SSHKeyRecord {
        SSHKeyRecord(
            id: "key-app-model",
            deviceID: "device-app-model",
            kind: .ed25519,
            publicKey: "ssh-ed25519 AAAAFixtureAppModelPublic app-model",
            fingerprint: "SHA256:fixture-app-model-public",
            privateKeyPath: "/Users/fixture/.ssh/keyport/identities/app-model",
            isInAgent: false,
            origin: .generated,
            isLocallyAvailable: true
        )
    }

    private func sampleResult() -> DiscoveryResult {
        DiscoveryResult(candidates: [
            DiscoveryCandidate(bind: .loopbackV4, port: 8080, processHint: "fixture-service")
        ])
    }

    private func successfulExecution() -> ProcessExecutionResult {
        ProcessExecutionResult(ending: .exited(0), stdout: Data(), stderr: Data(), duration: 0.01)
    }
}

private final class AppModelDiscoveryFakeExecutor: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ProcessExecutionResult]
    private(set) var requests: [ProcessExecutionRequest] = []

    init(responses: [ProcessExecutionResult] = []) {
        self.responses = responses
    }

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        lock.lock()
        requests.append(request)
        let response = responses.isEmpty
            ? ProcessExecutionResult(ending: .exited(0), stdout: Data(), stderr: Data(), duration: 0.01)
            : responses.removeFirst()
        lock.unlock()
        return response
    }
}

private final class RecordingListenerDiscoveryAdapter: ListenerDiscoveryAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private let result: DiscoveryResult
    private let waitsForCancellation: Bool
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var discoverCount = 0

    init(result: DiscoveryResult, waitsForCancellation: Bool = false) {
        self.result = result
        self.waitsForCancellation = waitsForCancellation
    }

    var platform: DiscoveryPlatform { .linux }

    func capabilities(using session: TrustedSSHSession) async throws -> DiscoveryCapabilities {
        DiscoveryCapabilities(platform: .linux, tools: [.ss])
    }

    func discover(using session: TrustedSSHSession, limits: DiscoveryLimits) async throws -> DiscoveryResult {
        lock.lock()
        discoverCount += 1
        let continuation = startedContinuation
        startedContinuation = nil
        lock.unlock()
        continuation?.resume()
        if waitsForCancellation {
            try await Task.sleep(for: .seconds(60))
        }
        return result
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if discoverCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                lock.unlock()
            }
        }
    }
}

private actor DiscoveryReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class LateResultListenerDiscoveryAdapter: ListenerDiscoveryAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private let result: DiscoveryResult
    private let gate: DiscoveryReleaseGate
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: DiscoveryResult, gate: DiscoveryReleaseGate) {
        self.result = result
        self.gate = gate
    }

    var platform: DiscoveryPlatform { .linux }

    func capabilities(using session: TrustedSSHSession) async throws -> DiscoveryCapabilities {
        DiscoveryCapabilities(platform: .linux, tools: [.ss])
    }

    func discover(using session: TrustedSSHSession, limits: DiscoveryLimits) async throws -> DiscoveryResult {
        lock.lock()
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }

        await gate.wait()
        return result
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startedWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
