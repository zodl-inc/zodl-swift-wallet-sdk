import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardStallRetryTests: ZcashTestCase {
    // Losing retained give-up state strands the second check on the exhausted syncing pass.
    func testCheckAfterTerminalStallRestartsExhaustedPass() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, checkTiming: clock.timing)
        await fixture.engine.setSnapshotOnStart(SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010))
        let syncing = XCTestExpectation(description: "first check started its pass")
        let subscription = fixture.synchronizer.stateStream
            .filter {
                if case .syncing = $0.syncStatus { return true }
                return false
            }
            .prefix(1)
            .sink { _ in syncing.fulfill() }
        defer { subscription.cancel() }
        let first = Task { try await fixture.redeemer.check() }
        defer { first.cancel() }
        await fulfillment(of: [syncing], timeout: 5)
        try await exhaustRecovery(fixture)
        do {
            _ = try await first.value
            XCTFail("The first attempt must fail when automatic recovery gives up")
        } catch ZcashError.giftCardCheckSyncStalled { }
        try await assertRetryReady(fixture)
        try await fixture.redeemer.cleanup()
    }

    // A waiter-local failure cache cannot observe exhaustion while no check exists.
    func testStallBetweenChecksIsRecoveredByNextCheck() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let initial = try await fixture.redeemer.check()
        XCTAssertEqual(initial.state, .ready)
        await fixture.engine.setSnapshotOnStart(SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010))
        try await fixture.synchronizer.start(retry: true)
        try await exhaustRecovery(fixture)
        try await assertRetryReady(fixture)
        try await fixture.redeemer.cleanup()
    }

    // Restarting every check would disrupt both healthy syncing and accepted up-to-date passes.
    func testHealthyPassIsNotRestarted() async throws {
        for syncing in [false, true] {
            let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
            let initial = try await fixture.redeemer.check()
            XCTAssertEqual(initial.state, .ready)
            if syncing {
                await fixture.engine.setSnapshotOnStart(SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010))
                try await fixture.synchronizer.start(retry: true)
            }
            let needsStart = await fixture.synchronizer.shouldStartForGiftCardCheck()
            XCTAssertFalse(needsStart, "Healthy syncing and up-to-date hosts must reuse their pass")
            let before = await fixture.engine.calls.filter { $0 == "start" }.count
            if syncing { await fixture.engine.setNextSnapshot(readySnapshot()) }
            let status = try await boundedCheck(fixture.redeemer)
            XCTAssertEqual(status.state, .ready)
            XCTAssertEqual(status.spendable, Zatoshi(50_000))
            let after = await fixture.engine.calls.filter { $0 == "start" }.count
            XCTAssertEqual(after, before)
            try await fixture.redeemer.cleanup()
        }
    }

    // Each explicit retry owns its own terminal event rather than replaying the prior one.
    func testSecondTerminalStallFailsTheRetry() async throws {
        let fixture = try await stalledFixture()
        let proposals = fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount
        let restarted = XCTestExpectation(description: "retry published its fresh syncing pass")
        let subscription = fixture.synchronizer.stateStream
            .dropFirst()
            .filter {
                if case .syncing = $0.syncStatus { return true }
                return false
            }
            .prefix(1)
            .sink { _ in restarted.fulfill() }
        defer { subscription.cancel() }
        let caller = Task { try await fixture.redeemer.check() }
        defer { caller.cancel() }
        let outcome = await XCTWaiter.fulfillment(of: [restarted], timeout: 5)
        guard outcome == .completed else {
            caller.cancel()
            _ = await caller.result
            XCTFail("Retry must restart before another terminal stall can be observed")
            try await fixture.redeemer.cleanup()
            return
        }
        try await exhaustRecovery(fixture)
        do {
            _ = try await caller.value
            XCTFail("A second exhausted pass must fail its own check")
        } catch ZcashError.giftCardCheckSyncStalled { }
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, proposals)
        try await fixture.redeemer.cleanup()
    }

    // Discarding the start error would silently return to waiting on the exhausted pass.
    func testRetryStartErrorPropagates() async throws {
        let fixture = try await stalledFixture()
        await fixture.engine.setStartError(ZcashError.rustSlipstreamNotOpen)
        do {
            _ = try await boundedCheck(fixture.redeemer)
            XCTFail("The explicit restart error must propagate")
        } catch ZcashError.rustSlipstreamNotOpen { }
        try await fixture.redeemer.cleanup()
    }

    // Caller detachment must not allow cleanup to close or delete a held retry start.
    func testCancelledHeldRetryRemainsOwnedUntilCleanupDrains() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await stalledFixture(clock: clock)
        let proposals = fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("held-retry-marker")
        try Data([1]).write(to: marker)
        let before = await fixture.engine.calls.count
        fixture.engine.startGate.close()
        defer { fixture.engine.startGate.open() }
        let entered = XCTestExpectation(description: "owned retry native start entered")
        await fixture.engine.onCall("start") { entered.fulfill() }
        let caller = Task { try await fixture.redeemer.check() }
        defer { caller.cancel() }
        let outcome = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard outcome == .completed else {
            caller.cancel()
            fixture.engine.startGate.open()
            _ = await caller.result
            XCTFail("Retry must reach the held start")
            try await fixture.redeemer.cleanup()
            return
        }
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Cancelled retry caller must detach")
        } catch is CancellationError { }
        let cleanup = Task { try await fixture.redeemer.cleanup() }
        await fulfillment(of: [clock.expectSleep(at: 30_000_000_000)], timeout: 5)
        clock.advance(to: 30_000_000_000)
        do {
            try await cleanup.value
            XCTFail("Cleanup must retain the held restart")
        } catch ZcashError.giftCardCleanupTimedOut { }
        let heldCalls = await fixture.engine.calls.dropFirst(before)
        XCTAssertFalse(heldCalls.contains(where: GatedFakeSlipstreamEngine.isStop))
        XCTAssertFalse(heldCalls.contains("close"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try GiftCardRedeemer(
            card: fixture.card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )) { XCTAssertEqual($0 as? ZcashError, .giftCardRedeemerAlreadyActive) }
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        fixture.engine.startGate.open()
        try await fixture.redeemer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, proposals)
    }

    private func stalledFixture(clock: GiftCardCleanupTestClock? = nil) async throws -> GiftCardCancellationFixture {
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock?.timing ?? .live,
            checkTiming: clock?.timing ?? .live
        )
        _ = try await fixture.redeemer.check()
        await fixture.engine.setSnapshotOnStart(SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010))
        try await fixture.synchronizer.start(retry: true)
        try await exhaustRecovery(fixture)
        return fixture
    }

    private func boundedCheck(_ redeemer: GiftCardRedeemer) async throws -> GiftCardStatus {
        let completed = XCTestExpectation(description: "check completes without using its ten-minute deadline")
        let caller = Task {
            defer { completed.fulfill() }
            return try await redeemer.check()
        }
        defer { caller.cancel() }
        let outcome = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        if outcome != .completed {
            caller.cancel()
            XCTFail("Check did not complete promptly")
        }
        return try await caller.value
    }

    private func readySnapshot() -> SlipstreamSnapshot {
        SlipstreamSnapshot(
            chainTip: 3_000_010,
            fetchedBlocks: 0,
            scannedBlocks: 0,
            enhancedTxs: 0,
            currentRangeEnd: 0,
            state: 3,
            progressPermille: 1000,
            tipFresh: 1
        )
    }

    private func exhaustRecovery(_ fixture: GiftCardCancellationFixture) async throws {
        let gaveUp = XCTestExpectation(description: "one terminal stall at the three-attempt cap")
        let subscription = fixture.synchronizer.eventStream.sink {
            if case .syncStalled(let attempt, true) = $0 {
                XCTAssertEqual(attempt, 3)
                gaveUp.fulfill()
            }
        }
        defer { subscription.cancel() }
        for attempt in 1...3 {
            await fixture.synchronizer.runStallRecovery(
                expectedPassGeneration: await fixture.synchronizer.passGenerationForTesting(),
                expectedStopRequestGeneration: await fixture.synchronizer.stopRequestGenerationForTesting(),
                attempt: attempt
            )
        }
        await fixture.engine.setNextSnapshot(
            SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010, stalledSeconds: 600)
        )
        await fixture.synchronizer.seedStallClockForTesting(secondsAgo: 600)
        let outcome = await XCTWaiter.fulfillment(of: [gaveUp], timeout: 5)
        XCTAssertEqual(outcome, .completed)
        guard outcome == .completed else { throw ZcashError.giftCardCheckTimedOut }
        let spent = await fixture.synchronizer.stallRestartAttemptsForTesting()
        XCTAssertEqual(spent, 3)
        if case .syncing = fixture.synchronizer.latestState.syncStatus { } else {
            XCTFail("Regression requires the exhausted pass to retain syncing state")
        }
    }

    private func assertRetryReady(_ fixture: GiftCardCancellationFixture) async throws {
        let startsBefore = await fixture.engine.calls.filter { $0 == "start" }.count
        fixture.engine.startGate.close()
        defer { fixture.engine.startGate.open() }
        await fixture.engine.setSnapshotOnStart(readySnapshot())
        let entered = XCTestExpectation(description: "retry explicitly starts a fresh pass")
        await fixture.engine.onCall("start") { entered.fulfill() }
        let retry = Task { try await fixture.redeemer.check() }
        defer { retry.cancel() }
        let outcome = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard outcome == .completed else {
            retry.cancel()
            fixture.engine.startGate.open()
            _ = await retry.result
            XCTFail("Retry never restarted the exhausted pass")
            return
        }
        let reset = await fixture.synchronizer.stallRestartAttemptsForTesting()
        XCTAssertEqual(reset, 0, "Explicit retry must restore the automatic recovery budget")
        fixture.engine.startGate.open()
        let completed = XCTestExpectation(description: "restarted check returns ready")
        let observer = Task {
            _ = await retry.result
            completed.fulfill()
        }
        let finished = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        if finished != .completed {
            retry.cancel()
            XCTFail("Restart did not produce coherent readiness")
        }
        await observer.value
        let ready = try await retry.value
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.spendable, Zatoshi(50_000))
        let startsAfter = await fixture.engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startsAfter, startsBefore + 1)
    }
}
