import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardCheckStartupTests: ZcashTestCase {
    // Preparation can display syncing from a persisted tip without owning a running pass.
    func testFirstCheckStartsPreparedWalletWithPersistedTip() async throws {
        try await assertFirstCheckStarts(chainTip: 3_509_420, progressPermille: 0)
    }

    // Preparation progress alone must not suppress the first native start either.
    func testFirstCheckStartsPreparedWalletWithProgressOnly() async throws {
        try await assertFirstCheckStarts(chainTip: 0, progressPermille: 100)
    }

    func testFirstCheckStartsEmptyPreparedWallet() async throws {
        try await assertFirstCheckStarts(chainTip: 0, progressPermille: 0)
    }

    // Checking while recovery owns a temporarily idle engine must not queue another start.
    func testCheckReusesRecoveryWhileNativeReopenIsHeld() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        addTeardownBlock {
            fixture.engine.reopenGate.open()
            try await fixture.redeemer.cleanup()
        }
        let initial = try await boundedCheck(fixture.redeemer)
        XCTAssertEqual(initial.state, .ready)
        fixture.engine.reopenGate.close()
        defer { fixture.engine.reopenGate.open() }
        let entered = XCTestExpectation(description: "automatic recovery entered native reopen")
        await fixture.engine.onCall("reopen") { entered.fulfill() }
        await fixture.synchronizer.requestStallRecovery(
            observedPassGeneration: await fixture.synchronizer.passGenerationForTesting(),
            observedStopRequestGeneration: await fixture.synchronizer.stopRequestGenerationForTesting(),
            attempt: 1
        )
        let held = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard held == .completed else {
            fixture.engine.reopenGate.open()
            try await fixture.redeemer.cleanup()
            XCTFail("Recovery did not enter the held native reopen")
            return
        }
        let running = await fixture.synchronizer.isRunningForTesting()
        XCTAssertFalse(running, "Native reopen must hold the recovery's stopped interval")
        let needsStart = await fixture.synchronizer.shouldStartForGiftCardCheck()
        XCTAssertFalse(needsStart, "A valid recovery still owns the intended pass")
        let completed = XCTestExpectation(description: "check reuses accepted readiness during held recovery")
        let caller = Task {
            defer { completed.fulfill() }
            return try await fixture.redeemer.check()
        }
        defer { caller.cancel() }
        let reused = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(reused, .completed, "The real check must not queue an explicit start behind recovery")
        fixture.engine.reopenGate.open()
        if reused != .completed { caller.cancel() }
        let result = await caller.result
        await fixture.synchronizer.stopAndWait()
        let starts = await fixture.engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, 2, "Only the original pass and its automatic recovery may start")
        try await fixture.redeemer.cleanup()
        let status = try result.get()
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.spendable, Zatoshi(50_000))
    }

    func testCheckStartsFreshPassAfterStopOrError() async throws {
        for failed in [false, true] {
            let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
            addTeardownBlock {
                try await fixture.redeemer.cleanup()
            }
            _ = try await boundedCheck(fixture.redeemer)
            await fixture.synchronizer.stopAndWait()
            if failed { await fixture.synchronizer.setInternalSyncStatusForTesting(.error(ZcashError.rustSlipstreamNotOpen)) }
            let result = try await boundedCheck(fixture.redeemer)
            XCTAssertEqual(result.state, .ready)
            XCTAssertEqual(result.spendable, Zatoshi(50_000))
            let starts = await fixture.engine.calls.filter { $0 == "start" }.count
            XCTAssertEqual(starts, 2)
            try await fixture.redeemer.cleanup()
        }
    }

    // A first-start failure must reach the caller exactly rather than becoming a timeout.
    func testFirstStartErrorPropagatesExactly() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        await fixture.engine.setStartError(ZcashError.rustSlipstreamNotOpen)
        do {
            _ = try await boundedCheck(fixture.redeemer)
            XCTFail("A first-start failure must propagate")
        } catch {
            XCTAssertEqual(error as? ZcashError, .rustSlipstreamNotOpen)
        }
        let starts = await fixture.engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, 1)
        try await fixture.redeemer.cleanup()
    }

    private func boundedCheck(_ redeemer: GiftCardRedeemer) async throws -> GiftCardStatus {
        let completed = XCTestExpectation(description: "check caller completes")
        let caller = Task {
            defer { completed.fulfill() }
            return try await redeemer.check()
        }
        defer { caller.cancel() }
        let finished = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        if finished != .completed {
            caller.cancel()
            XCTFail("Check did not complete")
        }
        return try await caller.value
    }

    private func assertFirstCheckStarts(chainTip: UInt64, progressPermille: UInt16) async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, checkTiming: clock.timing)
        await fixture.engine.setNextSnapshot(
            SlipstreamSnapshot(
                chainTip: chainTip,
                fetchedBlocks: 0,
                scannedBlocks: 0,
                enhancedTxs: 0,
                currentRangeEnd: 0,
                state: 0,
                progressPermille: progressPermille
            )
        )
        fixture.engine.startGate.close()
        defer { fixture.engine.startGate.open() }
        let entered = XCTestExpectation(description: "first check reaches native start")
        await fixture.engine.onCall("start") { entered.fulfill() }
        let completed = XCTestExpectation(description: "first check returns ready after startup")
        let caller = Task {
            defer { completed.fulfill() }
            return try await fixture.redeemer.check()
        }
        defer { caller.cancel() }
        let started = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(started, .completed, "Prepared display state must not suppress the first native start")
        fixture.engine.startGate.open()
        if started != .completed {
            await fulfillment(of: [clock.expectSleep(at: 600_000_000_000)], timeout: 5)
            clock.advance(to: 600_000_000_000)
        }
        let finished = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        if finished != .completed {
            caller.cancel()
            XCTFail("First check did not complete after native start returned")
        }
        switch await caller.result {
        case .success(let status):
            XCTAssertEqual(status.state, .ready)
            XCTAssertEqual(status.spendable, Zatoshi(50_000))
        case .failure(let error):
            XCTFail("First check must return ready: \(error.localizedDescription)")
        }
        let starts = await fixture.engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, 1)
        try await fixture.redeemer.cleanup()
    }
}
