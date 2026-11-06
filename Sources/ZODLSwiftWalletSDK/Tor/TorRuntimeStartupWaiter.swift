import Foundation
import os

/// Each caller has its own completion budget while the native attempt retains its original deadline.
/// Cancelling or expiring one caller releases its interest without disturbing other callers.
final class TorRuntimeStartupWaiter: @unchecked Sendable {
    private struct State {
        var result: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
        var timer: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let abandon: @Sendable () -> Void

    init(abandon: @escaping @Sendable () -> Void) {
        self.abandon = abandon
    }

    func wait(for task: Task<Void, Error>, deadline: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = state.withLockUnchecked { state -> Result<Void, Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let completed {
                    continuation.resume(with: completed)
                    return
                }
                // Observation retains the native attempt through quiescence even if this waiter leaves.
                Task { finish(await task.result) }
                let timer = Task {
                    do {
                        let now = DispatchTime.now().uptimeNanoseconds
                        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                        finish(.failure(URLError(.timedOut)))
                    } catch {
                        // Completion or cancellation removed this caller's timer.
                    }
                }
                state.withLockUnchecked { state in
                    if state.result == nil { state.timer = timer } else { timer.cancel() }
                }
            }
        } onCancel: {
            // Also release interest if native completion raced cancellation before the actor resumed.
            abandon()
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let completion = state.withLockUnchecked { state -> (CheckedContinuation<Void, Error>?, Task<Void, Never>?)? in
            guard state.result == nil else { return nil }
            state.result = result
            let completion = (state.continuation, state.timer)
            state.continuation = nil
            state.timer = nil
            return completion
        }
        guard let completion else { return }
        if case .failure = result { abandon() }
        completion.1?.cancel()
        completion.0?.resume(with: result)
    }
}
