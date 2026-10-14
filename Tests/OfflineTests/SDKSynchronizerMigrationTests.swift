//
//  SDKSynchronizerMigrationTests.swift
//  OfflineTests
//
//  Tests `SDKSynchronizer`'s migration group (R4-B): the 32 `Synchronizer` protocol requirements,
//  as thin forwards to a seamed `OrchardMigrationHost` -- except the DB-free, account-free Keystone
//  batch-signing bridge (4 members, #1806), which forwards straight to `initializer.rustBackend`
//  instead, bypassing the host entirely -- and the two SDK-enforced session-separation behaviors --
//  the start() privacy gate and the submitNoteSplit/performMigrationBroadcast broadcast
//  guard. Driven through the host's injecting initializer + a scripted actor factory, mirroring
//  R4-A's `OrchardMigrationHostTests` seam, with the host substituted into a real `SDKSynchronizer`
//  via the container-mock seam (`container.mock(type: OrchardMigrationHost.self, ...)`) that
//  `SDKSynchronizer.init` resolves against, same as `sdkFlags`/`submitPlanStore`.
//
//  No network, no real FFI beyond local SQLite/key-derivation calls that `Initializer`/
//  `TestsData` already make offline elsewhere in this suite.
//

import Combine
import Foundation
@testable import TestUtils
import XCTest
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class SDKSynchronizerMigrationTests: ZcashTestCase {
    private let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0A, count: 16))
    private let submissionEndpoint = LightWalletEndpoint(address: "submit.example", port: 9067)
    private var cancellables: [AnyCancellable] = []
    private static let uaString = """
    u1l9f0l4348negsncgr9pxd9d3qaxagmqv3lnexcplmufpq7muffvfaue6ksevfvd7wrz7xrvn95rc5zjtn7ugkmgh5rnxswmcj30y0pw52pn0zjvy38rn2esfgve64rj5pcmazxgpyuj
    """

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        super.tearDown()
    }

    // MARK: - Forwarding (representatives: advance step, split, schedule, delivery, recovery, PCZT)

    /// `migrationAdvanceStep` is a VERBATIM conduit of the welding's own next-step decision: every
    /// case (plus the no-stored-run `nil`) must surface through the `Synchronizer` surface
    /// untouched, with the account forwarded to the welding call.
    func testMigrationAdvanceStepForwardsToTheAccountsActorVerbatimForEveryCase() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let cases: [MigrationAdvance?] = [
            nil,
            MigrationAdvance(
                step: .prove(transactions: [MigrationProveTarget(id: 3, kind: .preparation(layer: 0, index: 1))]),
                next: nil
            ),
            MigrationAdvance(
                step: .prove(transactions: [MigrationProveTarget(id: 4, kind: .transfer(crossing: 2))]),
                next: nil
            ),
            MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 5)), next: nil),
            MigrationAdvance(step: .rebuild(id: 6), next: nil),
            MigrationAdvance(step: .waiting, next: MigrationNextWork(height: 850_000, kind: .broadcast)),
            MigrationAdvance(step: .complete, next: nil),
            MigrationAdvance(step: .replan, next: nil),
            MigrationAdvance(step: .reevaluate, next: nil)
        ]

        for expectedAdvance in cases {
            welding.migrationAdvanceStepForEstimatedTipReturnValue = expectedAdvance

            let advance = try await synchronizer.migrationAdvanceStep(accountUUID: accountUUID)

            XCTAssertEqual(advance, expectedAdvance)
            XCTAssertEqual(welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.account, accountUUID)
        }
    }

    func testPrepareNoteSplitForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = NoteSplitProposal(outputNotes: [Zatoshi(500), Zatoshi(500)], fee: Zatoshi(100), proposalHandle: 1)
        welding.migrationPrepareNoteSplitForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let proposal = try await synchronizer.prepareNoteSplit(accountUUID: accountUUID)

        XCTAssertEqual(proposal, expected)
        XCTAssertEqual(welding.migrationPrepareNoteSplitForReceivedAccount, accountUUID)
    }

    func testProposeMigrationTransfersForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = MigrationSchedule(transfers: [], estimatedDurationHours: 3, proposalHandle: 0, preparations: [])
        welding.migrationProposeTransfersForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let schedule = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)

        XCTAssertEqual(schedule, expected)
        XCTAssertEqual(welding.migrationProposeTransfersForReceivedAccount, accountUUID)
    }

    func testHasOverdueMigrationTransfersForwards() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationHasOverdueTransfersForEstimatedTipReturnValue = true
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let overdue = try await synchronizer.hasOverdueMigrationTransfers(accountUUID: accountUUID)

        XCTAssertTrue(overdue)
        let received = welding.migrationHasOverdueTransfersForEstimatedTipReceivedArguments
        XCTAssertEqual(received?.account, accountUUID)
        XCTAssertNil(received?.estimatedTip, "the one-argument convenience overload must default useEstimatedTip to false")
    }

    /// The live per-transaction status read behind `migrationProgress`'s aggregate summary --
    /// forwards to the per-account actor and returns the engine's rows untouched.
    func testMigrationTransactionStatusesForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = [
            MigrationTransactionStatus(
                id: 3,
                kind: .transfer(crossing: 0),
                state: .awaitingSignature,
                scheduledHeight: 3_000_000,
                expiryHeight: 3_000_100,
                isReady: true,
                nextAction: .prove,
                blockedOn: nil,
                dependsOn: [],
                anchorBoundaryHeight: nil
            )
        ]
        welding.migrationTransactionStatusesForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let statuses = try await synchronizer.migrationTransactionStatuses(accountUUID: accountUUID)

        XCTAssertEqual(statuses, expected)
        XCTAssertEqual(welding.migrationTransactionStatusesForReceivedAccount, accountUUID)
    }

    /// `refreshStaleMigrationTransfers`'s external-signer (Keystone) lane: a `nil` usk must reach
    /// the welding call as `nil`, not be coerced into some non-optional stand-in -- the engine
    /// itself branches on nilness to select the unsigned-rebuild path (see
    /// `OrchardMigration.refreshStaleTransfers(usk:)`) -- and the welding's post-refresh stored
    /// schedule must flow back to the caller unmodified (it is the truth the host re-displays and
    /// echoes on the consent-verified calls).
    func testRefreshStaleMigrationTransfersForwardsNilUskForTheExternalSignerLane() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(
                    id: 3,
                    amount: Zatoshi(100_000_000),
                    anchorHeight: 3_600_000,
                    nextExecutableAfterHeight: 3_600_100,
                    expiryHeight: 3_640_000
                )
            ],
            estimatedDurationHours: 2,
            // A refresh reads the stored run, which always carries handle 0 (see
            // `MigrationSchedule.proposalHandle`'s doc) -- commit-shaped calls resume it
            // handle-free, never by re-identifying a cached plan.
            proposalHandle: 0,
            preparations: [
                MigrationPreparationStep(id: 1, layer: 0, index: 0, broadcastHeight: 3_600_000, dependsOn: [])
            ]
        )
        welding.migrationRefreshStaleTransfersUskForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let refreshed = try await synchronizer.refreshStaleMigrationTransfers(accountUUID: accountUUID, usk: nil)

        XCTAssertEqual(refreshed, expected)
        let received = welding.migrationRefreshStaleTransfersUskForReceivedArguments
        XCTAssertEqual(received?.account, accountUUID)
        XCTAssertNil(received?.usk, "a nil usk must forward as nil, selecting the external-signer lane")
    }

    /// The sibling of the nil-usk test above: a real spending key must forward untouched, selecting
    /// the in-process sign-anew lane, with the returned schedule again round-tripping unmodified.
    func testRefreshStaleMigrationTransfersForwardsARealUskForTheInProcessLane() async throws {
        let welding = ZcashRustBackendWeldingMock()
        // A refresh reads the stored run, which always carries handle 0 -- see the sibling
        // nil-usk test above.
        let expected = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0, preparations: [])
        welding.migrationRefreshStaleTransfersUskForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let usk = TestsData(networkType: .testnet).spendingKey

        let refreshed = try await synchronizer.refreshStaleMigrationTransfers(accountUUID: accountUUID, usk: usk)

        XCTAssertEqual(refreshed, expected)
        let received = welding.migrationRefreshStaleTransfersUskForReceivedArguments
        XCTAssertEqual(received?.account, accountUUID)
        XCTAssertEqual(received?.usk, usk)
    }

    /// The sequential-runs contract at the API level: `.complete` is per-run (terminal for the
    /// STORED run, never "nothing left to migrate"), and the authority for "does anything remain to
    /// migrate" is a fresh propose — an empty schedule means no, a non-empty one is the next run's
    /// proposal. Hosts must not latch "never migrate again" off `migrationAdvanceStep` alone.
    func testAfterCompleteProposeMigrationTransfersAnswersWhetherAnythingRemains() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .complete, next: nil)
        welding.migrationProposeTransfersForReturnValue = MigrationSchedule(
            transfers: [],
            estimatedDurationHours: 0,
            // The empty "nothing to migrate" answer carries handle 0 (no cached plan).
            proposalHandle: 0,
            preparations: []
        )
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let advance = try await synchronizer.migrationAdvanceStep(accountUUID: accountUUID)
        XCTAssertEqual(advance?.step, .complete)

        let remains = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)
        XCTAssertTrue(remains.transfers.isEmpty, "an empty schedule is the 'nothing remains' answer")

        // Funds arrive later (or a large balance needed another round): the same call now answers
        // with the next run's proposal.
        let nextRun = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(
                    id: 3,
                    amount: Zatoshi(100_000_000),
                    anchorHeight: BlockHeight(1_000),
                    nextExecutableAfterHeight: BlockHeight(1_010),
                    expiryHeight: BlockHeight(70_000)
                )
            ],
            estimatedDurationHours: 1,
            // A freshly proposed, not-yet-committed plan: a live nonzero handle.
            proposalHandle: 1,
            preparations: []
        )
        welding.migrationProposeTransfersForReturnValue = nextRun
        let proposed = try await synchronizer.proposeMigrationTransfers(accountUUID: accountUUID)
        XCTAssertEqual(proposed, nextRun, "a non-empty schedule is the next run's proposal")
    }

    /// #1806: `createUnsignedNoteSplitPCZTs` gained a required `schedule` parameter with the
    /// opaque-handle reshape (the welding call now needs it to identify which cached plan a
    /// fresh-build should be built from -- see `MigrationSchedule.proposalHandle`). Both the
    /// account AND the schedule -- handle included -- must reach the welding call untouched.
    func testCreateUnsignedNoteSplitPCZTsForwards() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = [MigrationUnsignedTransferPczt(id: 0, pczt: Data([0xAA, 0xBB]), actions: 16)]
        welding.migrationCreateUnsignedNoteSplitPcztsForForReturnValue = expected
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 77, preparations: [])

        let pczts = try await synchronizer.createUnsignedNoteSplitPCZTs(accountUUID: accountUUID, for: schedule)

        XCTAssertEqual(pczts, expected)
        let received = welding.migrationCreateUnsignedNoteSplitPcztsForForReceivedArguments
        XCTAssertEqual(received?.account, accountUUID)
        XCTAssertEqual(received?.schedule, schedule, "the schedule -- and its proposalHandle -- must forward untouched")
    }

    /// MOB-1513: the immediate lane's `proposeImmediateMigration` forwards to the per-account actor
    /// and returns its `ImmediateMigrationProposal` untouched -- unlike `proposeMigrationTransfers`,
    /// there is no engine schedule involved, so this is a plain one-hop forward like every other
    /// member in this group.
    func testProposeImmediateMigrationForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let ownAddress = UnifiedAddress(validatedEncoding: Self.uaString, networkType: .testnet)
        welding.getCurrentAddressAccountUUIDReturnValue = ownAddress
        var proposal = FfiProposal()
        var step = FfiProposalStep()
        var input = FfiProposedInput()
        var receivedOutput = FfiReceivedOutput()
        receivedOutput.value = 500_000
        input.receivedOutput = receivedOutput
        step.inputs = [input]
        var balance = FfiTransactionBalance()
        balance.feeRequired = 10_000
        step.balance = balance
        proposal.steps = [step]
        welding.proposeSendMaxTransferAccountUUIDRecipientMemoOrchardOnlyReturnValue = proposal
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let immediateProposal = try await synchronizer.proposeImmediateMigration(accountUUID: accountUUID)

        XCTAssertEqual(immediateProposal.fee, Zatoshi(10_000))
        XCTAssertEqual(immediateProposal.amount, Zatoshi(500_000 - 10_000))
        XCTAssertEqual(welding.getCurrentAddressAccountUUIDReceivedAccountUUID, accountUUID)
        XCTAssertEqual(welding.proposeSendMaxTransferAccountUUIDRecipientMemoOrchardOnlyReceivedArguments?.recipient, ownAddress.stringEncoded)
    }

    /// `recordImmediateMigration` forwards the account and txid to the per-account actor, which in
    /// turn forwards to the welding record call -- this is NOT broadcast-sensitive (no
    /// `throwIfSyncingForMigrationBroadcast()` guard), matching the contract that only the two
    /// actual broadcasting members are guarded.
    func testRecordImmediateMigrationForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        var receivedTxid: Data?
        var receivedAccount: AccountUUID?
        welding.migrationRecordImmediateRunTxidForClosure = { txid, account in
            receivedTxid = txid
            receivedAccount = account
        }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let txid = Data(repeating: 0xEF, count: 32)

        try await synchronizer.recordImmediateMigration(accountUUID: accountUUID, txid: txid)

        XCTAssertEqual(receivedTxid, txid)
        XCTAssertEqual(receivedAccount, accountUUID)
    }

    /// `lockMigrationResidual` — the "Lock balance" choice at migration `Complete` — forwards to
    /// the per-account actor and returns the welding's locked total untouched. Like the rest of the
    /// group it needs no `prepare()` and carries no broadcast guard (locking is a data-db write,
    /// nothing is broadcast).
    func testLockMigrationResidualForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDReturnValue = Zatoshi(21_500)
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let locked = try await synchronizer.lockMigrationResidual(accountUUID: accountUUID)

        XCTAssertEqual(locked, Zatoshi(21_500))
        XCTAssertEqual(welding.lockMigrationResidualAccountUUIDReceivedAccountUUID, accountUUID)
    }

    /// A lock failure (in particular the concurrent-lock race, which the caller may retry)
    /// propagates through the `Synchronizer` surface untouched.
    func testLockMigrationResidualPropagatesTheWeldingError() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.lockMigrationResidualAccountUUIDThrowableError = ZcashError.rustMigrationLockResidual("concurrent lock race")
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        do {
            _ = try await synchronizer.lockMigrationResidual(accountUUID: accountUUID)
            XCTFail("expected rustMigrationLockResidual to propagate")
        } catch ZcashError.rustMigrationLockResidual {
            // expected
        } catch {
            XCTFail("expected rustMigrationLockResidual, got \(error)")
        }
    }

    /// `unlockMigrationResidual` — the release half; "Migrate anyway" composes as this call
    /// followed by `proposeImmediateMigration` — forwards to the per-account actor and returns the
    /// cleared-lock count untouched.
    func testUnlockMigrationResidualForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.unlockMigrationResidualAccountUUIDReturnValue = 7
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let cleared = try await synchronizer.unlockMigrationResidual(accountUUID: accountUUID)

        XCTAssertEqual(cleared, 7)
        XCTAssertEqual(welding.unlockMigrationResidualAccountUUIDReceivedAccountUUID, accountUUID)
    }

    /// `estimateMigrationRuns` forwards to the per-account actor and hands the engine's
    /// `MigrationRunEstimate` through unchanged — pinned with a non-trivial two-run fixture so any
    /// field cross-wiring in the pass-through would break equality, including the precomputed
    /// `actions`/`keystoneSigningSessions` fields (and their `totalActions`/
    /// `totalKeystoneSigningSessions` sums), which are a verbatim engine passthrough, not
    /// Swift-side derived math.
    func testEstimateMigrationRunsForwardsToTheAccountsActor() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let estimate = MigrationRunEstimate(
            runs: [
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(75_000_000),
                    crossings: 15,
                    preparationLayers: 2,
                    preparationTransactions: 5,
                    actions: 125,
                    keystoneSigningSessions: 2
                ),
                MigrationRunEstimate.Run(
                    migratable: Zatoshi(1_200_000),
                    crossings: 3,
                    preparationLayers: 1,
                    preparationTransactions: 1,
                    actions: 25,
                    keystoneSigningSessions: 1
                )
            ],
            finalResidual: Zatoshi(42_000)
        )
        welding.estimateMigrationRunsAccountUUIDReturnValue = estimate
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let returned = try await synchronizer.estimateMigrationRuns(accountUUID: accountUUID)

        XCTAssertEqual(returned, estimate)
        XCTAssertEqual(welding.estimateMigrationRunsAccountUUIDReceivedAccountUUID, accountUUID)
        XCTAssertEqual(returned.totalActions, 150)
        XCTAssertEqual(returned.totalKeystoneSigningSessions, 3)
    }

    // MARK: - Forwarding: Keystone batch-signing bridge (DB-free, no host)
    //
    // Unlike the rest of this group, these four bypass `migrationHost.migration(for:)` entirely --
    // DB-free and account-free, they forward straight to `initializer.rustBackend` (see
    // `SDKSynchronizer.swift`'s own "ordinary PCZT operations" precedent: `createPCZTFromProposal`,
    // `redactPCZTForSigner`, et al.), mirroring `SlipstreamSynchronizer`'s override of the same
    // four. `ZcashRustBackendWelding` is substituted into the SAME container `SDKSynchronizer.init`
    // resolves `initializer.rustBackend` from (mirrors
    // `SynchronizerOfflineTests.testPreparePropagatesSeedNotRelevantFromRustBackend`'s seam), so
    // `welding` backs both the (here, unused) `OrchardMigrationHost` and the direct rust-backend
    // forward under test.

    func testBuildKeystoneSignBatchQRPartsForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expectedParts = [
            "ur:zcash-migration-keystone-batch-sign-req/1-2/abcdefgh",
            "ur:zcash-migration-keystone-batch-sign-req/2-2/ijklmnop"
        ]
        welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenReturnValue = expectedParts
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let requestId = Data(repeating: 0x11, count: 16)
        let pczts = [
            MigrationUnsignedTransferPczt(id: 0, pczt: Data([0xAA, 0xBB]), actions: 16),
            MigrationUnsignedTransferPczt(id: 1, pczt: Data([0xCC, 0xDD, 0xEE]), actions: 3)
        ]

        let parts = try await synchronizer.buildKeystoneSignBatchQRParts(requestId: requestId, pczts: pczts, maxFragmentLen: 200)

        XCTAssertEqual(parts, expectedParts)
        XCTAssertEqual(welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenCallsCount, 1)
        let received = welding.migrationKeystoneBuildSignBatchQrPartsRequestIdPcztsMaxFragmentLenReceivedArguments
        XCTAssertEqual(received?.requestId, requestId)
        XCTAssertEqual(received?.pczts, pczts)
        XCTAssertEqual(received?.maxFragmentLen, 200)
    }

    /// Infallible and DB-free: pinned by call count alone, since there is no return value to
    /// round-trip.
    func testResetKeystoneSignBatchDecoderForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationKeystoneResetSignBatchDecoderClosure = { }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        await synchronizer.resetKeystoneSignBatchDecoder()

        XCTAssertEqual(welding.migrationKeystoneResetSignBatchDecoderCallsCount, 1)
    }

    /// Pinned with a COMPLETE result carrying a firmware version, so any field cross-wiring in the
    /// pass-through would break equality.
    func testDecodeKeystoneSignBatchPartForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = KeystoneBatchDecodeResult(
            complete: true,
            progress: 100,
            data: Data([0x01, 0x02, 0x03]),
            firmwareVersion: KeystoneFirmwareVersion(major: 1, minor: 2, build: 3)
        )
        welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdReturnValue = expected
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let expectedRequestId = Data(repeating: 0x22, count: 16)
        let part = "ur:zcash-migration-keystone-batch-sign-res/1-1/qrpayload"

        let result = try await synchronizer.decodeKeystoneSignBatchPart(part, expectedRequestId: expectedRequestId)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdCallsCount, 1)
        let received = welding.migrationKeystoneDecodeSignBatchPartExpectedRequestIdReceivedArguments
        XCTAssertEqual(received?.part, part)
        XCTAssertEqual(received?.expectedRequestId, expectedRequestId)
    }

    func testApplyKeystoneBatchSignaturesForwardsToTheRustBackend() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let expected = [
            MigrationSignedTransferPczt(id: 0, pczt: Data([0xAA, 0xBB, 0x01])),
            MigrationSignedTransferPczt(id: 1, pczt: Data([0xCC, 0xDD, 0x02]))
        ]
        welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReturnValue = expected
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        let pczts = [
            MigrationUnsignedTransferPczt(id: 0, pczt: Data([0xAA, 0xBB]), actions: 16),
            MigrationUnsignedTransferPczt(id: 1, pczt: Data([0xCC, 0xDD]), actions: 3)
        ]
        let batchSignResponse = Data(repeating: 0x33, count: 8)

        let signed = try await synchronizer.applyKeystoneBatchSignatures(pczts: pczts, batchSignResponse: batchSignResponse)

        XCTAssertEqual(signed, expected)
        XCTAssertEqual(welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseCallsCount, 1)
        let received = welding.migrationKeystoneApplyBatchSignaturesPcztsBatchSignResponseReceivedArguments
        XCTAssertEqual(received?.pczts, pczts)
        XCTAssertEqual(received?.batchSignResponse, batchSignResponse)
    }

    // MARK: - Forwarding: wallet-scope gate members

    /// The forwarding tests' "engineered-non-default blocked" driver — a gate FILE with a live
    /// in-flight broadcast marker, written where `makeHost`'s storage points so the host's
    /// wallet-scope predicate reads it. (The earlier levers — the ready-broadcast probe, then the
    /// privacy buffer — died with the gate's forward-looking clause on 2026-08-05 and its timed
    /// clause on 2026-08-07 respectively; the marker is the only condition left.)
    private func writeLiveInFlightGateFile(accountUUID: AccountUUID) throws {
        let fileURL = testGeneralStorageDirectory!
            .appendingPathComponent(MigrationSyncGate.fileName(accountUUID: accountUUID))
        let inFlightUntil = Date().addingTimeInterval(MigrationSyncGate.broadcastInFlightGuardDuration)
        let json = "{\"version\":1,\"inFlightUntilEpochSeconds\":\(inFlightUntil.timeIntervalSince1970)}"
        try Data(json.utf8).write(to: fileURL)
    }

    func testIsMigrationSyncBlockedForwardsToHostPredicate() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        try writeLiveInFlightGateFile(accountUUID: accountUUID)
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let blocked = await synchronizer.isMigrationSyncBlocked()

        // The inert protocol default always returns false; true here proves this is genuinely
        // wired to the host's own (engineered-non-default) predicate result.
        XCTAssertTrue(blocked)
    }

    func testMigrationSyncBlockedStreamForwardsToHostStream() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, tickInterval: 0.02))

        var received: [Bool] = []
        let sawBlocked = expectation(description: "the forwarded stream observed the host's live blocked state")
        let cancellable = synchronizer.migrationSyncBlockedStream.sink { value in
            received.append(value)
            if value {
                sawBlocked.fulfill()
            }
        }
        cancellables.append(cancellable)

        // The flip is driven by the gate FILE — written only after the seed emission, so the
        // "fresh host seeds false" precondition stays observable; the host's next 0.02 s recompute
        // reads the file and flips.
        while received.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try writeLiveInFlightGateFile(accountUUID: accountUUID)

        await fulfillment(of: [sawBlocked], timeout: 5)
        // The inert protocol default only ever emits false; observing true here proves this is
        // genuinely wired to the host's own reactive stream, not the static default.
        XCTAssertEqual(received.first, false, "precondition: a fresh host seeds false")
        XCTAssertEqual(received.last, true)
    }


    // MARK: - Enforcement: start() privacy gate

    func testStartThrowsMigrationSyncBlockedWhenHostReportsBlocked() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountUUID)]
        try writeLiveInFlightGateFile(accountUUID: accountUUID)
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        await synchronizer.updateStatus(.stopped)

        do {
            try await synchronizer.start(retry: false)
            XCTFail("expected start() to throw migrationSyncBlocked")
        } catch let error as ZcashError {
            guard case .migrationSyncBlocked = error else {
                XCTFail("expected migrationSyncBlocked, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0125")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }
    }

    func testStartProceedsPastTheGateWhenHostReportsUnblocked() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = []
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        await synchronizer.updateStatus(.stopped)

        do {
            try await synchronizer.start(retry: false)
            // Ideal outcome: the gate passed and start() ran to completion offline.
        } catch let error as ZcashError {
            if case .migrationSyncBlocked = error {
                XCTFail("start() must not report migrationSyncBlocked when the host reports unblocked")
            }
            // Any other ZcashError is an unrelated offline failure (no live lightwalletd) and is
            // acceptable here -- only the gate's behavior is under test.
        } catch {
            // Likewise tolerated as an unrelated offline failure.
        }

        synchronizer.stop()
    }

    // MARK: - Enforcement: broadcast guard

    func testSubmitNoteSplitThrowsDuringSyncWithoutTouchingTheHost() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.syncing(0.5, false))

        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(1_000)], fee: Zatoshi(100), proposalHandle: 1)
        let usk = TestsData(networkType: .testnet).spendingKey
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.submitNoteSplit(accountUUID: accountUUID, proposal: proposal, usk: usk, options: options)
            XCTFail("expected migrationBroadcastDuringSync")
        } catch let error as ZcashError {
            guard case .migrationBroadcastDuringSync = error else {
                XCTFail("expected migrationBroadcastDuringSync, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0126")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 0, "the guard must throw before the host is ever consulted")
        XCTAssertFalse(welding.migrationSignNoteSplitProposalUskForCalled, "the engine must never see a during-sync submission")
    }

    func testPerformMigrationBroadcastThrowsDuringSyncWithoutTouchingTheHost() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.syncing(0.5, false))

        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.performMigrationBroadcast(
                accountUUID: accountUUID,
                MigrationBroadcastInstruction(id: 1),
                options: options
            )
            XCTFail("expected migrationBroadcastDuringSync")
        } catch let error as ZcashError {
            guard case .migrationBroadcastDuringSync = error else {
                XCTFail("expected migrationBroadcastDuringSync, got \(error)")
                return
            }
            XCTAssertEqual(error.code.rawValue, "ZRUST0126")
        } catch {
            XCTFail("expected a ZcashError, got \(error)")
        }

        XCTAssertEqual(recorder.callCount, 0, "the guard must throw before the host is ever consulted")
        XCTAssertFalse(
            welding.migrationTakeBroadcastTransactionIdForCalled,
            "the engine must never see a during-sync execution attempt"
        )
    }

    /// Not-syncing companion: proves the guard does NOT trip outside the syncing case, and the call
    /// really does reach the per-account actor's engine call -- by stubbing the engine's first
    /// broadcast-flow step to throw a distinctive, non-`ZcashError` failure and observing it
    /// propagate untouched (rather than seeing `migrationBroadcastDuringSync`, or a crash from an
    /// unconfigured mock return value).
    func testSubmitNoteSplitForwardsWhenNotSyncing() async throws {
        struct StubSigningFailure: Error, Equatable {}
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationSignNoteSplitProposalUskForThrowableError = StubSigningFailure()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.stopped)

        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(1_000)], fee: Zatoshi(100), proposalHandle: 1)
        let usk = TestsData(networkType: .testnet).spendingKey
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.submitNoteSplit(accountUUID: accountUUID, proposal: proposal, usk: usk, options: options)
            XCTFail("expected the stubbed signing failure to propagate")
        } catch let error as StubSigningFailure {
            XCTAssertEqual(error, StubSigningFailure())
        } catch {
            XCTFail("expected StubSigningFailure, got \(error)")
        }

        // Note: the mock's generated body checks `...ThrowableError` before bumping `...CallsCount`,
        // so `migrationSignNoteSplitProposalUskForCalled` stays false on this path -- catching the
        // exact stub type above (which can only originate from that one call site) plus the
        // recorder count already prove the call reached the engine.
        XCTAssertEqual(recorder.callCount, 1, "the host must be consulted when the synchronizer is not syncing")
    }

    /// Not-syncing companion for `performMigrationBroadcast`, mirroring
    /// `testSubmitNoteSplitForwardsWhenNotSyncing()`.
    func testPerformMigrationBroadcastForwardsWhenNotSyncing() async throws {
        struct StubNextDueTransferFailure: Error, Equatable {}
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationTakeBroadcastTransactionIdForThrowableError = StubNextDueTransferFailure()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.stopped)

        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)

        do {
            _ = try await synchronizer.performMigrationBroadcast(
                accountUUID: accountUUID,
                MigrationBroadcastInstruction(id: 1),
                options: options
            )
            XCTFail("expected the stubbed next-due-transfer failure to propagate")
        } catch let error as StubNextDueTransferFailure {
            XCTAssertEqual(error, StubNextDueTransferFailure())
        } catch {
            XCTFail("expected StubNextDueTransferFailure, got \(error)")
        }

        // See the note in `testSubmitNoteSplitForwardsWhenNotSyncing()`: `...ThrowableError` bypasses
        // the mock's `...CallsCount` bump, so the recorder + exact stub type are the proof here.
        XCTAssertEqual(recorder.callCount, 1, "the host must be consulted when the synchronizer is not syncing")
    }

    // MARK: - The preparation accessor (the txid seam)

    /// `takeMigrationPreparation` forwards to the per-account actor and is NOT sync-guarded: it
    /// only RETRIEVES, and the pass that produces its txids is a proving pass, which by design
    /// runs inside a sync session. Guarding it would make the whole seam unreachable where the
    /// engine intends it to be used.
    ///
    /// Proved by stubbing the actor's one engine call to throw a distinctive, non-`ZcashError`
    /// failure and watching it propagate untouched WHILE THE SYNCHRONIZER IS SYNCING -- had a
    /// broadcast guard been wired in front, `migrationBroadcastDuringSync` would surface instead.
    func testTakeMigrationPreparationForwardsEvenWhileSyncing() async throws {
        struct StubTakePreparationFailure: Error, Equatable {}
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationTakePreparationTxidForThrowableError = StubTakePreparationFailure()
        let recorder = FactoryInvocationRecorder()
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding, factoryRecorder: recorder))
        await synchronizer.updateStatus(.syncing(0.5, false))

        do {
            _ = try await synchronizer.takeMigrationPreparation(
                accountUUID: accountUUID,
                byTxid: Data(repeating: 7, count: 32)
            )
            XCTFail("expected the stubbed take-preparation failure to propagate")
        } catch let error as StubTakePreparationFailure {
            XCTAssertEqual(error, StubTakePreparationFailure())
        } catch {
            XCTFail("expected StubTakePreparationFailure, got \(error)")
        }

        // See the note in `testSubmitNoteSplitForwardsWhenNotSyncing()`: `...ThrowableError` bypasses
        // the mock's `...CallsCount` bump, so the recorder + exact stub type are the proof here.
        XCTAssertEqual(recorder.callCount, 1, "a retrieval must reach the host even mid-sync")
    }

    /// The txid reaches the engine verbatim, and the DTO comes back whole -- engine transfer id
    /// included, which is what lets a host record the submission's outcome with no identity of
    /// its own.
    func testTakeMigrationPreparationPassesTheTxidThroughAndReturnsTheEngineId() async throws {
        let txid = Data(repeating: 0x5A, count: 32)
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationTakePreparationTxidForReturnValue = PreparedMigrationTransfer(
            id: 11,
            txid: txid,
            pczt: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))

        let prepared = try await synchronizer.takeMigrationPreparation(accountUUID: accountUUID, byTxid: txid)

        XCTAssertEqual(prepared.id, 11, "the engine transfer id crosses the surface")
        XCTAssertEqual(prepared.txid, txid)
        XCTAssertEqual(prepared.pczt, Data([0xDE, 0xAD, 0xBE, 0xEF]), "the finalized transaction is submittable as-is")
        XCTAssertEqual(welding.migrationTakePreparationTxidForReceivedArguments?.txid, txid)
        XCTAssertEqual(welding.migrationTakePreparationTxidForReceivedArguments?.account, accountUUID)
    }

    /// The seam's closing member forwards to the per-account actor, and — like the accessor — is
    /// NOT sync-guarded: the pass that submits a preparation is a proving pass, which runs inside
    /// a sync session. The engine's mark reaches the standard record path with the retrieval DTO's
    /// own id.
    func testRecordMigrationPreparationBroadcastForwardsEvenWhileSyncing() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationTransactionStatusesForReturnValue = [
            MigrationTransactionStatus(
                id: 5,
                kind: .preparation(layer: 0, index: 0),
                state: .proved,
                scheduledHeight: 3_000_000,
                expiryHeight: 3_000_100,
                isReady: true,
                nextAction: .broadcast,
                blockedOn: nil,
                dependsOn: [],
                anchorBoundaryHeight: nil
            )
        ]
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let synchronizer = try makeSynchronizer(migrationHost: makeHost(welding: welding))
        await synchronizer.updateStatus(.syncing(0.5, false))

        let prepared = PreparedMigrationTransfer(id: 5, txid: Data(repeating: 0x5A, count: 32), pczt: Data([0x01]))
        try await synchronizer.recordMigrationPreparationBroadcast(
            accountUUID: accountUUID,
            prepared,
            result: .success(txId: prepared.txid.toHexStringTxId())
        )

        let received = try XCTUnwrap(welding.migrationRecordTransferResultTransferIdResultForReceivedArguments)
        XCTAssertEqual(received.transferId, 5, "the engine mark is keyed by the retrieval DTO's id")
        XCTAssertEqual(received.account, accountUUID)
    }

    // MARK: - Resource lifecycle: migration-host registration must not retain the Initializer

    /// Regression test: `SDKSynchronizer.init` registers a factory closure for `OrchardMigrationHost`
    /// on `initializer.container`. If that closure captures `initializer` with no capture list, the
    /// result is a cycle -- `initializer` owns `container` (`Initializer.container: DIContainer`),
    /// `container` stores the closure, and the closure captures `initializer` right back
    /// (`initializer -> container -> closure -> initializer`). Once that happens, `initializer` (and
    /// everything it owns: the container, the resolved `OrchardMigrationHost`, every per-account actor)
    /// outlives the synchronizer that built it for as long as the container itself stays reachable --
    /// e.g. this test's `mockContainer`, which `ZcashTestCase` keeps alive for the whole test method,
    /// well past this test's own local scope.
    ///
    /// Deliberately does NOT go through `makeSynchronizer(migrationHost:)`/`makeHost(welding:)` like
    /// every other test in this file: pre-mocking `OrchardMigrationHost` would mean `SDKSynchronizer.init`
    /// resolves the *mock* dependency, and `DIContainer.resolve`'s singleton-cache write-back
    /// (`dependencies[key] = Dependency(factory: dependency.factory, ...)`) always writes into the
    /// non-mock `dependencies` dictionary, even when what it just resolved came from `mockedDependencies`
    /// -- so a pre-registered mock overwrites (and thereby immediately releases) the real,
    /// initializer-capturing closure before it is ever invoked, which would hide this exact bug. Letting
    /// `SDKSynchronizer.init` register and resolve the real `OrchardMigrationHost(initializer:)` is what
    /// exercises the production code path the bug lives in.
    ///
    /// Also deliberately does NOT go through `SDKSynchronizer.init(initializer:)` (the public convenience
    /// initializer): that convenience initializer builds its `CompactBlockProcessor` with
    /// `walletBirthdayProvider: { initializer.walletBirthday }`, an unrelated, pre-existing closure (predates
    /// this migration work) that captures `initializer` and ends up retained by the container too, via
    /// `Dependencies.setupCompactBlockProcessor`'s `UTXOFetcher` registration
    /// (`UTXOFetcherConfig(walletBirthdayProvider: config.walletBirthdayProvider)`). That is a second,
    /// independent container/`Initializer` cycle -- out of scope here (not part of the migration-host
    /// registration this test targets) -- that would otherwise keep `initializer` alive regardless of
    /// this fix and make the test unable to isolate the one cycle it exists to catch. Calling the
    /// designated initializer directly, with a `walletBirthdayProvider` that returns a constant instead of
    /// capturing `initializer`, sidesteps that unrelated cycle without touching any production code.
    func testMigrationHostRegistrationDoesNotLeakTheInitializer() throws {
        weak var weakInitializer: Initializer?
        weak var weakSynchronizer: SDKSynchronizer?

        func buildAndReleaseSynchronizer() throws {
            let initializer = Initializer(
                container: mockContainer,
                cacheDbURL: nil,
                fsBlockDbRoot: testTempDirectory,
                generalStorageURL: testGeneralStorageDirectory,
                dataDbURL: try __dataDbURL(),
                torDirURL: try __torDirURL(),
                endpoint: LightWalletEndpointBuilder.default,
                network: ZcashNetworkBuilder.network(for: .testnet),
                spendParamsURL: try __spendParamsURL(),
                outputParamsURL: try __outputParamsURL(),
                saplingParamsSourceURL: SaplingParamsSourceURL.tests,
                isTorEnabled: false,
                isExchangeRateEnabled: false
            )
            let blockProcessor = CompactBlockProcessor(
                initializer: initializer,
                walletBirthdayProvider: { 0 }
            )
            let synchronizer = SDKSynchronizer(
                status: .unprepared,
                initializer: initializer,
                transactionEncoder: WalletTransactionEncoder(initializer: initializer),
                transactionRepository: initializer.transactionRepository,
                blockProcessor: blockProcessor,
                syncSessionTicker: .live
            )

            weakInitializer = initializer
            weakSynchronizer = synchronizer
        }

        try buildAndReleaseSynchronizer()

        XCTAssertNil(weakSynchronizer, "SDKSynchronizer should deallocate once every strong reference to it goes out of scope")
        XCTAssertNil(
            weakInitializer,
            """
            Initializer should deallocate once its owning SDKSynchronizer is gone -- a non-nil value means the \
            OrchardMigrationHost registration closure is still retaining it (initializer -> container -> closure -> initializer)
            """
        )
    }

    // MARK: - Helpers

    /// Builds an `SDKSynchronizer` whose one `OrchardMigrationHost` is `migrationHost`, substituted
    /// via the same container-mock seam `SDKSynchronizer.init` resolves the production host through.
    private func makeSynchronizer(migrationHost: OrchardMigrationHost) throws -> SDKSynchronizer {
        mockContainer.mock(type: OrchardMigrationHost.self, isSingleton: true) { _ in migrationHost }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        return SDKSynchronizer(initializer: initializer)
    }

    /// Builds an `OrchardMigrationHost` via its injecting initializer, following R4-A's
    /// `OrchardMigrationHostTests` seam: `welding` backs both the wallet-scope predicate and every
    /// per-account actor the (scripted) `actorFactory` produces. `factoryRecorder`, when supplied,
    /// counts every `actorFactory` invocation -- i.e. every time `migrationHost.migration(for:)`
    /// actually built (or reused... no, `migration(for:)` caches, so this only fires once per
    /// account) a per-account actor, which is what the broadcast guard's "never touched the host"
    /// assertions pin.
    private func makeHost(
        welding: ZcashRustBackendWeldingMock,
        broadcaster: any MigrationBroadcasting = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
        tickInterval: TimeInterval = 3600,
        factoryRecorder: FactoryInvocationRecorder? = nil
    ) -> OrchardMigrationHost {
        // `isSyncBlocked()`/`syncBlockedStream`/`start()`'s privacy gate unconditionally read
        // `migrationBlockRateSamples` (`ChainTipEstimator`'s raw input); default it to "no samples"
        // so a test that never cares about the estimate does not crash on the mock's un-stubbed,
        // implicitly-unwrapped `ReturnValue` -- a test that DOES care sets it itself before calling
        // this helper, which this guard leaves untouched.
        if welding.migrationBlockRateSamplesWindowReturnValue == nil {
            welding.migrationBlockRateSamplesWindowReturnValue = []
        }
        let storage = testGeneralStorageDirectory!
        return OrchardMigrationHost(
            welding: welding,
            sharedBroadcaster: broadcaster,
            generalStorageURL: storage,
            tickInterval: tickInterval,
            now: { Date() },
            logger: logger,
            actorFactory: { accountUUID, broadcaster in
                factoryRecorder?.recordCall()
                return OrchardMigration(
                    welding: welding,
                    accountUUID: accountUUID,
                    broadcaster: broadcaster,
                    syncGate: MigrationSyncGate(
                        directory: storage,
                        accountUUID: accountUUID,
                        tickInterval: tickInterval,
                        now: { Date() },
                        logger: logger
                    ),
                    logger: logger
                )
            }
        )
    }

    private func makeAccount(_ uuid: AccountUUID) -> Account {
        Account(
            id: uuid,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
    }
}

/// Records how many times a scripted `OrchardMigrationHost` `actorFactory` closure ran -- i.e. how
/// many times `migrationHost.migration(for:)` actually had to build a per-account actor. Mutated
/// synchronously from the (non-async) `actorFactory` closure, which this suite's tests only ever
/// invoke serially -- mirroring how `ZcashRustBackendWeldingMock`'s own plain `CallsCount` fields
/// are mutated in this codebase's generated mocks.
private final class FactoryInvocationRecorder {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}
