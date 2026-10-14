/// An optional capability for awaiting a synchronizer's own stop operation.
///
/// Both SDK synchronizers support this capability. Existing `Synchronizer` conformers need not
/// implement it. The synchronous `stop()` remains a request that returns before teardown finishes.
public protocol AwaitableStopSynchronizer: Synchronizer {
    /// Requests a stop and waits for that stop operation to finish, even when the caller is cancelled.
    ///
    /// Completion covers the implementation's stop body and any lifecycle work queued ahead of it.
    /// It does not rely on a new state-stream event, including when the synchronizer is idle or
    /// unprepared. `SDKSynchronizer` joins its processor-owned sync, mempool, rewind, poll and action work.
    /// Other implementations may return from their engine stop with a writer still active.
    /// Callers must coordinate subsequent starts to keep the synchronizer stopped for their work.
    func stopAndWait() async
}
