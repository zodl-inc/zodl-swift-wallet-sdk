import Foundation

/// Owns teardown independently of the lifetime and cancellation of its callers.
/// NSLock dates from the SDK's iOS 13 / macOS 12 floor, below OSAllocatedUnfairLock's
/// iOS 16 / macOS 13.
final class GiftCardCleanupCoordinator: @unchecked Sendable {
    private enum Phase {
        case idle
        case attempting
        case retrying(UUID)
        case finishing
        case completed
    }

    /// All fields are protected by the coordinator's lock, including registration races.
    private final class Waiter {
        let id = UUID()
        let expiresAt: UInt64
        var continuation: CheckedContinuation<Void, Error>?
        var result: Result<Void, Error>?
        var timer: Task<Void, Never>?

        init(expiresAt: UInt64) {
            self.expiresAt = expiresAt
        }
    }

    private struct Delivery {
        let continuation: CheckedContinuation<Void, Error>
        let result: Result<Void, Error>
        let timer: Task<Void, Never>?

        func resume() {
            timer?.cancel()
            continuation.resume(with: result)
        }
    }

    private struct Attempt {
        let predecessor: Task<Void, Never>?
        let retryToCancel: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let timing: GiftCardCleanupTiming
    private let wipe: () async throws -> Void
    private let removeRoot: () throws -> Void
    private let didFinish: () -> Void
    private var phase = Phase.idle
    private var predecessor: Task<Void, Never>?
    private var wipeSucceeded = false
    private var failureCount = 0
    private var retryTask: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]

    init(
        timing: GiftCardCleanupTiming = .live,
        wipe: @escaping () async throws -> Void,
        removeRoot: @escaping () throws -> Void,
        didFinish: @escaping () -> Void
    ) {
        self.timing = timing
        self.wipe = wipe
        self.removeRoot = removeRoot
        self.didFinish = didFinish
    }

    func requestCleanup(after predecessor: Task<Void, Never>?) {
        let attempt = withLock { admitAttempt(after: predecessor) }
        if let attempt { launch(attempt) }
    }

    func cleanup(after predecessor: Task<Void, Never>?, admittedAt: UInt64? = nil) async throws {
        let admittedAt = admittedAt ?? timing.now()
        let deadline = admittedAt.addingReportingOverflow(30_000_000_000)
        let expiresAt = deadline.overflow ? UInt64.max : deadline.partialValue
        let waiter = Waiter(expiresAt: expiresAt)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var delivery: Delivery?
                let attempt = withLock {
                    waiter.continuation = continuation
                    if let result = waiter.result {
                        delivery = takeDelivery(for: waiter, result: result)
                    } else if timing.now() >= waiter.expiresAt {
                        delivery = takeDelivery(for: waiter, result: .failure(GiftCardCleanupWaitError.timedOut))
                    } else if case .completed = phase {
                        delivery = takeDelivery(for: waiter, result: .success(()))
                    } else {
                        waiters[waiter.id] = waiter
                    }
                    return admitAttempt(after: predecessor)
                }
                delivery?.resume()
                if let attempt { launch(attempt) }
                scheduleDeadline(for: waiter)
            }
        } onCancel: {
            self.finish(waiter, with: .failure(CancellationError()))
        }
    }

    /// Called only under the lock. Reserving the attempt before launch prevents duplicates.
    private func admitAttempt(after predecessor: Task<Void, Never>?) -> Attempt? {
        switch phase {
        case .idle:
            self.predecessor = predecessor
        case .retrying:
            break
        case .attempting, .finishing, .completed:
            return nil
        }
        phase = .attempting
        let attempt = Attempt(predecessor: self.predecessor, retryToCancel: retryTask)
        retryTask = nil
        return attempt
    }

    private func launch(_ attempt: Attempt) {
        attempt.retryToCancel?.cancel()
        // The task owns the coordinator until teardown succeeds or ownership passes to a retry.
        Task {
            await attempt.predecessor?.value
            await performAttempt()
        }
    }

    private func performAttempt() async {
        do {
            let needsWipe = withLock { !wipeSucceeded }
            if needsWipe {
                try await wipe()
                withLock { wipeSucceeded = true }
            }
            try removeRoot()
            withLock { phase = .finishing }
            // Ownership release may reenter this coordinator. Success remains unavailable until it returns.
            didFinish()
            let deliveries = withLock {
                phase = .completed
                predecessor = nil
                return takeAllDeliveries(with: .success(()))
            }
            deliveries.forEach { $0.resume() }
        } catch {
            let retryID = UUID()
            let failure = withLock {
                failureCount = min(failureCount + 1, 6)
                phase = .retrying(retryID)
                return (count: failureCount, deliveries: takeAllDeliveries(with: .failure(error)))
            }
            failure.deliveries.forEach { $0.resume() }
            scheduleRetry(id: retryID, failureCount: failure.count)
        }
    }

    private func scheduleRetry(id: UUID, failureCount: Int) {
        let delay: UInt64 = [1, 2, 4, 8, 16, 30][failureCount - 1] * 1_000_000_000
        let deadline = timing.now().addingReportingOverflow(delay)
        let expiresAt = deadline.overflow ? UInt64.max : deadline.partialValue
        let task = Task {
            do {
                try await timing.sleepUntil(expiresAt)
                let attempt = withLock { () -> Attempt? in
                    guard case .retrying(let currentID) = phase, currentID == id else { return nil }
                    phase = .attempting
                    retryTask = nil
                    return Attempt(predecessor: predecessor, retryToCancel: nil)
                }
                if let attempt { launch(attempt) }
            } catch {
                // A new caller prompted this retry, so the cancelled timer has no further work.
            }
        }
        let installed = withLock {
            guard case .retrying(let currentID) = phase, currentID == id else { return false }
            retryTask = task
            return true
        }
        if !installed { task.cancel() }
    }

    private func scheduleDeadline(for waiter: Waiter) {
        let isPending = withLock { waiter.result == nil }
        guard isPending else { return }
        let timer = Task {
            do {
                try await timing.sleepUntil(waiter.expiresAt)
                finish(waiter, with: .failure(GiftCardCleanupWaitError.timedOut))
            } catch {
                // Completion or caller cancellation disposed of this waiter timer.
            }
        }
        let installed = withLock {
            guard waiter.result == nil else { return false }
            waiter.timer = timer
            return true
        }
        if !installed { timer.cancel() }
    }

    private func finish(_ waiter: Waiter, with result: Result<Void, Error>) {
        let delivery = withLock { () -> Delivery? in
            guard waiter.result == nil else { return nil }
            waiter.result = result
            waiters.removeValue(forKey: waiter.id)
            return takeDelivery(for: waiter, result: result)
        }
        delivery?.resume()
    }

    /// Called only under the lock. A result recorded before registration is delivered at registration.
    private func takeDelivery(for waiter: Waiter, result: Result<Void, Error>) -> Delivery? {
        waiter.result = result
        guard let continuation = waiter.continuation else { return nil }
        let delivery = Delivery(continuation: continuation, result: result, timer: waiter.timer)
        waiter.continuation = nil
        waiter.timer = nil
        return delivery
    }

    private func takeAllDeliveries(with result: Result<Void, Error>) -> [Delivery] {
        // Elapsed time selects pending outcomes even if the deadline task has not run yet.
        let instant = timing.now()
        let deliveries = waiters.values.compactMap { waiter in
            let selected: Result<Void, Error> = instant >= waiter.expiresAt
                ? .failure(GiftCardCleanupWaitError.timedOut)
                : result
            return takeDelivery(for: waiter, result: selected)
        }
        waiters = [:]
        return deliveries
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
