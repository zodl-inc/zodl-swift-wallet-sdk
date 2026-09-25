//
//  TorClientExecutorTests.swift
//  ZcashLightClientKitTests
//

import Foundation
import XCTest
@testable import ZcashLightClientKit

/// Every native call `TorClient` makes blocks its thread until Arti answers. Those waits — a bootstrap, a request with
/// its retries — must happen on the client's own queue, never on one of Swift's cooperative threads.
final class TorClientExecutorTests: XCTestCase {
    private final class LabelRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []

        func record() {
            let label = String(cString: __dispatch_queue_get_label(nil))
            lock.withLock { labels.append(label) }
        }

        var recorded: [String] {
            lock.withLock { labels }
        }
    }

    /// A native whose runtime creation — Arti's bootstrap — records where it ran and takes `delay` seconds.
    /// Only `freeRuntime` and `createRuntime` are replaced; the pointers are fakes, so they are freed as such.
    private func slowBootstrapNative(delay: TimeInterval, recorder: LabelRecorder) -> TorHTTPGetNative {
        TorHTTPGetNative(
            freeRuntime: { pointer in
                if let pointer {
                    UnsafeMutablePointer<UInt8>(pointer).deallocate()
                }
            },
            createRuntime: { _, _ in
                recorder.record()
                Thread.sleep(forTimeInterval: delay)
                return OpaquePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
            }
        )
    }

    private func temporaryTorDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tor-executor-\(UUID().uuidString)")
    }

    func testBootstrapRunsOnTheClientsOwnQueue() async throws {
        let recorder = LabelRecorder()
        let client = TorClient(torDir: temporaryTorDirectory(), httpGetNative: slowBootstrapNative(delay: 0, recorder: recorder))
        try await client.prepare()
        XCTAssertEqual(recorder.recorded, ["cash.z.wallet.sdk.tor-client"])
        try await client.close()
    }

    @MainActor
    func testSlowBootstrapsDoNotHoldCooperativeThreads() async throws {
        let recorder = LabelRecorder()
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let clients = (0..<count).map { _ in
            TorClient(torDir: temporaryTorDirectory(), httpGetNative: slowBootstrapNative(delay: 0.6, recorder: recorder))
        }
        let bootstraps = clients.map { client in
            Task.detached(priority: .userInitiated) { try await client.prepare() }
        }
        // Let every bootstrap reach its blocking call. `usleep`, not `Thread.sleep`: this is an async context.
        usleep(150_000)
        let scheduled = Date()
        let latency = await Task.detached(priority: .userInitiated) { Date().timeIntervalSince(scheduled) }.value
        for bootstrap in bootstraps {
            try await bootstrap.value
        }
        for client in clients {
            try await client.close()
        }
        XCTAssertLessThan(latency, 0.3, "a userInitiated task waited \(latency) s for a cooperative thread")
    }
}
