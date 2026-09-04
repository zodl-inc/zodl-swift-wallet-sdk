//
//  SlipstreamStallRecoveryPolicyTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Coverage for the stall watchdog's recovery restart (MOB-1850): the pure policy
/// `SlipstreamSynchronizer.stallRecoveryDecision(...)`, and the reporting the restart owes its host
/// when it cannot bring the pass back up. The watchdog used to only log a stalled pass; it now
/// restarts one, so the policy owns the two properties that keep the restart safe -- a per-handle
/// cap on how many times a pass may be resurrected, and an exponential wait between attempts so a
/// server that is down is not hammered once per poll tick -- and the restart owns the promise that
/// every `.syncStalled` the host is handed eventually resolves.
final class SlipstreamStallRecoveryPolicyTests: ZcashTestCase {
    private let backoffBase: TimeInterval = 60
    private let maxAttempts = 3

    /// A healthy pass never restarts, whatever the counters say.
    func testNotStalledDecidesNone() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: false,
                attemptsSoFar: 0,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: nil,
                backoffBase: backoffBase
            ),
            .none
        )
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: false,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 10_000,
                backoffBase: backoffBase
            ),
            .none,
            "a recovered pass must not restart just because its budget and backoff would allow it"
        )
    }

    /// The first stall of a handle restarts immediately — there is no earlier restart to wait after,
    /// and the whole point is to reconnect without the user asking.
    func testFirstStallRestartsImmediately() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 0,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: nil,
                backoffBase: backoffBase
            ),
            .restart(attempt: 1)
        )
    }

    /// Still inside the first backoff window (60 s after restart 1) → hold. Without this the poll
    /// loop would re-decide every 2 s and burn the whole budget in six seconds.
    func testSecondStallInsideBackoffWindowHolds() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 1,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 30,
                backoffBase: backoffBase
            ),
            .none
        )
    }

    /// Past the first backoff window → the second restart is allowed.
    func testSecondStallPastBackoffWindowRestarts() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 1,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 61,
                backoffBase: backoffBase
            ),
            .restart(attempt: 2)
        )
    }

    /// The window doubles with each attempt: after two restarts the wait is 120 s, so 119 s holds.
    func testThirdStallInsideDoubledBackoffWindowHolds() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 119,
                backoffBase: backoffBase
            ),
            .none
        )
    }

    /// …and 121 s clears it, allowing the third and last restart.
    func testThirdStallPastDoubledBackoffWindowRestarts() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 121,
                backoffBase: backoffBase
            ),
            .restart(attempt: 3)
        )
    }

    /// The budget is spent: the SDK stops trying and says so, so the host can offer the user a
    /// server switch instead of watching a pass restart forever.
    func testBudgetExhaustedGivesUp() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 10_000,
                backoffBase: backoffBase
            ),
            .giveUp,
            "the cap wins over an elapsed backoff window"
        )
    }

    /// The shipped policy, end to end: 3 restarts per handle with exactly TWO waits between them,
    /// 60 s and then 120 s, and a give-up in place of a fourth restart.
    ///
    /// The cap is checked before any backoff window is computed, so the doubling stops where the
    /// budget does: with `maxStallRestartsPerHandle == 3` the largest window a shipped decision
    /// can ever evaluate is the one for `attemptsSoFar == 2`. A third window would need a fourth
    /// restart to sit in front of, and there is none.
    func testShippedPolicyRestartsThreeTimesWithTwoWaits() {
        XCTAssertEqual(SlipstreamSynchronizer.maxStallRestartsPerHandle, 3)
        XCTAssertEqual(SlipstreamSynchronizer.stallRestartBackoffBase, 60)

        // Walk the shipped constants through the policy the way `tickPoll` does, so the waits
        // between consecutive restarts are pinned as 60 s and then 120 s.
        for (attemptsSoFar, window) in [(1, 60.0), (2, 120.0)] {
            let justInside = shippedDecision(attemptsSoFar: attemptsSoFar, secondsSinceLastRestart: window - 1)
            let atWindow = shippedDecision(attemptsSoFar: attemptsSoFar, secondsSinceLastRestart: window)
            XCTAssertEqual(justInside, .none, "attempt \(attemptsSoFar + 1) must wait the full \(Int(window)) s")
            XCTAssertEqual(atWindow, .restart(attempt: attemptsSoFar + 1), "attempt \(attemptsSoFar + 1) is due at \(Int(window)) s")
        }

        // And there is no third wait: after the third restart the budget is spent, so however long
        // the host waits it is told to stop rather than handed a 240 s window.
        for elapsed in [239.0, 240.0, 10_000.0] {
            XCTAssertEqual(
                shippedDecision(attemptsSoFar: 3, secondsSinceLastRestart: elapsed),
                .giveUp,
                "the shipped cap gives up instead of opening a further backoff window at \(Int(elapsed)) s"
            )
        }
    }

    /// The doubling itself, tested as a property of the FUNCTION rather than of the shipped
    /// policy: raise the cap and the window after attempt 3 is 240 s. The shipped configuration
    /// never reaches this window (see the test above); it is asserted here so a change to the
    /// backoff formula cannot pass unnoticed behind the cap.
    func testBackoffWindowKeepsDoublingWhenTheCapAllowsIt() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: 4,
                secondsSinceLastRestart: 239,
                backoffBase: backoffBase
            ),
            .none
        )
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: 4,
                secondsSinceLastRestart: 240,
                backoffBase: backoffBase
            ),
            .restart(attempt: 4)
        )
    }

    // MARK: - The watchdog -> policy seam

    /// The stall fact the policy consumes comes from `checkStallWatchdog`, which clamps the
    /// engine-reported span to the CURRENT handle's lifetime. That clamp used to only spare the
    /// user a wrong log line; it now decides whether the SDK tears the engine down. A freshly
    /// opened handle must therefore report "not stalled" no matter how large a span the engine
    /// carries over -- `stalledSeconds` survives a stop->start, so believing an inherited span
    /// would restart a pass that is seconds old, and the restart would hand the next tick exactly
    /// the same inherited span again.
    func testFreshHandleReportsNoStallDespiteInheritedStallSpan() async throws {
        let synchronizer = try makeSynchronizer()
        let snapshot = SlipstreamSnapshot(
            chainTip: 2_000_000,
            fetchedBlocks: 10,
            scannedBlocks: 10,
            enhancedTxs: 0,
            currentRangeEnd: 2_000_000,
            state: 1,
            stalledSeconds: 497
        )

        let stalled = await synchronizer.checkStallWatchdog(snapshot)

        XCTAssertFalse(stalled, "a handle opened moments ago cannot have accrued a 497 s stall")
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: stalled,
                attemptsSoFar: 0,
                maxAttempts: SlipstreamSynchronizer.maxStallRestartsPerHandle,
                secondsSinceLastRestart: nil,
                backoffBase: SlipstreamSynchronizer.stallRestartBackoffBase
            ),
            .none,
            "and so must not spend a restart from the handle's budget"
        )
    }

    // MARK: - A restart that cannot bring the pass back up

    /// A failed restart must report the give-up on attempt 1, not only at the cap.
    ///
    /// `restartHandleForRecovery` calls `stopPolling()` before anything else and `start()` throws
    /// before it reaches `startPolling()`, so a restart whose `start()` fails leaves no poll loop
    /// at all: nothing ticks, nothing re-decides, and the `.giveUp` branch — which lives in
    /// `tickPoll` — can never fire. While the give-up report was gated on
    /// `stallRestartAttempts >= maxStallRestartsPerHandle`, a failure on attempt 1 or 2 therefore
    /// left the synchronizer permanently stopped AND permanently silent: a host that had just been
    /// handed `.syncStalled(attempt: 1, gaveUp: false)` waited forever for a resolution nothing
    /// could produce. This synchronizer is unprepared, so its `start()` throws
    /// `.synchronizerNotPrepared` on the very first attempt — the most reachable of the three ways
    /// `start()` can fail, alongside the migration gate and a dead transport failing
    /// `engine.start()`.
    func testRestartWhoseStartFailsReportsGiveUpOnTheFirstAttempt() async throws {
        let synchronizer = try makeSynchronizer()
        let giveUp = XCTestExpectation(description: "give-up stall event")
        var events: [SynchronizerEvent] = []
        let subscription = synchronizer.eventStream.sink { event in
            events.append(event)
            if case .syncStalled(_, let gaveUp) = event, gaveUp {
                giveUp.fulfill()
            }
        }
        defer { subscription.cancel() }

        // Generation 0 is the value a poll tick would capture on a synchronizer nothing has
        // stopped, so both of the recovery's generation guards pass and it reaches its `start()`.
        await synchronizer.restartHandleForRecovery(expectedStopGeneration: 0)

        await fulfillment(of: [giveUp], timeout: 5)
        XCTAssertEqual(
            events.compactMap { event -> Int? in
                guard case .syncStalled(let attempt, let gaveUp) = event, gaveUp else { return nil }
                return attempt
            },
            [1],
            "exactly one give-up, naming the attempt that failed"
        )
    }

    // MARK: - Helpers

    /// The policy as the poll loop asks it, with the shipped constants substituted for the
    /// caller-supplied ones.
    private func shippedDecision(attemptsSoFar: Int, secondsSinceLastRestart: TimeInterval?) -> SlipstreamSynchronizer.StallRecoveryDecision {
        SlipstreamSynchronizer.stallRecoveryDecision(
            isStalled: true,
            attemptsSoFar: attemptsSoFar,
            maxAttempts: SlipstreamSynchronizer.maxStallRestartsPerHandle,
            secondsSinceLastRestart: secondsSinceLastRestart,
            backoffBase: SlipstreamSynchronizer.stallRestartBackoffBase
        )
    }

    /// A prepared-nothing synchronizer: no engine handle, `.unprepared` status, no poll loop.
    ///
    /// Enough to drive `checkStallWatchdog`, which reads only the snapshot it is handed and the
    /// watchdog's own Swift-side state, and enough to drive `restartHandleForRecovery`, whose
    /// `engine.reopen` opens a real (idle) handle against the test wallet database while its
    /// `start()` fails on the `isPrepared` guard. Neither touches the network.
    private func makeSynchronizer() throws -> SlipstreamSynchronizer {
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }

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

        return SlipstreamSynchronizer(initializer: initializer)
    }
}
