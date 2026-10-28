//
//  CompactBlockProcessorMempoolHeightTests.swift
//  OfflineTests
//

import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// The mempool stream hands the processor `RawTransaction`s whose `height` is a `UInt64` the server chose.
/// The transactions are stored whatever it is, but the `foundTransactions` event carries the height as a
/// `BlockHeight`, so it is only sent for a height the SDK can use.
final class CompactBlockProcessorMempoolHeightTests: ZcashTestCase {
    private let rawID = Data(repeating: 0xAB, count: 32)

    func testMempoolTransactionAtAUsableHeightIsStoredAndAnnounced() async throws {
        let outcome = try await consumeMempool(heights: [UInt64(Int32.max)])

        XCTAssertEqual(outcome.storedTransactions, 1)
        XCTAssertEqual(outcome.announcedRanges, [BlockHeight(Int32.max)...BlockHeight(Int32.max)])
    }

    func testMempoolTransactionJustAboveInt32MaxIsStoredButNotAnnounced() async throws {
        let outcome = try await consumeMempool(heights: [UInt64(Int32.max) + 1])

        XCTAssertEqual(outcome.storedTransactions, 1)
        XCTAssertEqual(outcome.announcedRanges, [])
    }

    /// `UInt64.max` is the height lightwalletd uses for a transaction that was mined on a fork.
    func testMempoolTransactionAtUInt64MaxIsStoredButNotAnnounced() async throws {
        let outcome = try await consumeMempool(heights: [UInt64.max])

        XCTAssertEqual(outcome.storedTransactions, 1)
        XCTAssertEqual(outcome.announcedRanges, [])
    }

    func testAnUnusableHeightDoesNotStopLaterMempoolTransactions() async throws {
        let outcome = try await consumeMempool(heights: [UInt64.max, 0])

        XCTAssertEqual(outcome.storedTransactions, 2)
        XCTAssertEqual(outcome.announcedRanges, [0...0])
    }

    // The mined height a transaction is stored with is the one the server reports, as long as that is a
    // height the SDK can use. Any other height (the mempool's 0, the `UInt64.max` of a transaction mined on a
    // fork, or one only a broken or hostile server reports) stores it unmined.

    func testMempoolTransactionAtAUsableHeightIsStoredAsMined() async throws {
        let outcome = try await consumeMempool(heights: [UInt64(Int32.max), 663_188])

        XCTAssertEqual(outcome.storedMinedHeights, [UInt32(Int32.max), 663_188])
    }

    func testMempoolTransactionAtZeroIsStoredAsUnmined() async throws {
        let outcome = try await consumeMempool(heights: [0])

        XCTAssertEqual(outcome.storedMinedHeights, [nil])
    }

    func testMempoolTransactionAboveInt32MaxIsStoredAsUnmined() async throws {
        let heights = [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64(Int64.max) + 1, UInt64.max]

        let outcome = try await consumeMempool(heights: heights)

        XCTAssertEqual(outcome.storedMinedHeights, [UInt32?](repeating: nil, count: heights.count))
    }

    // MARK: - Fixture

    private struct Outcome {
        let storedTransactions: Int
        let storedMinedHeights: [UInt32?]
        let announcedRanges: [CompactBlockRange]
    }

    private final class StoredHeights: Sendable {
        private let heights = OSAllocatedUnfairLock(initialState: [UInt32?]())

        func append(_ height: UInt32?) {
            heights.withLock { $0.append(height) }
        }

        var all: [UInt32?] {
            heights.withLock { $0 }
        }
    }

    private final class Announcements: Sendable {
        private let ranges = OSAllocatedUnfairLock(initialState: [CompactBlockRange]())

        func append(_ range: CompactBlockRange) {
            ranges.withLock { $0.append(range) }
        }

        var all: [CompactBlockRange] {
            ranges.withLock { $0 }
        }
    }

    private func consumeMempool(heights: [UInt64]) async throws -> Outcome {
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        addTeardownBlock {
            await processor.stopAndWait()
            try await fixture.cleanup()
        }

        fixture.service.getMempoolStreamClosure = {
            AsyncThrowingStream { continuation in
                for height in heights {
                    var transaction = RawTransaction()
                    transaction.data = Data([0x04, 0x00, 0x00, 0x80])
                    transaction.height = height
                    continuation.yield(transaction)
                }
                continuation.finish()
            }
        }
        let storedHeights = StoredHeights()
        fixture.backend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { [rawID] _, minedHeight in
            storedHeights.append(minedHeight)
            return rawID
        }
        fixture.repository.findRawIDReturnValue = overview(rawID: rawID)

        let announcements = Announcements()
        await processor.updateEventClosure(identifier: "mempool-height") { event in
            if case let .foundTransactions(_, range) = event {
                announcements.append(range)
            }
        }

        try await processor.consumeMempoolStream()

        return Outcome(
            storedTransactions: fixture.backend.decryptAndStoreTransactionTxBytesMinedHeightCallsCount,
            storedMinedHeights: storedHeights.all,
            announcedRanges: announcements.all
        )
    }

    private func overview(rawID: Data) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: Zatoshi(0),
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: Data(),
            rawID: rawID,
            receivedNoteCount: 1,
            sentNoteCount: 0,
            value: Zatoshi(1_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }
}
