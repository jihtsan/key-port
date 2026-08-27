import Foundation
import Network

struct NetworkLoopbackPortReserver: LoopbackPortReserving, Sendable {
    private let callbackQueue: DispatchQueue

    init(callbackQueue: DispatchQueue = DispatchQueue(label: "com.jihtsan.KeyPort.tunnel-port")) {
        self.callbackQueue = callbackQueue
    }

    func reserve() async throws -> any LoopbackPortReservation {
        let state = ListenerReservationState()
        let cancellation = ListenerCancellationSignal()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .loopback
                parameters.allowLocalEndpointReuse = false

                do {
                    let listener = try NWListener(using: parameters, on: .any)
                    let reservation = NetworkLoopbackPortReservation(
                        listener: listener,
                        cancellation: cancellation
                    )
                    listener.newConnectionHandler = { connection in
                        connection.cancel()
                    }
                    listener.stateUpdateHandler = { listenerState in
                        switch listenerState {
                        case .ready:
                            guard !state.cancellationRequested() else {
                                listener.cancel()
                                return
                            }
                            guard listener.port?.rawValue ?? 0 > 0 else {
                                guard state.markFinished() else { return }
                                continuation.resume(throwing: NetworkLoopbackPortError.missingPort)
                                return
                            }
                            guard state.markFinished() else { return }
                            continuation.resume(returning: reservation)
                        case .failed(let error):
                            guard state.markFinished() else { return }
                            continuation.resume(throwing: NetworkLoopbackPortError.listenerFailed(error.localizedDescription))
                        case .cancelled:
                            cancellation.markCancelled()
                            guard state.markFinished() else { return }
                            continuation.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    state.install(listener: listener)
                    listener.start(queue: callbackQueue)
                } catch {
                    guard state.markFinished() else { return }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

enum NetworkLoopbackPortError: Error, Equatable, Sendable {
    case missingPort
    case listenerFailed(String)
}

final class NetworkLoopbackPortReservation: LoopbackPortReservation, @unchecked Sendable {
    let host = "127.0.0.1"
    let listener: NWListener
    private let cancellation: ListenerCancellationSignal

    fileprivate init(listener: NWListener, cancellation: ListenerCancellationSignal) {
        self.listener = listener
        self.cancellation = cancellation
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func release() async {
        listener.cancel()
        await cancellation.waitForCancellation()
    }
}

private final class ListenerCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markCancelled() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitForCancellation() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isCancelled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class ListenerReservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var listener: NWListener?
    private var isCancellationRequested = false

    func install(listener: NWListener) {
        lock.lock()
        let shouldCancel = isCancellationRequested || isFinished
        if !shouldCancel {
            self.listener = listener
        }
        lock.unlock()
        if shouldCancel { listener.cancel() }
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isCancellationRequested = true
        let listener = self.listener
        lock.unlock()
        listener?.cancel()
    }

    func cancellationRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancellationRequested
    }

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}
