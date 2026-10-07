//
//  ZcashTransactionStateTests.swift
//
//
//  Created by Francisco Gindre on 5/3/23.
//

import XCTest
import TestUtils
@testable import ZcashLightClientKit

final class ZcashTransactionStateTests: XCTestCase {
    func testExpiredUnminedState() throws {
        let currentHeight = 1010

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: true
            ),
            .expired
        )
    }

    func testConfirmationsBelowStaleConstantIsPending() {
        let currentHeight = 1010

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight,
                expiredUnmined: false
            ),
            .pending
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight - ZcashSDK.defaultStaleTolerance + 1,
                expiredUnmined: false
            ),
            .pending
        )

        XCTAssertNotEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight - ZcashSDK.defaultStaleTolerance,
                expiredUnmined: false
            ),
            .pending
        )
    }

    func testUnminedPastExpiryIsExpiredWhenColumnNotYetUpdated() {
        let currentHeight = 1_500_000

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: false,
                expiryHeight: currentHeight - 1
            ),
            .expired
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: false,
                expiryHeight: currentHeight
            ),
            .expired
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: false,
                expiryHeight: currentHeight + 100
            ),
            .pending
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: false,
                expiryHeight: nil
            ),
            .pending
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: nil,
                expiredUnmined: false
            ),
            .pending
        )
    }

    func testMinedHeightAboveOrEqualToStaleConstantIsConfirmed() {
        let currentHeight = 1010

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight - ZcashSDK.defaultStaleTolerance,
                expiredUnmined: false
            ),
            .confirmed
        )

        XCTAssertEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight - ZcashSDK.defaultStaleTolerance - 1,
                expiredUnmined: false
            ),
            .confirmed
        )

        XCTAssertNotEqual(
            ZcashTransaction.Overview.State(
                currentHeight: currentHeight,
                minedHeight: currentHeight - ZcashSDK.defaultStaleTolerance + 1,
                expiredUnmined: false
            ),
            .confirmed
        )
    }

    // MARK: - Trusted receives (ZIP 315)

    /// A trusted receive is confirmed at the transfer policy's trusted count, the depth at which
    /// its funds become spendable; an untrusted one still waits for the stale tolerance.
    func testTrustedReceiveConfirmsAtTrustedThreshold() {
        let tip = 1_000
        let trusted = Int(ConfirmationsPolicy.defaultTransferPolicy().trusted)
        let untrusted = ZcashSDK.defaultStaleTolerance

        let trustedReceive = { (mined: Int) in Self.overview(value: 50_000, minedHeight: mined, isTrusted: true) }
        XCTAssertEqual(trustedReceive(tip - trusted + 1).getState(for: tip), .pending)
        XCTAssertEqual(trustedReceive(tip - trusted).getState(for: tip), .confirmed)

        let untrustedReceive = { (mined: Int) in Self.overview(value: 50_000, minedHeight: mined, isTrusted: false) }
        XCTAssertEqual(untrustedReceive(tip - trusted).getState(for: tip), .pending)
        XCTAssertEqual(untrustedReceive(tip - untrusted + 1).getState(for: tip), .pending)
        XCTAssertEqual(untrustedReceive(tip - untrusted).getState(for: tip), .confirmed)
    }

    /// Trust relaxes only receives: a sent or shielding transaction keeps the stale tolerance
    /// even if it carries the trust flag.
    func testTrustDoesNotRelaxSentOrShieldingTransactions() {
        let tip = 1_000
        let trusted = Int(ConfirmationsPolicy.defaultTransferPolicy().trusted)

        let sent = Self.overview(value: -50_000, minedHeight: tip - trusted, isTrusted: true)
        XCTAssertEqual(sent.getState(for: tip), .pending)
        XCTAssertEqual(sent.requiredConfirmations, ZcashSDK.defaultStaleTolerance)

        let shielding = Self.overview(value: 50_000, minedHeight: tip - trusted, isTrusted: true, isShielding: true)
        XCTAssertEqual(shielding.getState(for: tip), .pending)
        XCTAssertEqual(shielding.requiredConfirmations, ZcashSDK.defaultStaleTolerance)
    }

    /// An unmined trusted receive is pending, not confirmed.
    func testUnminedTrustedReceiveIsPending() {
        XCTAssertEqual(Self.overview(value: 50_000, minedHeight: nil, isTrusted: true).getState(for: 1_000), .pending)
    }

    static func overview(
        value: Int64,
        minedHeight: BlockHeight?,
        isTrusted: Bool,
        isShielding: Bool = false
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: isShielding,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: nil,
            rawID: Data(repeating: 1, count: 32),
            receivedNoteCount: 1,
            sentNoteCount: 0,
            value: Zatoshi(value),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: isTrusted,
            zip318Kind: .notClassified
        )
    }
}
