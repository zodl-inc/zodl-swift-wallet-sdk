//
//  MigrationFFITests.swift
//  OfflineTests
//
//  Exercises the Orchard -> Ironwood migration FFI marshaling and the empty-DB state machine
//  through the real ZcashRustBackend welding, against a freshly initialized, never-synced wallet
//  database (no network, no scanning). Complements MigrationLogicTests.swift (pure logic, mocked
//  welding) and OrchardMigrationCompositionTests.swift (actor composition, mocked welding): this is
//  the one place the SDK's committed migration FFI (rust/src/migration.rs, welded in
//  ZcashRustBackend) is exercised through the real libzcashlc, so a marshaling regression (wrong
//  sentinel, wrong error mapping, wrong tag) shows up here rather than only downstream.
//
//  Ported from the michal/MOB-1455-ironwood-migration-prototype-ffi branch (commit 86450d54) to the
//  committed API, then updated again when the SDK-side `MigrationState`/`migrationState(for:)` state
//  machine was replaced by the verbatim `migrationAdvanceStep(for:)` conduit:
//  `MigrationTransferResult.success` takes `txId:` (display-hex) rather than `txid:`, and there is no
//  `migrationInitializePostUpgrade` in the committed surface -- account creation goes through the
//  standard `createAccount` fixture pattern instead.
//
//  The balance-bearing paths (note splitting, proposing/signing transfers) need a seeded, synced
//  wallet with a real Orchard balance -- a documented integration gap, consistent with every other
//  file under OfflineTests (no network, no lightwalletd) -- so they are not covered here.
//

