//
//  SlipstreamBalanceWalkTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// The local balances come from a full `get_wallet_summary` walk. `getAccountsBalances()` never needs it, and the poll
/// tick re-reads it only when something that can move the balances changed.
final class SlipstreamBalanceWalkTests: ZcashTestCase {
    private final class CountingWelding: ZcashRustBackendWeldingMock, LocalBalanceProviding, @unchecked Sendable {
        /// Non-empty, so a tick that dropped the local balances instead of carrying them forward would show.
        let localBalances: [AccountUUID: AccountBalance] = [
            TestsData.mockedAccountUUID: AccountBalance(
                saplingBalance: PoolBalance(
                    spendableValue: Zatoshi(500_000),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: .zero
                ),
                orchardBalance: .zero,
                unshielded: .zero
            )
        ]

        private let lock = NSLock()
        private var walks = 0

        var walkCount: Int {
            lock.withLock { walks }
        }

        func getWalletSummaryWithLocalBalances() async throws -> (summary: WalletSummary?, localBalances: [AccountUUID: AccountBalance]) {
            lock.withLock { walks += 1 }
            return (nil, localBalances)
        }

        func getLocalAccountBalances() async throws -> [AccountUUID: AccountBalance] {
            lock.withLock { walks += 1 }
            return localBalances
        }
    }

    private func summary() -> WalletSummary {
        WalletSummary(
            accountBalances: [:],
            chainTipHeight: 3_000_000,
            fullyScannedHeight: 2_999_990,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
    }

    func testGetAccountsBalancesDoesNotWalkTheWallet() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextWalletSummary(summary())
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 1000, tipFresh: 1))
        let welding = CountingWelding()
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)

        _ = try await sync.getAccountsBalances()

        XCTAssertEqual(welding.walkCount, 0)
    }

    func testUnchangedTicksReuseTheLocalBalancesUntilTheTransactionSetMoves() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextWalletSummary(summary())
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 1000, tipFresh: 1, txSetVersion: 1))
        let welding = CountingWelding()
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        // A tick that sees `txSetVersion` move also re-reads the transaction list, and the generated repository mock
        // force-unwraps an answer nobody stubbed, which would crash the run rather than fail it.
        let repository = try XCTUnwrap(mockContainer.resolve(TransactionRepository.self) as? TransactionRepositoryMock)
        repository.findOffsetLimitKindReturnValue = []
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        // Stops the poll loop on every way out, a throwing sleep included.
        defer { sync.stop() }
        // Three poll ticks (every 2 s) with nothing changed: one walk.
        try await Task.sleep(nanoseconds: 5_500_000_000)
        XCTAssertEqual(welding.walkCount, 1)
        // The two ticks that skipped the walk still published the first tick's local balances.
        XCTAssertEqual(sync.latestState.localAccountsBalances, welding.localBalances)

        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 1000, tipFresh: 1, txSetVersion: 2))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(welding.walkCount, 2)
    }
}
