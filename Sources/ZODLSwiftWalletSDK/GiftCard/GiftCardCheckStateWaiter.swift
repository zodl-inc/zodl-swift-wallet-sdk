import Combine
import Foundation

/// One attempt observes coherent balances and host recovery without changing sync policy.
/// NSLock dates from the SDK's iOS 13 / macOS 12 floor, below OSAllocatedUnfairLock's
/// iOS 16 / macOS 13. Disposal runs outside the lock.
final class GiftCardCheckStateWaiter: @unchecked Sendable {
    private struct EmptyCandidate {
        let tip: BlockHeight
        let deadline: UInt64
        let balance: AccountBalance
    }

    private struct Effects {
        var subscriptions: [AnyCancellable] = []
        var cancelledTimer: Task<Void, Never>?
        var scheduledTimer: (UUID, UInt64)?
        var continuation: CheckedContinuation<AccountBalance, Error>?
        var result: Result<AccountBalance, Error>?

        func deliver() {
            subscriptions.forEach { $0.cancel() }
            cancelledTimer?.cancel()
            if let result { continuation?.resume(with: result) }
        }
    }

    private let lock = NSLock()
    private let accountUUID: AccountUUID
    private let policy: GiftCardCheckPolicy
    private let timing: GiftCardCleanupTiming
    private var subscriptions: [AnyCancellable] = []
    private var continuation: CheckedContinuation<AccountBalance, Error>?
    private var result: Result<AccountBalance, Error>?
    private var suppressReplay = false
    private var startInProgress = false
    private var pendingBalance: AccountBalance?
    private var empty: EmptyCandidate?
    private var disconnectedUntil: UInt64?
    private var timer: Task<Void, Never>?
    private var timerIdentity = UUID()
    private var timerDeadline: UInt64?

    init(accountUUID: AccountUUID, policy: GiftCardCheckPolicy, timing: GiftCardCleanupTiming) {
        self.accountUUID = accountUUID
        self.policy = policy
        self.timing = timing
    }

    func wait(
        stateStream: AnyPublisher<SynchronizerState, Never>,
        eventStream: AnyPublisher<SynchronizerEvent, Never>,
        start: (() async throws -> Void)?
    ) async throws -> AccountBalance {
        try await wait(
            stateStream: stateStream,
            eventStream: eventStream,
            shouldStart: { start != nil },
            start: { try await start?() }
        )
    }

