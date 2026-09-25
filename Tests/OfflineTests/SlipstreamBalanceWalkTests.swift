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

    /// A host sends through `broadcaster`, which stores the transaction where the engine cannot see it. Unless the
    /// engine hears about it, the version the tick compares never moves, and the pre-send local balances stay on screen
    /// until the backstop re-reads them.
    func testASendThroughTheBroadcasterNotifiesTheEngine() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let rawID = Data(repeating: 0xAB, count: 32)
        let welding = ZcashRustBackendWeldingMock()
        welding.createProposedTransactionsProposalUskReturnValue = [rawID]
        welding.getTransactionTxIdReturnValue = TransactionData(txId: rawID, raw: Data([0x01, 0x02, 0x03]), expiryHeight: 123_456)
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        // Creation enriches its event from the transaction history. A failed read there is only logged, and the
        // generated repository mock would otherwise crash on an answer nobody stubbed.
        let repository = try XCTUnwrap(mockContainer.resolve(TransactionRepository.self) as? TransactionRepositoryMock)
        repository.findRawIDThrowableError = ZcashError.transactionRepositoryEntityNotFound

        let created = try await sync.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(created.map(\.txId), [rawID])
        // The notification does not hold up the send, so it is waited for rather than read straight away.
        let notified = await waitUntil {
            await engine.calls.contains("notifyTxChange")
        }
        XCTAssertTrue(notified, "a send through the broadcaster must tell the engine the transaction set changed")
    }
}
