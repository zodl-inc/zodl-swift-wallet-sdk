import XCTest

@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardCheckDeadlineTests: ZcashTestCase {
    // Removing caller detachment would make cancellation wait for native preparation again.
    func testCallerCancellationDuringNonCooperativePreparationReturnsBeforeNativeCompletion() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let entered = XCTestExpectation(description: "native preparation entered")
        let finished = XCTestExpectation(description: "check caller detached")
        let gate = holdPreparation(fixture, entered: entered)
        let caller = Task {
            defer { finished.fulfill() }
            return try await fixture.redeemer.check()
        }
        await fulfillment(of: [entered], timeout: 5)
        caller.cancel()
        await fulfillment(of: [finished], timeout: 5)
        await assertCancellation(caller)
        let calls = await fixture.engine.calls
        XCTAssertFalse(calls.contains("start"))
        XCTAssertFalse(calls.contains(where: GatedFakeSlipstreamEngine.isStop))
        await gate.open()
        // This following call joins native preparation and reuses the completed account.
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready)
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    // Removing the independent deadline or dropping real queue ownership breaks this test.
    func testPreparationNeverReturnsAndSecondQueuedCheckHaveIndependentDeadlinesWhileCleanupOwnsWork() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing,
            checkTiming: clock.timing
        )
        let entered = XCTestExpectation(description: "native preparation entered")
        let gate = holdPreparation(fixture, entered: entered)
        let first = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let sentinel = root.appendingPathComponent("preparation-owned")
        try Data([1]).write(to: sentinel)
        clock.advance(to: 600_000_000_000)
        await assertTimeout(first)

        let second = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [clock.expectSleep(at: 1_200_000_000_000)], timeout: 5)
        clock.advance(to: 1_200_000_000_000)
        await assertTimeout(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        assertAliasOwned(card: fixture.card)

        let cleanup = Task { try await fixture.redeemer.cleanup() }
        await fulfillment(of: [clock.expectSleep(at: 1_230_000_000_000)], timeout: 5)
        clock.advance(to: 1_230_000_000_000)
        do {
            try await cleanup.value
            XCTFail("Cleanup cannot complete while native preparation is held")
        } catch ZcashError.giftCardCleanupTimedOut {
        }
        let calls = await fixture.engine.calls
        XCTAssertFalse(calls.contains(where: GatedFakeSlipstreamEngine.isStop))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        assertAliasOwned(card: fixture.card)
        await gate.open()
        try await fixture.redeemer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 1)
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 0)
    }

    func testDroppingTimedOutCallerAndRedeemerKeepsNativePreparationOwnedUntilDrain() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            checkTiming: clock.timing
        )
        let card = try XCTUnwrap(fixture).card
        let engine = try XCTUnwrap(fixture).engine
        let entered = XCTestExpectation(description: "native preparation entered")
        let gate = holdPreparation(try XCTUnwrap(fixture), entered: entered)
        var caller = startCheck(try XCTUnwrap(fixture).redeemer)
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        clock.advance(to: 600_000_000_000)
        await assertTimeout(try XCTUnwrap(caller))
        weak var retained = fixture?.redeemer
        caller = nil
        fixture = nil
        XCTAssertNotNil(retained, "The real wallet operation must retain its owner")
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let calls = await engine.calls
        XCTAssertFalse(calls.contains(where: GatedFakeSlipstreamEngine.isStop))
        assertAliasOwned(card: card)
        let cleanup = startCleanup(try XCTUnwrap(retained))
        await gate.open()
        try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTimedOutPreparationCompletesBookkeepingAndFollowingCheckPreservesPreparedRoot() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, checkTiming: clock.timing)
        let entered = XCTestExpectation(description: "native preparation entered")
        let gate = holdPreparation(fixture, entered: entered)
        let caller = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let sentinel = root.appendingPathComponent("prepared-wallet")
        try Data([1]).write(to: sentinel)
        clock.advance(to: 600_000_000_000)
        await assertTimeout(caller)
        await gate.open()
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    func testCheckQueuedBehindHeldNativeClaimTimesOutWithoutReleasingClaimOwnership() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing,
            checkTiming: clock.timing
        )
        _ = try await fixture.redeemer.check()
        let entered = XCTestExpectation(description: "native claim admitted")
        let gate = GiftCardOperationGate()
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyClosure = { _, _, _ in
            try GiftCardTransactionCreationContext.admission?.beginNativeCreation()
            entered.fulfill()
            await gate.wait()
            return [Data(repeating: 0xA1, count: 32)]
        }
        let claim = Task { try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil) }
        await fulfillment(of: [entered], timeout: 5)
        let caller = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [clock.expectSleep(at: 600_000_000_000, count: 2)], timeout: 5)
        clock.advance(to: 600_000_000_000)
        await assertTimeout(caller)
        let cleanup = Task { try await fixture.redeemer.cleanup() }
        await fulfillment(of: [clock.expectSleep(at: 630_000_000_000)], timeout: 5)
        let calls = await fixture.engine.calls
        XCTAssertFalse(calls.contains(where: GatedFakeSlipstreamEngine.isStop))
        assertAliasOwned(card: fixture.card)
        await gate.open()
        let result = try await claim.value
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        try await cleanup.value
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 2)
    }

    func testQueuedCheckDoesNotStartAfterDeadlineWithTimerDeliveryWithheld() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, checkTiming: clock.timing)
        let entered = XCTestExpectation(description: "native preparation entered")
        let gate = holdPreparation(fixture, entered: entered)
        let first = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        let second = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [clock.expectSleep(at: 600_000_000_000, count: 2)], timeout: 5)
        clock.advance(to: 600_000_000_000, deliveringSleeps: false)
        await gate.open()
        await assertTimeout(first)
        await assertTimeout(second)
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 0)
        let calls = await fixture.engine.calls
        XCTAssertFalse(calls.contains("start"))
        try await fixture.redeemer.cleanup()
    }

    func testCallerCancelledBeforeAdmissionDoesNotCreateWallet() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "caller waits before check")
        let caller = Task {
            entered.fulfill()
            await gate.wait()
            return try await fixture.redeemer.check()
        }
        await fulfillment(of: [entered], timeout: 5)
        caller.cancel()
        await gate.open()
        await assertCancellation(caller)
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    func testDeadlineStartsAtSuppliedEntryTimestamp() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        clock.advance(to: 123)
        let operation = GiftCardCheckOperation(admittedAt: 123, policy: .live(isTorEnabled: false), timing: clock.timing)
        // Simulates time spent waiting for actor admission before the owned operation is scheduled.
        clock.advance(to: 100_000_000_123)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                return GiftCardStatus(balance: nil, sweep: nil)
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_123)], timeout: 5)
        clock.advance(to: 600_000_000_123)
        await assertTimeout(caller)
        await gate.open()
    }

    func testSaturatingDeadlineDoesNotWrapIntoImmediateTimeout() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        clock.advance(to: UInt64.max - 10)
        let operation = GiftCardCheckOperation(admittedAt: UInt64.max - 10, policy: .live(isTorEnabled: true), timing: clock.timing)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                return GiftCardStatus(balance: nil, sweep: nil)
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: UInt64.max)], timeout: 5)
        clock.advance(to: UInt64.max)
        await assertTimeout(caller)
        await gate.open()
    }

    func testResultBeforeDeadlineSucceedsAndCancelsOutstandingTimer() async throws {
        try await assertResult(at: 599_999_999_999, timesOut: false)
    }

    func testResultAtDeadlineTimesOutWhenTimerDeliveryIsWithheld() async throws {
        try await assertResult(at: 600_000_000_000, timesOut: true)
    }

    func testLateResultTimesOutWhenTimerDeliveryIsWithheld() async throws {
        try await assertResult(at: 600_000_000_001, timesOut: true)
    }

    func testLateErrorTimesOutWhenTimerDeliveryIsWithheld() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let operation = GiftCardCheckOperation(admittedAt: 0, policy: .live(isTorEnabled: false), timing: clock.timing)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                throw ZcashError.giftCardRedeemerNotReady
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        clock.advance(to: 600_000_000_001, deliveringSleeps: false)
        await gate.open()
        await assertTimeout(caller)
        await fulfillment(of: [clock.expectNoPendingSleeps()], timeout: 5)
    }

    func testCancellationAndLateResultDeliverOnlyOnceAndDisposeTimer() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let operation = GiftCardCheckOperation(admittedAt: 0, policy: .live(isTorEnabled: false), timing: clock.timing)
        let gate = GiftCardOperationGate()
        let drained = XCTestExpectation(description: "late owned result completed")
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                defer { drained.fulfill() }
                return GiftCardStatus(balance: nil, sweep: nil)
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        caller.cancel()
        await assertCancellation(caller)
        await fulfillment(of: [clock.expectNoPendingSleeps()], timeout: 5)
        clock.advance(to: 600_000_000_000)
        await gate.open()
        await fulfillment(of: [drained], timeout: 5)
        await assertCancellation(caller)
    }

    func testCancellationCallbackInstalledAfterExpiryStillReceivesRequest() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let operation = GiftCardCheckOperation(admittedAt: 0, policy: .live(isTorEnabled: false), timing: clock.timing)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                return GiftCardStatus(balance: nil, sweep: nil)
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        clock.advance(to: 600_000_000_000)
        await assertTimeout(caller)
        let cancelled = XCTestExpectation(description: "late cancellation callback requested")
        operation.installCancellation { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 5)
        await gate.open()
    }

    private func assertResult(at instant: UInt64, timesOut: Bool) async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let operation = GiftCardCheckOperation(admittedAt: 0, policy: .live(isTorEnabled: false), timing: clock.timing)
        let gate = GiftCardOperationGate()
        let entered = XCTestExpectation(description: "owned check work entered")
        let caller = Task {
            try await operation.value {
                entered.fulfill()
                await gate.wait()
                return GiftCardStatus(balance: nil, sweep: nil)
            }
        }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        clock.advance(to: instant, deliveringSleeps: false)
        await gate.open()
        if timesOut {
            await assertTimeout(caller)
        } else {
            let result = try await caller.value
            XCTAssertEqual(result.state, .empty)
        }
        await fulfillment(of: [clock.expectNoPendingSleeps()], timeout: 5)
    }

    private func startCheck(_ redeemer: GiftCardRedeemer) -> Task<GiftCardStatus, Error>? {
        Task { try await redeemer.check() }
    }

    private func startCleanup(_ redeemer: GiftCardRedeemer) -> Task<Void, Error> {
        Task { try await redeemer.cleanup() }
    }

    private func holdPreparation(_ fixture: GiftCardCancellationFixture, entered: XCTestExpectation) -> GiftCardOperationGate {
        let gate = GiftCardOperationGate()
        let original = fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure!
        fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure = { seed, state, until, name, source in
            entered.fulfill()
            await gate.wait()
            return try await original(seed, state, until, name, source)
        }
        return gate
    }

    private func assertTimeout(_ task: Task<GiftCardStatus, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Check must time out")
        } catch ZcashError.giftCardCheckTimedOut {
        } catch {
            XCTFail("Expected check timeout, got \(error.localizedDescription)")
        }
    }

    private func assertCancellation(_ task: Task<GiftCardStatus, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled caller must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error.localizedDescription)")
        }
    }

    private func assertAliasOwned(card: GiftCard) {
        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: ZcashNetworkBuilder.network(for: card.network),
                endpoint: LightWalletEndpoint(address: "127.0.0.1", port: 1, secure: false),
                isTorEnabled: false,
                storageDirectory: testTempDirectory
            )
        ) { error in
            XCTAssertEqual((error as? ZcashError)?.code, ZcashError.giftCardRedeemerAlreadyActive.code)
        }
    }
}
