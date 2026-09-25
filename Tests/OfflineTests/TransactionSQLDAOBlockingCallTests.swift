//
//  TransactionSQLDAOBlockingCallTests.swift
//  ZcashLightClientKitTests
//

import Foundation
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Every transaction read runs through the DAO's blocking-call runner, so the SQLite wait — SQLite.swift serialises
/// every statement on one connection queue — never holds one of Swift's cooperative threads.
final class TransactionSQLDAOBlockingCallTests: XCTestCase {
    private final class RecordingBlockingCalls: BlockingCallRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var count: Int {
            lock.withLock { calls }
        }

        func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
            lock.withLock { calls += 1 }
            return try body()
        }
    }

    private var runner: RecordingBlockingCalls!
    private var dao: TransactionSQLDAO!

    override func setUp() async throws {
        try await super.setUp()
        runner = RecordingBlockingCalls()
        // Same fixture database and initialisation as TransactionRepositoryTests.setUp.
        let rustBackend = ZcashRustBackend.makeForTests(
            dbData: TestDbBuilder.prePopulatedMainnetDataDbURL()!,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .mainnet
        )
        let provider = try await TestDbBuilder.prepopulatedDataDbProvider(rustBackend: rustBackend)!
        dao = TransactionSQLDAO(dbProvider: provider, blockingCalls: runner)
    }

    override func tearDown() async throws {
        dao = nil
        runner = nil
        try await super.tearDown()
    }

    func testCountsReadThroughTheRunner() async throws {
        _ = try await dao.countAll()
        _ = try await dao.countUnmined()
        XCTAssertEqual(runner.count, 2)
    }

    func testTransactionQueriesReadThroughTheRunner() async throws {
        let before = runner.count
        let transactions = try await dao.find(offset: 0, limit: 10, kind: .all)
        XCTAssertGreaterThan(runner.count, before)

        let afterList = runner.count
        _ = try await dao.findReceived(offset: 0, limit: 10)
        _ = try await dao.findSent(offset: 0, limit: 10)
        XCTAssertEqual(runner.count, afterList + 2)

        let first = try XCTUnwrap(transactions.first)

        let afterFinds = runner.count
        _ = try await dao.find(rawID: first.rawID)
        _ = try await dao.getTransactionOutputs(for: first.rawID)
        _ = try await dao.findMemos(for: first.rawID)
        XCTAssertEqual(runner.count, afterFinds + 3)

        let beforeSearch = runner.count
        _ = try await dao.fetchTxidsWithMemoContaining(searchTerm: "anything")
        XCTAssertEqual(runner.count, beforeSearch + 1)

        let beforeUnreconciled = runner.count
        _ = try await dao.unreconciledTxids()
        XCTAssertEqual(runner.count, beforeUnreconciled + 1)

        // Duplicated id: the chunk loop de-duplicates before it ever reaches the runner, so this
        // must still cost exactly one hop, not two.
        let beforeBatchOutputs = runner.count
        _ = try await dao.getTransactionOutputs(for: [first.rawID, first.rawID])
        XCTAssertEqual(runner.count, beforeBatchOutputs + 1)

        let beforeBlock = runner.count
        _ = try await dao.blockForHeight(1)
        XCTAssertEqual(runner.count, beforeBlock + 1)
    }
}