import XCTest
import libzcashlc
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class MigrationFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    var account: AccountUUID!
    var usk: UnifiedSpendingKey!

    override func setUp() async throws {
        try await super.setUp()

        dbData = try __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )

        let dbInit = try await rustBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        // A real, created account -- mirroring ZcashRustBackendTests/IronwoodFFITests -- rather than
        // a bare, never-registered AccountUUID: some migration welding calls read the wallet schema
        // (via the engine's `open_wallet`), so the fixture needs an actual `accounts` row to be
        // representative of real usage, even though this specific empty-DB state machine happens not
        // to depend on it for most of the assertions below (see the throwing tests further down).
        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .testnet)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        usk = try await rustBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await rustBackend.listAccounts()
        account = try XCTUnwrap(accounts.first?.id)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
        account = nil
        usk = nil
    }

    // MARK: - Empty-DB state machine

    /// A fresh wallet has no committed run at all, so there is nothing to advance: `nil`, not the
    /// terminal `.complete` case (which is reserved for a run that WAS stored).
    func testFreshWalletMigrationAdvanceStepIsNil() async throws {
        let step = try await rustBackend.migrationAdvanceStep(for: account)
        XCTAssertNil(step, "a fresh wallet with no stored run has nothing to advance")
    }

    func testFreshWalletMigrationProgressIsNil() async throws {
        let progress = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(progress)
    }

    func testFreshWalletHasNoOverdueTransfers() async throws {
        let hasOverdue = try await rustBackend.migrationHasOverdueTransfers(for: account, estimatedTip: nil)
        XCTAssertFalse(hasOverdue)
    }

    func testFreshWalletHasNoInvalidTransfers() async throws {
        let hasInvalid = try await rustBackend.migrationHasInvalidTransfers(for: account)
        XCTAssertFalse(hasInvalid)
    }

    /// No stored run marshals as an EMPTY container (`len == 0`), not an error -- see
    /// `zcashlc_migration_transaction_statuses`'s doc.
    func testFreshWalletHasNoTransactionStatuses() async throws {
        let statuses = try await rustBackend.migrationTransactionStatuses(for: account)
        XCTAssertTrue(statuses.isEmpty)
    }

    /// The delivery executor has no benign empty answer: on a wallet with no stored run there is
    /// no instruction to discharge, so naming a transaction is a caller error and throws rather
    /// than reporting "nothing due". A host learns there is nothing to broadcast from
    /// `migrationAdvanceStep`, never from this call.
    func testFreshWalletTakeBroadcastTransactionThrows() async throws {
        do {
            _ = try await rustBackend.migrationTakeBroadcastTransaction(id: 0, submissionServerHeight: 4_000_000, for: account)
            XCTFail("a wallet with no stored run has no transaction to serve")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code.rawValue, "ZRUST0111")
        }
    }

    /// The prove executor is safe to run against a wallet with no migration run at all: there is
    /// nothing to prove, which is the benign EMPTY OUTCOME — not a throw. This is what lets a host
    /// call it unconditionally from its sync path without first asking whether a migration exists.
    /// An EMPTY instruction is likewise empty: naming no transactions asks for no work, so a host
    /// need not special-case a batch it has already exhausted. Neither answer offers a preparation
    /// txid, so the handoff to `migrationTakePreparation` never fires.
    func testFreshWalletProveTransactionsProvesNothing() async throws {
        let named = try await rustBackend.migrationProveTransactions(ids: [0, 1], maxProofs: 8, for: account)
        XCTAssertEqual(named, MigrationProveOutcome(totalProved: 0, preparationTxids: []))

        let empty = try await rustBackend.migrationProveTransactions(ids: [], maxProofs: 8, for: account)
        XCTAssertEqual(empty, MigrationProveOutcome(totalProved: 0, preparationTxids: []))
    }

    /// The preparation accessor has no benign empty answer either: with no stored run there is no
    /// row a txid could name, so it throws rather than reporting "nothing to retrieve". A host
    /// only ever reaches it holding a txid `migrationProveTransactions` just handed out.
    func testFreshWalletTakePreparationThrows() async throws {
        do {
            _ = try await rustBackend.migrationTakePreparation(
                txid: Data(repeating: 0, count: 32),
                submissionServerHeight: 4_000_000,
                for: account
            )
            XCTFail("a wallet with no stored run has no preparation to serve")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code.rawValue, "ZRUST0149")
        }
    }

    /// A txid that is not 32 bytes is a CALLER BUG, named as such before the FFI is entered — the
    /// accessor's parameter is a raw internal-order txid, never a display-hex string.
    func testTakePreparationRejectsAMalformedTxid() async throws {
        do {
            _ = try await rustBackend.migrationTakePreparation(
                txid: Data(repeating: 0, count: 31),
                submissionServerHeight: 4_000_000,
                for: account
            )
            XCTFail("a 31-byte txid must be refused")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code.rawValue, "ZRUST0149")
            XCTAssertTrue(
                "\(error)".contains("31-byte txid"),
                "the refusal must name the offending length, got: \(error)"
            )
        }
    }

    /// `isNoteSplitNeeded` plans fresh against the live balance. On this never-synced fixture the
    /// engine reports "nothing to migrate" (no spendable Orchard notes), which the FFI maps to a
    /// benign `false` — the same answer the platform's "does anything remain" sequential-runs check
    /// consumes. (The v1 crate threw `NotSynced` here; the final engine plans over whatever the
    /// wallet database knows.)
    func testFreshUnsyncedWalletIsNoteSplitNeededIsFalse() async throws {
        let needed = try await rustBackend.migrationIsNoteSplitNeeded(for: account)
        XCTAssertFalse(needed, "a fresh wallet with nothing to migrate needs no note split")
    }

    /// Same root behavior as `isNoteSplitNeeded` above: with nothing to migrate there is no note
    /// split and therefore no residual — `nil`, not a throw. (The v1 crate threw `NotSynced` on
    /// this fixture.)
    func testFreshUnsyncedWalletResidualAfterMigrationIsNil() async throws {
        let residual = try await rustBackend.migrationResidualAfterMigration(for: account)
        XCTAssertNil(residual, "a fresh wallet with nothing to migrate has no residual")
    }

    // MARK: - Residual locking

    /// On a fresh wallet with no spendable Orchard notes, locking the residual locks nothing:
    /// `Zatoshi(0)` is the legitimate "nothing was spendable" answer, not an error. (The
    /// account-creation fixture gives the wallet a chain tip via the checkpoint birthday, which
    /// the lock path's note selection targets — the same reason `isNoteSplitNeeded` plans
    /// benignly above.)
    func testFreshWalletLockResidualLocksNothing() async throws {
        let locked = try await rustBackend.lockMigrationResidual(accountUUID: account)
        XCTAssertEqual(locked, Zatoshi(0))
    }

    /// The release half on a fresh wallet: no locks exist, so the cleared-output count is `0`.
    func testFreshWalletUnlockResidualClearsNothing() async throws {
        let unlocked = try await rustBackend.unlockMigrationResidual(accountUUID: account)
        XCTAssertEqual(unlocked, 0)
    }

    /// Lock-then-unlock on the empty wallet is a stable round trip (both legs `0`), pinning that
    /// a no-op lock leaves no stray lock state behind for unlock to find.
    func testLockThenUnlockResidualOnFreshWalletIsAZeroRoundTrip() async throws {
        let locked = try await rustBackend.lockMigrationResidual(accountUUID: account)
        XCTAssertEqual(locked, Zatoshi(0))

        let unlocked = try await rustBackend.unlockMigrationResidual(accountUUID: account)
        XCTAssertEqual(unlocked, 0)
    }

    // MARK: - Run-count estimate

    /// On a fresh wallet with nothing to migrate, the run-count estimate is the ZERO-RUN
    /// estimate — `runCount` 0 and no residual — a legitimate answer decoded from a non-null
    /// FFI struct, not an error: the estimate analog of the empty propose schedule (and of
    /// `isNoteSplitNeeded`'s benign `false` above).
    func testFreshWalletEstimateMigrationRunsIsZeroRuns() async throws {
        let estimate = try await rustBackend.estimateMigrationRuns(accountUUID: account)

        XCTAssertEqual(estimate.runCount, 0)
        XCTAssertTrue(estimate.runs.isEmpty)
        XCTAssertEqual(estimate.finalResidual, .zero)
        XCTAssertEqual(estimate.totalActions, 0)
        XCTAssertEqual(estimate.totalKeystoneSigningSessions, 0)
    }

    // MARK: - Invalid-state transitions

    /// A commit whose handle identifies no cached plan is the plan-stale contract: the engine
    /// signs exactly the plan the handle identifies (ZIP 318 draws fresh schedule randomness on
    /// every proposal, so plan identity is the consent boundary), so committing with nothing
    /// cached — here via the `0` "no plan" sentinel an empty or persisted schedule carries —
    /// must surface `migrationPlanStale`, the actionable "propose again" signal, not a generic
    /// failure.
    func testSignAndStoreWithoutAPreviewedPlanThrowsPlanStale() async throws {
        let emptySchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0, preparations: [])
        do {
            try await rustBackend.migrationSignAndStoreSchedule(emptySchedule, usk: usk, for: account)
            XCTFail("Expected committing without a previewed plan to throw")
        } catch ZcashError.migrationPlanStale {
            // expected
        } catch {
            XCTFail("Expected migrationPlanStale but got \(error)")
        }
    }

    /// The handle gate's second arm: even with a NONZERO handle — one a live proposal DTO could
    /// have carried before a process restart, or before a newer proposal replaced it — a commit
    /// finding no cached plan under that handle surfaces the same `migrationPlanStale` recovery
    /// signal. Nothing was ever cached in this fixture, so any handle value is "missing".
    func testSignAndStoreWithAStaleNonzeroHandleThrowsPlanStale() async throws {
        let staleSchedule = MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 0,
            proposalHandle: 0xDEAD_BEEF,
            preparations: []
        )
        do {
            try await rustBackend.migrationSignAndStoreSchedule(staleSchedule, usk: usk, for: account)
            XCTFail("Expected committing with a stale handle to throw")
        } catch ZcashError.migrationPlanStale {
            // expected
        } catch {
            XCTFail("Expected migrationPlanStale but got \(error)")
        }
    }

    // MARK: - The scheduled lane before NU7 (real FFI)
    //
    // `rustBackend` is born at the bundled testnet checkpoint at 4,500,000, past testnet's NU7
    // activation at 4,465,026, so the gate is open for it. These tests use a second, unfunded wallet
    // born at the bundled checkpoint at 4,000,000, for which the scheduled lane is closed until
    // 4,465,026 unless the backend's bypass holder is set.

    /// A call the NU7 gate guards, by the welding member it goes through, and the error code it
    /// fails with once it is through the gate on an unfunded wallet with no stored run (`nil` when
    /// it succeeds).
    private struct GatedWeldingCall {
        let name: String
        let codePastTheGate: ZcashErrorCode?
        let run: () async throws -> Void
    }

    /// A testnet wallet that holds nothing and was born at the bundled checkpoint at height
    /// 4,000,000, with the bypass holder its backend reads on every gated call.
    private struct PreActivationWallet {
        let backend: ZcashRustBackend
        let bypass: MigrationUpgradeGateBypass
        let account: AccountUUID
        let usk: UnifiedSpendingKey
    }

    /// Thrown when the wallet could not be set up; the failure itself was already reported.
    private struct PreActivationWalletUnavailable: Error {}

    private func makePreActivationTestnetWallet(in directory: URL) async throws -> PreActivationWallet {
        let bypass = MigrationUpgradeGateBypass()
        let backend = ZcashRustBackend.makeForTests(
            dbData: directory.appendingPathComponent("data.db"),
            fsBlockDbRoot: directory.appendingPathComponent("fs_cache", isDirectory: true),
            networkType: .testnet,
            migrationUpgradeGateBypass: bypass
        )
        let dbInit = try await backend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            throw PreActivationWalletUnavailable()
        }

        let treeState = CheckpointSourceFactory.fromBundle(for: .testnet).birthday(for: 4_000_000).treeState()
        let usk = try await backend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await backend.listAccounts()
        let account = try XCTUnwrap(accounts.first?.id)
        return PreActivationWallet(backend: backend, bypass: bypass, account: account, usk: usk)
    }

    /// The nine welding members that plan, build, sign, store or rebuild a scheduled run, called with
    /// arguments that make each fail wherever it goes past the gate: a proposal handle no plan was
    /// cached under, and no signed PCZTs. `migrationRefreshStaleTransfers` has a call site for each
    /// of its two lanes (a spending key, and none for an external signer), so it appears twice.
    private func gatedWeldingCalls(for wallet: PreActivationWallet) -> [GatedWeldingCall] {
        let backend = wallet.backend
        let account = wallet.account
        let usk = wallet.usk
        let noSchedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0, preparations: [])
        let noSplit = NoteSplitProposal(outputNotes: [], fee: Zatoshi(0), proposalHandle: 0)
        return [
            GatedWeldingCall(name: "migrationProposeTransfers", codePastTheGate: nil) {
                _ = try await backend.migrationProposeTransfers(for: account)
            },
            GatedWeldingCall(name: "migrationPrepareNoteSplit", codePastTheGate: nil) {
                _ = try await backend.migrationPrepareNoteSplit(for: account)
            },
            GatedWeldingCall(name: "migrationSignNoteSplit", codePastTheGate: .migrationPlanStale) {
                _ = try await backend.migrationSignNoteSplit(
                    proposal: noSplit,
                    usk: usk,
                    submissionServerHeight: 4_000_000,
                    for: account
                )
            },
            GatedWeldingCall(name: "migrationSignAndStoreSchedule", codePastTheGate: .migrationPlanStale) {
                try await backend.migrationSignAndStoreSchedule(noSchedule, usk: usk, for: account)
            },
            GatedWeldingCall(name: "migrationCreateUnsignedNoteSplitPczts", codePastTheGate: .migrationPlanStale) {
                _ = try await backend.migrationCreateUnsignedNoteSplitPczts(for: noSchedule, for: account)
            },
            GatedWeldingCall(name: "migrationCreateUnsignedTransferPczts", codePastTheGate: .migrationPlanStale) {
                _ = try await backend.migrationCreateUnsignedTransferPczts(for: noSchedule, for: account)
            },
            GatedWeldingCall(name: "migrationStoreSignedNoteSplitPczts", codePastTheGate: .rustMigrationStoreSignedNoteSplitPczt) {
                _ = try await backend.migrationStoreSignedNoteSplitPczts([], for: account)
            },
            GatedWeldingCall(name: "migrationStoreSignedSchedulePczts", codePastTheGate: .rustMigrationStoreSignedSchedulePczts) {
                try await backend.migrationStoreSignedSchedulePczts([], for: account)
            },
            GatedWeldingCall(name: "migrationRefreshStaleTransfers with a spending key", codePastTheGate: nil) {
                _ = try await backend.migrationRefreshStaleTransfers(usk: usk, for: account)
            },
            GatedWeldingCall(name: "migrationRefreshStaleTransfers without a spending key", codePastTheGate: nil) {
                _ = try await backend.migrationRefreshStaleTransfers(usk: nil, for: account)
            }
        ]
    }

    /// Before testnet's NU7 activation the scheduled lane starts nothing: a proposal is refused with
    /// the typed error that names the activation height. With the bypass the same call goes through.
    func testProposeIsRefusedBeforeTestnetActivationUnlessBypassed() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)

        do {
            _ = try await wallet.backend.migrationProposeTransfers(for: wallet.account)
            XCTFail("a proposal before NU7 activates must be refused")
        } catch ZcashError.migrationPausedUntilNetworkUpgrade(let activationHeight) {
            XCTAssertEqual(activationHeight, 4_465_026)
        } catch {
            XCTFail("Expected migrationPausedUntilNetworkUpgrade but got \(error)")
        }

        wallet.bypass.setBypassed(true)
        let schedule = try await wallet.backend.migrationProposeTransfers(for: wallet.account)
        XCTAssertTrue(schedule.transfers.isEmpty, "an unfunded wallet has nothing to migrate")
        XCTAssertEqual(schedule.proposalHandle, 0, "an empty schedule carries no plan handle")
    }

    /// Every gated welding member passes the bypass holder's current value on to the FFI and routes
    /// the refusal to the typed error: each is refused while the holder is off, and each goes through
    /// the gate to its own answer once it is on, then is refused again when it is turned back off.
    func testEveryGatedCallIsRefusedBeforeTestnetActivationUnlessBypassed() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)
        let calls = gatedWeldingCalls(for: wallet)

        func assertRefused() async {
            for call in calls {
                do {
                    try await call.run()
                    XCTFail("\(call.name) must be refused before NU7 activates")
                } catch ZcashError.migrationPausedUntilNetworkUpgrade(let activationHeight) {
                    XCTAssertEqual(activationHeight, 4_465_026, call.name)
                } catch {
                    XCTFail("\(call.name) failed with \(error) instead of the refusal")
                }
            }
        }

        await assertRefused()

        wallet.bypass.setBypassed(true)
        for call in calls {
            do {
                try await call.run()
                XCTAssertNil(call.codePastTheGate, "\(call.name) was expected to fail past the gate")
            } catch let error as ZcashError {
                XCTAssertNotEqual(
                    error.code,
                    ZcashErrorCode.migrationPausedUntilNetworkUpgrade,
                    "\(call.name) was refused with the bypass on"
                )
                XCTAssertEqual(error.code, call.codePastTheGate, "\(call.name) failed with \(error)")
            }
        }

        wallet.bypass.setBypassed(false)
        await assertRefused()
    }

    /// A restart before the activation is a success, not a failure: it reports the activation height
    /// a new scheduled plan waits for instead of planning. With the bypass it plans, as it always did.
    func testRestartBeforeTestnetActivationReportsTheUpgradeUnlessBypassed() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)

        let waiting = try await wallet.backend.migrationRestartStep(for: wallet.account)
        XCTAssertEqual(waiting, .cancelledUntilNetworkUpgrade(activationHeight: 4_465_026))

        wallet.bypass.setBypassed(true)
        let replanned = try await wallet.backend.migrationRestartStep(for: wallet.account)
        XCTAssertEqual(
            replanned,
            .replanned(MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0, preparations: [])),
            "an unfunded wallet plans the empty schedule"
        )
    }

    /// Past the activation the gate is open without the bypass: the fixture wallet is born at the
    /// 4,500,000 checkpoint, so its restart plans.
    func testRestartAfterTestnetActivationReplansWithoutTheBypass() async throws {
        let outcome = try await rustBackend.migrationRestartStep(for: account)

        XCTAssertEqual(
            outcome,
            .replanned(MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0, preparations: []))
        )
    }

    // MARK: - The submission check (real FFI)

    /// The note-split ceremony takes the submission server's height by value over the FFI, right
    /// after the gate. A height that is not one (the "unknown" -1) fails closed there, before any run
    /// is committed, and the rust layer's own words come back in the member's error: past the gate
    /// (the bypass is on) it is the height that is refused, not the upgrade, and the same call with
    /// a real height goes on to its plan-stale answer (see
    /// `testEveryGatedCallIsRefusedBeforeTestnetActivationUnlessBypassed`).
    func testSignNoteSplitFailsClosedWithoutASubmissionServerHeightOverRealFFI() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)
        wallet.bypass.setBypassed(true)
        let noSplit = NoteSplitProposal(outputNotes: [], fee: Zatoshi(0), proposalHandle: 0)

        do {
            _ = try await wallet.backend.migrationSignNoteSplit(
                proposal: noSplit,
                usk: wallet.usk,
                submissionServerHeight: -1,
                for: wallet.account
            )
            XCTFail("an unknown submission server height must fail closed")
        } catch ZcashError.rustMigrationSignNoteSplit(let message) {
            XCTAssertTrue(
                message.contains("the submission server's height is unknown"),
                "the refusal must say why, got: \(message)"
            )
        } catch {
            XCTFail("Expected rustMigrationSignNoteSplit but got \(error)")
        }
    }

    // MARK: - The availability read and the cancel-only call (real FFI)

    /// The availability follows the wallet's own chain tip through the gate's phases, with no
    /// account involved. On testnet, NU7 activates at 4,465,026. New scheduled work stays paused
    /// until tip 4,465,025, whose next block is the activation. The immediate lane stays available
    /// throughout, and the activation height is testnet's in both phases.
    func testAvailabilityDecodesEachPhase() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)

        let expectations: [(tip: Int32, expected: MigrationAvailability)] = [
            (
                4_000_000,
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            ),
            (
                4_464_976,
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            ),
            (
                4_464_977,
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            ),
            (
                4_465_024,
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            ),
            (
                4_465_025,
                MigrationAvailability(phase: .available, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            )
        ]
        for (tip, expected) in expectations {
            try await wallet.backend.updateChainTip(height: tip)

            let availability = try await wallet.backend.migrationAvailability(upgradeGateBypass: false)

            XCTAssertEqual(availability, expected, "tip \(tip)")
        }
    }

    /// The bypass the caller passes opens the gate at the heights that would close it, and the
    /// answer is the one the argument decides: a holder the backend carries for its own gated calls
    /// plays no part, because the availability read belongs to no account's backend and takes the
    /// host's value explicitly.
    func testAvailabilityFollowsTheBypass() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)
        let open = MigrationAvailability(phase: .available, activationHeight: 4_465_026, isImmediateLaneAvailable: true)

        for (tip, closed) in [
            (
                Int32(4_000_000),
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            ),
            (
                Int32(4_464_977),
                MigrationAvailability(phase: .pausedUntilNetworkUpgrade, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
            )
        ] {
            try await wallet.backend.updateChainTip(height: tip)

            let withTheBypass = try await wallet.backend.migrationAvailability(upgradeGateBypass: true)
            let withoutTheBypass = try await wallet.backend.migrationAvailability(upgradeGateBypass: false)
            XCTAssertEqual(withTheBypass, open, "tip \(tip)")
            XCTAssertEqual(withoutTheBypass, closed, "tip \(tip)")

            wallet.bypass.setBypassed(true)
            let heldByTheBackend = try await wallet.backend.migrationAvailability(upgradeGateBypass: false)
            wallet.bypass.setBypassed(false)
            XCTAssertEqual(heldByTheBackend, closed, "tip \(tip): the argument decides, not the backend's own holder")
        }
    }

    /// Past testnet's activation the gate is open without any bypass: the fixture wallet is born
    /// at the 4,500,000 checkpoint.
    func testAvailabilityIsOpenOnTestnetAfterActivation() async throws {
        let availability = try await rustBackend.migrationAvailability(upgradeGateBypass: false)

        XCTAssertEqual(
            availability,
            MigrationAvailability(phase: .available, activationHeight: 4_465_026, isImmediateLaneAvailable: true)
        )
    }

    /// A wallet that has never learned a chain tip cannot be judged, so the read fails with the
    /// availability error. With the bypass the gate is open at every height, and no tip is needed.
    func testAvailabilityWithoutAChainTipThrowsUnlessBypassed() async throws {
        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ZcashRustBackend.makeForTests(
            dbData: directory.appendingPathComponent("data.db"),
            fsBlockDbRoot: directory.appendingPathComponent("fs_cache", isDirectory: true),
            networkType: .testnet
        )
        let dbInit = try await backend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            return XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
        }

        do {
            _ = try await backend.migrationAvailability(upgradeGateBypass: false)
            XCTFail("a wallet with no chain tip has no phase")
        } catch ZcashError.rustMigrationAvailability(let message) {
            XCTAssertTrue(message.contains("sync first"), "unexpected message: \(message)")
        } catch {
            XCTFail("Expected rustMigrationAvailability but got \(error)")
        }

        let bypassed = try await backend.migrationAvailability(upgradeGateBypass: true)
        XCTAssertEqual(bypassed, MigrationAvailability(phase: .available, activationHeight: 4_465_026, isImmediateLaneAvailable: true))
    }

    /// The FFI struct decodes to the model: each phase constant to its case, and the `-1` sentinel
    /// of a network with no NU7 activation height to a `nil` height. A phase the header does not
    /// name is a malformed answer, not a guess.
    func testAvailabilityMappingDecodesEachPhaseAndTheNoActivationSentinel() throws {
        let cases: [(phase: Int32, expected: MigrationAvailability.Phase)] = [
            (ZCASHLC_MIGRATION_AVAILABLE, .available),
            (ZCASHLC_MIGRATION_PAUSED_UNTIL_UPGRADE, .pausedUntilNetworkUpgrade)
        ]
        for (phase, expected) in cases {
            let ffi = FfiMigrationAvailability(phase: UInt32(phase), activation_height: 3_543_405, immediate_available: false)

            let decoded = try XCTUnwrap(ffi.unsafeToMigrationAvailability())

            XCTAssertEqual(decoded.phase, expected)
            XCTAssertEqual(decoded.activationHeight, 3_543_405)
            XCTAssertFalse(decoded.isImmediateLaneAvailable, "the flag is the FFI's, not derived from the phase")
        }

        let noNU7 = FfiMigrationAvailability(phase: UInt32(ZCASHLC_MIGRATION_AVAILABLE), activation_height: -1, immediate_available: true)
        XCTAssertEqual(
            noNU7.unsafeToMigrationAvailability(),
            MigrationAvailability(phase: .available, activationHeight: nil, isImmediateLaneAvailable: true)
        )

        XCTAssertNil(FfiMigrationAvailability(phase: 99, activation_height: 3_543_405, immediate_available: true).unsafeToMigrationAvailability())
    }

    /// With no run stored there is nothing to end: the cancel succeeds and stores nothing, so there
    /// is still no run to advance. The upgrade gate stops what starts a run, never what ends one,
    /// so it succeeds throughout the preactivation pause, with no bypass.
    func testCancelRunWithoutARunSucceeds() async throws {
        try await rustBackend.migrationCancelRun(for: account)
        let pastActivationStep = try await rustBackend.migrationAdvanceStep(for: account)
        XCTAssertNil(pastActivationStep, "cancelling nothing stores nothing")

        let directory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await makePreActivationTestnetWallet(in: directory)
        for tip in [Int32(4_000_000), Int32(4_464_977)] {
            try await wallet.backend.updateChainTip(height: tip)

            try await wallet.backend.migrationCancelRun(for: wallet.account)

            let step = try await wallet.backend.migrationAdvanceStep(for: wallet.account)
            XCTAssertNil(step, "tip \(tip): cancelling nothing stores nothing")
        }
    }

    /// A cancel that fails reaches the caller as the cancel's own error, with the rust layer's
    /// message: an account the wallet does not know has no run store to open.
    func testCancelRunForAnUnknownAccountThrowsTheCancelError() async throws {
        let stranger = AccountUUID(id: [UInt8](repeating: 0x07, count: 16))

        do {
            try await rustBackend.migrationCancelRun(for: stranger)
            XCTFail("an unknown account has no run to cancel")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code, ZcashErrorCode.rustMigrationCancelRun)
            XCTAssertEqual(error.code.rawValue, "ZRUST0161")
        }
    }

    /// Recording a SUCCESS against a transfer id with no active migration run throws: that path
    /// must load the stored run to mark the transfer broadcast, and there is none. A deterministic,
    /// sync-independent throw — it never touches the wallet schema.
    ///
    /// (Before transfer ids became `UInt32` this test passed `.networkError` with an unparseable
    /// string id, so what threw was the id decode, not the missing run. `.networkError` records
    /// nothing by design — see `testRecordTransferResultForANetworkErrorSucceedsWithNoActiveRun`
    /// — so it can never exercise this contract.)
    func testRecordTransferResultWithNoActiveRunThrows() async throws {
        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: 4_294_967_295,
                result: MigrationTransferResult.success(txId: String(repeating: "ab", count: 32)),
                for: account
            )
            XCTFail("Expected recording a success with no active migration run to throw")
        } catch ZcashError.rustMigrationRecordTransferResult {
            // expected
        } catch {
            XCTFail("Expected rustMigrationRecordTransferResult but got \(error)")
        }
    }

    /// A network error is a Swift-level signal for the caller's own retry policy: the native side
    /// records nothing and reports success, even with no active run. Documents the asymmetry the
    /// test above depends on.
    func testRecordTransferResultForANetworkErrorSucceedsWithNoActiveRun() async throws {
        try await rustBackend.migrationRecordTransferResult(
            transferId: 4_294_967_295,
            result: MigrationTransferResult.networkError(retryable: true),
            for: account
        )
    }

    // MARK: - Immediate migration (send-max lane)

    /// MOB-1513: `migrationRecordImmediateRun` validates `txid.count == 32` in Swift before making
    /// any FFI call (the C side reads it as a fixed 32-byte buffer with no length parameter, so this
    /// guard is load-bearing, not defensive-only). A short txid must never reach the FFI.
    func testMigrationRecordImmediateRunRejectsNon32ByteTxid() async throws {
        do {
            try await rustBackend.migrationRecordImmediateRun(txid: Data([0x01, 0x02, 0x03]), for: account)
            XCTFail("Expected a non-32-byte txid to be rejected before any FFI call")
        } catch ZcashError.migrationRecordImmediateRunInvalidTxId(let length) {
            XCTAssertEqual(length, 3)
        } catch {
            XCTFail("Expected migrationRecordImmediateRunInvalidTxId but got \(error)")
        }
    }

    /// This fixture's `createAccount` call installs a checkpoint `treeState` (mirroring every other
    /// test in this file), which already gives `chain_height()` a height to report -- so unlike the
    /// balance-bearing paths, recording an immediate run does NOT require a real sync to succeed
    /// (the documented "no chain tip yet" failure mode applies before any account has been created
    /// at all, which this offline suite's setup always provides). This exercises the real FFI
    /// marshaling end-to-end (db/account bytes, the fixed 32-byte txid buffer, the boolean success
    /// mapping) and `migrationProgress`'s read reading it straight back: an unmined, unrecognized
    /// txid falls into the documented fallback-pending bucket (the default expiry delta after
    /// `recorded_at_height`, 120 blocks here because this fixture is testnet at its 4,500,000
    /// checkpoint, past NU7; not yet elapsed), so progress reports `0 of 1`, flagged `isImmediate`,
    /// not `nil`. The immediate lane is entirely outside the migration engine (see
    /// `MigrationProgress.isImmediate`'s doc), so `migrationAdvanceStep` -- which answers for the
    /// STORED (engine-tracked) run only -- must stay `nil` throughout: the two surfaces are
    /// orthogonal.
    func testMigrationRecordImmediateRunThenMigrationProgressReportsInProgress() async throws {
        let txid = Data(repeating: 0xAB, count: 32)

        try await rustBackend.migrationRecordImmediateRun(txid: txid, for: account)

        let progress = try await rustBackend.migrationProgress(for: account)
        let unwrappedProgress = try XCTUnwrap(
            progress,
            "an unmined recorded immediate run must report a live progress snapshot, not nil"
        )
        XCTAssertEqual(unwrappedProgress.completedTransfers, 0)
        XCTAssertEqual(unwrappedProgress.totalTransfers, 1)
        XCTAssertTrue(
            unwrappedProgress.isImmediate,
            "a recorded immediate-lane run must map to isImmediate = true through the real FFI"
        )

        let step = try await rustBackend.migrationAdvanceStep(for: account)
        XCTAssertNil(step, "the immediate lane records no engine-tracked run, so there is still nothing to advance")
    }

    /// MOB-1513 R2: the FFI→model mapping (`FfiMigrationProgress.unsafeToMigrationProgress()`) must
    /// copy `is_immediate` straight through, so the immediate lane's quiet-aftermath flag survives
    /// the boundary and the model's defaulted `isImmediate` can never silently swallow it. Both
    /// paths are exercised on the mapping directly (constructing the `#[repr(C)]` struct) because an
    /// engine-tracked InProgress — the only real-FFI `is_immediate == false` source — needs a
    /// seeded, synced Orchard balance this offline suite does not have. The `true` path is
    /// additionally covered end-to-end over the real FFI by
    /// `testMigrationRecordImmediateRunThenMigrationProgressReportsInProgress` above.
    func testMigrationProgressMappingCarriesIsImmediateBothWays() throws {
        let immediate = FfiMigrationProgress(
            is_present: true,
            completed_transfers: 0,
            total_transfers: 1,
            remaining_orchard_value: 0,
            next_transfer_ready_at_height: -1,
            is_immediate: true
        )
        let immediateProgress = try XCTUnwrap(immediate.unsafeToMigrationProgress())
        XCTAssertTrue(immediateProgress.isImmediate, "an immediate-lane FFI struct must map to isImmediate = true")

        let engine = FfiMigrationProgress(
            is_present: true,
            completed_transfers: 1,
            total_transfers: 3,
            remaining_orchard_value: 12_345,
            next_transfer_ready_at_height: 100,
            is_immediate: false
        )
        let engineProgress = try XCTUnwrap(engine.unsafeToMigrationProgress())
        XCTAssertFalse(engineProgress.isImmediate, "an engine-tracked FFI struct must map to isImmediate = false")
    }

    // MARK: - Ironwood activation height

    /// Verified against the pinned rust source directly: zcash_protocol 0.10.0 @ e0e1277
    /// (components/zcash_protocol/src/consensus.rs), `impl Parameters for MainNetwork` ->
    /// `NetworkUpgrade::Nu6_3 => Some(BlockHeight(3_428_143))`. Also asserts the public
    /// `OrchardMigration.ironwoodActivationHeight(for:)` accessor delegates to the same value, so
    /// the public surface -- not just the internal backend -- is test-covered.
    func testIronwoodActivationHeightMainnet() throws {
        let height = try XCTUnwrap(ZcashRustBackend.ironwoodActivationHeight(networkType: .mainnet))
        XCTAssertEqual(height, 3_428_143)

        let publicHeight = try XCTUnwrap(OrchardMigration.ironwoodActivationHeight(for: .mainnet))
        XCTAssertEqual(publicHeight, height)

        // The public `ZcashNetwork.ironwoodActivationHeight` extension (the app-facing home that
        // replaces hosts' hardcoded NU heights) resolves to the same value.
        let networkHeight = try XCTUnwrap(ZcashNetworkBuilder.network(for: .mainnet).ironwoodActivationHeight)
        XCTAssertEqual(networkHeight, height)
    }

    /// Verified against the pinned rust source directly: zcash_protocol 0.10.0 @ e0e1277
    /// (components/zcash_protocol/src/consensus.rs), `impl Parameters for TestNetwork` ->
    /// `NetworkUpgrade::Nu6_3 => Some(BlockHeight(4_134_000))`. Matches the brief's expectation
    /// exactly; no discrepancy to flag.
    func testIronwoodActivationHeightTestnet() throws {
        let height = try XCTUnwrap(ZcashRustBackend.ironwoodActivationHeight(networkType: .testnet))
        XCTAssertEqual(height, 4_134_000)

        // The public `ZcashNetwork.ironwoodActivationHeight` extension resolves to the same value.
        let networkHeight = try XCTUnwrap(ZcashNetworkBuilder.network(for: .testnet).ironwoodActivationHeight)
        XCTAssertEqual(networkHeight, height)
    }

    /// The public `ZcashNetwork.ironwoodActivationHeight` extension on a custom (regtest-slot)
    /// network resolves through the same FFI path and reports `nil` -- the documented "no known
    /// Ironwood activation for that network" case: the regtest network id carries no fixed NU6.3
    /// height. Registers the same idempotent custom heights as
    /// `testOrchardMigrationRegistersCustomActivationHeightsOnInit` /
    /// `RegtestActivationHeightsTests.testRegtestConsensusBranchIdReflectsCustomActivationHeights`
    /// (`zcashlc_set_custom_network` is process-global and a conflicting re-registration asserts, so
    /// identical values keep every registrant idempotent regardless of run order).
    func testIronwoodActivationHeightForCustomNetworkIsNil() {
        let activationHeights = NetworkActivationHeights(
            overwinter: 1,
            sapling: 1,
            blossom: 1,
            heartwood: 1,
            canopy: 1,
            nu5: 100,
            nu6: 200
        )
        _ = ZcashRustBackend.setCustomNetwork(base: .regtest, activationHeights)
        let network = ZcashNetworkBuilder.custom(base: .mainnet, activationHeights: activationHeights)

        XCTAssertNil(network.ironwoodActivationHeight)
    }

    // MARK: - Marshaling determinism

    func testMigrationProgressNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationProgress(for: account)
        let second = try await rustBackend.migrationProgress(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    func testMigrationTransactionStatusesEmptyIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationTransactionStatuses(for: account)
        let second = try await rustBackend.migrationTransactionStatuses(for: account)
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    /// The executor is idempotent on a wallet with nothing to prove: no accumulating side effect,
    /// so a host may call it on every scan pass.
    func testMigrationProveTransactionsIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationProveTransactions(ids: [0], maxProofs: 8, for: account)
        let second = try await rustBackend.migrationProveTransactions(ids: [0], maxProofs: 8, for: account)
        XCTAssertEqual(first, MigrationProveOutcome(totalProved: 0, preparationTxids: []))
        XCTAssertEqual(first, second)
    }

    func testMigrationResidualAfterMigrationNilIsStableAcrossRepeatedCalls() async throws {
        let first = try await rustBackend.migrationResidualAfterMigration(for: account)
        let second = try await rustBackend.migrationResidualAfterMigration(for: account)
        XCTAssertNil(first)
        XCTAssertEqual(first, second)
    }

    /// Rebuild-on-expiry is live in the engine: on a fresh wallet with NO stored migration run
    /// there is nothing to refresh and nothing to re-display, so `refreshStaleTransfers` returns
    /// the legitimate EMPTY schedule — not a throw. (The call returns the run's stored schedule
    /// so a host can re-display and echo the post-refresh truth; with no run stored that truth
    /// is empty.) The in-process lane (a real spending key selects sign-anew rebuilds).
    func testRefreshStaleTransfersOnFreshWalletReturnsAnEmptyScheduleWithSpendingKey() async throws {
        let refreshed = try await rustBackend.migrationRefreshStaleTransfers(usk: usk, for: account)
        XCTAssertTrue(refreshed.transfers.isEmpty)
        XCTAssertEqual(refreshed.estimatedDurationHours, 0)
    }

    /// The external-signer lane of the same nothing-to-refresh answer: a `nil` spending key
    /// (NULL over the FFI) selects the unsigned rebuild and must be a legitimate input — an
    /// imported hardware-wallet account has no in-process spend authority — so it too returns
    /// the empty schedule on a fresh wallet rather than throwing.
    func testRefreshStaleTransfersOnFreshWalletReturnsAnEmptyScheduleWithNilSpendingKey() async throws {
        let refreshed = try await rustBackend.migrationRefreshStaleTransfers(usk: nil, for: account)
        XCTAssertTrue(refreshed.transfers.isEmpty)
        XCTAssertEqual(refreshed.estimatedDurationHours, 0)
    }

    /// Guards against last-error-channel pollution across calls: a throwing call must not corrupt
    /// the next legitimate `false` answer from an ambiguous-bool-sentinel call
    /// (`hasOverdueTransfers`, which reads only the empty migration store on a fresh db)
    /// sandwiched around it. The throwing predecessor is `recordTransferResult` with no active
    /// run — deterministic and sync-independent (see
    /// `testRecordTransferResultWithNoActiveRunThrows`) — now that `refreshStaleTransfers`
    /// legitimately returns the empty schedule on this fixture instead of throwing.
    func testHasOverdueTransfersIsUnaffectedByAPrecedingThrowingMigrationCall() async throws {
        let before = try await rustBackend.migrationHasOverdueTransfers(for: account, estimatedTip: nil)
        XCTAssertFalse(before)

        do {
            try await rustBackend.migrationRecordTransferResult(
                transferId: 4_294_967_295,
                result: MigrationTransferResult.success(txId: String(repeating: "ab", count: 32)),
                for: account
            )
            XCTFail("Expected recording a result with no active migration run to throw")
        } catch {
            // Expected; the specific case is asserted by
            // testRecordTransferResultWithNoActiveRunThrows above.
        }

        let after = try await rustBackend.migrationHasOverdueTransfers(for: account, estimatedTip: nil)
        XCTAssertFalse(after)
        XCTAssertEqual(before, after)
    }

    /// Complements the hygiene test above: that one covers a predecessor that itself throws (and so
    /// consumes/clears the FFI's last-error via `lastErrorMessage` on its own throw path). This one
    /// covers a predecessor that sets a last-error and returns *without ever throwing* --
    /// `ironwoodActivationHeight` mapping the FFI's `-1` sentinel to `nil` for a network id outside
    /// `{testnet, mainnet}` (`.regtest`) leaves that error unconsumed in the (thread-local) FFI error
    /// channel, pre-fix. A bool-sentinel migration call on a healthy, freshly initialized db must not
    /// misfire on it merely because it happens to run on the same thread afterward.
    func testABoolSentinelMigrationCallIsUnaffectedByAPrecedingUnconsumedIronwoodActivationHeightError() async throws {
        let staleProducerResult = ZcashRustBackend.ironwoodActivationHeight(networkType: .regtest)
        XCTAssertNil(staleProducerResult, "regtest has no fixed NU6.3 height; `-1` must still map to nil")

        let hasOverdue = try await rustBackend.migrationHasOverdueTransfers(for: account, estimatedTip: nil)
        XCTAssertFalse(hasOverdue)
    }

    // MARK: - Transaction status decode mapping
    //
    // `FfiMigrationTransactionStatus`'s raw C fields fold into `MigrationTransactionStatus`'s
    // enums; these tests construct the `#[repr(C)]` struct directly (mirroring
    // `testMigrationProgressMappingCarriesIsImmediateBothWays` above) and exercise the internal
    // `unsafeToMigrationTransactionStatus()` decode function itself. The balance-bearing engine
    // state a real committed run needs is out of reach for this offline suite (see the file
    // header), so the field-by-field mapping -- including the malformed-discriminant fallback --
    // is exercised here instead of over the real FFI.

    func testDecodeMapsPreparationKind() throws {
        let ffi = makeStatus(isTransfer: false, prepLayer: 2, prepIndex: 1, crossing: -1)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.kind, .preparation(layer: 2, index: 1))
    }

    func testDecodeMapsTransferKind() throws {
        let ffi = makeStatus(isTransfer: true, prepLayer: -1, prepIndex: -1, crossing: 5)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.kind, .transfer(crossing: 5))
    }

    func testDecodeMapsAwaitingSignatureSignedAndProvedStates() throws {
        let awaitingSignature = try XCTUnwrap(makeStatus(state: 0).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(awaitingSignature.state, .awaitingSignature)

        let signed = try XCTUnwrap(makeStatus(state: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(signed.state, .signed)

        let proved = try XCTUnwrap(makeStatus(state: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(proved.state, .proved)
    }

    /// `has_txid` is engine-verbatim -- true only while `state == 3` (Broadcast) -- so the folded
    /// `.broadcast` case carries the txid straight through.
    func testDecodeMapsBroadcastStateWithItsTxid() throws {
        let bytes = (0 ..< 32).map { UInt8($0) }
        let ffi = makeStatus(state: 3, txid: Self.tuple32(bytes), hasTxid: true)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.state, .broadcast(txid: Data(bytes)))
    }

    /// A mined row's txid is NOT carried by the engine's state model (`has_txid` drops back to
    /// `false` once mined) -- `.mined` carries only the height, matching the model's own doc.
    func testDecodeMapsMinedStateWithItsHeight() throws {
        let ffi = makeStatus(state: 4, minedHeight: 3_500_000)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.state, .mined(height: 3_500_000))
    }

    func testDecodeMapsExpiryHeightZeroSentinelToNil() throws {
        let ffi = makeStatus(expiryHeight: 0)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertNil(decoded.expiryHeight, "the engine's 0 sentinel means 'never expires'")
    }

    func testDecodeMapsANonzeroExpiryHeightThrough() throws {
        let ffi = makeStatus(expiryHeight: 3_100_000)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.expiryHeight, 3_100_000)
    }

    func testDecodeMapsIdScheduledHeightAndReadyStraightThrough() throws {
        let ffi = makeStatus(id: 42, scheduledHeight: 3_050_000, ready: false)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.scheduledHeight, 3_050_000)
        XCTAssertFalse(decoded.isReady)
    }

    func testDecodeMapsEachNextActionCase() throws {
        let none = try XCTUnwrap(makeStatus(action: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(none.nextAction)

        let prove = try XCTUnwrap(makeStatus(action: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(prove.nextAction, .prove)

        let broadcast = try XCTUnwrap(makeStatus(action: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(broadcast.nextAction, .broadcast)
    }

    func testDecodeMapsEachBlockedOnCase() throws {
        let none = try XCTUnwrap(makeStatus(blockedOn: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(none.blockedOn)

        let dependencies = try XCTUnwrap(makeStatus(blockedOn: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(dependencies.blockedOn, .dependencies)

        let schedule = try XCTUnwrap(makeStatus(blockedOn: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(schedule.blockedOn, .schedule)

        let anchorBoundary = try XCTUnwrap(makeStatus(blockedOn: 3).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(anchorBoundary.blockedOn, .anchorBoundary)

        let signature = try XCTUnwrap(makeStatus(blockedOn: 4).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(signature.blockedOn, .signature)

        let expired = try XCTUnwrap(makeStatus(blockedOn: 5).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(expired.blockedOn, .expired)

        let invalid = try XCTUnwrap(makeStatus(blockedOn: 6).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(invalid.blockedOn, .invalid)
    }

    /// The Invalid lifecycle state (discriminant 5) folds `invalid_reason` into
    /// `.invalid(reason:)` the way Mined folds its height: `0` = fundingSpent,
    /// `1` = rejectedInvalid, `2` = rejectedExpired.
    func testDecodeMapsInvalidStateWithEachReason() throws {
        let fundingSpent = try XCTUnwrap(makeStatus(state: 5, invalidReason: 0).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(fundingSpent.state, .invalid(reason: .fundingSpent))

        let rejectedInvalid = try XCTUnwrap(makeStatus(state: 5, invalidReason: 1).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(rejectedInvalid.state, .invalid(reason: .rejectedInvalid))

        let rejectedExpired = try XCTUnwrap(makeStatus(state: 5, invalidReason: 2).unsafeToMigrationTransactionStatus())
        XCTAssertEqual(rejectedExpired.state, .invalid(reason: .rejectedExpired))
    }

    /// An Invalid row without its reason payload (`-1` — the "not invalid" sentinel) or with an
    /// out-of-range one violates the FFI contract: decode treats it as malformed rather than
    /// inventing a reason, mirroring the broadcast-without-txid rule below.
    func testDecodeReturnsNilForAnInvalidStateWithoutAValidReason() {
        XCTAssertNil(makeStatus(state: 5, invalidReason: -1).unsafeToMigrationTransactionStatus())
        XCTAssertNil(makeStatus(state: 5, invalidReason: 99).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAnOutOfRangeState() {
        XCTAssertNil(makeStatus(state: 99).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAnOutOfRangeNextAction() {
        XCTAssertNil(makeStatus(action: 99).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAnOutOfRangeBlockedOn() {
        XCTAssertNil(makeStatus(blockedOn: 99).unsafeToMigrationTransactionStatus())
    }

    /// The engine's contract ties `has_txid` to `state == 3` (Broadcast) -- see
    /// `FfiMigrationTransactionStatus`'s doc. A broadcast row without a txid violates that
    /// contract, so decode treats it as malformed rather than silently folding in a fake empty
    /// txid.
    func testDecodeReturnsNilForABroadcastStateWithoutATxid() {
        XCTAssertNil(makeStatus(state: 3, hasTxid: false).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAMinedStateWithNoMinedHeight() {
        XCTAssertNil(makeStatus(state: 4, minedHeight: -1).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForAPreparationRowWithANegativeLayerOrIndex() {
        XCTAssertNil(makeStatus(isTransfer: false, prepLayer: -1, prepIndex: 0).unsafeToMigrationTransactionStatus())
        XCTAssertNil(makeStatus(isTransfer: false, prepLayer: 0, prepIndex: -1).unsafeToMigrationTransactionStatus())
    }

    func testDecodeReturnsNilForATransferRowWithANegativeCrossing() {
        XCTAssertNil(makeStatus(isTransfer: true, crossing: -1).unsafeToMigrationTransactionStatus())
    }

    /// Exercises `FfiMigrationTransactionStatuses.unsafeToMigrationTransactionStatuses()` (the
    /// container decode) directly: the engine's own `transaction_statuses` order (dependency
    /// order: preparation layers first, then transfers) must survive the marshal untouched.
    func testDecodeContainerMapsMultipleRowsInEngineOrder() throws {
        var rows = [
            makeStatus(id: 1, isTransfer: false, prepLayer: 0, prepIndex: 0, crossing: -1),
            makeStatus(id: 2, isTransfer: true, prepLayer: -1, prepIndex: -1, crossing: 0)
        ]
        let decoded = try rows.withUnsafeMutableBufferPointer { buffer -> [MigrationTransactionStatus] in
            let container = FfiMigrationTransactionStatuses(ptr: buffer.baseAddress, len: UInt(buffer.count))
            return try XCTUnwrap(container.unsafeToMigrationTransactionStatuses())
        }
        XCTAssertEqual(decoded.map(\.id), [1, 2])
    }

    /// A single malformed row anywhere in the container must fail the WHOLE decode -- a partially
    /// decoded array would silently drop the malformed transaction rather than surfacing the
    /// "returned malformed data" error `ZcashRustBackend.migrationTransactionStatuses` maps it to.
    func testDecodeContainerReturnsNilWhenAnyRowIsMalformed() {
        var rows = [
            makeStatus(id: 1),
            makeStatus(id: 2, state: 99)
        ]
        let decoded = rows.withUnsafeMutableBufferPointer { buffer -> [MigrationTransactionStatus]? in
            FfiMigrationTransactionStatuses(ptr: buffer.baseAddress, len: UInt(buffer.count)).unsafeToMigrationTransactionStatuses()
        }
        XCTAssertNil(decoded, "a malformed row anywhere in the array must fail the whole decode")
    }

    /// `dependsOn` copies the heap array pointed to by `depends_on`/`depends_on_len` straight
    /// through, preserving order.
    func testDecodeMapsDependsOnIds() throws {
        var ids: [UInt32] = [3, 7, 9]
        let decoded = ids.withUnsafeMutableBufferPointer { buffer -> MigrationTransactionStatus? in
            makeStatus(dependsOnPtr: buffer.baseAddress, dependsOnLen: UInt(buffer.count)).unsafeToMigrationTransactionStatus()
        }
        XCTAssertEqual(try XCTUnwrap(decoded).dependsOn, [3, 7, 9])
    }

    /// The default (no dependencies) row -- `depends_on == nil`, `depends_on_len == 0` -- decodes
    /// to an EMPTY array, not `nil`: `MigrationTransactionStatus.dependsOn` is non-optional.
    func testDecodeMapsNoDependsOnToAnEmptyArray() throws {
        let decoded = try XCTUnwrap(makeStatus().unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.dependsOn, [])
    }

    /// A non-negative `anchor_boundary` on a TRANSFER row decodes straight through.
    func testDecodeMapsAnchorBoundaryHeightForATransfer() throws {
        let ffi = makeStatus(isTransfer: true, crossing: 2, anchorBoundary: 3_200_000)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertEqual(decoded.anchorBoundaryHeight, 3_200_000)
    }

    /// The engine's `-1` "no drawn boundary" sentinel decodes to `nil` -- the default `makeStatus()`
    /// row's value, and always so for a PREPARATION (which anchors near-tip at proving time instead
    /// of a drawn boundary; see `MigrationTransactionStatus.anchorBoundaryHeight`'s doc).
    func testDecodeMapsNegativeAnchorBoundarySentinelToNilForAPreparation() throws {
        let ffi = makeStatus(isTransfer: false, prepLayer: 0, prepIndex: 0)
        let decoded = try XCTUnwrap(ffi.unsafeToMigrationTransactionStatus())
        XCTAssertNil(decoded.anchorBoundaryHeight, "a preparation never carries a drawn boundary")
    }

    // MARK: - Advance step decode mapping
    //
    // `FfiMigrationAdvanceStep`'s marshal into `MigrationAdvance`, constructed directly like
    // the status rows above. The discriminants are asserted through the header's exported
    // `ZCASHLC_ADVANCE_STEP_*` constants (U3) — the same names the decode itself matches on — so
    // a renumbering on either side surfaces here. Assertions unwrap `.step`; the outlook
    // (`.next`) has its own dedicated section below.

    /// Every step discriminant decodes to its case; `replan`/`reevaluate` decode BARE — upstream
    /// carries no transaction id on either step, and the marshal must not invent one.
    func testAdvanceStepDecodeMapsEveryStepIncludingReplanAndReevaluate() throws {
        let prove = makeProveAdvanceStep([
            FfiProveTarget(id: 4, kind_is_preparation: false, kind_layer: 0, kind_index: 0, kind_crossing: 2, schedule_due: false)
        ])
        defer { freeProveAdvanceStep(prove) }
        XCTAssertEqual(
            prove.unsafeToMigrationAdvance()?.step,
            .prove(transactions: [MigrationProveTarget(id: 4, kind: .transfer(crossing: 2), isScheduleDue: false)])
        )

        let provePreparation = makeProveAdvanceStep([
            FfiProveTarget(id: 5, kind_is_preparation: true, kind_layer: 1, kind_index: 3, kind_crossing: 0, schedule_due: true)
        ])
        defer { freeProveAdvanceStep(provePreparation) }
        XCTAssertEqual(
            provePreparation.unsafeToMigrationAdvance()?.step,
            .prove(transactions: [MigrationProveTarget(id: 5, kind: .preparation(layer: 1, index: 3), isScheduleDue: true)]),
            "the schedule_due flag must cross the marshal per row, not be defaulted away"
        )

        let broadcast = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_BROADCAST), id: 6)
        XCTAssertEqual(broadcast.unsafeToMigrationAdvance()?.step, .broadcast(MigrationBroadcastInstruction(id: 6)))

        let rebuild = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_REBUILD), id: 7)
        XCTAssertEqual(rebuild.unsafeToMigrationAdvance()?.step, .rebuild(id: 7))

        let waiting = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_WAITING), id: 0)
        XCTAssertEqual(waiting.unsafeToMigrationAdvance()?.step, .waiting)

        let complete = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_COMPLETE), id: 0)
        XCTAssertEqual(complete.unsafeToMigrationAdvance()?.step, .complete)

        let replan = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_REPLAN), id: 9)
        XCTAssertEqual(
            replan.unsafeToMigrationAdvance()?.step,
            .replan,
            "Replan decodes bare — an id on the DTO is ignored, never surfaced"
        )

        let reevaluate = makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_REEVALUATE), id: 9)
        XCTAssertEqual(
            reevaluate.unsafeToMigrationAdvance()?.step,
            .reevaluate,
            "Reevaluate decodes bare — an id on the DTO is ignored, never surfaced"
        )
    }

    func testAdvanceStepDecodeReturnsNilForAnOutOfRangeStep() {
        XCTAssertNil(makeAdvanceStep(step: 99, id: 1).unsafeToMigrationAdvance())
        // 5 is the retired Attend discriminant — a HOLE, never reused: a stale header speaking
        // the old vocabulary must decode to nil, not to some other step.
        XCTAssertNil(makeAdvanceStep(step: 5, id: 1).unsafeToMigrationAdvance())
    }

    /// The two network-upgrade steps decode to their cases carrying the activation height the
    /// step reports, with no outlook (neither names a transaction or carries one). A negative
    /// height on either is the `-1` "none" sentinel where an activation must be, so the step is
    /// malformed and decodes to `nil` like any other defensive failure. On every other step the
    /// field is not read.
    func testAdvanceStepDecodeMapsPausedAndInterrupted() throws {
        let paused = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_PAUSED_FOR_NETWORK_UPGRADE),
            id: 0,
            networkUpgradeHeight: 3_543_405
        )
        let pausedAdvance = try XCTUnwrap(paused.unsafeToMigrationAdvance())
        XCTAssertEqual(pausedAdvance.step, .pausedForNetworkUpgrade(activationHeight: 3_543_405))
        XCTAssertNil(pausedAdvance.next)

        let interrupted = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_INTERRUPTED_BY_NETWORK_UPGRADE),
            id: 0,
            networkUpgradeHeight: 3_543_405
        )
        let interruptedAdvance = try XCTUnwrap(interrupted.unsafeToMigrationAdvance())
        XCTAssertEqual(interruptedAdvance.step, .interruptedByNetworkUpgrade(activationHeight: 3_543_405))
        XCTAssertNil(interruptedAdvance.next)

        for step in [ZCASHLC_ADVANCE_STEP_PAUSED_FOR_NETWORK_UPGRADE, ZCASHLC_ADVANCE_STEP_INTERRUPTED_BY_NETWORK_UPGRADE] {
            XCTAssertNil(
                makeAdvanceStep(step: UInt32(step), id: 0, networkUpgradeHeight: -1).unsafeToMigrationAdvance(),
                "a network-upgrade step without an activation height is malformed"
            )
        }

        let waiting = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_WAITING),
            id: 0,
            networkUpgradeHeight: 3_543_405
        )
        XCTAssertEqual(
            waiting.unsafeToMigrationAdvance()?.step,
            .waiting,
            "the activation height means nothing on a step the gate did not answer"
        )
    }

    /// A multi-entry Prove batch marshals every row, ordered and typed, mixing preparation and
    /// transfer kinds in one batch (upstream #2939); an EMPTY batch is a malformed step (upstream
    /// documents the batch never empty), so it decodes to `nil` rather than an empty-transactions
    /// case.
    func testAdvanceStepDecodeMapsAMultiEntryProveBatchAndRejectsAnEmptyOne() throws {
        let prove = makeProveAdvanceStep([
            FfiProveTarget(id: 5, kind_is_preparation: true, kind_layer: 1, kind_index: 3, kind_crossing: 0, schedule_due: true),
            FfiProveTarget(id: 4, kind_is_preparation: false, kind_layer: 0, kind_index: 0, kind_crossing: 2, schedule_due: false)
        ])
        defer { freeProveAdvanceStep(prove) }
        XCTAssertEqual(
            prove.unsafeToMigrationAdvance()?.step,
            .prove(transactions: [
                MigrationProveTarget(id: 5, kind: .preparation(layer: 1, index: 3), isScheduleDue: true),
                MigrationProveTarget(id: 4, kind: .transfer(crossing: 2), isScheduleDue: false)
            ]),
            "entries must marshal in array order, each keeping its own id, kind and dueness"
        )

        let empty = makeProveAdvanceStep([])
        XCTAssertNil(
            empty.unsafeToMigrationAdvance(),
            "an empty Prove batch is malformed (upstream never serves one empty), not a valid step"
        )
    }

    // MARK: - Restart outcome decode mapping

    /// A restart that planned carries the schedule and `-1`; one that waited for the upgrade carries
    /// no schedule and the activation height. Constructed directly like the rows above: the first
    /// shape needs a funded wallet over the real FFI, and the second a wallet before NU7.
    func testRestartOutcomeDecode() throws {
        let waiting = FfiMigrationRestartOutcome(schedule: nil, replan_after_height: 3_543_405)
        XCTAssertEqual(
            waiting.unsafeToMigrationRestartOutcome(),
            .cancelledUntilNetworkUpgrade(activationHeight: 3_543_405)
        )

        let schedule = UnsafeMutablePointer<FfiMigrationSchedule>.allocate(capacity: 1)
        schedule.initialize(
            to: FfiMigrationSchedule(
                transfers: nil,
                transfers_len: 0,
                estimated_duration_hours: 3,
                proposal_handle: 7,
                preparations: nil,
                preparations_len: 0
            )
        )
        defer { schedule.deallocate() }
        let planned = FfiMigrationRestartOutcome(schedule: schedule, replan_after_height: -1)
        XCTAssertEqual(
            planned.unsafeToMigrationRestartOutcome(),
            .replanned(MigrationSchedule(transfers: [], estimatedDurationHours: 3, proposalHandle: 7, preparations: []))
        )
    }

    /// An outcome with neither a plan nor an activation height to wait for is malformed, and
    /// decodes to `nil` like any other defensive failure.
    func testRestartOutcomeDecodeRejectsAnOutcomeWithNeitherAPlanNorAHeight() {
        XCTAssertNil(FfiMigrationRestartOutcome(schedule: nil, replan_after_height: -1).unsafeToMigrationRestartOutcome())
    }

    // MARK: - Prove outcome decode mapping (the txid seam)
    //
    // `FfiMigrationProveOutcome`'s marshal into `MigrationProveOutcome`, constructed directly like
    // the rows above. The txid buffer is a heap array of raw `[u8; 32]` values, so what needs
    // pinning is that the decode walks it by ELEMENT (32 bytes each, in order) rather than
    // flattening it, and that a total-only outcome is a valid shape.

    /// The C side's `uint8_t[32]` element type as Swift imports it -- a 32-byte tuple, spelled out
    /// once here so the fixture below can name it.
    private typealias ImportedTxId = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    /// Builds an `FfiMigrationProveOutcome` over a heap txid buffer the caller must free with
    /// `freeProveOutcome`.
    ///
    /// An empty `txids` leaves the pointer `nil`. That is NOT what rust hands back — `ptr_from_vec`
    /// on an empty `Vec` yields a DANGLING NON-NULL pointer with `len == 0` — so this arm exercises
    /// the decode's defensive `if let` rather than the production shape. Both must decode to the
    /// same empty result, which is the point: the length is what the decode may trust, and the
    /// pointer is never dereferenced at length 0 either way.
    private func makeProveOutcome(totalProved: UInt32, txids: [[UInt8]]) -> FfiMigrationProveOutcome {
        guard !txids.isEmpty else {
            return FfiMigrationProveOutcome(total_proved: totalProved, preparation_txids: nil, preparation_txids_len: 0)
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: txids.count * 32,
            alignment: MemoryLayout<ImportedTxId>.alignment
        )
        for (index, txid) in txids.enumerated() {
            precondition(txid.count == 32, "a fixture txid must be 32 bytes")
            txid.withUnsafeBufferPointer { bytes in
                buffer.advanced(by: index * 32).copyMemory(from: bytes.baseAddress!, byteCount: 32)
            }
        }
        return FfiMigrationProveOutcome(
            total_proved: totalProved,
            preparation_txids: buffer.bindMemory(to: ImportedTxId.self, capacity: txids.count),
            preparation_txids_len: UInt(txids.count)
        )
    }

    private func freeProveOutcome(_ outcome: FfiMigrationProveOutcome) {
        outcome.preparation_txids?.deallocate()
    }

    /// Every txid crosses whole and in order, keyed to its own 32-byte element -- the handoff list
    /// a host walks to retrieve each proved preparation.
    func testProveOutcomeDecodeMapsEveryPreparationTxidInOrder() {
        let first = [UInt8](repeating: 0xAB, count: 32)
        let second = [UInt8]((0 ..< 32).map { UInt8($0) })
        let outcome = makeProveOutcome(totalProved: 3, txids: [first, second])
        defer { freeProveOutcome(outcome) }

        XCTAssertEqual(
            outcome.unsafeToMigrationProveOutcome(),
            MigrationProveOutcome(totalProved: 3, preparationTxids: [Data(first), Data(second)]),
            "the total counts every kind; the txids marshal element-by-element, in buffer order"
        )
    }

    /// A pass that proved TRANSFERS ONLY reports its count with no txids: only preparations are
    /// retrievable, so a non-zero total with an empty handoff list is the correct shape, not a
    /// marshal that lost data.
    func testProveOutcomeDecodeMapsATotalWithNoPreparationTxids() {
        let outcome = makeProveOutcome(totalProved: 2, txids: [])
        defer { freeProveOutcome(outcome) }

        XCTAssertEqual(
            outcome.unsafeToMigrationProveOutcome(),
            MigrationProveOutcome(totalProved: 2, preparationTxids: []),
            "a transfers-only pass offers nothing for retrieval"
        )
    }

    // MARK: - Outlook decode mapping (librustzcash #2936)
    //
    // `FfiMigrationAdvanceStep.next_height`/`next_kind`'s marshal into `MigrationAdvance.next`,
    // independent of which step they ride along with (`.waiting` here is an arbitrary carrier —
    // the outlook decodes the same regardless of `.step`'s own case).

    /// A non-negative `next_height` paired with a recognized `next_kind` decodes to the matching
    /// `MigrationNextWork`.
    func testAdvanceStepDecodeMapsAPresentOutlook() throws {
        let step = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_WAITING),
            id: 0,
            nextHeight: 850_000,
            nextKind: UInt32(ZCASHLC_STEP_KIND_BROADCAST)
        )
        XCTAssertEqual(
            step.unsafeToMigrationAdvance()?.next,
            MigrationNextWork(height: 850_000, kind: .broadcast)
        )
    }

    /// The `next_height == -1` sentinel decodes to `next == nil` -- nothing is height-schedulable.
    func testAdvanceStepDecodeMapsTheNoOutlookSentinelToNil() throws {
        let step = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_WAITING),
            id: 0,
            nextHeight: -1,
            nextKind: 0
        )
        XCTAssertNil(step.unsafeToMigrationAdvance()?.next)
    }

    /// An out-of-range `next_kind` alongside a non-negative `next_height` is a malformed outlook,
    /// so the WHOLE decode fails -- mirroring the step discriminant's own defensive-nil contract
    /// (`testAdvanceStepDecodeReturnsNilForAnOutOfRangeStep`), never a `MigrationAdvance` whose
    /// `next` silently drops the unrecognized kind.
    func testAdvanceStepDecodeReturnsNilForAnOutOfRangeOutlookKind() throws {
        let step = makeAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_WAITING),
            id: 0,
            nextHeight: 850_000,
            nextKind: 99
        )
        XCTAssertNil(step.unsafeToMigrationAdvance())
    }

    // MARK: - Routed migration error parsing (U13)
    //
    // `migrationRoutedError` parses the rust layer's stable message prefixes; the branches are
    // pinned directly (internal member) because no offline path can drive each prefix through a
    // real FFI failure.

    /// `MIGRATION_WAKEUP_INFEASIBLE:<id>` parses the id into `.migrationWakeupInfeasible(id)`.
    func testMigrationRoutedErrorParsesWakeupInfeasibleWithItsTransferId() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        let routed = backend.migrationRoutedError(
            "MIGRATION_WAKEUP_INFEASIBLE:17",
            fallback: ZcashError.rustMigrationSyncWakeups
        )

        guard case .migrationWakeupInfeasible(let transferId) = routed else {
            XCTFail("expected migrationWakeupInfeasible, got \(routed)")
            return
        }
        XCTAssertEqual(transferId, 17)
    }

    /// A malformed id (contract drift) degrades to the member's own fallback case rather than
    /// fabricating a transfer id.
    func testMigrationRoutedErrorDegradesAMalformedWakeupInfeasibleIdToTheFallback() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        for malformed in ["MIGRATION_WAKEUP_INFEASIBLE:", "MIGRATION_WAKEUP_INFEASIBLE:abc", "MIGRATION_WAKEUP_INFEASIBLE:-3"] {
            let routed = backend.migrationRoutedError(malformed, fallback: ZcashError.rustMigrationSyncWakeups)

            guard case .rustMigrationSyncWakeups(let message) = routed else {
                XCTFail("expected the rustMigrationSyncWakeups fallback for \(malformed), got \(routed)")
                return
            }
            XCTAssertEqual(message, malformed, "the fallback must carry the raw message untouched")
        }
    }

    /// The two payload-less prefixes route to their dedicated cases.
    func testMigrationRoutedErrorRoutesPlanStaleAndProvingUnavailable() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        let planStale = backend.migrationRoutedError(
            "MIGRATION_PLAN_STALE: the previewed plan was superseded",
            fallback: ZcashError.rustMigrationSignAndStoreSchedule
        )
        guard case .migrationPlanStale = planStale else {
            XCTFail("expected migrationPlanStale, got \(planStale)")
            return
        }

        let provingUnavailable = backend.migrationRoutedError(
            "MIGRATION_PROVING_UNAVAILABLE: prover parameters missing",
            fallback: ZcashError.rustMigrationProveTransactions
        )
        guard case .migrationProvingUnavailable(let message) = provingUnavailable else {
            XCTFail("expected migrationProvingUnavailable, got \(provingUnavailable)")
            return
        }
        XCTAssertTrue(message.hasPrefix("MIGRATION_PROVING_UNAVAILABLE"))
    }

    /// `MIGRATION_PAUSED_UNTIL_UPGRADE:<activation height>` parses the height into
    /// `.migrationPausedUntilNetworkUpgrade(height)`, whichever member the failure came from; a
    /// height that does not parse (contract drift) degrades to the member's own fallback rather
    /// than fabricating one.
    func testPausedPrefixRoutesToTheTypedError() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        let routed = backend.migrationRoutedError(
            "MIGRATION_PAUSED_UNTIL_UPGRADE:4465026",
            fallback: ZcashError.rustMigrationProposeTransfers
        )
        guard case .migrationPausedUntilNetworkUpgrade(let activationHeight) = routed else {
            XCTFail("expected migrationPausedUntilNetworkUpgrade, got \(routed)")
            return
        }
        XCTAssertEqual(activationHeight, 4_465_026)
        XCTAssertEqual(routed.code.rawValue, "ZRUST0159")

        let malformedMessages = [
            "MIGRATION_PAUSED_UNTIL_UPGRADE:",
            "MIGRATION_PAUSED_UNTIL_UPGRADE:abc",
            "MIGRATION_PAUSED_UNTIL_UPGRADE:-3",
            "MIGRATION_PAUSED_UNTIL_UPGRADE:4465026 and more",
            "MIGRATION_PAUSED_UNTIL_UPGRADE"
        ]
        for malformed in malformedMessages {
            let degraded = backend.migrationRoutedError(malformed, fallback: ZcashError.rustMigrationProposeTransfers)

            guard case .rustMigrationProposeTransfers(let message) = degraded else {
                XCTFail("expected the rustMigrationProposeTransfers fallback for \(malformed), got \(degraded)")
                return
            }
            XCTAssertEqual(message, malformed, "the fallback must carry the raw message untouched")
        }
    }

    /// `MIGRATION_SUBMISSION_REFUSED:<code>` routes to `.migrationSubmissionRefused(refusal)` for
    /// each code the rust layer emits, whichever member the failure came from; a code this SDK does
    /// not know (contract drift), or none, degrades to the member's own fallback rather than
    /// fabricating a refusal.
    func testSubmissionRefusedPrefixRoutesToTheTypedError() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        let codes: [(rustCode: String, refusal: TransactionSubmissionRefusal)] = [
            ("wrong_branch", .wrongConsensusBranch),
            ("expired", .expired)
        ]
        for (rustCode, refusal) in codes {
            let routed = backend.migrationRoutedError(
                "MIGRATION_SUBMISSION_REFUSED:\(rustCode)",
                fallback: ZcashError.rustMigrationTakeBroadcastTransaction
            )
            guard case .migrationSubmissionRefused(let routedRefusal) = routed else {
                XCTFail("expected migrationSubmissionRefused for \(rustCode), got \(routed)")
                return
            }
            XCTAssertEqual(routedRefusal, refusal, rustCode)
            XCTAssertEqual(routed.code.rawValue, "ZRUST0162")
        }

        let unknownMessages = [
            "MIGRATION_SUBMISSION_REFUSED:",
            "MIGRATION_SUBMISSION_REFUSED:not_a_code",
            "MIGRATION_SUBMISSION_REFUSED:expired and more",
            "MIGRATION_SUBMISSION_REFUSED:EXPIRED",
            "MIGRATION_SUBMISSION_REFUSED"
        ]
        for unknown in unknownMessages {
            let degraded = backend.migrationRoutedError(unknown, fallback: ZcashError.rustMigrationTakePreparation)

            guard case .rustMigrationTakePreparation(let message) = degraded else {
                XCTFail("expected the rustMigrationTakePreparation fallback for \(unknown), got \(degraded)")
                return
            }
            XCTAssertEqual(message, unknown, "the fallback must carry the raw message untouched")
        }
    }

    /// The refusal's local codes and descriptions are part of the public surface: a consumer that
    /// carries a refusal in a failure with an integer code sees these, and none of them is a code a
    /// server sends.
    func testTransactionSubmissionRefusalHasStableCodesAndDescriptions() {
        XCTAssertEqual(TransactionSubmissionRefusal.wrongConsensusBranch.code, -9101)
        XCTAssertEqual(TransactionSubmissionRefusal.expired.code, -9102)
        XCTAssertEqual(
            Set([
                TransactionSubmissionRefusal.wrongConsensusBranch.description,
                TransactionSubmissionRefusal.expired.description
            ]).count,
            2,
            "each refusal describes itself"
        )
    }

    /// An unrelated message — including one merely CONTAINING a known prefix mid-string — falls
    /// through to the member's own case untouched.
    func testMigrationRoutedErrorLeavesUnrelatedMessagesToTheFallback() throws {
        let backend = try XCTUnwrap(rustBackend as? ZcashRustBackend)

        let unrelatedMessages = [
            "sqlite disk I/O error",
            "saw MIGRATION_PLAN_STALE downstream",
            "saw MIGRATION_PAUSED_UNTIL_UPGRADE:3543405 downstream",
            "saw MIGRATION_SUBMISSION_REFUSED:expired downstream"
        ]
        for unrelated in unrelatedMessages {
            let routed = backend.migrationRoutedError(unrelated, fallback: ZcashError.rustMigrationRestartStep)

            guard case .rustMigrationRestartStep(let message) = routed else {
                XCTFail("expected the rustMigrationRestartStep fallback for \(unrelated), got \(routed)")
                return
            }
            XCTAssertEqual(message, unrelated)
        }
    }

    // MARK: - Actor integration over real FFI (nil paths)

    /// Constructs a real `OrchardMigration` via the injecting initializer, wired to the SAME
    /// real-FFI-backed welding as the rest of this file (not a mock) plus a real, temp-file-backed
    /// `MigrationSyncGate`, and hands the broadcast executor an instruction no crank could have
    /// issued on this fresh wallet (there is no stored run at all).
    ///
    /// THE BACKSTOP, OVER REAL FFI: the Swift surface makes the instruction un-forgeable, but this
    /// test forges one through `@testable` precisely to prove the honest-boundary claim in the
    /// surface docs — the rust seam refuses it on its own per-row state, so nothing is submitted
    /// and nothing is recorded. A pre-broadcast refusal, not a silent no-op. (The broadcaster is
    /// reached, because the take runs from within it once it has connected and read a height, and it
    /// is the take that is refused.)
    func testFreshWalletActorPerformBroadcastRefusesAnUninstructedIdOverRealFFI() async throws {
        let storageDirectory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = OrchardMigration(
            welding: rustBackend,
            accountUUID: account,
            broadcaster: broadcaster,
            syncGate: MigrationSyncGate(
                directory: storageDirectory,
                accountUUID: account,
                tickInterval: 3600,
                logger: logger
            ),
            logger: logger,
            spacing: TargetBlockSpacing(networkType: .testnet)
        )

        do {
            _ = try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: 0),
                options: MigrationNetworkPrivacyOptions(
                    useTor: false,
                    submissionEndpoint: LightWalletEndpoint(address: "default.example", port: 9067)
                )
            )
            XCTFail("Expected the rust seam to refuse an id no stored run can serve")
        } catch ZcashError.rustMigrationTakeBroadcastTransaction {
            // expected: "no migration run is stored, so transaction 0 cannot be served"
        } catch {
            XCTFail("Expected rustMigrationTakeBroadcastTransaction but got \(error)")
        }

        XCTAssertTrue(broadcaster.submittedTransactions.isEmpty, "a refused serve must never reach the network")
    }

    // MARK: - Gate ticker boundary wake (field-caught 2026-08-02)
    //
    // The gate KNOWS when its persisted input flips (`inFlightUntil` is a wall-clock deadline),
    // yet the flat tickInterval sleep left a cleared gate unnoticed for up to a whole interval —
    // a dead half-minute of foreground between "gate expired" and "sync resumed".
    // `nextRecomputeDelay` sleeps only until that FUTURE boundary (+0.25 s epsilon), capped at the
    // interval; with no future boundary pending it keeps the flat interval cadence.

    func testNextRecomputeDelayWakesAtTheMarkerBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let delay = MigrationSyncGate.nextRecomputeDelay(
            now: now,
            inFlightUntil: now.addingTimeInterval(6),
            tickInterval: 15
        )
        XCTAssertEqual(delay, 6.25, accuracy: 0.001, "the boundary (+epsilon) must win over the interval")
    }

    func testNextRecomputeDelayIgnoresAPastBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let delay = MigrationSyncGate.nextRecomputeDelay(
            now: now,
            inFlightUntil: now.addingTimeInterval(-5),
            tickInterval: 15
        )
        XCTAssertEqual(delay, 15, "an expired boundary must fall back to the plain interval")
    }

    func testNextRecomputeDelayWithNoBoundaryKeepsTheInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            MigrationSyncGate.nextRecomputeDelay(now: now, inFlightUntil: nil, tickInterval: 15),
            15
        )
    }

    func testNextRecomputeDelayCapsADistantBoundaryAtTheInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        let delay = MigrationSyncGate.nextRecomputeDelay(
            now: now,
            inFlightUntil: now.addingTimeInterval(600),
            tickInterval: 15
        )
        XCTAssertEqual(delay, 15, "a boundary beyond the interval must not stretch the cadence")
    }

    // MARK: - Custom network registration

    /// `OrchardMigration.init(config:)` builds its own `ZcashRustBackend` rather than sharing the
    /// synchronizer's, so it -- like `Initializer.setup` -- must register a custom network's
    /// activation heights with the Rust core itself; nothing else does it on this path. Pre-fix,
    /// every migration FFI call on a `.regtest`/custom network id (2) throws "custom network (id 2)
    /// used before it was configured" (see `rust/src/lib.rs`'s `parse_network`), which
    /// `migrationAdvanceStep()` surfaces as `rustMigrationAdvanceStep`, and which
    /// `isSyncBlocked()`-style callers silently swallow via `try?` instead (finding
    /// 5's "migration dead on .custom/.regtest").
    ///
    /// `NetworkActivationHeights` here intentionally matches
    /// `RegtestActivationHeightsTests.testRegtestConsensusBranchIdReflectsCustomActivationHeights`'s
    /// values exactly: `zcashlc_set_custom_network` is process-global, `swift test` runs the whole
    /// `OfflineTests` bundle in one process, and a conflicting re-registration is a host
    /// configuration bug this code path asserts on (`assertionFailure`, live in a debug/test build).
    /// Identical values make both tests' registrations idempotent regardless of run order.
    ///
    /// The engine's store tables ride the wallet schema migrations (the FFI no longer creates
    /// them on first touch), so the fixture initializes the wallet database first — exactly like
    /// a real caller, whose `Initializer`/`prepare` runs `initDataDb` before any migration read —
    /// and then verifies `migrationAdvanceStep()` reads `nil` (no stored run yet) over the custom
    /// network the `OrchardMigration` initializer registered.
    ///
    /// `migrationAdvanceStep()` opens the account-scoped migration store, which requires a real
    /// `accounts` row (mirroring this file's class-wide `setUp()` and its own "representative of
    /// real usage" rationale). The FIRST `OrchardMigration.init(config:)` below registers the custom network as
    /// a side effect (the behavior under test; its placeholder `accountUUID` is never queried) --
    /// only once that registration has happened can any other FFI call on this network id succeed,
    /// so `initDataDb`/`createAccount` (which discover the REAL `AccountUUID` the wallet assigns)
    /// must run after it. The SECOND `OrchardMigration.init(config:)`, bound to that real account, is
    /// the instance the assertion below exercises; re-registering the same activation heights is
    /// harmlessly idempotent.
    func testOrchardMigrationRegistersCustomActivationHeightsOnInit() async throws {
        let activationHeights = NetworkActivationHeights(
            overwinter: 1,
            sapling: 1,
            blossom: 1,
            heartwood: 1,
            canopy: 1,
            nu5: 100,
            nu6: 200
        )
        let network = ZcashNetworkBuilder.regtest(activationHeights: activationHeights)

        let storageDirectory = try makeUniqueStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        func makeConfig(accountUUID: AccountUUID) -> OrchardMigration.Config {
            OrchardMigration.Config(
                dataDbURL: storageDirectory.appendingPathComponent("data.db"),
                fsBlockDbRoot: storageDirectory.appendingPathComponent("fs_cache", isDirectory: true),
                spendParamsURL: storageDirectory.appendingPathComponent("sapling-spend.params"),
                outputParamsURL: storageDirectory.appendingPathComponent("sapling-output.params"),
                network: network,
                accountUUID: accountUUID,
                torDirURL: storageDirectory.appendingPathComponent("tor", isDirectory: true),
                generalStorageURL: storageDirectory,
                upgradeGateBypass: MigrationUpgradeGateBypass(),
                submissionHeight: { _ in 4_000_000 },
                loggingPolicy: .noLogging
            )
        }

        // Registers the custom network as a side effect of `init(config:)` -- this placeholder
        // account is never used past this point.
        _ = OrchardMigration(config: makeConfig(accountUUID: AccountUUID(id: [UInt8](repeating: 9, count: 16))))

        let initBackend = ZcashRustBackend.makeForTests(
            dbData: storageDirectory.appendingPathComponent("data.db"),
            fsBlockDbRoot: storageDirectory.appendingPathComponent("fs_cache", isDirectory: true),
            networkType: network.networkType
        )
        let dbInit = try await initBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .regtest, regtestActivationHeights: activationHeights)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        _ = try await initBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await initBackend.listAccounts()
        let accountUUID = try XCTUnwrap(accounts.first?.id)

        let migration = OrchardMigration(config: makeConfig(accountUUID: accountUUID))

        do {
            let step = try await migration.advanceStep()
            XCTAssertNil(step, "a fresh account on the custom network has no stored run yet")
        } catch {
            XCTFail("Expected advanceStep() to succeed once the custom network is registered by init(config:); got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeUniqueStorageDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MigrationFFITests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The imported shape of `FfiMigrationTransactionStatus.txid` (`uint8_t[32]`): an unlabeled
    /// 32-`UInt8` tuple, structurally identical to (and freely interchangeable with) that field's
    /// own C-imported type, matching how `FfiTxId.tuple` is used elsewhere in the SDK.
    private typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private static func tuple32(_ bytes: [UInt8]) -> Bytes32 {
        precondition(bytes.count == 32, "a txid is exactly 32 bytes")
        return bytes.withUnsafeBytes { $0.load(as: Bytes32.self) }
    }

    /// Builds an `FfiMigrationAdvanceStep` with no Prove batch (`prove_targets: nil`,
    /// `prove_targets_len: 0`) — every step but Prove, mirroring the FFI contract. `nextHeight`/
    /// `nextKind` default to the no-outlook sentinel (`-1`/`0`); override them for the outlook
    /// decode tests below. `networkUpgradeHeight` defaults to the `-1` "none" sentinel every step
    /// but the two network-upgrade steps carries.
    private func makeAdvanceStep(
        step: UInt32,
        id: UInt32,
        nextHeight: Int64 = -1,
        nextKind: UInt32 = 0,
        networkUpgradeHeight: Int64 = -1
    ) -> FfiMigrationAdvanceStep {
        FfiMigrationAdvanceStep(
            step: step,
            id: id,
            prove_targets: nil,
            prove_targets_len: 0,
            next_height: nextHeight,
            next_kind: nextKind,
            network_upgrade_height: networkUpgradeHeight
        )
    }

    /// Builds an `FfiMigrationAdvanceStep` for `ZCASHLC_ADVANCE_STEP_PROVE`, heap-allocating one
    /// `FfiProveTarget` per entry of `targets` in order (an empty array leaves `prove_targets`
    /// `nil`, mirroring the malformed-empty-batch case). The caller must free the result with
    /// `freeProveAdvanceStep` — these fixtures are constructed directly rather than through the
    /// real FFI, so nothing else owns the allocation. Carries no outlook (`next_height: -1`): the
    /// outlook decode is exercised independently, in the dedicated section above.
    private func makeProveAdvanceStep(_ targets: [FfiProveTarget]) -> FfiMigrationAdvanceStep {
        guard !targets.isEmpty else {
            return makeAdvanceStep(step: UInt32(ZCASHLC_ADVANCE_STEP_PROVE), id: 0)
        }
        let pointer = UnsafeMutablePointer<FfiProveTarget>.allocate(capacity: targets.count)
        for (index, target) in targets.enumerated() {
            pointer.advanced(by: index).initialize(to: target)
        }
        return FfiMigrationAdvanceStep(
            step: UInt32(ZCASHLC_ADVANCE_STEP_PROVE),
            id: 0,
            prove_targets: pointer,
            prove_targets_len: UInt(targets.count),
            next_height: -1,
            next_kind: 0,
            network_upgrade_height: -1
        )
    }

    /// Frees the heap array `makeProveAdvanceStep` allocated (a no-op for an empty batch, whose
    /// `prove_targets` is `nil`).
    private func freeProveAdvanceStep(_ step: FfiMigrationAdvanceStep) {
        step.prove_targets?.deallocate()
    }

    /// Builds a valid row -- transfer 0, awaiting signature, ready, no next action, not blocked,
    /// no txid, no dependencies, no drawn anchor boundary -- with every field defaulted; override
    /// only the field(s) under test. Mirrors `FfiMigrationTransactionStatus`'s field-by-field
    /// contract (see `rust/src/migration.rs`'s doc comments).
    ///
    /// - Note: `dependsOnPtr`/`dependsOnLen` default to `nil`/`0` (no dependencies -- the C side's
    ///   own "empty" encoding, not a null-vs-empty distinction the decode makes). A test exercising
    ///   a non-empty `dependsOn` must supply a pointer that stays valid for the call's duration --
    ///   see `testDecodeMapsDependsOnIds` below, which scopes one via
    ///   `withUnsafeMutableBufferPointer`, mirroring `testDecodeContainerMapsMultipleRowsInEngineOrder`'s
    ///   existing pattern for the outer container.
    private func makeStatus(
        id: UInt32 = 7,
        isTransfer: Bool = true,
        prepLayer: Int64 = -1,
        prepIndex: Int64 = -1,
        crossing: Int64 = 0,
        state: UInt8 = 0,
        scheduledHeight: Int64 = 3_000_000,
        expiryHeight: Int64 = 3_000_100,
        minedHeight: Int64 = -1,
        txid: Bytes32 = MigrationFFITests.tuple32([UInt8](repeating: 0, count: 32)),
        hasTxid: Bool = false,
        ready: Bool = true,
        action: UInt8 = 0,
        blockedOn: UInt8 = 0,
        dependsOnPtr: UnsafeMutablePointer<UInt32>? = nil,
        dependsOnLen: UInt = 0,
        anchorBoundary: Int64 = -1,
        invalidReason: Int32 = -1
    ) -> FfiMigrationTransactionStatus {
        FfiMigrationTransactionStatus(
            id: id,
            is_transfer: isTransfer,
            prep_layer: prepLayer,
            prep_index: prepIndex,
            crossing: crossing,
            state: state,
            scheduled_height: scheduledHeight,
            expiry_height: expiryHeight,
            mined_height: minedHeight,
            txid: txid,
            has_txid: hasTxid,
            ready: ready,
            action: action,
            blocked_on: blockedOn,
            depends_on: dependsOnPtr,
            depends_on_len: dependsOnLen,
            anchor_boundary: anchorBoundary,
            invalid_reason: invalidReason
        )
    }
}
