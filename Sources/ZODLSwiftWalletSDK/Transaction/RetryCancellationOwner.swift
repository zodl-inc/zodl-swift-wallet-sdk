import Foundation
import os

/// Cancellation can arrive before an unstructured retry task has been installed. Retain that
/// request for its generation, and never let an old completion clear a later task's ownership.
final class RetryCancellationOwner: Sendable {
    private struct State {
        var id: UUID?
        var task: Task<Void, Never>?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin() -> UUID {
        state.withLock {
            let id = UUID()
            $0 = State(id: id)
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

    func cancel() {
        let task = state.withLock {
            $0.cancelled = true
            return $0.task
        }
        task?.cancel()
    }

    func finish(id: UUID) {
        state.withLock {
            if $0.id == id { $0 = State() }
        }
    }
}
