//
//  DispatchQueueSerialExecutor.swift
//  ZcashLightClientKit
//

import Foundation

/// A serial executor that runs an actor's jobs on a dispatch queue of its own instead of Swift's cooperative pool.
///
/// Actors that make synchronous FFI or SQLite calls adopt it through `unownedExecutor`. Such a call can block its
/// thread for as long as the network or the database takes — seconds, sometimes minutes. On the cooperative pool that
/// is a thread the whole process loses: the pool has one thread per core and does not grow when one blocks, so a few
/// of these waits at once starve every `async` task the host runs, its UI work included. A dispatch queue's thread is
/// GCD's, which starts another thread for work the blocked ones cannot take, and every caller awaiting the actor
/// suspends instead of blocking.
///
/// The actor's jobs still run one at a time, but strictly in the order they arrive, each at the QoS of whoever queued
/// it — unlike a default actor, which runs its queued jobs in priority order.
final class DispatchQueueSerialExecutor: SerialExecutor, @unchecked Sendable {
    /// The queue every job runs on. Serial, so the actor's isolation holds.
    let queue: DispatchQueue
    private let specificKey = DispatchSpecificKey<ObjectIdentifier>()

    init(label: String, qos: DispatchQoS = .unspecified) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: specificKey, value: ObjectIdentifier(self))
    }

    /// Whether the calling code is running on this executor's queue.
    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: specificKey) == ObjectIdentifier(self)
    }

    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