    func wait(
        stateStream: AnyPublisher<SynchronizerState, Never>,
        eventStream: AnyPublisher<SynchronizerEvent, Never>,
        shouldStart: () async -> Bool,
        start: () async throws -> Void
    ) async throws -> AccountBalance {
        try await withTaskCancellationHandler {
            // Observe terminal events before the actor hop that selects a restart.
            install(eventStream.sink { [weak self] event in
                if case .syncStalled(_, true) = event {
                    self?.finish(.failure(ZcashError.giftCardCheckSyncStalled))
                }
            })
            let needsStart = await shouldStart()
            withLock {
                startInProgress = needsStart
                suppressReplay = needsStart
            }
            install(stateStream.sink { [weak self] state in self?.receive(state) })
            // Slipstream's CurrentValueSubject replays synchronously during subscription. A
            // stream without replay must not lose its first new value after subscription.
            withLock { suppressReplay = false }
            if needsStart, withLock({ result == nil }) {
                do { try await start() } catch { finish(.failure(error)) }
            }
            apply(withLock {
                startInProgress = false
                guard result == nil else { return Effects() }
                if let disconnectedUntil, timing.now() >= disconnectedUntil {
                    return finishLocked(.failure(ZcashError.giftCardCheckDisconnected))
                }
                if let pendingBalance { return finishLocked(.success(pendingBalance)) }
                if let empty, timing.now() >= empty.deadline { return finishLocked(.success(empty.balance)) }
                return Effects()
            })
            return try await withCheckedThrowingContinuation { continuation in
                let completed = withLock { () -> Result<AccountBalance, Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func receive(_ state: SynchronizerState) {
        let effects = withLock { () -> Effects in
            guard result == nil else { return Effects() }
            if suppressReplay {
                suppressReplay = false
                return Effects()
            }
            pendingBalance = nil
            let now = timing.now()
            // Unlike empty settling, expiry of a continuous disconnect wins over late recovery.
            if let disconnectedUntil, now >= disconnectedUntil {
                return finishLocked(.failure(ZcashError.giftCardCheckDisconnected))
            }
            if case .error(let error) = state.syncStatus {
                empty = nil
                guard (error as? ZcashError)?.code == ZcashError.synchronizerDisconnected.code else {
                    return finishLocked(.failure(error))
                }
                if disconnectedUntil == nil {
                    disconnectedUntil = deadline(from: now, duration: policy.disconnectGraceNanoseconds)
                }
                return refreshTimerLocked()
            }
            disconnectedUntil = nil
            guard case .upToDate = state.syncStatus,
                  state.latestBlockHeight > 0,
                  state.fullyScannedHeight >= state.latestBlockHeight,
                  let balance = state.accountsBalances[accountUUID] else {
                empty = nil
                return refreshTimerLocked()
            }
            // Classify this newly observed snapshot before considering an old zero deadline.
            if balance.shieldedTotal() > .zero { return finishLocked(.success(balance)) }
            let expires: UInt64
            if let empty, empty.tip == state.latestBlockHeight {
                expires = empty.deadline
            } else {
                expires = deadline(from: now, duration: policy.emptySettleNanoseconds)
            }
            empty = EmptyCandidate(tip: state.latestBlockHeight, deadline: expires, balance: balance)
            if now >= expires { return finishLocked(.success(balance)) }
            return refreshTimerLocked()
        }
        apply(effects)
    }

    private func refreshTimerLocked() -> Effects {
        let deadline = disconnectedUntil ?? (pendingBalance == nil ? empty?.deadline : nil)
        guard deadline != timerDeadline else { return Effects() }
        var effects = Effects()
        effects.cancelledTimer = timer
        timer = nil
        timerIdentity = UUID()
        timerDeadline = deadline
        if let deadline { effects.scheduledTimer = (timerIdentity, deadline) }
        return effects
    }

    private func apply(_ effects: Effects) {
        effects.deliver()
        guard let (identity, deadline) = effects.scheduledTimer else { return }
        let task = Task {
            do {
                try await timing.sleepUntil(deadline)
                timerFired(identity: identity, deadline: deadline)
            } catch { }
        }
        let installed = withLock {
            guard result == nil, timerIdentity == identity, timerDeadline == deadline else { return false }
            timer = task
            return true
        }
        if !installed { task.cancel() }
    }

    private func timerFired(identity: UUID, deadline: UInt64) {
        let effects = withLock { () -> Effects in
            guard result == nil, timerIdentity == identity, timerDeadline == deadline,
                  timing.now() >= deadline else { return Effects() }
            if disconnectedUntil != nil { return finishLocked(.failure(ZcashError.giftCardCheckDisconnected)) }
            if let empty { return finishLocked(.success(empty.balance)) }
            return Effects()
        }
        apply(effects)
    }

    private func install(_ subscription: AnyCancellable) {
        let installed = withLock {
            guard result == nil else { return false }
            subscriptions.append(subscription)
            return true
        }
        if !installed { subscription.cancel() }
    }

    private func finish(_ result: Result<AccountBalance, Error>) {
        apply(withLock { finishLocked(result) })
    }

    private func finishLocked(_ result: Result<AccountBalance, Error>) -> Effects {
        guard self.result == nil else { return Effects() }
        // A successful snapshot during start is provisional until owned startup drains. New
        // terminal/error callbacks must still be able to fail this attempt before that boundary.
        if startInProgress, case .success(let balance) = result {
            pendingBalance = balance
            // Settled zero retains its completed interval for same-tip snapshots during start.
            // Funded readiness removes that candidate. Either success disposes its timer.
            if balance.shieldedTotal() > .zero { empty = nil }
            return refreshTimerLocked()
        }
        self.result = result
        pendingBalance = nil
        var effects = Effects()
        effects.subscriptions = subscriptions
        effects.cancelledTimer = timer
        effects.continuation = continuation
        effects.result = result
        subscriptions = []
        continuation = nil
        timer = nil
        timerDeadline = nil
        timerIdentity = UUID()
        empty = nil
        disconnectedUntil = nil
        return effects
    }

    private func deadline(from now: UInt64, duration: UInt64) -> UInt64 {
        let sum = now.addingReportingOverflow(duration)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
