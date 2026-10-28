import Foundation

/// SDK waiting policies for one gift-card check, measured on a monotonic clock.
struct GiftCardCheckPolicy: Sendable {
    let budgetNanoseconds: UInt64
    let disconnectGraceNanoseconds: UInt64
    let emptySettleNanoseconds: UInt64

    static func live(isTorEnabled: Bool) -> GiftCardCheckPolicy {
        GiftCardCheckPolicy(
            budgetNanoseconds: 600_000_000_000,
            disconnectGraceNanoseconds: isTorEnabled ? 120_000_000_000 : 60_000_000_000,
            emptySettleNanoseconds: isTorEnabled ? 30_000_000_000 : 15_000_000_000
        )
    }
}

/// Detaches the caller on timeout or cancellation without joining non-cooperative wallet work.
/// The work itself remains owned by the redeemer's serialized queue until it actually drains.
/// NSLock dates from the SDK's iOS 13 / macOS 12 floor, below OSAllocatedUnfairLock's
/// iOS 16 / macOS 13.
final class GiftCardCheckOperation: @unchecked Sendable {
    private struct Delivery {
        let continuation: CheckedContinuation<GiftCardStatus, Error>?
        let result: Result<GiftCardStatus, Error>
        let timer: Task<Void, Never>?
        let cancellation: (@Sendable () -> Void)?

        func resume() {
            timer?.cancel()
            cancellation?()
            continuation?.resume(with: result)
        }
    }

    private let lock = NSLock()
    private let expiresAt: UInt64
    private let timing: GiftCardCleanupTiming
    // Every mutable field is protected by lock. Callbacks and continuations run outside it.
    private var continuation: CheckedContinuation<GiftCardStatus, Error>?
    private var result: Result<GiftCardStatus, Error>?
    private var timer: Task<Void, Never>?
    private var cancellation: (@Sendable () -> Void)?
    private var cancellationRequested = false

    init(admittedAt: UInt64, policy: GiftCardCheckPolicy, timing: GiftCardCleanupTiming) {
        let deadline = admittedAt.addingReportingOverflow(policy.budgetNanoseconds)
        expiresAt = deadline.overflow ? UInt64.max : deadline.partialValue
        self.timing = timing
    }

    func value(operation: @escaping @Sendable () async throws -> GiftCardStatus) async throws -> GiftCardStatus {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delivery = withLock { () -> Delivery? in
                    self.continuation = continuation
                    guard let result else { return nil }
                    self.continuation = nil
                    return Delivery(continuation: continuation, result: result, timer: nil, cancellation: nil)
                }
                delivery?.resume()
                scheduleDeadline()
                // This task owns real work independently of the caller continuation. Cancelling
                // it requests cancellation, but does not join or discard a non-cooperative await.
                let work = Task {
                    do {
                        try requireActive()
                        finish(with: .success(try await operation()))
                    } catch {
                        finish(with: .failure(error))
                    }
                }
                installCancellation { work.cancel() }
            }
        } onCancel: {
            self.finish(with: .failure(CancellationError()), requestingCancellation: true)
        }
    }

    /// Admission and execution must obey expiry even when the timer has not been scheduled yet.
    func requireActive() throws {
        if timing.now() >= expiresAt { throw ZcashError.giftCardCheckTimedOut }
        // A cancelled caller can register before the work task's cancellation callback exists.
        // Inspect the recorded request too, so that installation cannot race native admission.
        if withLock({ cancellationRequested }) { throw CancellationError() }
        try Task.checkCancellation()
    }

    func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let requested = withLock {
            if cancellationRequested { return true }
            if result == nil { self.cancellation = cancellation }
            return false
        }
        if requested { cancellation() }
    }

    private func scheduleDeadline() {
        guard withLock({ result == nil }) else { return }
        let deadline = Task {
            do {
                try await timing.sleepUntil(expiresAt)
                finish(with: .failure(ZcashError.giftCardCheckTimedOut), requestingCancellation: true)
            } catch {
                // Caller completion disposed of its timer, while wallet work retains its owner.
            }
        }
        let installed = withLock {
            guard result == nil else { return false }
            timer = deadline
            return true
        }
        if !installed { deadline.cancel() }
    }

    private func finish(with result: Result<GiftCardStatus, Error>, requestingCancellation: Bool = false) {
        let delivery = withLock { () -> Delivery? in
            guard self.result == nil else { return nil }
            let expired = timing.now() >= expiresAt
            let selected: Result<GiftCardStatus, Error> = expired ? .failure(ZcashError.giftCardCheckTimedOut) : result
            self.result = selected
            cancellationRequested = requestingCancellation || expired
            let delivery = Delivery(
                continuation: continuation,
                result: selected,
                timer: timer,
                cancellation: cancellationRequested ? cancellation : nil
            )
            continuation = nil
            timer = nil
            cancellation = nil
            return delivery
        }
        delivery?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
