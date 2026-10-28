import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardCheckReadinessTests: ZcashTestCase {
    // Removing the settle window returns an authoritative zero before its timer exists.
    func testConcreteHostZeroRegistersSettleBeforeReturningEmpty() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            spendableValue: .zero,
            checkTiming: clock.timing
        )
        let caller = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [clock.expectSleep(at: 15_000_000_000)], timeout: 5)
        clock.advance(to: 15_000_000_000)
        let result = try await caller.value
        XCTAssertEqual(result.state, .empty)
        try await fixture.redeemer.cleanup()
    }

    func testConcreteHostUnknownTipTimesOutWithoutProposal() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory, chainTip: 0, checkTiming: clock.timing
        )
        let done = XCTestExpectation(description: "host published done without known tip")
        let observation = fixture.synchronizer.stateStream.filter { $0.syncStatus == .upToDate }.prefix(1).sink { _ in done.fulfill() }
        defer { observation.cancel() }
        let caller = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [done, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        clock.advance(to: 600_000_000_000)
        do {
            _ = try await caller.value
            XCTFail("Unknown tip must not classify funds")
        } catch ZcashError.giftCardCheckTimedOut { }
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    func testConcreteHostCheckUsesAcceptedSnapshotWithoutAnotherSummaryRead() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let initial = try await fixture.redeemer.check()
        XCTAssertEqual(initial.state, .ready)
        await fixture.engine.setNextWalletSummary(nil)
        let before = await fixture.engine.calls.filter { $0 == "walletSummary" }.count
        let next = try await fixture.redeemer.check()
        let after = await fixture.engine.calls.filter { $0 == "walletSummary" }.count
        XCTAssertEqual(next.spendable, initial.spendable)
        XCTAssertEqual(next.state, .ready)
        XCTAssertEqual(after, before, "Check must use its accepted state rather than querying the summary again")
        try await fixture.redeemer.cleanup()
    }

    func testRepeatedEmptyResetsStillObeyOverallBudget() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let operation = GiftCardCheckOperation(admittedAt: 0, policy: harness.policy, timing: harness.clock.timing)
        let registered = XCTestExpectation(description: "readiness observers registered")
        let caller = Task {
            try await operation.value {
                let accepted = try await harness.waiter.wait(
                    stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                    start: { registered.fulfill() }
                )
                return GiftCardStatus(balance: accepted, sweep: nil)
            }
        }
        await fulfillment(of: [registered, harness.clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        for index in 0..<60 {
            harness.clock.advance(to: UInt64(index) * 10_000_000_000, deliveringSleeps: false)
            harness.states.send(state(tip: 100 + index, scanned: 100 + index, value: 0))
        }
        harness.clock.advance(to: 600_000_000_000)
        do {
            _ = try await caller.value
            XCTFail("Repeated resets cannot extend the caller's budget")
        } catch ZcashError.giftCardCheckTimedOut { }
        await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
    }

    func testCancelledHeldStartupRemainsOwnedUntilCleanupCanDrain() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory, cleanupTiming: clock.timing, checkTiming: clock.timing
        )
        fixture.engine.startGate.close()
        let entered = XCTestExpectation(description: "owned native start entered")
        await fixture.engine.onCall("start") { entered.fulfill() }
        let caller = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [entered, clock.expectSleep(at: 600_000_000_000)], timeout: 5)
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Cancelled caller must detach")
        } catch is CancellationError { }
        let cleanup = Task { try await fixture.redeemer.cleanup() }
        await fulfillment(of: [clock.expectSleep(at: 30_000_000_000)], timeout: 5)
        clock.advance(to: 30_000_000_000)
        do {
            try await cleanup.value
            XCTFail("Cleanup must continue owning held start")
        } catch ZcashError.giftCardCleanupTimedOut { }
        let calls = await fixture.engine.calls
        XCTAssertFalse(calls.contains("close"))
        XCTAssertFalse(calls.contains(where: GatedFakeSlipstreamEngine.isStop))
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 0)
        fixture.engine.startGate.open()
        try await fixture.redeemer.cleanup()
    }

    func testReadinessRejectsUnknownTipIncompleteCoverageAndMissingAccount() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.states.send(state(tip: 0, scanned: 0, value: 50_000))
        harness.states.send(state(tip: 100, scanned: 99, value: 50_000))
        harness.states.send(state(tip: 100, scanned: 100, value: nil))
        harness.states.send(state(tip: 100, scanned: 100, value: 70_000))
        let balance = try await caller.value
        XCTAssertEqual(balance.shieldedSpendableValue, Zatoshi(70_000))
        XCTAssertTrue(harness.clock.pendingDeadlines.isEmpty)
    }

    func testPositivePendingAndDustReturnImmediately() async throws {
        for balance in [balance(value: 50_000), balance(value: 1), balance(value: 0, pending: 10_000)] {
            let harness = Harness()
            defer { harness.clock.dispose() }
            let caller = try await begin(harness)
            var snapshot = state(tip: 100, scanned: 100, value: 0)
            snapshot.accountsBalances[TestsData.mockedAccountUUID] = balance
            harness.states.send(snapshot)
            let accepted = try await caller.value
            XCTAssertEqual(accepted, balance)
            XCTAssertTrue(harness.clock.pendingDeadlines.isEmpty)
        }
    }

    func testEmptySettlesAtDirectAndTorDefaults() async throws {
        for tor in [false, true] {
            let harness = Harness(tor: tor)
            defer { harness.clock.dispose() }
            let caller = try await begin(harness)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            let deadline = tor ? UInt64(30_000_000_000) : UInt64(15_000_000_000)
            await fulfillment(of: [harness.clock.expectSleep(at: deadline)], timeout: 5)
            harness.clock.advance(to: deadline - 1)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            harness.clock.advance(to: deadline)
            let accepted = try await caller.value
            XCTAssertEqual(accepted.shieldedTotal(), .zero)
        }
    }

    func testFundedArrivalDuringSettleReturnsNewSnapshot() async throws {
        try await fundedArrival(at: 10_000_000_000)
    }

    func testLateFundedArrivalWinsWhenEmptyTimerDeliveryIsWithheld() async throws {
        try await fundedArrival(at: 20_000_000_000)
    }

    func testEmptySettleResetsForSyncingMissingBalanceCoverageLossAndTipChange() async throws {
        var syncing = state(tip: 100, scanned: 100, value: 0)
        syncing.syncStatus = .syncing(0, false)
        let invalid = [
            syncing,
            state(tip: 100, scanned: 100, value: nil),
            state(tip: 100, scanned: 99, value: 0),
            state(tip: 101, scanned: 101, value: 0)
        ]
        for snapshot in invalid {
            let harness = Harness()
            defer { harness.clock.dispose() }
            let caller = try await begin(harness)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
            harness.clock.advance(to: 10_000_000_000)
            harness.states.send(snapshot)
            harness.states.send(state(tip: snapshot.latestBlockHeight, scanned: snapshot.latestBlockHeight, value: 0))
            await fulfillment(of: [harness.clock.expectSleep(at: 25_000_000_000)], timeout: 5)
            harness.clock.advance(to: 25_000_000_000)
            let accepted = try await caller.value
            XCTAssertEqual(accepted.shieldedTotal(), .zero)
        }
    }

    func testDisconnectRecoveryWithinDirectAndTorGrace() async throws {
        for tor in [false, true] {
            let harness = Harness(tor: tor)
            defer { harness.clock.dispose() }
            let caller = try await begin(harness)
            harness.states.send(disconnected())
            let grace = harness.policy.disconnectGraceNanoseconds
            await fulfillment(of: [harness.clock.expectSleep(at: grace)], timeout: 5)
            harness.clock.advance(to: grace - 1)
            harness.states.send(state(tip: 100, scanned: 100, value: 50_000))
            let accepted = try await caller.value
            XCTAssertEqual(accepted.shieldedSpendableValue, Zatoshi(50_000))
            await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
        }
    }

    func testContinuousDisconnectExpires() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.states.send(disconnected())
        await fulfillment(of: [harness.clock.expectSleep(at: 60_000_000_000)], timeout: 5)
        harness.clock.advance(to: 60_000_000_000)
        await assertError(caller, code: ZcashError.giftCardCheckDisconnected.code)
    }

    func testExpiredGraceWinsOverLateHealthyWithTimerDeliveryWithheld() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.states.send(disconnected())
        await fulfillment(of: [harness.clock.expectSleep(at: 60_000_000_000)], timeout: 5)
        harness.clock.advance(to: 60_000_000_000, deliveringSleeps: false)
        harness.states.send(state(tip: 100, scanned: 100, value: 50_000))
        await assertError(caller, code: ZcashError.giftCardCheckDisconnected.code)
    }

    func testHealthyResetsGraceForLaterDisconnect() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.states.send(disconnected())
        await fulfillment(of: [harness.clock.expectSleep(at: 60_000_000_000)], timeout: 5)
        harness.clock.advance(to: 40_000_000_000)
        harness.states.send(SynchronizerState.zero)
        harness.states.send(disconnected())
        await fulfillment(of: [harness.clock.expectSleep(at: 100_000_000_000)], timeout: 5)
        harness.clock.advance(to: 100_000_000_000)
        await assertError(caller, code: ZcashError.giftCardCheckDisconnected.code)
    }

    func testSubstantiveErrorPropagates() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        var snapshot = SynchronizerState.zero
        snapshot.syncStatus = .error(ZcashError.giftCardRedeemerNotReady)
        harness.states.send(snapshot)
        await assertError(caller, code: ZcashError.giftCardRedeemerNotReady.code)
    }

    func testRecoverableStallPreservesWaitAndTerminalStallFails() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.events.send(.syncStalled(attempt: 1, gaveUp: false))
        harness.states.send(state(tip: 100, scanned: 100, value: 0))
        await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
        harness.events.send(.syncStalled(attempt: 2, gaveUp: true))
        await assertError(caller, code: ZcashError.giftCardCheckSyncStalled.code)
        await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
    }

    func testTerminalStallAfterFundedStateDuringStartStillFails() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        do {
            _ = try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                start: {
                    harness.states.send(self.state(tip: 100, scanned: 100, value: 50_000))
                    harness.events.send(.syncStalled(attempt: 1, gaveUp: true))
                }
            )
            XCTFail("A terminal event during owned startup must override provisional readiness")
        } catch ZcashError.giftCardCheckSyncStalled { }
    }

    func testFundedStateDuringHeldStartDisposesPriorEmptyTimer() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let gate = GiftCardOperationGate()
        let caller = Task {
            try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                start: {
                    harness.states.send(self.state(tip: 100, scanned: 100, value: 0))
                    await gate.wait()
                }
            )
        }
        await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
        harness.clock.advance(to: 10_000_000_000)
        harness.states.send(state(tip: 100, scanned: 100, value: 80_000))
        XCTAssertTrue(harness.clock.pendingDeadlines.isEmpty, "Funded readiness must dispose the prior empty timer")
        harness.clock.advance(to: 15_000_000_000)
        await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
        await gate.open()
        let accepted = try await caller.value
        XCTAssertEqual(accepted.shieldedSpendableValue, Zatoshi(80_000))
    }

    func testSettledZeroDuringHeldStartKeepsCompletedWindowAcrossIdenticalSnapshots() async throws {
        for tor in [false, true] {
            let harness = Harness(tor: tor)
            defer { harness.clock.dispose() }
            let gate = GiftCardOperationGate()
            let completed = XCTestExpectation(description: "settled zero returns as soon as startup drains")
            let caller = Task {
                defer { completed.fulfill() }
                return try await harness.waiter.wait(
                    stateStream: harness.states.eraseToAnyPublisher(),
                    eventStream: harness.events.eraseToAnyPublisher(),
                    start: {
                        harness.states.send(self.state(tip: 100, scanned: 100, value: 0))
                        await gate.wait()
                    }
                )
            }
            let settle = harness.policy.emptySettleNanoseconds
            await fulfillment(of: [harness.clock.expectSleep(at: settle)], timeout: 5)
            // A same-tip state at expiry settles synchronously, independent of timer delivery.
            harness.clock.advance(to: settle, deliveringSleeps: false)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
            harness.clock.advance(to: settle + 1_000_000_000)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            await gate.open()
            await fulfillment(of: [completed], timeout: 5)
            // Drain a regressed implementation too, so RED cannot strand its continuation.
            harness.clock.advance(to: settle * 2 + 1_000_000_000)
            let accepted = try await caller.value
            XCTAssertEqual(accepted.shieldedTotal(), .zero)
            await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
        }
    }

    func testSettledZeroDuringHeldStartRestartsWindowAfterReadinessLossOrTipChange() async throws {
        var syncing = state(tip: 100, scanned: 100, value: 0)
        syncing.syncStatus = .syncing(0, false)
        let invalidations = [
            syncing,
            state(tip: 100, scanned: 100, value: nil),
            state(tip: 100, scanned: 99, value: 0),
            state(tip: 0, scanned: 0, value: 0),
            state(tip: 101, scanned: 101, value: 0)
        ]
        for invalid in invalidations {
            let harness = Harness()
            defer { harness.clock.dispose() }
            let gate = GiftCardOperationGate()
            let caller = Task {
                try await harness.waiter.wait(
                    stateStream: harness.states.eraseToAnyPublisher(),
                    eventStream: harness.events.eraseToAnyPublisher(),
                    start: {
                        harness.states.send(self.state(tip: 100, scanned: 100, value: 0))
                        await gate.wait()
                    }
                )
            }
            await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
            harness.clock.advance(to: 15_000_000_000, deliveringSleeps: false)
            harness.states.send(state(tip: 100, scanned: 100, value: 0))
            await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
            harness.clock.advance(to: 16_000_000_000)
            harness.states.send(invalid)
            let tip = max(invalid.latestBlockHeight, 100)
            harness.states.send(state(tip: tip, scanned: tip, value: 0))
            await fulfillment(of: [harness.clock.expectSleep(at: 31_000_000_000)], timeout: 5)
            await gate.open()
            harness.clock.advance(to: 31_000_000_000)
            let accepted = try await caller.value
            XCTAssertEqual(accepted.shieldedTotal(), .zero)
            await fulfillment(of: [harness.clock.expectNoPendingSleeps()], timeout: 5)
        }
    }

    // Subscribing after the actor decision loses a terminal event and starts the failed attempt.
    func testTerminalStallDuringStartDecisionFailsWithoutStarting() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        let selected = XCTestExpectation(description: "start decision suspended")
        let caller = Task {
            try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                shouldStart: {
                    selected.fulfill()
                    await gate.wait()
                    return true
                },
                start: {
                    XCTFail("An observed terminal stall must prevent restart")
                    harness.states.send(self.state(tip: 100, scanned: 100, value: 50_000))
                }
            )
        }
        defer { caller.cancel() }
        await fulfillment(of: [selected], timeout: 5)
        harness.events.send(.syncStalled(attempt: 3, gaveUp: true))
        await gate.open()
        await assertError(caller, code: ZcashError.giftCardCheckSyncStalled.code)
    }

    // Cancellation must dispose the event listener even while the actor decision is held.
    func testCancellationDuringStartDecisionDoesNotStart() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        let selected = XCTestExpectation(description: "start decision suspended")
        let disposed = XCTestExpectation(description: "decision event listener cancelled")
        let caller = Task {
            try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.handleEvents(receiveCancel: { disposed.fulfill() }).eraseToAnyPublisher(),
                shouldStart: {
                    selected.fulfill()
                    await gate.wait()
                    return true
                },
                start: { XCTFail("A cancelled decision must never admit a restart") }
            )
        }
        defer { caller.cancel() }
        await fulfillment(of: [selected], timeout: 5)
        caller.cancel()
        await fulfillment(of: [disposed], timeout: 5)
        await gate.open()
        do {
            _ = try await caller.value
            XCTFail("Cancelled decision must throw")
        } catch is CancellationError { }
    }

    func testPolicyDefaultsAreExact() {
        let direct = GiftCardCheckPolicy.live(isTorEnabled: false)
        let tor = GiftCardCheckPolicy.live(isTorEnabled: true)
        XCTAssertEqual(direct.budgetNanoseconds, 600_000_000_000)
        XCTAssertEqual(tor.budgetNanoseconds, 600_000_000_000)
        XCTAssertEqual(direct.emptySettleNanoseconds, 15_000_000_000)
        XCTAssertEqual(tor.emptySettleNanoseconds, 30_000_000_000)
        XCTAssertEqual(direct.disconnectGraceNanoseconds, 60_000_000_000)
        XCTAssertEqual(tor.disconnectGraceNanoseconds, 120_000_000_000)
    }

    func testTerminalStallEmittedSynchronouslyDuringStartIsObserved() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        do {
            _ = try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                start: { harness.events.send(.syncStalled(attempt: 1, gaveUp: true)) }
            )
            XCTFail("Terminal event must fail this attempt")
        } catch ZcashError.giftCardCheckSyncStalled { }
    }

    func testRestartSuppressesOnlyReplayedError() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        var stale = SynchronizerState.zero
        stale.syncStatus = .error(ZcashError.giftCardRedeemerNotReady)
        harness.states.send(stale)
        do {
            _ = try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                start: { harness.states.send(stale) }
            )
            XCTFail("New error during start must propagate")
        } catch ZcashError.giftCardRedeemerNotReady { }
    }

    func testCancellationDisposesSubscriptionsAndTimerAndCannotCompleteNextAttempt() async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let stateCancelled = XCTestExpectation(description: "state subscription disposed")
        let eventCancelled = XCTestExpectation(description: "event subscription disposed")
        let registered = XCTestExpectation(description: "cancellation observers registered")
        let caller = Task {
            try await harness.waiter.wait(
                stateStream: harness.states.handleEvents(receiveCancel: { stateCancelled.fulfill() }).eraseToAnyPublisher(),
                eventStream: harness.events.handleEvents(receiveCancel: { eventCancelled.fulfill() }).eraseToAnyPublisher(),
                start: { registered.fulfill() }
            )
        }
        try await awaitRegistration(registered, of: caller)
        harness.states.send(state(tip: 100, scanned: 100, value: 0))
        await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
        caller.cancel()
        do {
            _ = try await boundedValue(of: caller)
            XCTFail("Cancelled attempt must throw")
        } catch is CancellationError { }
        await fulfillment(of: [stateCancelled, eventCancelled, harness.clock.expectNoPendingSleeps()], timeout: 5)
        let next = Harness(clock: harness.clock)
        let nextCaller = try await begin(next)
        harness.events.send(.syncStalled(attempt: 9, gaveUp: true))
        harness.clock.advance(to: 15_000_000_000)
        next.states.send(state(tip: 100, scanned: 100, value: 90_000))
        let accepted = try await boundedValue(of: nextCaller)
        XCTAssertEqual(accepted.shieldedSpendableValue, Zatoshi(90_000))
    }

    /// Awaits the attempt's value, but never longer than the hang backstop. The waiter runs on
    /// the test clock, so a healthy attempt completes in milliseconds of wall time; this bound
    /// exists so a regression fails the test in seconds instead of stalling the CI job until its
    /// timeout kills the runner (run 38475223787 lost 52 minutes to exactly that).
    private func boundedValue(of task: Task<AccountBalance, Error>, seconds: UInt64 = 30) async throws -> AccountBalance {
        // The guard runs inside the group so it is always joined before this function returns:
        // a backstop failure can never be posted late and attributed to a later test.
        try await withThrowingTaskGroup(of: AccountBalance?.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                guard (try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)) != nil else { return nil }
                task.cancel()
                XCTFail("attempt did not complete within the \(seconds) s hang backstop")
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let value = result { return value }
            }
            throw CancellationError()
        }
    }

    private func fundedArrival(at instant: UInt64) async throws {
        let harness = Harness()
        defer { harness.clock.dispose() }
        let caller = try await begin(harness)
        harness.states.send(state(tip: 100, scanned: 100, value: 0))
        await fulfillment(of: [harness.clock.expectSleep(at: 15_000_000_000)], timeout: 5)
        harness.clock.advance(to: instant, deliveringSleeps: false)
        harness.states.send(state(tip: 100, scanned: 100, value: 80_000))
        let accepted = try await caller.value
        XCTAssertEqual(accepted.shieldedSpendableValue, Zatoshi(80_000))
    }

    private func begin(_ harness: Harness) async throws -> Task<AccountBalance, Error> {
        let registered = XCTestExpectation(description: "both observers registered before start")
        let caller = Task {
            try await harness.waiter.wait(
                stateStream: harness.states.eraseToAnyPublisher(),
                eventStream: harness.events.eraseToAnyPublisher(),
                start: { registered.fulfill() }
            )
        }
        try await awaitRegistration(registered, of: caller)
        return caller
    }

    /// Waits until the attempt has subscribed and entered `start`, and stops the test if it never
    /// does. Every state the test sends afterwards relies on that subscription: a state sent
    /// earlier lands in the subject first, the attempt then receives it as the subscription replay,
    /// which the waiter deliberately suppresses, and no later input completes the attempt. A
    /// timed-out `fulfillment` only records a failure and lets the test continue into exactly that
    /// wait, so a stalled runner turned a late registration into a hang. Registration takes
    /// milliseconds; the generous bound only absorbs a stalled runner.
    private func awaitRegistration<T>(
        _ registered: XCTestExpectation,
        of caller: Task<T, Error>,
        seconds: TimeInterval = 30
    ) async throws {
        guard await XCTWaiter.fulfillment(of: [registered], timeout: seconds) == .completed else {
            caller.cancel()
            XCTFail("attempt did not register its observers within \(Int(seconds)) s")
            throw CancellationError()
        }
    }

    private func state(tip: BlockHeight, scanned: BlockHeight, value: Int64?) -> SynchronizerState {
        SynchronizerState(
            syncSessionID: UUID(),
            accountsBalances: value.map { [TestsData.mockedAccountUUID: balance(value: $0)] } ?? [:],
            localAccountsBalances: [:],
            internalSyncStatus: .synced,
            latestBlockHeight: tip,
            fullyScannedHeight: scanned
        )
    }

    private func balance(value: Int64, pending: Int64 = 0) -> AccountBalance {
        AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(value),
                changePendingConfirmation: .zero,
                valuePendingSpendability: Zatoshi(pending)
            ),
            unshielded: .zero
        )
    }

    private func disconnected() -> SynchronizerState {
        var snapshot = SynchronizerState.zero
        snapshot.syncStatus = .error(ZcashError.synchronizerDisconnected)
        return snapshot
    }

    private func assertError(_ task: Task<AccountBalance, Error>, code: ZcashErrorCode) async {
        do {
            _ = try await task.value
            XCTFail("Expected error \(code)")
        } catch {
            XCTAssertEqual((error as? ZcashError)?.code, code)
        }
    }
}

private struct Harness {
    let clock: GiftCardCleanupTestClock
    let policy: GiftCardCheckPolicy
    let waiter: GiftCardCheckStateWaiter
    let states = CurrentValueSubject<SynchronizerState, Never>(SynchronizerState.zero)
    let events = PassthroughSubject<SynchronizerEvent, Never>()

    init(tor: Bool = false, clock: GiftCardCleanupTestClock = GiftCardCleanupTestClock()) {
        self.clock = clock
        policy = GiftCardCheckPolicy.live(isTorEnabled: tor)
        waiter = GiftCardCheckStateWaiter(accountUUID: TestsData.mockedAccountUUID, policy: policy, timing: clock.timing)
    }
}
