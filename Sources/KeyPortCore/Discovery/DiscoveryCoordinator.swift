import Foundation

public enum DiscoveryCoordinatorError: Error, Equatable, Sendable {
    case capacityReached
    case operationAlreadyActive
    case cancelled
}

/// Coordinates user-triggered, one-shot discovery sessions. A Host has at
/// most one active session, while the process-wide default is two sessions.
/// The operation closure owns the platform work; cancellation is forwarded to
/// it without storing any candidate or command output.
public actor DiscoveryCoordinator {
    private struct ActiveSession {
        let hostID: UUID
        let task: Task<DiscoveryResult, Error>
    }

    private let maximumConcurrentSessions: Int
    private var activeSessions: [UUID: ActiveSession] = [:]
    private var operationByHost: [UUID: UUID] = [:]

    public init(maximumConcurrentSessions: Int = 2) {
        self.maximumConcurrentSessions = max(1, maximumConcurrentSessions)
    }

    public func discover(
        hostID: UUID,
        operationID: UUID,
        operation: @escaping @Sendable () async throws -> DiscoveryResult
    ) async throws -> DiscoveryResult {
        guard activeSessions[operationID] == nil else {
            throw DiscoveryCoordinatorError.operationAlreadyActive
        }

        if let previousID = operationByHost[hostID], let previous = activeSessions[previousID] {
            previous.task.cancel()
            _ = try? await previous.task.value
            activeSessions.removeValue(forKey: previousID)
            operationByHost.removeValue(forKey: hostID)
        }

        guard activeSessions.count < maximumConcurrentSessions else {
            throw DiscoveryCoordinatorError.capacityReached
        }

        let task = Task<DiscoveryResult, Error> {
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                throw DiscoveryCoordinatorError.cancelled
            }
        }
        activeSessions[operationID] = ActiveSession(hostID: hostID, task: task)
        operationByHost[hostID] = operationID

        do {
            let result = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            remove(operationID: operationID, hostID: hostID)
            return result
        } catch {
            remove(operationID: operationID, hostID: hostID)
            throw error
        }
    }

    public func cancel(operationID: UUID) async {
        guard let active = activeSessions[operationID] else { return }
        active.task.cancel()
        _ = try? await active.task.value
        remove(operationID: operationID, hostID: active.hostID)
    }

    public func isActive(operationID: UUID) -> Bool {
        activeSessions[operationID] != nil
    }

    public func activeSessionCount() -> Int {
        activeSessions.count
    }

    private func remove(operationID: UUID, hostID: UUID) {
        guard activeSessions[operationID] != nil else { return }
        activeSessions.removeValue(forKey: operationID)
        if operationByHost[hostID] == operationID {
            operationByHost.removeValue(forKey: hostID)
        }
    }
}
