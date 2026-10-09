//
//  IronwoodFFITests.swift
//  OfflineTests
//
//  Exercises the Ironwood (Orchard note-version V3 / NU6.3) receive/sync welding through the real
//  ZcashRustBackend: the `putIronwoodSubtreeRoots` FFI and the `AccountBalance.ironwoodBalance` model
//  field. Detecting actual Ironwood notes / non-zero balances needs a lightwalletd that serves Ironwood
//  compact blocks and an activated NU6.3 network (a documented integration gap), so that is not covered.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class IronwoodFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!

    override func setUp() {
        super.setUp()
        dbData = try! __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
    }

    /// `putIronwoodSubtreeRoots` with an empty root set is a no-op that exercises the new
    /// `zcashlc_put_ironwood_subtree_roots` symbol end-to-end through the welding without needing a
    /// populated Ironwood commitment tree.
    func testPutIronwoodSubtreeRootsWithEmptyRootsSucceeds() async throws {
        _ = try await rustBackend.initDataDb(seed: nil)
        try await rustBackend.putIronwoodSubtreeRoots(startIndex: 0, roots: [])
    }

    /// The public `AccountBalance.ironwoodBalance` field holds and totals an Ironwood pool balance, and
    /// is `.zero` on the zero balance.
    func testAccountBalanceExposesIronwoodBalance() {
        let ironwood = PoolBalance(
            spendableValue: Zatoshi(5),
            changePendingConfirmation: Zatoshi(2),
            valuePendingSpendability: Zatoshi(1)
        )
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: .zero,
            ironwoodBalance: ironwood,
            unshielded: .zero
        )

        XCTAssertEqual(balance.ironwoodBalance, ironwood)
        XCTAssertEqual(balance.ironwoodBalance.total(), Zatoshi(8))
        XCTAssertEqual(AccountBalance.zero.ironwoodBalance, .zero)
    }

    /// `PoolBalance.lockedValue` participates in `total()` — the FFI balance contract is that the
    /// sum of the fields is the account's total, and locked value (e.g. the Orchard migration
    /// residual locked via `lockMigrationResidual`) leaves `spendableValue` without leaving the
    /// account. Fixtures that predate locking default it to `.zero`.
    func testPoolBalanceTotalIncludesLockedValue() {
        let balance = PoolBalance(
            spendableValue: Zatoshi(5),
            changePendingConfirmation: Zatoshi(2),
            valuePendingSpendability: Zatoshi(1),
            lockedValue: Zatoshi(7)
        )

        XCTAssertEqual(balance.lockedValue, Zatoshi(7))
        XCTAssertEqual(balance.total(), Zatoshi(15))
        XCTAssertEqual(PoolBalance.zero.lockedValue, .zero)
    }

    /// Strengthens the "sum of the fields is the account's total" contract (see
    /// `testPoolBalanceTotalIncludesLockedValue`, which pins it per pool) at the ACCOUNT level:
    /// `AccountBalance`'s multi-pool convenience accessors sum locked value into
    /// `shieldedTotal()` across every shielded pool, without it also leaking into
    /// `shieldedSpendableValue`/`shieldedChangePendingConfirmation`/`shieldedValuePendingSpendability`
    /// (which would double-count it) or being dropped entirely (which would be a gap) — matching
    /// the upstream `AccountBalance`/`Balance` totals this SDK marshals from, which likewise
    /// include locked value in their totals.
    func testAccountBalanceShieldedTotalsIncludeLockedValueAcrossPools() {
        let sapling = PoolBalance(
            spendableValue: Zatoshi(10),
            changePendingConfirmation: Zatoshi(20),
            valuePendingSpendability: Zatoshi(30),
            lockedValue: Zatoshi(40)
        )
        let orchard = PoolBalance(
            spendableValue: Zatoshi(1),
            changePendingConfirmation: Zatoshi(2),
            valuePendingSpendability: Zatoshi(3),
            lockedValue: Zatoshi(4)
        )
        let ironwood = PoolBalance(
            spendableValue: Zatoshi(100),
            changePendingConfirmation: Zatoshi(200),
            valuePendingSpendability: Zatoshi(300),
            lockedValue: Zatoshi(400)
        )
        let balance = AccountBalance(
            saplingBalance: sapling,
            orchardBalance: orchard,
            ironwoodBalance: ironwood,
            unshielded: .zero
        )
        let totalLocked = sapling.lockedValue + orchard.lockedValue + ironwood.lockedValue

        // The account-wide contract: spendable + pending-change + pending-spendability + locked,
        // summed across every shielded pool, equals the shielded total exactly — no gap (locked
        // is included) and no double count (it is not ALSO folded into the other accessors).
        XCTAssertEqual(
            balance.shieldedSpendableValue
                + balance.shieldedChangePendingConfirmation
                + balance.shieldedValuePendingSpendability
                + totalLocked,
            balance.shieldedTotal()
        )
        // Spot-check the individual pieces so a future change that broke the identity above by
        // canceling out two compensating errors would still be caught.
        XCTAssertEqual(balance.shieldedSpendableValue, Zatoshi(111))
        XCTAssertEqual(balance.shieldedChangePendingConfirmation, Zatoshi(222))
        XCTAssertEqual(balance.shieldedValuePendingSpendability, Zatoshi(333))
        XCTAssertEqual(totalLocked, Zatoshi(444))
        XCTAssertEqual(balance.shieldedTotal(), Zatoshi(1_110))
    }
}
