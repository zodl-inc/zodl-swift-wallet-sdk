//
//  MigrationRunEstimateTests.swift
//  OfflineTests
//
//  Pure model math for `MigrationRunEstimate`: the per-run transaction-count arithmetic
//  (`Run.transactions`) and the cross-run totals -- including `totalActions` /
//  `totalKeystoneSigningSessions`, which are plain SUMS of each run's own precomputed (upstream
//  `MinRounds`-packed) fields, never a Swift-side re-derivation or re-packing across runs (a later
//  run's transactions spend notes an earlier run must mine first, so nothing can be pooled across
//  runs -- see `MigrationRunEstimate`'s doc). The count-based
//  `signingSessions(maxTransactionsPerSession:)` / `totalSigningSessions(...)` this file used to
//  pin were deleted along with their Swift-side ceiling math: `keystoneSigningSessions` is now a
//  verbatim passthrough of the engine's own optimal packing, so these tests assert passthrough, not
//  arithmetic. The FFI decode of the estimate is exercised through the real welding in
//  MigrationFFITests.swift.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class MigrationRunEstimateTests: XCTestCase {
    /// `transactions` is the run's preparation transactions plus one crossing transfer per
    /// funding note. `actions`/`keystoneSigningSessions` are unrelated inputs the run carries
    /// verbatim -- this fixture mirrors the type doc's own worked example: 6 preparations + 1
    /// transfer is 99 actions, one Keystone round over the 96-action budget, so 2 rounds.
    func testRunTransactionsIsPreparationPlusCrossings() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 1,
            preparationLayers: 2,
            preparationTransactions: 6,
            actions: 99,
            keystoneSigningSessions: 2
        )

        XCTAssertEqual(run.transactions, 7)
    }

    /// `actions` and `keystoneSigningSessions` are stored and read back verbatim -- the Swift side
    /// performs no packing of its own (see `MigrationRunEstimate`'s doc: the upstream engine's
    /// optimal `MinRounds` packing already computed them).
    func testRunActionsAndKeystoneSigningSessionsPassThroughVerbatim() {
        let run = MigrationRunEstimate.Run(
            migratable: Zatoshi(100),
            crossings: 3,
            preparationLayers: 2,
            preparationTransactions: 4,
            actions: 77,
            keystoneSigningSessions: 5
        )

        XCTAssertEqual(run.actions, 77)
        XCTAssertEqual(run.keystoneSigningSessions, 5)
    }

    /// The totals are plain sums across runs, and `totalTransactions` equals
    /// `totalPreparationTransactions + totalCrossings`.
    func testTotalsSumAcrossRuns() {
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(500),
                    crossings: 2,
                    preparationLayers: 1,
                    preparationTransactions: 3,
                    actions: 54, // 3 preparations * 16 + 2 crossings * 3
                    keystoneSigningSessions: 1
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(250),
                    crossings: 3,
                    preparationLayers: 2,
                    preparationTransactions: 2,
                    actions: 41, // 2 preparations * 16 + 3 crossings * 3
                    keystoneSigningSessions: 1
                )
            ],
            finalResidual: Zatoshi(7)
        )

        XCTAssertEqual(estimate.runCount, 2)
        XCTAssertEqual(estimate.totalMigratable, Zatoshi(750))
        XCTAssertEqual(estimate.totalCrossings, 5)
        XCTAssertEqual(estimate.totalPreparationLayers, 3)
        XCTAssertEqual(estimate.totalPreparationTransactions, 5)
        XCTAssertEqual(estimate.totalTransactions, 10)
        XCTAssertEqual(estimate.totalActions, 95)
        XCTAssertEqual(estimate.totalKeystoneSigningSessions, 2)
        XCTAssertEqual(estimate.finalResidual, Zatoshi(7))
    }

    /// The load-bearing session semantics: `totalKeystoneSigningSessions` is the SUM of each run's
    /// OWN precomputed `keystoneSigningSessions`, never a Swift-side re-pack across runs. This
    /// fixture's two runs together total only 95 actions (under the 96-action Keystone budget), so
    /// a repacking implementation could wrongly claim a single round; the real per-run sessions (2
    /// + 2) show neither run's leftover capacity is usable by the other, because a later run's
    /// inputs are not even minable until the earlier run has broadcast.
    func testTotalKeystoneSigningSessionsSumsPerRunSessionsWithoutRepacking() {
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(500),
                    crossings: 2,
                    preparationLayers: 1,
                    preparationTransactions: 3,
                    actions: 54,
                    keystoneSigningSessions: 2
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(250),
                    crossings: 3,
                    preparationLayers: 2,
                    preparationTransactions: 2,
                    actions: 41,
                    keystoneSigningSessions: 2
                )
            ],
            finalResidual: Zatoshi.zero
        )

        XCTAssertEqual(estimate.totalActions, 95)
        XCTAssertEqual(estimate.totalKeystoneSigningSessions, 4)
        XCTAssertNotEqual(
            estimate.totalKeystoneSigningSessions,
            1,
            "per-run sessions must not collapse into a pooled repack of the total action count"
        )
    }

    /// The zero-run estimate (nothing migrates) has all-zero totals -- a legitimate answer,
    /// mirroring the FFI's non-error empty marshaling.
    func testZeroRunEstimateHasAllZeroTotals() {
        let estimate = MigrationRunEstimate(runs: [], finalResidual: Zatoshi.zero)

        XCTAssertEqual(estimate.runCount, 0)
        XCTAssertEqual(estimate.totalMigratable, .zero)
        XCTAssertEqual(estimate.totalCrossings, 0)
        XCTAssertEqual(estimate.totalPreparationLayers, 0)
        XCTAssertEqual(estimate.totalPreparationTransactions, 0)
        XCTAssertEqual(estimate.totalTransactions, 0)
        XCTAssertEqual(estimate.totalActions, 0)
        XCTAssertEqual(estimate.totalKeystoneSigningSessions, 0)
        XCTAssertEqual(estimate.finalResidual, .zero)
    }
}
