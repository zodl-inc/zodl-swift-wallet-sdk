//
//  BlockingWorkExecutorTests.swift
//  ZcashLightClientKitTests
//

import Foundation
import XCTest
@testable import ZcashLightClientKit

/// A synchronous call that blocks for a long time must not hold one of Swift's cooperative threads: the pool has one
/// per core and does not grow, so enough such waits at once stop every other task from starting.
///
/// The starvation tests run on the main actor on purpose. The main actor is not part of the cooperative pool, so the
/// test body can keep going — and schedule its probe — while the pool is saturated, and the probe measures its own
/// start latency.
final class BlockingWorkExecutorTests: XCTestCase {
    /// An actor pinned to a queue of its own, the way the SDK's FFI-calling actors are.
    private actor QueuePinnedActor {
        nonisolated let executor: DispatchQueueSerialExecutor

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            executor.asUnownedSerialExecutor()
        }

        init(label: String) {
            executor = DispatchQueueSerialExecutor(label: label)
        }

        func isOnOwnExecutor() -> Bool {
            executor.isCurrent
        }

        func block(for seconds: TimeInterval) {
            BlockingWorkExecutorTests.block(for: seconds)
        }
    }

    private static let blockingSeconds: TimeInterval = 0.6

    private static var blockerCount: Int {
        ProcessInfo.processInfo.activeProcessorCount * 2
    }

    /// How long a fresh `.userInitiated` task waits for a cooperative thread, measured by the task itself.
    ///
    /// Main-actor isolated on purpose: a nonisolated `async` function called from `@MainActor` code would itself
    /// hop to the cooperative pool before running, so `scheduled` would already be stale by the time it is read —
    /// hiding exactly the wait this is meant to measure. Isolating this to the caller's actor keeps `let scheduled`
    /// on the main actor, so the only hop left is the one under measurement: `Task.detached` reaching the pool.
    @MainActor
    private static func probeStartLatency() async -> TimeInterval {
        let scheduled = Date()
        return await Task.detached(priority: .userInitiated) {
            Date().timeIntervalSince(scheduled)
        }.value
    }

    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    /// Blocks the calling thread for `seconds` without using `Thread.sleep(forTimeInterval:)`, which is unavailable
    /// from asynchronous contexts (a warning today, an error under the Swift 6 language mode).
    private static func block(for seconds: TimeInterval) {
        usleep(UInt32(seconds * 1_000_000))
    }

    func testActorIsolatedWorkRunsOnTheExecutorQueue() async {
        let actor = QueuePinnedActor(label: "test.queue-pinned")
        let isOnOwnExecutor = await actor.isOnOwnExecutor()
        XCTAssertTrue(isOnOwnExecutor)
    }

    func testIsCurrentIsFalseOffTheQueue() {
        let executor = DispatchQueueSerialExecutor(label: "test.off-queue")
        XCTAssertFalse(executor.isCurrent)
    }

    func testBlockingCallReturnsTheBodysValueFromItsQueue() async throws {
        let label = try await BlockingCall.shared.run { Self.currentQueueLabel() }
        XCTAssertEqual(label, "cash.z.wallet.sdk.blocking-call")
    }

    func testBlockingCallRethrowsTheBodysError() async {
        struct Boom: Error {}
        do {
            _ = try await BlockingCall.shared.run { () throws -> Int in throw Boom() }
            XCTFail("expected the body's error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    @MainActor
    func testBlockingCallsDoNotHoldCooperativeThreads() async throws {
        let blockers = (0..<Self.blockerCount).map { _ in
            Task.detached(priority: .userInitiated) {
                try await BlockingCall.shared.run { Self.block(for: Self.blockingSeconds) }
            }
        }
        // Let every blocker reach its blocking call before probing.
        Self.block(for: 0.15)
        let latency = await Self.probeStartLatency()
        for blocker in blockers {
            try await blocker.value
        }
        XCTAssertLessThan(latency, 0.3, "a userInitiated task waited \(latency) s for a cooperative thread")
    }

    @MainActor
    func testQueuePinnedActorsDoNotHoldCooperativeThreads() async throws {
        let actors = (0..<Self.blockerCount).map { QueuePinnedActor(label: "test.queue-pinned.\($0)") }
        let blockers = actors.map { actor in
            Task.detached(priority: .userInitiated) {
                await actor.block(for: Self.blockingSeconds)
            }
        }
        Self.block(for: 0.15)
        let latency = await Self.probeStartLatency()
        for blocker in blockers {
            await blocker.value
        }
        XCTAssertLessThan(latency, 0.3, "a userInitiated task waited \(latency) s for a cooperative thread")
    }

    /// Control: proves the probe can observe starvation on this machine, so the two tests above cannot pass vacuously.
    @MainActor
    func testInlineBlockingStarvesTheProbe() async throws {
        let blockers = (0..<Self.blockerCount).map { _ in
            Task.detached(priority: .userInitiated) {
                Self.block(for: Self.blockingSeconds)
            }
        }
        Self.block(for: 0.15)
        let latency = await Self.probeStartLatency()
        for blocker in blockers {
            await blocker.value
        }
        XCTAssertGreaterThan(latency, 0.3, "the control expected the inline blockers to delay the probe")
    }
}
