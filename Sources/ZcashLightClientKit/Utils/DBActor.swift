//
//  DBActor.swift
//
//
//  Created by Lukáš Korba on 04-08-2024.
//

import Foundation

/// Serializer of Swift-initiated database WRITES — and only that.
///
/// THE RULE (read/write split, 2026-08-03): every method that can write through the FFI or the
/// Swift DAO layer takes `@DBActor`. Genuinely read-only methods do NOT take it; each carries a
/// `// DB-READ (audited <date>): <verified function/SQL> — <reason>` marker naming exactly what
/// was checked. A call whose read-only-ness cannot be positively established stays `@DBActor`
/// with a comment saying so. When the librustzcash pin moves, any FFI function whose Rust body
/// changed needs its classification re-checked before the marker date is trusted.
///
/// The migration read entry points are the exception that needs no re-check: they open through
/// the FFI's `open_read` (SQLITE_OPEN_READ_ONLY on both connections), so their read-only-ness
/// is enforced by SQLite itself, not by audit.
///
/// WHAT THIS ACTOR GUARANTEES: no two Swift-initiated writes ever interleave. Its writes run on
/// ``DBActor/executor``'s queue, so a write waiting on the database never holds a cooperative
/// thread.
///
/// WHAT IT DOES NOT AND CANNOT GUARANTEE: the slipstream engine writes to the same database
/// files from Rust-managed threads continuously, outside any Swift actor — Swift-side
/// serialization has never covered it. Nor does the actor provide cross-call snapshot
/// consistency: every FFI call opens its own connection and sees its own WAL snapshot. Data
/// safety below the actor is per-call connections + WAL + the 15-second busy_timeout, which is
/// also why long CPU-bound writes (proof generation) are CHUNKED rather than detached: the
/// actor holds through each chunk on purpose — writers queue, readers (off-actor) do not.
@globalActor
enum DBActor {
    typealias ActorType = Actor

    actor Actor {
        nonisolated var unownedExecutor: UnownedSerialExecutor {
            DBActor.executor.asUnownedSerialExecutor()
        }
    }

    /// Where every Swift-initiated write runs — and waits, for as long as the FFI and SQLite's 15-second busy timeout
    /// make it wait, including behind the sync engine's commits. A queue of its own rather than Swift's cooperative
    /// pool: a write stuck there holds a dispatch thread, not one of the few cooperative threads the host's own
    /// `async` work needs. Writes still run one at a time, but in the order they arrive, each at the QoS of whoever
    /// queued it, where a default actor would run the highest-priority one first. Arrival order is what keeps a long
    /// migration proving run from holding queued writers for more than one proof: it yields between proofs and
    /// re-queues behind them.
    static let executor = DispatchQueueSerialExecutor(label: "cash.z.wallet.sdk.db-writes")
    static let shared = Actor()

    static var sharedUnownedExecutor: UnownedSerialExecutor {
        shared.unownedExecutor
    }
}
