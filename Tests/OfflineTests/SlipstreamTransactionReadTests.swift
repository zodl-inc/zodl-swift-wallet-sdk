//
//  SlipstreamTransactionReadTests.swift
//  ZODLSwiftWalletSDK
//
//  MOB-2645: a send mined while the engine was stopped read as expired after the resume. The
//  chain tip had passed its expiry height, the block that mined it was not scanned yet, and
//  nothing re-read the stored rows once it was, because setting a mined height bumps no
//  `txSetVersion`. These pin the host's two answers: expiry is judged against the fully scanned
//  height, and the rows are read again when the scan advances past a read that still held an
//  unmined, unexpired transaction.
//

import XCTest
import TestUtils
@testable import ZODLSwiftWalletSDK

final class SlipstreamTransactionReadTests: XCTestCase {
    private static let expiryHeight = 1_000_040

    // MARK: - transactionsWithState

    func testUnminedSendStaysPendingWhileTheScanIsShortOfItsExpiry() {
        let tip = Self.expiryHeight + 500
        let states = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: nil)],
            currentHeight: tip,
            scannedHeight: Self.expiryHeight - 1
        )
        XCTAssertEqual(states.map(\.state), [.pending])
    }

    func testUnminedSendExpiresOnceTheScanReachesItsExpiry() {
        let tip = Self.expiryHeight + 500
        let states = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: nil)],
            currentHeight: tip,
            scannedHeight: Self.expiryHeight
        )
        XCTAssertEqual(states.map(\.state), [.expired])
    }

    func testMinedSendCountsConfirmationsFromTheTip() {
        let tip = Self.expiryHeight + 500
        let states = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: tip - ZcashSDK.defaultStaleTolerance)],
            currentHeight: tip,
            scannedHeight: 0
        )
        XCTAssertEqual(states.map(\.state), [.confirmed])
    }

    // MARK: - needsTransactionReadOnScanAdvance

    func testScanAdvancePastAReadWithAnUnminedRowTriggersARead() {
        XCTAssertTrue(SlipstreamSynchronizer.needsTransactionReadOnScanAdvance(
            lastReadHadUnexpiredUnmined: true,
            lastReadScannedHeight: 1_000_000,
            fullyScannedHeight: 1_000_001
        ))
    }

    func testScanAdvanceWithEveryRowMinedOrExpiredTriggersNoRead() {
        XCTAssertFalse(SlipstreamSynchronizer.needsTransactionReadOnScanAdvance(
            lastReadHadUnexpiredUnmined: false,
            lastReadScannedHeight: 1_000_000,
            fullyScannedHeight: 1_000_001
        ))
    }

    func testAnUnchangedOrLowerScannedHeightTriggersNoRead() {
        XCTAssertFalse(SlipstreamSynchronizer.needsTransactionReadOnScanAdvance(
            lastReadHadUnexpiredUnmined: true,
            lastReadScannedHeight: 1_000_000,
            fullyScannedHeight: 1_000_000
        ))
        XCTAssertFalse(SlipstreamSynchronizer.needsTransactionReadOnScanAdvance(
            lastReadHadUnexpiredUnmined: true,
            lastReadScannedHeight: 1_000_000,
            fullyScannedHeight: 999_999
        ))
    }

    // MARK: - hasUnexpiredUnmined

    func testAnUnminedPendingRowKeepsTheScanAdvanceReadArmed() {
        let rows = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: nil)],
            currentHeight: Self.expiryHeight + 500,
            scannedHeight: Self.expiryHeight - 1
        )
        XCTAssertTrue(SlipstreamSynchronizer.hasUnexpiredUnmined(rows))
    }

    func testAnExpiredRowDoesNotKeepTheScanAdvanceReadArmed() {
        let rows = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: nil)],
            currentHeight: Self.expiryHeight + 500,
            scannedHeight: Self.expiryHeight
        )
        XCTAssertFalse(SlipstreamSynchronizer.hasUnexpiredUnmined(rows))
    }

    func testAMinedRowDoesNotKeepTheScanAdvanceReadArmed() {
        let rows = SlipstreamSynchronizer.transactionsWithState(
            [Self.send(minedHeight: Self.expiryHeight - 30)],
            currentHeight: Self.expiryHeight + 500,
            scannedHeight: 0
        )
        XCTAssertFalse(SlipstreamSynchronizer.hasUnexpiredUnmined(rows))
    }

    private static func send(minedHeight: BlockHeight?) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
            blockTime: nil,
            expiryHeight: expiryHeight,
            fee: Zatoshi(10_000),
            index: nil,
            isShielding: false,
            hasChange: true,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: nil,
            rawID: Data(repeating: 1, count: 32),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-100_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 1,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }
}
