import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class GiftCardCleanupCoordinatorTests: ZcashTestCase {
    // Catches deleting or releasing a wallet whose native wipe refused teardown.
    func testRefusedWipeRetainsRootAndDoesNotFinish() async throws {
        let marker = testTempDirectory.appendingPathComponent("live-marker")
        try Data([1]).write(to: marker)
        let wiped = XCTestExpectation(description: "wipe entered")
        let finished = CoordinatorProbe()
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let attempts = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                if attempts.increment() == 1 { wiped.fulfill() }
                if attempts.count > 1 { return }
                throw CoordinatorTestError.refused
            },
            removeRoot: { try FileManager.default.removeItem(at: marker) },
            didFinish: { finished.increment() }
        )
        do {
            try await coordinator.cleanup(after: nil)
            XCTFail("A refused wipe must reach the waiter")
        } catch {
            XCTAssertEqual(error as? CoordinatorTestError, .refused)
        }
        let entered = await XCTWaiter.fulfillment(of: [wiped], timeout: 1)
        XCTAssertEqual(entered, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(finished.count, 0)
        try await waitFor(clock.expectSleep(at: 1_000_000_000))
        XCTAssertEqual(attempts.count, 1)
        clock.advance(to: 999_999_999)
        XCTAssertEqual(attempts.count, 1)
        let done = XCTestExpectation(description: "retry completes")
        let retry = Task {
            defer { done.fulfill() }
            try await coordinator.cleanup(after: nil)
        }
        try await waitFor(done)
        try await retry.value
    }

    // Catches missing/capped-wrong retries and overlapping automatic attempts.
    func testRetriesUseSerialCappedBackoff() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let attempts = CoordinatorProbe()
        let finished = XCTestExpectation(description: "retry eventually finishes")
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                if attempts.increment() < 8 { throw CoordinatorTestError.refused }
            },
            removeRoot: {},
            didFinish: { finished.fulfill() }
        )
        coordinator.requestCleanup(after: nil)
        for (index, deadline) in [1, 3, 7, 15, 31, 61, 91].enumerated() {
            let instant = UInt64(deadline) * 1_000_000_000
            try await waitFor(clock.expectSleep(at: instant))
            XCTAssertEqual(attempts.count, index + 1)
            clock.advance(to: instant - 1)
            XCTAssertEqual(attempts.count, index + 1)
            clock.advance(to: instant)
        }
        try await waitFor(finished)
        XCTAssertEqual(attempts.count, 8)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches treating a retrying root deletion as permission to wipe a closed handle again.
    func testRootRemovalRetryDoesNotRepeatSuccessfulWipe() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let wipes = CoordinatorProbe()
        let removals = CoordinatorProbe()
        let finishes = CoordinatorProbe()
        let marker = testTempDirectory.appendingPathComponent("root-marker")
        try Data([1]).write(to: marker)
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { wipes.increment() },
            removeRoot: {
                if removals.increment() == 1 { throw CoordinatorTestError.refused }
                try FileManager.default.removeItem(at: marker)
            },
            didFinish: { finishes.increment() }
        )
        do {
            try await coordinator.cleanup(after: nil)
            XCTFail("Root removal error must reach the waiter")
        } catch { XCTAssertEqual(error as? CoordinatorTestError, .refused) }
        try await waitFor(clock.expectSleep(at: 1_000_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(finishes.count, 0)
        try await coordinator.cleanup(after: nil)
        XCTAssertEqual(wipes.count, 1)
        XCTAssertEqual(removals.count, 2)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches stale failure delivery or a new caller leaving owned cleanup asleep in backoff.
    func testRepeatedCleanupPromptsPendingRetry() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let attempts = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { if attempts.increment() < 4 { throw CoordinatorTestError.refused } },
            removeRoot: {},
            didFinish: {}
        )
        for deadline in [1, 2, 4] {
            do {
                try await coordinator.cleanup(after: nil)
                XCTFail("Attempt must fail before eventual success")
            } catch { XCTAssertEqual(error as? CoordinatorTestError, .refused) }
            try await waitFor(clock.expectSleep(at: UInt64(deadline) * 1_000_000_000))
        }
        try await coordinator.cleanup(after: nil)
        XCTAssertEqual(attempts.count, 4)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches starting duplicate native attempts when another caller joins hung teardown.
    func testConcurrentWaitersJoinOneWipeAndFinishBeforeSuccess() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let wipes = CoordinatorProbe()
        let finishes = CoordinatorProbe()
        let entered = XCTestExpectation(description: "wipe entered")
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                if wipes.increment() == 1 { entered.fulfill() }
                await gate.wait()
            },
            removeRoot: {},
            didFinish: { finishes.increment() }
        )
        let first = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(entered)
        let second = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000, count: 2))
        XCTAssertEqual(wipes.count, 1)
        await gate.open()
        try await first.value
        XCTAssertEqual(finishes.count, 1)
        try await second.value
        XCTAssertEqual(finishes.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches starting the budget after predecessor completion or cancelling owned work on expiry.
    func testTimeoutIncludesTimeQueuedBehindPredecessor() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let entered = XCTestExpectation(description: "predecessor entered")
        let predecessor = Task {
            entered.fulfill()
            await gate.wait()
        }
        let wipes = CoordinatorProbe()
        let finished = XCTestExpectation(description: "late teardown completes")
        let returned = XCTestExpectation(description: "waiter times out")
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { wipes.increment() },
            removeRoot: {},
            didFinish: { finished.fulfill() }
        )
        try await waitFor(entered)
        let cleanup = Task {
            defer { returned.fulfill() }
            try await coordinator.cleanup(after: predecessor)
        }
        try await waitFor(clock.expectSleep(at: 30_000_000_000))
        clock.advance(to: 30_000_000_000)
        try await waitFor(returned)
        do {
            try await cleanup.value
            XCTFail("Queued caller must time out")
        } catch { XCTAssertTrue(error is GiftCardCleanupWaitError) }
        XCTAssertEqual(wipes.count, 0)
        await gate.open()
        try await waitFor(finished)
        XCTAssertEqual(wipes.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches waiter cancellation propagating to native wipe or another caller.
    func testCancellingOneWaiterDoesNotCancelAttemptOrOtherWaiters() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let wipes = CoordinatorProbe()
        let attemptCancelled = CoordinatorProbe()
        let entered = XCTestExpectation(description: "wipe entered")
        let returned = XCTestExpectation(description: "cancelled waiter returns")
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                if wipes.increment() == 1 { entered.fulfill() }
                await gate.wait()
                if Task.isCancelled { attemptCancelled.increment() }
            },
            removeRoot: {},
            didFinish: {}
        )
        let first = Task {
            defer { returned.fulfill() }
            try await coordinator.cleanup(after: nil)
        }
        try await waitFor(entered)
        let second = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000, count: 2))
        first.cancel()
        try await waitFor(returned)
        do {
            try await first.value
            XCTFail("Cancelled waiter must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(wipes.count, 1)
        await gate.open()
        try await second.value
        XCTAssertEqual(attemptCancelled.count, 0)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches cancellation lost before the continuation is registered.
    func testCancellationBeforeWaiterRegistrationStillStartsOwnedCleanup() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let entryGate = GiftCardCleanupTestGate()
        defer { Task { await entryGate.open() } }
        let finishes = XCTestExpectation(description: "owned cleanup finishes")
        let wipes = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { wipes.increment() },
            removeRoot: {},
            didFinish: { finishes.fulfill() }
        )
        let caller = Task {
            await entryGate.wait()
            try await coordinator.cleanup(after: nil)
        }
        caller.cancel()
        await entryGate.open()
        do {
            try await caller.value
            XCTFail("Already cancelled caller must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        try await waitFor(finishes)
        XCTAssertEqual(wipes.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches granting a new budget after public entry already consumed the full deadline.
    func testExpiredAdmissionTimesOutBeforeOwnedTeardownFinishes() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        clock.advance(to: 31_000_000_000, deliveringSleeps: false)
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let returned = XCTestExpectation(description: "expired admission returns without waiting for teardown")
        let finished = XCTestExpectation(description: "owned teardown finishes after caller returns")
        let wipes = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                wipes.increment()
                await gate.wait()
            },
            removeRoot: {},
            didFinish: { finished.fulfill() }
        )
        let caller = Task {
            defer { returned.fulfill() }
            try await coordinator.cleanup(after: nil, admittedAt: 0)
        }
        let result = await XCTWaiter.fulfillment(of: [returned], timeout: 5)
        XCTAssertEqual(result, .completed, "Elapsed admission must select timeout without timer delivery or teardown completion")
        // Release the owned attempt even when the unchanged implementation failed the assertion.
        await gate.open()
        do {
            try await caller.value
            XCTFail("Admission beyond 30 seconds must time out")
        } catch { XCTAssertTrue(error is GiftCardCleanupWaitError) }
        try await waitFor(finished)
        try await coordinator.cleanup(after: nil)
        XCTAssertEqual(wipes.count, 1, "A fresh completed call must remain idempotent")
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches another caller's completed teardown bypassing an older admission's elapsed deadline.
    func testExpiredAdmissionStillTimesOutAfterAnotherCallerCompletedCleanup() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let wipes = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { wipes.increment() },
            removeRoot: {},
            didFinish: {}
        )
        try await coordinator.cleanup(after: nil)
        clock.advance(to: 31_000_000_000, deliveringSleeps: false)
        do {
            try await coordinator.cleanup(after: nil, admittedAt: 0)
            XCTFail("An earlier expired admission must time out even when another caller finished teardown")
        } catch { XCTAssertTrue(error is GiftCardCleanupWaitError) }
        try await coordinator.cleanup(after: nil)
        XCTAssertEqual(wipes.count, 1, "Fresh completed calls remain idempotent")
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches late success beating timeout when the timer's delivery is delayed.
    func testSuccessAfterDeadlineTimesOutWithTimerDeliveryHeld() async throws {
        try await verifyCompletionWithTimerHeld(at: 31_000_000_000, fails: false)
    }

    // Catches late failure beating timeout when the timer's delivery is delayed.
    func testFailureAfterDeadlineTimesOutWithTimerDeliveryHeld() async throws {
        try await verifyCompletionWithTimerHeld(at: 31_000_000_000, fails: true)
    }

    // Catches incorrectly replacing an in-budget success with timeout.
    func testSuccessBeforeDeadlineWithTimerDeliveryHeld() async throws {
        try await verifyCompletionWithTimerHeld(at: 29_000_000_000, fails: false)
    }

    // Catches incorrectly replacing an in-budget failure with timeout.
    func testFailureBeforeDeadlineWithTimerDeliveryHeld() async throws {
        try await verifyCompletionWithTimerHeld(at: 29_000_000_000, fails: true)
    }

    // Catches elapsed-time arbitration overwriting an already selected cancellation.
    func testSelectedCancellationSurvivesLateSuccessWithTimerDeliveryHeld() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let finished = XCTestExpectation(description: "owned teardown completes")
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { await gate.wait() },
            removeRoot: {},
            didFinish: { finished.fulfill() }
        )
        let caller = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000))
        caller.cancel()
        do {
            try await caller.value
            XCTFail("Cancellation must return independently of teardown")
        } catch { XCTAssertTrue(error is CancellationError) }
        clock.advance(to: 31_000_000_000, deliveringSleeps: false)
        await gate.open()
        try await waitFor(finished)
        try await coordinator.cleanup(after: nil)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    private func verifyCompletionWithTimerHeld(at instant: UInt64, fails: Bool) async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let attempts = CoordinatorProbe()
        let finishes = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {
                let attempt = attempts.increment()
                await gate.wait()
                if fails && attempt == 1 { throw CoordinatorTestError.refused }
            },
            removeRoot: {},
            didFinish: { finishes.increment() }
        )
        let caller = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000))
        clock.advance(to: instant, deliveringSleeps: false)
        await gate.open()
        do {
            try await caller.value
            if instant > 30_000_000_000 {
                XCTFail("Completion after expiry must time out even while timer delivery is held")
            } else {
                XCTAssertFalse(fails, "In-budget failure must reach the caller")
            }
        } catch {
            if instant > 30_000_000_000 {
                XCTAssertTrue(error is GiftCardCleanupWaitError, "Expiry must beat late wipe failure")
            } else {
                XCTAssertEqual(error as? CoordinatorTestError, .refused)
                XCTAssertTrue(fails)
            }
        }
        if fails {
            // Join retry registration before a fresh caller prompts it, preserving serial recovery.
            try await waitFor(clock.expectSleep(at: instant + 1_000_000_000))
        }
        try await coordinator.cleanup(after: nil)
        XCTAssertEqual(attempts.count, fails ? 2 : 1)
        XCTAssertEqual(finishes.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches double-resume in simultaneous timeout/success and abandoned timer tasks.
    func testSuccessAtDeadlineDisposesWaiterTimer() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let finishes = XCTestExpectation(description: "attempt finishes")
        let returned = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { await gate.wait() },
            removeRoot: {},
            didFinish: { finishes.fulfill() }
        )
        let caller = Task {
            defer { returned.increment() }
            try await coordinator.cleanup(after: nil)
        }
        try await waitFor(clock.expectSleep(at: 30_000_000_000))
        let expiry = Task { clock.advance(to: 30_000_000_000) }
        await gate.open()
        await expiry.value
        do { try await caller.value } catch { XCTAssertTrue(error is GiftCardCleanupWaitError) }
        try await waitFor(finishes)
        XCTAssertEqual(returned.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches losing teardown when deinit is the last external owner during backoff.
    func testDroppingAllExternalCoordinatorReferencesStillCompletesRetry() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let attempts = CoordinatorProbe()
        let finished = XCTestExpectation(description: "retained retry completes")
        var coordinator: GiftCardCleanupCoordinator? = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { if attempts.increment() == 1 { throw CoordinatorTestError.refused } },
            removeRoot: {},
            didFinish: { finished.fulfill() }
        )
        let reference = CoordinatorReference(coordinator)
        coordinator?.requestCleanup(after: nil)
        try await waitFor(clock.expectSleep(at: 1_000_000_000))
        coordinator = nil
        XCTAssertNotNil(reference.coordinator)
        clock.advance(to: 1_000_000_000)
        try await waitFor(finished)
        XCTAssertEqual(attempts.count, 2)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches an old completed coordinator deleting a replacement wallet's files.
    func testRepeatedCleanupAfterCompletionDoesNotTouchFiles() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let wipes = CoordinatorProbe()
        let finishes = CoordinatorProbe()
        let marker = testTempDirectory.appendingPathComponent("replacement-marker")
        try Data([1]).write(to: marker)
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { wipes.increment() },
            removeRoot: { try FileManager.default.removeItem(at: marker) },
            didFinish: { finishes.increment() }
        )
        try await coordinator.cleanup(after: nil)
        try Data([2]).write(to: marker)
        try await coordinator.cleanup(after: nil)
        coordinator.requestCleanup(after: nil)
        XCTAssertEqual(wipes.count, 1)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(try Data(contentsOf: marker), Data([2]))
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches sharing the first caller's deadline with a later caller.
    func testEachCallerReceivesItsOwnAdmissionBudget() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        defer { Task { await gate.open() } }
        let secondReturned = CoordinatorProbe()
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: { await gate.wait() },
            removeRoot: {},
            didFinish: {}
        )
        let first = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000))
        clock.advance(to: 10_000_000_000)
        let second = Task {
            defer { secondReturned.increment() }
            try await coordinator.cleanup(after: nil)
        }
        try await waitFor(clock.expectSleep(at: 40_000_000_000))
        clock.advance(to: 30_000_000_000)
        do {
            try await first.value
            XCTFail("The first caller must time out independently")
        } catch { XCTAssertTrue(error is GiftCardCleanupWaitError) }
        XCTAssertEqual(secondReturned.count, 0)
        await gate.open()
        try await second.value
        XCTAssertEqual(secondReturned.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    // Catches reporting success while owner release is blocked, or invoking release under the state lock.
    func testFinishCallbackMayReenterAndMustReturnBeforeSuccess() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let finishGate = CoordinatorBlockingGate()
        defer { finishGate.open() }
        let entered = XCTestExpectation(description: "owner release entered")
        let returned = CoordinatorProbe()
        let finishes = CoordinatorProbe()
        let reference = CoordinatorReference(nil)
        let coordinator = GiftCardCleanupCoordinator(
            timing: clock.timing,
            wipe: {},
            removeRoot: {},
            didFinish: {
                if finishes.increment() == 1 {
                    reference.coordinator?.requestCleanup(after: nil)
                    entered.fulfill()
                }
                finishGate.wait()
            }
        )
        reference.coordinator = coordinator
        let caller = Task {
            defer { returned.increment() }
            try await coordinator.cleanup(after: nil)
        }
        try await waitFor(entered)
        let joined = Task { try await coordinator.cleanup(after: nil) }
        try await waitFor(clock.expectSleep(at: 30_000_000_000, count: 2))
        XCTAssertEqual(returned.count, 0)
        finishGate.open()
        try await caller.value
        try await joined.value
        XCTAssertEqual(finishes.count, 1)
        try await waitFor(clock.expectNoPendingSleeps())
    }

    private func waitFor(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw CoordinatorTestError.testDeadline }
    }
}

private enum CoordinatorTestError: Error {
    case refused
    case testDeadline
}

private final class CoordinatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let result = value
        lock.unlock()
        return result
    }
}

private final class CoordinatorReference: @unchecked Sendable {
    weak var coordinator: GiftCardCleanupCoordinator?

    init(_ coordinator: GiftCardCleanupCoordinator?) {
        self.coordinator = coordinator
    }
}

private final class CoordinatorBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}
