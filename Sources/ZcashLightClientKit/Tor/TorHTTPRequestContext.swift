import Foundation

/// Owns caller completion before the first actor hop. Once isolation starts, the
/// admission task must finish disposing its native owner before completing the caller.
final class TorHTTPRequestContext: @unchecked Sendable {
    typealias Response = TorHTTPRequestExecutor.Response

    private enum Phase { case waiting, owned, terminal }

    private struct Completion {
        let caller: CheckedContinuation<Response, Error>?
        let admission: Task<Void, Never>?
        let timer: Task<Void, Never>?
        let result: Result<Response, Error>

        func deliver() {
            admission?.cancel()
            timer?.cancel()
            caller?.resume(with: result)
        }
    }

    let deadlineUptime: UInt64
    private let now: @Sendable () -> UInt64
    private let sleepUntil: @Sendable (UInt64) async throws -> Void
    // NSLock preserves the SDK's iOS 13/macOS 12 deployment floors.
    private let lock = NSLock()
    private var phase = Phase.waiting
    private var reason: Error?
    private var result: Result<Response, Error>?
    private var continuation: CheckedContinuation<Response, Error>?
    private var admissionTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(
        deadlineUptime: UInt64,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: (@Sendable (UInt64) async throws -> Void)? = nil
    ) {
        self.deadlineUptime = deadlineUptime
        self.now = now
        self.sleepUntil = sleepUntil ?? { deadline in
            let instant = now()
            if deadline > instant { try await Task.sleep(nanoseconds: deadline - instant) }
        }
    }

    func run(_ admission: @escaping @Sendable (TorHTTPRequestContext) async throws -> Response) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Result<Response, Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let completed {
                    continuation.resume(with: completed)
                    return
                }
                let timer = Task {
                    do {
                        try await sleepUntil(deadlineUptime)
                        try Task.checkCancellation()
                        stop(URLError(.timedOut))
                    } catch {
                        // Completion or cancellation removed the deadline timer.
                    }
                }
                install(timer, isTimer: true)
                let task = Task {
                    let result: Result<Response, Error>
                    do {
                        try checkCancellation()
                        result = .success(try await admission(self))
                    } catch {
                        result = .failure(error)
                    }
                    finish(result)
                }
                install(task, isTimer: false)
            }
        } onCancel: {
            self.stop(CancellationError())
        }
    }

    /// The atomic boundary immediately before native isolation starts.
    func claimOwnership() throws {
        try lock.withLock {
            try checkLocked()
            guard phase == .waiting else { throw CancellationError() }
            phase = .owned
        }
    }

    func checkCancellation() throws {
        try lock.withLock { try checkLocked() }
    }

    private func checkLocked() throws {
        if let reason { throw reason }
        guard phase != .terminal else { throw CancellationError() }
        guard now() < deadlineUptime else { throw URLError(.timedOut) }
    }

    private func install(_ task: Task<Void, Never>, isTimer: Bool) {
        let cancel = lock.withLock {
            guard phase != .terminal, reason == nil else { return true }
            if isTimer { timer = task } else { admissionTask = task }
            return false
        }
        if cancel { task.cancel() }
    }

    private func stop(_ error: Error) {
        let removed = lock.withLock { () -> Completion? in
            guard phase != .terminal, reason == nil else { return nil }
            reason = error
            let effects = Completion(
                caller: phase == .waiting ? continuation : nil,
                admission: admissionTask,
                timer: timer,
                result: .failure(error)
            )
            admissionTask = nil
            timer = nil
            if phase == .waiting {
                phase = .terminal
                result = .failure(error)
                continuation = nil
            }
            return effects
        }
        // Cancellation propagates through the unstructured admission task into the
        // executor, but completion of an owned request still waits for its disposal.
        removed?.deliver()
    }

    private func finish(_ operationResult: Result<Response, Error>) {
        let removed = lock.withLock { () -> Completion? in
            guard phase != .terminal else { return nil }
            let completed = reason.map { Result<Response, Error>.failure($0) } ?? operationResult
            phase = .terminal
            result = completed
            let effects = Completion(caller: continuation, admission: nil, timer: timer, result: completed)
            continuation = nil
            timer = nil
            admissionTask = nil
            return effects
        }
        removed?.deliver()
    }
}
