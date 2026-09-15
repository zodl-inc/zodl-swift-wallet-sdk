import Foundation

/// Admits at most two bounded native GETs across all Tor clients in the process.
/// The worker owns cleanup until its synchronous operation has completely exited.
actor TorHTTPRequestExecutor {
    typealias Response = (data: Data, response: HTTPURLResponse)
    static let shared = TorHTTPRequestExecutor()

    private struct Job {
        let id: UUID
        let deadline: UInt64
        let cancellation: TorHTTPRequestCancellation
        let operation: @Sendable (UInt64) throws -> Response
        let dispose: @Sendable () -> Void
        let continuation: CheckedContinuation<Response, Error>
        var timer: Task<Void, Never>?
    }

    private let workerQueue: DispatchQueue
    private let now: @Sendable () -> UInt64
    private let sleepUntil: @Sendable (UInt64) async throws -> Void
    private var queued: [Job] = []
    private var active: [UUID: Job] = [:]

    init(
        workerQueue: DispatchQueue = DispatchQueue(label: "cash.z.tor.http", attributes: .concurrent),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: (@Sendable (UInt64) async throws -> Void)? = nil
    ) {
        self.workerQueue = workerQueue
        self.now = now
        self.sleepUntil = sleepUntil ?? { deadline in
            let instant = DispatchTime.now().uptimeNanoseconds
            if deadline > instant {
                try await Task.sleep(nanoseconds: deadline - instant)
            }
        }
    }

    nonisolated static func deadline(timeoutMilliseconds: UInt64, now: UInt64) throws -> UInt64 {
        guard timeoutMilliseconds > 0 else { throw URLError(.timedOut) }
        let duration = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let deadline = now.addingReportingOverflow(duration.partialValue)
        return duration.overflow || deadline.overflow ? UInt64.max : deadline.partialValue
    }

    func execute(
        deadlineUptime: UInt64,
        operation: @escaping @Sendable (UInt64) throws -> Response,
        dispose: @escaping @Sendable () -> Void = {}
    ) async throws -> Response {
        let id = UUID()
        let cancellation = TorHTTPRequestCancellation()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(
                    id: id,
                    deadline: deadlineUptime,
                    cancellation: cancellation,
                    operation: operation,
                    dispose: dispose,
                    continuation: continuation
                )
                if Task.isCancelled { cancellation.cancel() }
                queued.append(job)
                admit()
                if let index = queued.firstIndex(where: { $0.id == id }) {
                    queued[index].timer = Task {
                        do {
                            try await sleepUntil(deadlineUptime)
                            expire(id)
                        } catch {
                            // Admission or cancellation removed this queued request.
                        }
                    }
                }
            }
        } onCancel: {
            // Also make cancellation visible to admission/native entry before the actor
            // receives its message. This closes cancellation racing worker completion.
            cancellation.cancel()
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
        return response
    }

    private func admit() {
        while active.count < 2, !queued.isEmpty {
            let job = queued.removeFirst()
            job.timer?.cancel()
            let instant = now()
            if job.cancellation.isCancelled {
                discard(job, error: CancellationError())
            } else if job.deadline <= instant || job.deadline - instant < 1_000_000 {
                discard(job, error: URLError(.timedOut))
            } else {
                active[job.id] = job
                let now = self.now
                workerQueue.async {
                    let result = Result<Response, Error> {
                        defer { job.dispose() }
                        try job.cancellation.check()
                        let instant = now()
                        let remaining = job.deadline > instant ? job.deadline - instant : 0
                        let milliseconds = remaining / 1_000_000
                        guard milliseconds > 0 else { throw URLError(.timedOut) }
                        return try job.operation(milliseconds)
                    }
                    Task { await self.complete(job.id, result: result) }
                }
            }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let job = queued.remove(at: index)
        job.timer?.cancel()
        discard(job, error: CancellationError())
    }

    private func expire(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        let job = queued.remove(at: index)
        discard(job, error: job.cancellation.isCancelled ? CancellationError() : URLError(.timedOut))
    }

    private func discard(_ job: Job, error: Error) {
        workerQueue.async {
            job.dispose()
            job.continuation.resume(throwing: error)
        }
    }

    private func complete(_ id: UUID, result: Result<Response, Error>) {
        guard let job = active.removeValue(forKey: id) else { return }
        if job.cancellation.isCancelled {
            job.continuation.resume(throwing: CancellationError())
        } else {
            job.continuation.resume(with: result)
        }
        admit()
    }
}

/// NSLock supports the SDK's iOS 13/macOS 12 minimums. The flag is shared only
/// between the synchronous cancellation handler, admission, and native entry.
private final class TorHTTPRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
