//
//  LocalBalanceRefreshPolicyTests.swift
//  ZcashLightClientKitTests
//

import Foundation
import XCTest
@testable import ZcashLightClientKit

final class LocalBalanceRefreshPolicyTests: XCTestCase {
    private let start: TimeInterval = 1_000_000

    private func summary(scanned: BlockHeight) -> WalletSummary {
        WalletSummary(
            accountBalances: [:],
            chainTipHeight: 3_000_000,
            fullyScannedHeight: scanned,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
    }

    private func refreshedPolicy() -> LocalBalanceRefreshPolicy {
        var policy = LocalBalanceRefreshPolicy()
        policy.recordRefresh(txSetVersion: 7, visibleSummary: summary(scanned: 10), isRecovering: false, at: start)
        return policy
    }

    func testTheFirstTickRefreshes() {
        XCTAssertTrue(LocalBalanceRefreshPolicy().shouldRefresh(txSetVersion: 0, visibleSummary: nil, isRecovering: false, now: start))
    }

    func testNothingChangedWithinTheMaximumAgeSkips() {
        let policy = refreshedPolicy()
        let later = start + LocalBalanceRefreshPolicy.maximumAge - 0.5
        XCTAssertFalse(policy.shouldRefresh(txSetVersion: 7, visibleSummary: summary(scanned: 10), isRecovering: false, now: later))
    }

    func testANewTransactionSetRefreshes() {
        let policy = refreshedPolicy()
        XCTAssertTrue(
            policy.shouldRefresh(
                txSetVersion: 8,
                visibleSummary: summary(scanned: 10),
                isRecovering: false,
                now: start + 1
            )
        )
    }

    func testAChangedVisibleSummaryRefreshes() {
        let policy = refreshedPolicy()
        XCTAssertTrue(
            policy.shouldRefresh(
                txSetVersion: 7,
                visibleSummary: summary(scanned: 11),
                isRecovering: false,
                now: start + 1
            )
        )
    }

    func testARecoveryPhaseChangeRefreshes() {
        let policy = refreshedPolicy()
        XCTAssertTrue(
            policy.shouldRefresh(
                txSetVersion: 7,
                visibleSummary: summary(scanned: 10),
                isRecovering: true,
                now: start + 1
            )
        )
    }

    func testTheMaximumAgeForcesARefresh() {
        let policy = refreshedPolicy()
        let later = start + LocalBalanceRefreshPolicy.maximumAge
        XCTAssertTrue(policy.shouldRefresh(txSetVersion: 7, visibleSummary: summary(scanned: 10), isRecovering: false, now: later))
    }
}
