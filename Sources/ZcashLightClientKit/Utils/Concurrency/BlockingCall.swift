//
//  BlockingCall.swift
//  ZcashLightClientKit
//

import Foundation

/// Runs synchronous work that can block for a long time — an FFI call, a SQLite query — where the waiting does not
/// cost Swift's cooperative pool a thread.
protocol BlockingCallRunning: Sendable {
    /// Runs `body` on a dispatch thread and answers with what it returned or threw.
    ///
    /// `body` runs start to finish on one thread, so it can read the FFI's per-thread last-error slot after a failing
    /// call. The caller suspends until `body` returns and cannot abandon it: an FFI call in progress cannot be
    /// interrupted, so cancelling the awaiting task takes effect only once `body` has returned.
    func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T
}

/// The SDK's shared ``BlockingCallRunning``: one concurrent dispatch queue for the blocking calls that are not made
/// from an actor with an executor of its own (see ``DispatchQueueSerialExecutor``). GCD grows the queue past a
/// blocked thread, so one slow call does not hold up the next — up to libdispatch's thread limit for the
/// non-overcommit worker pool the queue draws on. Past that limit further calls, and other work on the global
/// concurrent queues, wait for a thread; calls are expected to be few and short-lived relative to that limit.
struct BlockingCall: BlockingCallRunning {
    static let shared = BlockingCall(label: "cash.z.wallet.sdk.blocking-call")

    let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, attributes: .concurrent)
    }

    func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }
}
