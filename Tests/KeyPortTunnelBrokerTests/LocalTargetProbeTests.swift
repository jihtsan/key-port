import Foundation
import Network
@testable import KeyPortTunnelBroker
import XCTest

final class LocalTargetProbeTests: XCTestCase {
    func testBrokerCannotPublishSuccessBeforeProbeCancellationIsAcknowledged() async throws {
        let listener = try TestTCPListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let callbackQueue = DispatchQueue(label: "KeyPortTunnelBrokerTests.probe-callback")
        let probe = LocalTargetProbe(
            port: port,
            callbackQueue: callbackQueue,
            cancellationTimeout: 0.02
        )
        let outcome = probe.run()
        XCTAssertEqual(outcome.result, .reachable)

        callbackQueue.suspend()
        var statuses: [String] = []
        XCTAssertThrowsError(
            try publishForwardEstablished(
                after: outcome,
                cancellationTimeout: 0.02,
                writeStatus: { statuses.append($0) }
            )
        )
        XCTAssertTrue(statuses.isEmpty)

        callbackQueue.resume()
        try publishForwardEstablished(
            after: outcome,
            cancellationTimeout: 1.0,
            writeStatus: { statuses.append($0) }
        )
        XCTAssertEqual(statuses, ["FORWARD_ESTABLISHED"])
    }
}

private final class TestTCPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "KeyPortTunnelBrokerTests.listener")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.store(connection)
            connection.start(queue: self?.queue ?? DispatchQueue.global())
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port > 0 else {
                        continuation.resume(throwing: TestTCPListenerError.missingPort)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let connections = self.connections
        self.connections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    private func store(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }
}

private enum TestTCPListenerError: Error {
    case missingPort
}
