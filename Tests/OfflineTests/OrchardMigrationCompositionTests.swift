//
//  OrchardMigrationCompositionTests.swift
//  OfflineTests
//
//  Actor-composition tests for `OrchardMigration`, driven through its internal injecting
//  initializer against `ZcashRustBackendWeldingMock` plus hand-written fakes for the
//  `MigrationBroadcasting` seam and a real, temp-file-backed `MigrationSyncGate` (as established by
//  MigrationLogicTests.swift's I1 canary test). No network, no real FFI: this file exercises the
//  composition wiring (call order, what gets recorded, when the sync gate's in-flight marker is
//  armed and released) over those
//  seams, complementing MigrationFFITests.swift (real FFI) and MigrationLogicTests.swift (pure
//  logic).
//

import XCTest
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class OrchardMigrationCompositionTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x33, count: 16))
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let defaultEndpoint = LightWalletEndpoint(address: "default.example", port: 9067)
    private let usk = UnifiedSpendingKey(network: .testnet, bytes: [UInt8](repeating: 0xEE, count: 32))

    private var welding: ZcashRustBackendWeldingMock!
    private var clock: TestClock!
    private var gate: MigrationSyncGate!

    override func setUp() {
        super.setUp()
        welding = ZcashRustBackendWeldingMock()
        clock = TestClock(referenceDate)
        gate = makeGate(account: accountA, clock: clock)
    }

    override func tearDown() {
        welding = nil
        clock = nil
        gate = nil
        super.tearDown()
    }

    // MARK: - submitNoteSplit composition

    /// Proves the full `sign -> broadcast -> record` order for the success path, and that the
    /// mapped result is returned. There is no extract step any more: the ceremony's handback comes
    /// through the store's broadcast seam already finalized, so what reaches the broadcaster is
    /// `prepared.pczt` verbatim. The `record` closure additionally asserts the in-flight marker is
    /// still armed at the moment it runs, pinning "the submit-to-record window stays bracketed
    /// until the record lands"; the marker is released only afterwards.
    func testSubmitNoteSplitOrdersSignBroadcastThenRecordsOnSuccess() async throws {
        let recorder = CompositionOrderRecorder()
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)

        welding.migrationSignNoteSplitProposalUskForClosure = { receivedProposal, receivedUsk, receivedAccount in
            recorder.record("sign")
            XCTAssertEqual(receivedProposal, proposal)
            XCTAssertEqual(receivedUsk, self.usk)
            XCTAssertEqual(receivedAccount, self.accountA)
            return prepared
        }
        welding.migrationRecordTransferResultTransferIdResultForClosure = { transferId, result, _ in
            recorder.record("record")
            XCTAssertEqual(transferId, prepared.id)
            XCTAssertEqual(result, MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId()))
            // Ordering proof: the submit-to-record window must still be open when record runs.
            XCTAssertNotNil(self.gate.currentInFlightUntil())
        }

        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        broadcaster.onBroadcast = { recorder.record("broadcast") }
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.submitNoteSplit(
            proposal: proposal,
            usk: usk,
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId()))
        XCTAssertEqual(recorder.events, ["sign", "broadcast", "record"])
        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertEqual(
            broadcaster.receivedCalls.first?.rawTransaction,
            prepared.pczt,
            "the seam's finalized bytes are submitted verbatim, with no extract step"
        )
        XCTAssertEqual(broadcaster.receivedCalls.first?.endpoint, defaultEndpoint)
        XCTAssertNil(gate.currentInFlightUntil(), "the recorded outcome closes the submit-to-record window")
        XCTAssertFalse(gate.currentlyBlocked(), "a completed broadcast leaves no timed hold behind")
    }

    /// Transport failure is *returned*, not thrown: recorded as a retryable network error, with
    /// the gate released once the outcome is durably recorded.
    func testSubmitNoteSplitOnTransportFailureRecordsNetworkErrorAndReleasesTheGate() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)
        welding.migrationSignNoteSplitProposalUskForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))
        let migration = makeMigration(broadcaster: broadcaster)

        // A plain `try await` (no do/catch) already proves this does not throw; the assertions below
        // pin down the recorded/gate side effects.
        let result = try await migration.submitNoteSplit(
            proposal: proposal,
            usk: usk,
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, MigrationTransferResult.networkError(retryable: true))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.networkError(retryable: true)
        )
        XCTAssertNil(gate.currentInFlightUntil(), "the recorded outcome closes the submit-to-record window")
        XCTAssertFalse(gate.currentlyBlocked())
    }

    /// The sibling of MigrationLogicTests' `testPerformBroadcastFailsClosedOnTor...`
    /// canary, driven through `submitNoteSplit` instead of `performBroadcast`: both public
    /// entry points share the same private `broadcastAndRecord` composition, so the fail-closed Tor
    /// guarantee must hold from this call site too.
    func testSubmitNoteSplitFailsClosedOnTorUnavailableWithoutRecordingOrGating() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        let prepared = makePreparedTransfer(id: 0)
        welding.migrationSignNoteSplitProposalUskForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.submitNoteSplit(
                proposal: proposal,
                usk: usk,
                options: MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected migrationTorUnavailable to be thrown")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        } catch {
            XCTFail("Expected migrationTorUnavailable but got \(error)")
        }

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertNil(gate.currentInFlightUntil(), "a fail-closed pre-submit throw must leave no marker behind")
        XCTAssertFalse(gate.currentlyBlocked())
    }

    // MARK: - performBroadcast composition

    /// THE EXECUTOR IS SUBSERVIENT TO THE DRIVE AND NEVER RE-ASKS IT: given an instruction, it
    /// serves exactly that id and never cranks `migrationAdvanceStep` — which is what makes the
    /// removal of the old lane's internal advance observable rather than a refactoring detail.
    func testPerformBroadcastServesTheInstructedIdWithoutCrankingTheDrive() async throws {
        let prepared = makePreparedTransfer(id: 7)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationTransactionStatusesForReturnValue = []
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .outcome(.submitted)))

        _ = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: 7),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(welding.migrationTakeBroadcastTransactionIdForReceivedArguments?.id, 7)
        XCTAssertFalse(
            welding.migrationAdvanceStepForEstimatedTipCalled,
            "the executor discharges the instruction it was given; it never asks the engine what to serve"
        )
        XCTAssertFalse(
            welding.migrationBlockRateSamplesWindowCalled,
            "and therefore never pays for the tip projection the advance would have needed"
        )
    }

    /// A STALE instruction is refused by the seam, not silently re-interpreted: the executor lets
    /// the refusal through untouched (nothing broadcast, nothing recorded, gate untouched), which
    /// is the caller's signal to crank again rather than retry.
    func testPerformBroadcastPropagatesTheSeamsStalenessRefusalWithoutBroadcasting() async throws {
        welding.migrationTakeBroadcastTransactionIdForThrowableError =
            ZcashError.rustMigrationTakeBroadcastTransaction("transaction 7 is not proved-and-servable")
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: 7),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected the staleness refusal to propagate")
        } catch ZcashError.rustMigrationTakeBroadcastTransaction {
            // expected
        }

        XCTAssertEqual(broadcaster.receivedCalls.count, 0)
        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
        XCTAssertNil(gate.currentInFlightUntil(), "a serve that never reached the network arms no marker")
    }

    func testPerformBroadcastSuccessPathRecordsAndReleasesTheGate() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, .success(txId: prepared.txid.toHexStringTxId()))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId())
        )
        XCTAssertNil(gate.currentInFlightUntil(), "the recorded outcome closes the submit-to-record window")
        XCTAssertFalse(gate.currentlyBlocked(), "a completed broadcast leaves no timed hold behind")
    }

    /// M5: seam-based coverage of the rejection branch's generic (non-expiry) message, at the
    /// composition level -- not just the pure `map` table already covered by MigrationLogicTests.
    func testPerformBroadcastInvalidNoteRejectionRecordsAndReleasesTheGate() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.rejected(errorCode: -25, message: "missing inputs")))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, .invalidNote)
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.invalidNote
        )
        XCTAssertNil(gate.currentInFlightUntil())
        XCTAssertFalse(gate.currentlyBlocked())
    }

    /// M5: seam-based coverage of the rejection branch's expiry message, at the composition level.
    func testPerformBroadcastExpiredRejectionRecordsAndReleasesTheGate() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.rejected(errorCode: -26, message: "tx-expiring-soon")))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, .expired)
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.expired
        )
        XCTAssertNil(gate.currentInFlightUntil())
        XCTAssertFalse(gate.currentlyBlocked())
    }

    /// Broadcaster single-endpoint discipline: exactly one call, to the options' required
    /// submission endpoint.
    func testBroadcasterReceivesExactlyOneCallToTheResolvedEndpoint() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let overrideEndpoint = LightWalletEndpoint(address: "override.example", port: 443)
        XCTAssertNotEqual(overrideEndpoint, defaultEndpoint)
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        _ = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: overrideEndpoint)
        )

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertEqual(broadcaster.receivedCalls.first?.endpoint, overrideEndpoint)
    }

    // MARK: - Estimated-tip wiring
    //
    // The estimate now enters through ONE door: `advanceStep()`, the conduit. With the
    // kind-filtered lanes gone, no executor projects a tip of its own, so these tests pin the
    // conduit's wiring and the `hasOverdueTransfers` read's opt-in — nothing else consults it.

    /// `advanceStep()` — the sole crank, and the sole entry point the public conduit uses — ALWAYS
    /// drives the engine with both targets; there is no opt-out overload any more (it existed for
    /// the kind-filtered lanes, which are gone), so the only way the estimate can be lost HERE is
    /// silently, by reaching the welding as
    /// `nil`. Pins the exact projected value rather than just non-nil: one sample 150 s (two 75 s
    /// target-spacing blocks) before the frozen clock projects to height + 2, which neither a
    /// dropped estimate nor a wall-clock leak can produce.
    func testAdvanceStepPassesTheProjectedTipEstimateToTheWelding() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-150)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let advance = try await migration.advanceStep()

        XCTAssertEqual(advance?.step, .waiting)
        let received = try XCTUnwrap(welding.migrationAdvanceStepForEstimatedTipReceivedArguments)
        XCTAssertEqual(received.account, accountA)
        XCTAssertEqual(
            received.estimatedTip,
            3_000_002,
            "the advance step must carry the tip projected at the actor's injected clock (height + floor(150/75))"
        )
    }

    /// The other half of the gating contract: an estimator failure degrades `advanceStep()` to the
    /// scanned-tip behavior (`nil`) instead of propagating — the estimate may accelerate the
    /// engine's scheduled-height due-ness, never block the call that consults it.
    func testAdvanceStepDegradesToNilTipWhenBlockRateSamplesThrows() async throws {
        welding.migrationBlockRateSamplesWindowThrowableError = StubEngineError()
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let advance = try await migration.advanceStep()

        XCTAssertEqual(advance?.step, .waiting, "an estimator failure must not fail the advance step")
        XCTAssertNil(
            welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.estimatedTip,
            "an estimator failure must degrade to the scanned-tip behavior"
        )
    }

    /// `hasOverdueTransfers(useEstimatedTip:)` mirrors the conduit's wiring on the READ side:
    /// `true` feeds a projected tip into the welding's overdue check, `false` always passes `nil`.
    func testHasOverdueTransfersPassesTheEstimatedTipOnlyWhenRequested() async throws {
        let sampleTime = referenceDate.addingTimeInterval(-100)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        welding.migrationHasOverdueTransfersForEstimatedTipReturnValue = false
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        _ = try await migration.hasOverdueTransfers(useEstimatedTip: false)
        XCTAssertNil(welding.migrationHasOverdueTransfersForEstimatedTipReceivedArguments?.estimatedTip)

        _ = try await migration.hasOverdueTransfers(useEstimatedTip: true)
        XCTAssertNotNil(welding.migrationHasOverdueTransfersForEstimatedTipReceivedArguments?.estimatedTip)
    }

    // MARK: - Txid byte order (welding record path)

    /// Finding 12: pins the EXACT bytes `migrationRecordTransferResult` receives across the welding
    /// record boundary, using an ascending, asymmetric txid fixture -- reversing it changes every
    /// byte, so a byte-order regression cannot hide the way it could behind this file's other tests'
    /// symmetric `makePreparedTransfer`/`Data(repeating: 0xAB, count: 32)` fixture (reversing 32
    /// identical bytes is a no-op; those tests would stay green even if the byte-order reversal
    /// silently dropped out of `OrchardMigration.broadcastAndRecord`).
    ///
    /// `expectedDisplayTxId` is hand-derived from the documented convention (reverse `prepared.txid`'s
    /// byte order, then hex-encode -- see `PreparedMigrationTransfer.txid` and
    /// `MigrationTransferResult.success`'s doc comments) independently of `Data.toHexStringTxId()`,
    /// not produced by running it and pasting the output. See `TxIdTests` for the same convention
    /// pinned directly against the conversion helpers themselves, off the actor.
    func testPerformBroadcastRecordsTheDocumentedByteOrderForAnAsymmetricTxId() async throws {
        let rawTxId: [UInt8] = (0..<32).map { UInt8($0) }
        let expectedDisplayTxId = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        let prepared = PreparedMigrationTransfer(id: 1, txid: Data(rawTxId), pczt: Data([0x01, 0x02]))
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let result = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(result, .success(txId: expectedDisplayTxId))
        XCTAssertEqual(
            welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.result,
            MigrationTransferResult.success(txId: expectedDisplayTxId)
        )
    }

    // MARK: - Record failure after a successful broadcast

    /// When the broadcast succeeded but recording the result throws, the in-flight marker must be
    /// RETAINED — the result was never recorded, which is exactly the submit-to-record gap the
    /// marker guards, and it self-expires on its own — and the call must surface the
    /// distinguishable `migrationRecordFailedAfterBroadcast` so the host knows the engine
    /// reconciles later.
    func testPerformBroadcastRecordThrowAfterSuccessfulBroadcastRetainsMarkerAndThrowsWrapped() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: prepared.id),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected migrationRecordFailedAfterBroadcast to be thrown")
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // expected
        } catch {
            XCTFail("Expected migrationRecordFailedAfterBroadcast but got \(error)")
        }

        XCTAssertEqual(broadcaster.receivedCalls.count, 1)
        XCTAssertNotNil(
            gate.currentInFlightUntil(),
            "an unrecorded but landed broadcast must retain the protective in-flight marker"
        )
    }

    /// The sibling of the test above for the other public broadcast flow.
    func testSubmitNoteSplitRecordThrowAfterSuccessfulBroadcastRetainsMarkerAndThrowsWrapped() async throws {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        welding.migrationSignNoteSplitProposalUskForReturnValue = makePreparedTransfer(id: 0)
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.submitNoteSplit(
                proposal: proposal,
                usk: usk,
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected migrationRecordFailedAfterBroadcast to be thrown")
        } catch ZcashError.migrationRecordFailedAfterBroadcast {
            // expected
        } catch {
            XCTFail("Expected migrationRecordFailedAfterBroadcast but got \(error)")
        }

        XCTAssertNotNil(
            gate.currentInFlightUntil(),
            "an unrecorded but landed broadcast must retain the protective in-flight marker"
        )
    }

    /// A record failure on a non-success outcome (here a transport error — nothing verifiably
    /// landed) propagates the raw error unwrapped: the
    /// record-failed-after-broadcast contract is reserved for outcomes that map to success.
    /// A11: the in-flight marker is RETAINED — a transport failure cannot prove the submit did
    /// not land, exactly the submit-to-record ambiguity the marker exists for (it self-expires).
    func testPerformBroadcastRecordThrowOnTransportErrorPropagatesRawAndLeavesGateUntouched() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: prepared.id),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected the raw record error to be rethrown")
        } catch is StubEngineError {
            // expected
        } catch {
            XCTFail("Expected StubEngineError but got \(error)")
        }

        XCTAssertNotNil(
            gate.currentInFlightUntil(),
            "A11: a record throw on a network error must retain the protective in-flight marker"
        )
    }

    /// A11, the definitive-rejection half: when the server's answer PROVES nothing landed (an
    /// expired / invalid-note rejection), a record throw clears the in-flight marker first — the
    /// submit-to-record ambiguity is over, so sync must not stay blocked for the marker's full
    /// self-expiry window — and then rethrows the raw record error.
    func testPerformBroadcastRecordThrowOnDefinitiveRejectionClearsInFlightMarkerAndRethrows() async throws {
        let rejections: [(script: MigrationBroadcastOutcome, expected: MigrationTransferResult)] = [
            (MigrationBroadcastOutcome.rejected(errorCode: -25, message: "tx-expiring-soon"), MigrationTransferResult.expired),
            (MigrationBroadcastOutcome.rejected(errorCode: -25, message: "bad-txns-inputs-spent"), MigrationTransferResult.invalidNote)
        ]

        for (script, expected) in rejections {
            let prepared = makePreparedTransfer(id: 1)
            welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
            welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
            let broadcaster = ScriptedBroadcaster(script: .outcome(script))
            let migration = makeMigration(broadcaster: broadcaster)

            do {
                _ = try await migration.performBroadcast(
                    MigrationBroadcastInstruction(id: prepared.id),
                    options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
                )
                XCTFail("Expected the raw record error to be rethrown for \(expected)")
            } catch is StubEngineError {
                // expected
            } catch {
                XCTFail("Expected StubEngineError but got \(error) for \(expected)")
            }

            // The mock throws before capturing arguments, so the mapped-result routing is pinned
            // by the non-throwing rejection tests above; here only the gate effects matter.
            XCTAssertNil(
                gate.currentInFlightUntil(),
                "A11: a definitive rejection proves nothing landed — the marker must be cleared before the rethrow (\(expected))"
            )
        }
    }

    /// A11 control: with the record SUCCEEDING, a non-success outcome still ends with the marker
    /// cleared (the outcome is durably recorded, so the submit-to-record window is closed).
    func testPerformBroadcastRecordSuccessOnNetworkErrorClearsInFlightMarker() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .outcome(.transportError)))

        _ = try await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertNil(gate.currentInFlightUntil(), "a recorded outcome closes the submit-to-record window")
    }

    // MARK: - In-flight marker arming at submit time (A9)

    /// A9: the in-flight marker is (re-)armed via the broadcaster's `onWillSubmit` hook at the
    /// LAST pre-submit instant — after connection setup — so its 120 s window covers the actual
    /// submit-to-record span rather than being burned by a slow Tor bootstrap. Pinned by
    /// capturing, at the exact moment the fake fires the hook, that the marker was already armed
    /// once (the early belt) and that the hook re-arms it: the re-armed expiry read AFTER the
    /// hook equals the hook-time clock + guard, not the (earlier) flow-start arm.
    func testPerformBroadcastReArmsTheInFlightMarkerAtSubmitTimeViaTheHook() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        welding.migrationRecordTransferResultTransferIdResultForThrowableError = StubEngineError()
        let broadcaster = ScriptedBroadcaster(script: .outcome(.transportError))

        // Stand in for a slow Tor bootstrap: by the time the fake reaches its pre-submit hook,
        // 90 s of the early (belt) marker's 120 s window have already elapsed.
        var armedAtHookTime: Date?
        broadcaster.onWillSubmitObserver = { [clock, gate] in
            armedAtHookTime = gate?.currentInFlightUntil()
            clock?.now = self.referenceDate.addingTimeInterval(90)
        }
        let migration = makeMigration(broadcaster: broadcaster)

        do {
            _ = try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: prepared.id),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
            XCTFail("Expected the record error to be rethrown (retaining the marker)")
        } catch is StubEngineError {
            // expected — a network-error record throw retains the marker (A11), letting this test
            // read the post-hook marker without the success path's clear.
        }

        XCTAssertEqual(broadcaster.onWillSubmitCallCount, 1)
        XCTAssertEqual(
            armedAtHookTime,
            referenceDate.addingTimeInterval(MigrationSyncGate.broadcastInFlightGuardDuration),
            "the early belt arm must already be in place when the hook fires"
        )
        XCTAssertEqual(
            gate.currentInFlightUntil(),
            referenceDate.addingTimeInterval(90 + MigrationSyncGate.broadcastInFlightGuardDuration),
            "the hook must RE-arm the marker at submit time, extending the window past the bootstrap"
        )
    }

    /// A9's no-submit half, via the composition: a fail-closed broadcaster throw means the hook
    /// never fired and the flow's early belt marker is cleared — nothing is in flight.
    func testPerformBroadcastFailClosedThrowNeverFiresTheHook() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepared
        let broadcaster = ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable))
        let migration = makeMigration(broadcaster: broadcaster)

        _ = try? await migration.performBroadcast(
            MigrationBroadcastInstruction(id: prepared.id),
            options: MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(broadcaster.onWillSubmitCallCount, 0, "a pre-submit throw must never fire the hook")
        XCTAssertNil(gate.currentInFlightUntil(), "the early belt marker is cleared when nothing reached the network")
    }

    // MARK: - proveTransactions composition

    /// The prove executor MARSHALS AND NOTHING ELSE: it names exactly the ids of the instruction
    /// it was handed, in order, forwards the caller's budget, and — the load-bearing half — never
    /// cranks the drive. The removed sweep's loop is gone with it: one call, one prove batch, and
    /// the OUTCOME the engine reports — count and preparation txids alike, passed through
    /// untouched (no kind judgment of its own: the engine's return already carries it).
    func testProveTransactionsNamesTheInstructionsIdsWithoutCrankingTheDrive() async throws {
        let preparationTxid = Data(repeating: 8, count: 32)
        welding.migrationProveTransactionsIdsMaxProofsForReturnValue =
            MigrationProveOutcome(totalProved: 2, preparationTxids: [preparationTxid])
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))
        let instruction = [
            MigrationProveTarget(id: 7, kind: .transfer(crossing: 0), isScheduleDue: false),
            MigrationProveTarget(id: 8, kind: .preparation(layer: 0, index: 1), isScheduleDue: true)
        ]

        let proved = try await migration.proveTransactions(instruction, maxProofs: 4)

        XCTAssertEqual(
            proved,
            MigrationProveOutcome(totalProved: 2, preparationTxids: [preparationTxid]),
            "the outcome reaches the caller verbatim: the total counts both kinds, the txids name only the preparation"
        )
        let received = try XCTUnwrap(welding.migrationProveTransactionsIdsMaxProofsForReceivedArguments)
        XCTAssertEqual(received.ids, [7, 8], "the instruction's ids, in its own order")
        XCTAssertEqual(received.maxProofs, 4, "the caller's session budget reaches the engine unmodified")
        XCTAssertEqual(received.account, accountA)
        XCTAssertEqual(
            welding.migrationProveTransactionsIdsMaxProofsForCallsCount,
            1,
            "one call per instruction: the re-advance loop belongs to the driver now"
        )
        XCTAssertFalse(
            welding.migrationAdvanceStepForEstimatedTipCalled,
            "the executor discharges the instruction it was given; it never asks the engine what to prove"
        )
    }

    /// A NON-POSITIVE BUDGET is a caller bug, named rather than silently treated as "prove
    /// nothing" — and the engine is never touched.
    func testProveTransactionsRejectsANonPositiveBudgetWithoutTouchingTheEngine() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))
        let instruction = [MigrationProveTarget(id: 7, kind: .transfer(crossing: 0), isScheduleDue: false)]

        for budget in [0, -1] {
            do {
                _ = try await migration.proveTransactions(instruction, maxProofs: budget)
                XCTFail("Expected a budget of \(budget) to be rejected")
            } catch ZcashError.rustMigrationProveTransactions {
                // expected
            } catch {
                XCTFail("Expected rustMigrationProveTransactions but got \(error) for budget \(budget)")
            }
        }

        XCTAssertFalse(welding.migrationProveTransactionsIdsMaxProofsForCalled)
    }

    /// An EMPTY instruction is the benign EMPTY OUTCOME (the engine never issues one, but a caller
    /// that filters its batch down to nothing must not fault): still one forwarded call, still no
    /// crank, and no preparation txid to hand off.
    func testProveTransactionsWithAnEmptyInstructionProvesNothing() async throws {
        welding.migrationProveTransactionsIdsMaxProofsForReturnValue =
            MigrationProveOutcome(totalProved: 0, preparationTxids: [])
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let proved = try await migration.proveTransactions([], maxProofs: 1)

        XCTAssertEqual(proved, MigrationProveOutcome(totalProved: 0, preparationTxids: []))
        XCTAssertEqual(welding.migrationProveTransactionsIdsMaxProofsForReceivedArguments?.ids, [])
        XCTAssertFalse(welding.migrationAdvanceStepForEstimatedTipCalled)
    }

    // MARK: - Closing the txid seam: the engine-side mark for an app-submitted preparation

    /// A preparation row for the gate to read. Only `id` and `kind` matter here — the gate asks
    /// the engine's public status view "is this id a preparation", nothing more.
    private func makeStatusRow(id: UInt32, kind: MigrationTransactionStatus.Kind) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: kind,
            state: .proved,
            scheduledHeight: 3_000_000,
            expiryHeight: 3_000_100,
            isReady: true,
            nextAction: .broadcast,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// THE LOOP CLOSES ON THE ENGINE. A preparation the host retrieved and submitted itself gets
    /// the same `Proved -> Broadcast` mark `performBroadcast`'s success arm makes — forwarded to
    /// the SAME welding record member, keyed by the id the retrieval DTO carried, with the host's
    /// outcome passed through verbatim.
    func testRecordPreparationBroadcastMarksThroughTheStandardRecordPath() async throws {
        let prepared = makePreparedTransfer(id: 5)
        welding.migrationTransactionStatusesForReturnValue = [
            makeStatusRow(id: 5, kind: .preparation(layer: 0, index: 0))
        ]
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))
        let landed = MigrationTransferResult.success(txId: prepared.txid.toHexStringTxId())

        try await migration.recordPreparationBroadcast(prepared, result: landed)

        let received = try XCTUnwrap(welding.migrationRecordTransferResultTransferIdResultForReceivedArguments)
        XCTAssertEqual(received.transferId, 5, "the mark is keyed by the retrieval DTO's engine transfer id")
        XCTAssertEqual(received.result, landed, "the host's outcome reaches the engine unmodified")
        XCTAssertEqual(received.account, accountA)
    }

    /// PREPARATION-GATED, in the accessor's own register. A transfer's id is refused and NOTHING is
    /// recorded: a transfer is served by the drive's broadcast instruction alone, and that
    /// broadcast records its own outcome — a second mark from here would be an app-side claim
    /// about a lane the app does not drive.
    func testRecordPreparationBroadcastRefusesATransferId() async throws {
        let prepared = makePreparedTransfer(id: 7)
        welding.migrationTransactionStatusesForReturnValue = [
            makeStatusRow(id: 7, kind: .transfer(crossing: 0))
        ]
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        do {
            try await migration.recordPreparationBroadcast(prepared, result: .success(txId: "landed"))
            XCTFail("a transfer's id must be refused")
        } catch let ZcashError.rustMigrationRecordTransferResult(message) {
            XCTAssertTrue(
                message.contains("transfers are served by the drive's broadcast instruction alone"),
                "the gate must speak the seam's own register, got: \(message)"
            )
        }

        XCTAssertFalse(
            welding.migrationRecordTransferResultTransferIdResultForCalled,
            "a gated id must never reach the record path"
        )
    }

    /// An id the stored run does not carry is refused the same way, and likewise records nothing.
    /// The DTO is a plain value type, so its `id` is an assertion the gate checks rather than a
    /// capability it trusts.
    func testRecordPreparationBroadcastRefusesAnUnknownId() async throws {
        let prepared = makePreparedTransfer(id: 99)
        welding.migrationTransactionStatusesForReturnValue = [
            makeStatusRow(id: 5, kind: .preparation(layer: 0, index: 0))
        ]
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        do {
            try await migration.recordPreparationBroadcast(prepared, result: .success(txId: "landed"))
            XCTFail("an id the run does not carry must be refused")
        } catch let ZcashError.rustMigrationRecordTransferResult(message) {
            XCTAssertTrue(message.contains("no migration transaction with id 99"), "got: \(message)")
        }

        XCTAssertFalse(welding.migrationRecordTransferResultTransferIdResultForCalled)
    }

    // MARK: - Broadcast single-flight

    /// Pins the single-flight discipline of the broadcast flows, now that it lives INSIDE the
    /// broadcast executor: with one `performBroadcast` deliberately suspended inside its broadcast,
    /// a second concurrent call holding the SAME instruction must not re-fetch and re-broadcast the
    /// same bytes. It waits for the in-flight flow, and only then serves — by which time the
    /// engine's own per-row state gating refuses the now-stale row.
    ///
    /// That refusal is the backstop the removed internal re-advance used to substitute for: the
    /// executor cannot report "nothing due" any more (it has an instruction, not a question), so a
    /// stale instruction is a throw the caller discharges by cranking again. The single-flight
    /// guard is still what makes the two flows strictly ordered rather than racing.
    /// Deterministic: the broadcaster suspends until the test opens it, and the seam refuses only
    /// once the first flow's result is recorded.
    func testConcurrentPerformBroadcastBroadcastsExactlyOnce() async throws {
        let prepared = makePreparedTransfer(id: 1)
        welding.migrationTakeBroadcastTransactionIdForClosure = { [welding] _, _ in
            // The engine contract: the row stays servable until its result is recorded, and the
            // seam refuses it thereafter.
            if welding?.migrationRecordTransferResultTransferIdResultForCalled == true {
                throw ZcashError.rustMigrationTakeBroadcastTransaction("transaction 1 is no longer proved-and-servable")
            }
            return prepared
        }
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = GatedBroadcaster(outcome: MigrationBroadcastOutcome.submitted)
        let migration = makeMigration(broadcaster: broadcaster)
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        let instruction = MigrationBroadcastInstruction(id: prepared.id)

        let first = Task {
            try await migration.performBroadcast(instruction, options: options)
        }
        // The first caller is provably suspended inside its broadcast before the second one starts.
        await broadcaster.awaitBroadcastsStarted(1)
        let second = Task {
            try await migration.performBroadcast(instruction, options: options)
        }
        // Scheduling aid only (correctness must not depend on it): give the second caller ample
        // opportunity to reach the actor while the first broadcast is still in flight, so a missing
        // single-flight guard reliably manifests as a second fetch/broadcast.
        for _ in 0..<50 {
            await Task.yield()
        }
        await broadcaster.open()

        let firstResult = try await first.value
        do {
            _ = try await second.value
            XCTFail("the concurrent caller's stale instruction must be refused, not re-broadcast")
        } catch ZcashError.rustMigrationTakeBroadcastTransaction {
            // expected
        }

        let broadcastsStarted = await broadcaster.startedCount
        XCTAssertEqual(broadcastsStarted, 1, "the same due transfer must be broadcast exactly once")
        XCTAssertEqual(firstResult, .success(txId: prepared.txid.toHexStringTxId()))
        XCTAssertFalse(
            welding.migrationAdvanceStepForEstimatedTipCalled,
            "neither caller advances: the executor is not a lane with a mind of its own"
        )
        XCTAssertEqual(
            welding.migrationTakeBroadcastTransactionIdForCallsCount,
            2,
            "the waiter does serve — strictly after the in-flight flow, where the seam refuses it"
        )
        XCTAssertEqual(welding.migrationRecordTransferResultTransferIdResultForCallsCount, 1)
    }

    /// The single-flight discipline spans the different broadcast entry points: a `submitNoteSplit`
    /// arriving while a `performBroadcast` is in flight runs strictly after it —
    /// its signing does not even start until the in-flight flow has recorded. Both flows then
    /// broadcast their own (different) transactions.
    func testSubmitNoteSplitWaitsForInFlightPerformBroadcast() async throws {
        let recorder = CompositionOrderRecorder()
        let dueTransfer = makePreparedTransfer(id: 1)
        let splitTransfer = makePreparedTransfer(id: 0)
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(100_000)], fee: Zatoshi(5_000), proposalHandle: 1)
        welding.migrationTakeBroadcastTransactionIdForReturnValue = dueTransfer
        welding.migrationSignNoteSplitProposalUskForClosure = { _, _, _ in
            recorder.record("sign")
            return splitTransfer
        }
        welding.migrationRecordTransferResultTransferIdResultForClosure = { transferId, _, _ in
            recorder.record("record:\(transferId)")
        }
        let broadcaster = GatedBroadcaster(outcome: MigrationBroadcastOutcome.submitted)
        let migration = makeMigration(broadcaster: broadcaster)

        let transferCall = Task {
            try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: dueTransfer.id),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
        }
        await broadcaster.awaitBroadcastsStarted(1)
        let splitCall = Task {
            try await migration.submitNoteSplit(
                proposal: proposal,
                usk: self.usk,
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
            )
        }
        // Scheduling aid only, as in the sibling test above.
        for _ in 0..<50 {
            await Task.yield()
        }
        await broadcaster.open()

        let transferResult = try await transferCall.value
        let splitResult = try await splitCall.value

        XCTAssertEqual(transferResult, .success(txId: dueTransfer.txid.toHexStringTxId()))
        XCTAssertEqual(splitResult, MigrationTransferResult.success(txId: splitTransfer.txid.toHexStringTxId()))
        let broadcastsStarted = await broadcaster.startedCount
        XCTAssertEqual(broadcastsStarted, 2, "each flow broadcasts its own transaction, strictly serialized")
        XCTAssertEqual(
            recorder.events,
            ["record:1", "sign", "record:0"],
            "the note split must not even sign until the in-flight transfer flow has recorded"
        )
    }

    // MARK: - Keystone flow

    /// Documents the engine's prep-first contract at the actor level: immediately after
    /// `storeSignedNoteSplitPCZTs`, the very next crank names the stored preparation transaction
    /// for broadcast (mirrored here by stubbing the drive to issue an instruction for the proven
    /// counterpart of the storage receipt), and the driver hands THAT instruction — the step's own
    /// payload, matched out of the advance rather than assembled by the test — to the executor.
    func testKeystoneFlowStoreSignedNoteSplitPCZTsThenBroadcastsThePrepTransfer() async throws {
        let prepTransfer = makePreparedTransfer(id: 0)
        welding.migrationStoreSignedNoteSplitPcztsForReturnValue = prepTransfer
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(
            step: .broadcast(MigrationBroadcastInstruction(id: prepTransfer.id)),
            next: nil
        )
        welding.migrationTakeBroadcastTransactionIdForReturnValue = prepTransfer
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }
        let broadcaster = ScriptedBroadcaster(script: .outcome(.submitted))
        let migration = makeMigration(broadcaster: broadcaster)

        let stored = try await migration.storeSignedNoteSplitPCZTs([
            MigrationSignedTransferPczt(id: prepTransfer.id, pczt: Data([0x09]))
        ])
        XCTAssertEqual(stored, prepTransfer)

        // The driver's own dispatch: crank, then perform the crank's dictate with its payload.
        guard case .broadcast(let instruction)? = try await migration.advanceStep()?.step else {
            return XCTFail("the crank after a preparation store must issue a broadcast instruction")
        }
        let result = try await migration.performBroadcast(
            instruction,
            options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: defaultEndpoint)
        )

        XCTAssertEqual(instruction.id, prepTransfer.id)
        XCTAssertEqual(result, .success(txId: prepTransfer.txid.toHexStringTxId()))
        XCTAssertEqual(welding.migrationRecordTransferResultTransferIdResultForReceivedArguments?.transferId, prepTransfer.id)
    }

    // MARK: - isSyncBlocked gate-file state

    /// `isSyncBlocked` answers from the persisted gate state -- checked with no marker
    /// (unblocked), with a live in-flight marker (blocked), and once it is cleared (unblocked
    /// again, immediately), so the answer is proven to actually read the gate rather than being a
    /// hardcoded constant, and proven to leave nothing behind once the submit is over.
    func testIsSyncBlockedAnswersFromThePersistedGateState() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blockedWithNoMarker = await migration.isSyncBlocked()
        XCTAssertFalse(blockedWithNoMarker)

        gate.markBroadcastInFlight()

        let blockedWhileInFlight = await migration.isSyncBlocked()
        XCTAssertTrue(blockedWhileInFlight)

        gate.clearBroadcastInFlight()

        let blockedAfterTheOutcomeLanded = await migration.isSyncBlocked()
        XCTAssertFalse(blockedAfterTheOutcomeLanded, "the clock has not moved: nothing timed may hold sync")
    }

    // MARK: - isSyncBlocked forward-looking policy (D1)

    /// D1 REVERSAL PIN (2026-08-05): the gate's forward-looking clause is
    /// deleted, so a migration with no in-flight marker never blocks sync, and no gate path pays
    /// for the wall-clock chain-tip estimate the clause needed.
    func testIsSyncBlockedIgnoresForwardLookingWork() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blocked = await migration.isSyncBlocked()

        XCTAssertFalse(blocked, "sync holds only while a submission is in flight")
        XCTAssertFalse(welding.migrationBlockRateSamplesWindowCalled, "no gate path pays for the estimate anymore")
    }

    /// THE WEDGE (D1): a due-but-unproved row — `migrationHasOverdueTransfers` would answer `true`
    /// for it — must NOT block sync: its proof is produced AT sync wake-ups, so gating sync on it
    /// would starve the very work that clears it. The overdue query throwing loudly (rather than
    /// answering) additionally proves the gate no longer consults it at all.
    func testIsSyncBlockedDoesNotBlockForADueButUnprovedSignedRow() async throws {
        welding.migrationHasOverdueTransfersForEstimatedTipThrowableError = StubEngineError()
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let blocked = await migration.isSyncBlocked()

        XCTAssertFalse(blocked, "a Signed-due row needs MORE syncing; it must never hold sync hostage")
        XCTAssertFalse(
            welding.migrationHasOverdueTransfersForEstimatedTipCalled,
            "no gate path may consult the overdue query anymore"
        )
    }

    // MARK: - nextMigrationWake retention

    /// Session start: before any crank runs, the retained outlook is `nil` -- the actor's own
    /// initial state, not a value read off an un-run engine call.
    func testNextMigrationWakeIsNilBeforeAnyCrank() async throws {
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        let outlook = await migration.nextMigrationWake

        XCTAssertNil(outlook, "no crank has run yet this session")
    }

    /// A crank's outlook is retained past the call that produced it, so a host can read it later
    /// without re-cranking the engine.
    func testNextMigrationWakeRetainsTheMostRecentCranksOutlook() async throws {
        let outlook = MigrationNextWork(height: 3_000_100, kind: .broadcast)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: outlook)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))

        _ = try await migration.advanceStep()

        let retained = await migration.nextMigrationWake
        XCTAssertEqual(retained, outlook)
    }

    /// The NEXT crank's outlook supersedes the previous one unconditionally -- including replacing
    /// a previously retained outlook with `nil` when the new crank's step carries none, so a stale
    /// outlook never outlives the crank that superseded it.
    func testNextMigrationWakeIsReplacedIncludingToNilOnTheNextCrank() async throws {
        let firstOutlook = MigrationNextWork(height: 3_000_100, kind: .broadcast)
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: firstOutlook)
        let migration = makeMigration(broadcaster: ScriptedBroadcaster(script: .throwing(StubEngineError())))
        _ = try await migration.advanceStep()
        let retainedAfterFirst = await migration.nextMigrationWake
        XCTAssertEqual(retainedAfterFirst, firstOutlook, "sanity: the first crank's outlook must be retained before it is superseded")

        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .complete, next: nil)
        _ = try await migration.advanceStep()

        let retainedAfterSecond = await migration.nextMigrationWake
        XCTAssertNil(retainedAfterSecond, "a crank with no outlook must clear the previous one, not preserve it")
    }

    // MARK: - Helpers

    private func makeMigration(broadcaster: any MigrationBroadcasting) -> OrchardMigration {
        // `isSyncBlocked()` and the `useEstimatedTip: true` paths unconditionally read
        // `migrationBlockRateSamples` (`ChainTipEstimator`'s raw input); default it to "no samples"
        // so a test that never cares about the estimate does not crash on the mock's un-stubbed,
        // implicitly-unwrapped `ReturnValue` -- a test that DOES care sets it itself before calling
        // this helper, which this guard leaves untouched.
        if welding.migrationBlockRateSamplesWindowReturnValue == nil {
            welding.migrationBlockRateSamplesWindowReturnValue = []
        }
        let clockValue = clock!
        return OrchardMigration(
            welding: welding,
            accountUUID: accountA,
            broadcaster: broadcaster,
            syncGate: gate,
            logger: logger,
            // The actor's estimate-consulting paths read the injected clock (U7), so the
            // fake-clock projection tests are deterministic.
            now: { clockValue.now }
        )
    }

    private func makeGate(account: AccountUUID, clock: TestClock) -> MigrationSyncGate {
        MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: account,
            // A long tick keeps the background re-evaluation out of these deterministic assertions.
            tickInterval: 3600,
            now: { clock.now },
            logger: logger
        )
    }

    private func makePreparedTransfer(id: UInt32) -> PreparedMigrationTransfer {
        PreparedMigrationTransfer(id: id, txid: Data(repeating: 0xAB, count: 32), pczt: Data([0x01, 0x02]))
    }
}

/// Records the order in which the broadcast composition's collaborators are invoked, so a test can
/// assert the exact sign -> extract -> broadcast -> record sequence
/// `OrchardMigration.broadcastAndRecord` promises. `OrchardMigration` is an actor and every awaited
/// call in the composition is sequential, so a plain array is sufficient.
private final class CompositionOrderRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// A generic, non-`ZcashError` failure for stubbing welding calls that must fail for reasons
/// unrelated to what a given test is actually asserting (e.g. an engine call the test never expects
/// to succeed but also never inspects the error from).
private struct StubEngineError: Error {}
