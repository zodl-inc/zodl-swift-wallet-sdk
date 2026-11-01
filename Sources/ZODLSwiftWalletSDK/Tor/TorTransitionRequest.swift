import Foundation
import os

/// A routing ticket. Creation fences networking; `apply()` activates it once under the host's
/// transaction guard. Cancelling a waiter never cancels an already activated shared request.
public final class TorTransitionRequest: Sendable {
    public let id: UUID
    let generation: UInt64
    let enabled: Bool
    let startsSync: Bool
    let resetRecoveryBudget: Bool
    let acquisitionDeadline: UInt64
    private struct Work {
        var activate: (@Sendable () -> Task<Void, Error>)?
        var task: Task<Void, Error>?
        var timer: Task<Void, Never>?
        var cancellation: (@Sendable () -> Void)?
        var dormantCancelled: (@Sendable () -> Void)?
        var activated = false
        var cancelled = false
    }
    private let work = OSAllocatedUnfairLock(initialState: Work())
    private let completion = TorTransitionCompletion()

    init(generation: UInt64, enabled: Bool, acquisitionDeadline: UInt64, startsSync: Bool, resetRecoveryBudget: Bool) {
        self.id = UUID()
        self.generation = generation
        self.enabled = enabled
        self.startsSync = startsSync
        self.resetRecoveryBudget = resetRecoveryBudget
        self.acquisitionDeadline = acquisitionDeadline
    }

    func configure(
        activate: @escaping @Sendable () -> Task<Void, Error>,
        cancellation: @escaping @Sendable () -> Void,
        dormantCancelled: @escaping @Sendable () -> Void
    ) {
        work.withLock {
            $0.activate = activate
            $0.cancellation = cancellation
            $0.dormantCancelled = dormantCancelled
        }
    }

    func installTimer(_ timer: Task<Void, Never>) {
        work.withLock {
            if $0.cancelled { timer.cancel() } else { $0.timer = timer }
        }
    }

    func acquired() {
        let timer = work.withLock { state in
            let timer = state.timer
            state.timer = nil
            return timer
        }
        timer?.cancel()
    }

    /// Activates the ticket exactly once. A repeated call joins the same result.
    public func apply() async throws {
        let activate = work.withLock { state -> (@Sendable () -> Task<Void, Error>)? in
            guard !state.activated, !state.cancelled else { return nil }
            state.activated = true
            let activate = state.activate
            state.activate = nil
            return activate
        }
        if let activate {
            let task = activate()
            let cancelled = work.withLock {
                $0.task = task
                return $0.cancelled
            }
            if cancelled { task.cancel() }
            Task { [self] in completion.resolve(await task.result) }
        }
        try await wait()
    }

    /// Lifecycle callers must retain their queue slot through the actual owner's cleanup,
    /// even when their observer was completed immediately by invalidation.
    func waitUntilOwnerFinishes() async {
        let task = work.withLock { $0.task }
        _ = await task?.result
    }

    /// Observes completion without activating. Caller cancellation affects only this observation.
    public func wait() async throws { try await completion.wait() }

    /// Used when the host could not obtain its transaction guard. Returns false after activation,
    /// so a joining caller's guard timeout cannot interrupt the owner already applying the route.
    @discardableResult
    public func cancelBeforeApplying() -> Bool {
        let effects = work.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            guard !state.activated, !state.cancelled else { return (false, nil) }
            state.cancelled = true
            state.activate = nil
            state.timer?.cancel()
            state.timer = nil
            return (true, state.dormantCancelled)
        }
        if effects.0 {
            completion.resolve(.failure(CancellationError()))
            effects.1?()
        }
        return effects.0
    }

    func onCancellation(_ action: @escaping @Sendable () -> Void) {
        let cancelled = work.withLock { state in
            let prior = state.cancellation
            state.cancellation = {
                prior?()
                action()
            }
            return state.cancelled
        }
        if cancelled { action() }
    }

    func cancel(error: Error = CancellationError()) {
        let effects = work.withLock { state -> (Task<Void, Error>?, (@Sendable () -> Void)?) in
            guard !state.cancelled else { return (nil, nil) }
            state.cancelled = true
            state.activate = nil
            state.timer?.cancel()
            state.timer = nil
            return (state.task, state.cancellation)
        }
        effects.1?()
        effects.0?.cancel()
        completion.resolve(.failure(error))
    }

    var isCancelled: Bool { work.withLock { $0.cancelled } }
}

/// A completion with independently cancellable observers, also usable before activation.
private final class TorTransitionCompletion: @unchecked Sendable {
    private struct State {
        var result: Result<Void, Error>?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var cancelled: Set<UUID> = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLockUnchecked { state -> Result<Void, Error>? in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if let result = state.result { return result }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = self.state.withLockUnchecked { state -> CheckedContinuation<Void, Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                if state.result == nil { state.cancelled.insert(id) }
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, Error>] in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }
}
