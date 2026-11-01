import Foundation
import libzcashlc
import os

/// Versioned native startup operations. `free` must never overlap another call on its job.
struct TorRuntimeStartupNative: Sendable {
    var begin: @Sendable ([UInt8], UInt64) -> OpaquePointer? = { directory, remaining in
        directory.withUnsafeBufferPointer { zcashlc_tor_startup_begin_v1($0.baseAddress, UInt($0.count), remaining) }
    }
    var cancel: @Sendable (OpaquePointer) -> Void = { zcashlc_tor_startup_cancel_v1($0) }
    var wait: @Sendable (OpaquePointer) -> UInt32 = { zcashlc_tor_startup_wait_v1($0) }
    var take: @Sendable (OpaquePointer) -> FfiTorStartupResultV1 = { zcashlc_tor_startup_take_v1($0) }
    var free: @Sendable (OpaquePointer) -> Void = { zcashlc_tor_startup_free_v1($0) }
}

/// Owns one startup through native quiescence. Native waits and cleanup run only on dispatch workers.
/// Cancellation can reach the native job while that worker waits. A transferred runtime stays
/// here until the actor claims it for its current generation, or cancellation disposes it.
final class TorRuntimeStartup: @unchecked Sendable {
    static let workerQueue = DispatchQueue(label: "cash.z.tor.startup")

    private struct State {
        var cancelled = false
        var job: TorNativeStartupJob?
        var runtime: OpaquePointer?
        var waiters: Set<UUID> = []
    }

    let deadline: UInt64
    private let directory: URL
    private let native: TorRuntimeStartupNative
    private let freeRuntime: @Sendable (OpaquePointer?) -> Void
    private let workerQueue: DispatchQueue
    private let now: @Sendable () -> UInt64
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(
        directory: URL,
        deadline: UInt64,
        native: TorRuntimeStartupNative,
        freeRuntime: @escaping @Sendable (OpaquePointer?) -> Void,
        workerQueue: DispatchQueue = TorRuntimeStartup.workerQueue,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.directory = directory
        self.deadline = deadline
        self.native = native
        self.freeRuntime = freeRuntime
        self.workerQueue = workerQueue
        self.now = now
    }

    var interestCount: Int { state.withLockUnchecked { $0.waiters.count } }

    var isCancelled: Bool { state.withLockUnchecked { $0.cancelled } }

    func registerWaiter() -> UUID? {
        state.withLockUnchecked { state in
            guard !state.cancelled else { return nil }
            let id = UUID()
            state.waiters.insert(id)
            return id
        }
    }

    /// A caller releases only its interest. The final abandoned interest cancels bootstrap.
    func releaseWaiter(_ id: UUID, cancelling: Bool) {
        state.withLockUnchecked { state in
            guard state.waiters.remove(id) != nil else { return }
            if cancelling && state.waiters.isEmpty { cancel(&state) }
        }
    }

    func cancel() {
        state.withLockUnchecked { state in cancel(&state) }
    }

    private func cancel(_ state: inout State) {
        guard !state.cancelled else { return }
        state.cancelled = true
        state.job?.cancel()
        disposeRuntime(&state)
    }

    /// Claiming is nonblocking and happens only on the owning actor after its generation check.
    func claimRuntime() throws -> OpaquePointer {
        try state.withLockUnchecked { state in
            guard !state.cancelled else { throw CancellationError() }
            guard now() < deadline else { throw URLError(.timedOut) }
            guard let runtime = state.runtime else { throw ZcashError.torClientUnavailable }
            state.runtime = nil
            return runtime
        }
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            workerQueue.async { [self] in
                continuation.resume(with: Result { try runOnWorker() })
            }
        }
    }

    private func runOnWorker() throws {
        guard !isCancelled else { throw CancellationError() }
        let instant = now()
        guard deadline > instant, (deadline - instant) / 1_000_000 > 0 else { throw URLError(.timedOut) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ZcashError.blockRepositoryCreateBlocksCacheDirectory(directory, error)
        }
        let beforeBegin = now()
        let remaining = deadline > beforeBegin ? (deadline - beforeBegin) / 1_000_000 : 0
        guard remaining > 0 else { throw URLError(.timedOut) }
        guard let job = native.begin(Array(directory.path.utf8), remaining) else {
            throw ZcashError.rustTorClientInit("Tor runtime startup could not begin")
        }
        let nativeJob = TorNativeStartupJob(pointer: job, native: native)
        state.withLockUnchecked { state in
            state.job = nativeJob
            if state.cancelled { nativeJob.cancel() }
        }
        let result = nativeJob.waitAndTakeOnWorker()
        state.withLockUnchecked { state in
            state.job = nil
            state.runtime = result.runtime
            if state.cancelled { disposeRuntime(&state) }
        }
        if isCancelled { throw CancellationError() }
        switch result.status {
        case 1:
            guard result.runtime != nil else { throw ZcashError.rustTorClientInit("Tor startup returned no runtime") }
        case 3: throw URLError(.timedOut)
        case 4: throw CancellationError()
        default: throw ZcashError.rustTorClientInit("Tor runtime startup failed")
        }
    }

    private func disposeRuntime(_ state: inout State) {
        guard let runtime = state.runtime else { return }
        state.runtime = nil
        let freeRuntime = freeRuntime
        // The captured owner is Sendable and disposes on the bounded startup queue.
        let owner = TorRuntimeDisposal(runtime: runtime, freeRuntime: freeRuntime)
        workerQueue.async { owner.dispose() }
    }

    deinit {
        state.withLockUnchecked { state in disposeRuntime(&state) }
    }
}

/// Transferring a raw pointer between queues does not grant concurrent access to it.
final class TorRuntimeDisposal: @unchecked Sendable {
    private let runtime: OpaquePointer
    private let freeRuntime: @Sendable (OpaquePointer?) -> Void

    init(runtime: OpaquePointer, freeRuntime: @escaping @Sendable (OpaquePointer?) -> Void) {
        self.runtime = runtime
        self.freeRuntime = freeRuntime
    }

    func dispose() { freeRuntime(runtime) }
}

/// Wait/take belong to the startup worker. This separate lane serializes cancellation and free
/// without holding a Swift state lock during native cleanup, including dropping an unclaimed READY.
private final class TorNativeStartupJob: @unchecked Sendable {
    private static let cancellationQueue = DispatchQueue(label: "cash.z.tor.startup.cancel")
    private let pointer: OpaquePointer
    private let native: TorRuntimeStartupNative
    // Accessed only on cancellationQueue, including callbacks queued after free.
    private var live = true

    init(pointer: OpaquePointer, native: TorRuntimeStartupNative) {
        self.pointer = pointer
        self.native = native
    }

    func cancel() {
        Self.cancellationQueue.async { [self] in
            if live { native.cancel(pointer) }
        }
    }

    func waitAndTakeOnWorker() -> FfiTorStartupResultV1 {
        _ = native.wait(pointer)
        let result = native.take(pointer)
        // Only the dispatch worker blocks here. All prior cancel calls finish before free;
        // any later queued cancellation sees live=false and never touches the released pointer.
        Self.cancellationQueue.sync { [self] in
            live = false
            native.free(pointer)
        }
        return result
    }
}
