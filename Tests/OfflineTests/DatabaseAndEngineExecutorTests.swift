//
//  DatabaseAndEngineExecutorTests.swift
//  ZcashLightClientKitTests
//

import Foundation
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

@DBActor
private func isRunningOnTheDatabaseQueue() -> Bool {
    DBActor.executor.isCurrent
}

extension SlipstreamEngine {
    fileprivate func isRunningOnItsOwnQueue() -> Bool {
        executor.isCurrent
    }
}

/// Swift-initiated database writes and the engine's FFI calls block while they wait on SQLite or the engine; they must
/// wait on their own queues, not on Swift's cooperative threads.
final class DatabaseAndEngineExecutorTests: XCTestCase {
    func testDBActorIsolatedWorkRunsOnTheDatabaseQueue() async {
        let onQueue = await isRunningOnTheDatabaseQueue()
        XCTAssertTrue(onQueue)
    }

    func testSlipstreamEngineWorkRunsOnItsOwnQueue() async throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("engine-executor-\(UUID().uuidString).db")
        let engine = SlipstreamEngine(dbURL: dbURL, server: LightWalletEndpointBuilder.default)
        let onQueue = await engine.isRunningOnItsOwnQueue()
        XCTAssertTrue(onQueue)
    }
}
