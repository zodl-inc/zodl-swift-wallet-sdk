import Foundation
import libzcashlc
import os

protocol SlipstreamTorStartupControlling: Sendable {
    func cancel()
    func waitUntilReady() async throws
}

protocol SlipstreamTorStarting: Actor {
    nonisolated func makeTorStartup(deadline: UInt64) throws -> any SlipstreamTorStartupControlling
    func startTor(birthday: BlockHeight, torDir: String, startup: any SlipstreamTorStartupControlling) async throws
}

/// Owns the independent native capability through start, readiness polling, and cancellation.
/// A strong reference held by each call prevents free from overlapping any use of the capability.
final class SlipstreamTorStartup: @unchecked Sendable, SlipstreamTorStartupControlling {
    private static let generations = OSAllocatedUnfairLock(initialState: UInt64(0))
    let pointer: OpaquePointer
    let generation: UInt64

    convenience init(deadline: UInt64) throws {
        let generation = Self.generations.withLock { value in
            value += 1
            return value
        }
        let now = DispatchTime.now().uptimeNanoseconds
        try self.init(generation: generation, remainingMilliseconds: deadline > now ? (deadline - now) / 1_000_000 : 0)
    }

    init(generation: UInt64, remainingMilliseconds: UInt64) throws {
        guard let pointer = zcashlc_slipstream_tor_startup_begin_v1(generation, remainingMilliseconds) else {
            throw TorTransitionState.Failure.startupFailed
        }
        self.pointer = pointer
        self.generation = generation
    }

    var snapshot: (generation: UInt64, status: UInt32) {
        let snapshot = zcashlc_slipstream_tor_startup_snapshot_v1(pointer)
        return (snapshot.generation, snapshot.status)
    }

    func cancel() { zcashlc_slipstream_tor_startup_cancel_v1(pointer) }

    func waitUntilReady() async throws {
        while true {
            try Task.checkCancellation()
            switch snapshot.status {
            case 0: try await Task.sleep(nanoseconds: 10_000_000)
            case 1: return
            case 3: throw TorTransitionState.Failure.startupTimedOut
            case 4: throw CancellationError()
            default: throw TorTransitionState.Failure.startupFailed
            }
        }
    }

    deinit { zcashlc_slipstream_tor_startup_free_v1(pointer) }
}
