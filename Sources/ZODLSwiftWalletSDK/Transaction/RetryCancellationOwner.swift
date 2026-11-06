import Foundation
import os

/// Cancellation can arrive before an unstructured retry task has been installed. Retain that
/// request for its generation, and never let an old completion clear a later task's ownership.
final class RetryCancellationOwner: Sendable {
    private struct State {
        var id: UUID?
        var task: Task<Void, Never>?
        var cancelled = false
        var pendingRequests = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onCancellation: @Sendable () -> Void

    init(onCancellation: @escaping @Sendable () -> Void = {}) {
        self.onCancellation = onCancellation
    }

    func begin() -> UUID {
        state.withLock {
            let id = UUID()
            $0.id = id
            $0.task = nil
            $0.cancelled = $0.pendingRequests > 0
            return id
        }
    }

    func install(_ task: Task<Void, Never>, id: UUID) {
        let cancelled = state.withLock {
            guard $0.id == id else { return true }
            $0.task = task
            return $0.cancelled
        }
        if cancelled { task.cancel() }
    }

    /// Keep admission fenced until the request has joined the lifecycle queue (or registered
    /// its Tor fence). Cancellation handlers and queue registration run outside the owner lock.
    @discardableResult
    func cancel<T>(perform registration: () throws -> T) rethrows -> T {
        let task = state.withLock {
            $0.pendingRequests += 1
            $0.cancelled = true
            return $0.task
        }
        defer { state.withLock { $0.pendingRequests -= 1 } }
        task?.cancel()
        onCancellation()
        return try registration()
    }

    func finish(id: UUID) {
        state.withLock {
            if $0.id == id {
                $0.id = nil
                $0.task = nil
                $0.cancelled = false
            }
        }
    }
}
