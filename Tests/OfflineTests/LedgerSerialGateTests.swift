//
//  LedgerSerialGateTests.swift
//  OfflineTests
//
//  LedgerSerialGate, and the two callers that bracket their operation with it.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// Polls `condition` with a short yield between checks, failing the test after `timeoutSeconds` if
/// it never becomes true. Not named `waitUntil`: `XCTestCase` has a member of that name (from
/// `TestUtils`) that returns the outcome instead of failing, and member lookup would win. Used to wait for an actor's observable state instead of guessing with a
/// fixed sleep, which would either race a slow run or waste time on a fast one.
private func expectEventually(
    timeoutSeconds: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = DispatchTime.now() + timeoutSeconds
    while DispatchTime.now() < deadline {
        if await condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("condition did not become true within \(timeoutSeconds) s", file: file, line: line)
}

final class LedgerSerialGateTests: XCTestCase {
    /// A caller cancelled while actually queued for the gate throws promptly, instead of being
    /// admitted later and failing inside its own operation. Arrival order for everyone else keeps
    /// working: the third caller is admitted as soon as the holder releases, right behind the (now
    /// gone) second.
    func testACancelledWaiterLeavesPromptlyAndArrivalOrderContinues() async throws {
        let gate = LedgerSerialGate()
        try await gate.acquire() // the holder

        let second = Task { try await gate.acquire() }
        // Waits for `second` to have actually reached the queue before cancelling it: cancelling
        // any earlier would exercise the already-cancelled-on-entry path instead of this one.
        await expectEventually { await gate.queuedCount == 1 }
        second.cancel()

        do {
            try await second.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }

        let third = Task { try await gate.acquire() }
        // A test-side backstop: if a bug left the gate unable to admit `third`, this cuts the test off
        // instead of hanging the whole run.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            third.cancel()
        }

        // Waits for `third` to have actually reached the queue before releasing: releasing any
        // earlier risks finding the gate idle (second already gone, third not queued yet) and
        // admitting it through the fast path, which is not the hand-off this test means to cover.
        await expectEventually { await gate.queuedCount == 1 }
        await gate.release()

        do {
            try await third.value
        } catch {
            XCTFail("a third caller must be admitted once the holder releases: \(error)")
        }
        watchdog.cancel()
    }

    /// A caller already cancelled before it ever calls `acquire()` throws at once, from the
    /// upfront `Task.checkCancellation()`, without being queued or touching the busy flag: the gate
    /// is still free for the very next caller.
    func testACallerAlreadyCancelledOnEntryThrowsWithoutTouchingTheGate() async throws {
        let gate = LedgerSerialGate()

        let task = Task {
            // Cancels this task from inside its own body, before its first line runs: cancelling
            // it from outside right after creation would race the task actually starting, and
            // could instead exercise the cancelled-while-queued path this test is not about.
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire()
        }

        do {
            try await task.value
            XCTFail("an already-cancelled caller must throw")
        } catch is CancellationError {
            // expected
        }

        let queuedCount = await gate.queuedCount
        XCTAssertEqual(queuedCount, 0, "an already-cancelled caller must never be queued")

        // The gate must still be free: nothing admitted the cancelled caller, so nothing is
        // holding it.
        try await gate.acquire()
    }

    /// `acquire()` used to park a non-throwing continuation, so a caller cancelled while queued
    /// stayed queued, was eventually admitted anyway, and then failed inside its operation on
    /// `Task.checkCancellation()` -- closing the shared transport out from under whichever call was
    /// really in flight. A caller that throws out of `acquire()` itself never held the gate, so it
    /// must not reach that failure path at all. Brackets `LedgerCommands.exchange` with its own gate
    /// the same way `LedgerBluetoothTransport` and `LedgerDevice` do internally, since both keep
    /// their own gate private.
    func testATransportIsNotClosedByACallerCancelledWhileWaitingForTheGate() async throws {
        let gate = LedgerSerialGate()
        let transport = ScriptedLedgerTransport(delayNanoseconds: 500_000_000) { _, _ in
            LedgerReplies.firmwareVersion(3, 9, 3)
        }

        func exchangeUnderGate() async throws -> Data {
            try await gate.acquire()
            do {
                let reply = try await LedgerCommands.exchange(Data([0xC4]), on: transport, timeout: nil)
                await gate.release()
                return reply
            } catch {
                await gate.release()
                throw error
            }
        }

        let first = Task { try await exchangeUnderGate() }
        // Waits for `first` to have actually reached its (stalled) exchange, so it provably still
        // holds the gate once `second` is created.
        await expectEventually { await transport.received.count == 1 }

        let second = Task { try await exchangeUnderGate() }
        // Waits for `second` to have actually reached the queue before cancelling it, for the same
        // reason as the test above.
        await expectEventually { await gate.queuedCount == 1 }
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }

        let reply = try await first.value
        XCTAssertEqual(reply, LedgerReplies.firmwareVersion(3, 9, 3), "the holder's own call must still complete normally")

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a caller cancelled while only queued for the gate must not close the transport")
    }

    /// `LedgerCommands.exchange` must not close a transport over a cancellation that never reached
    /// the wire: two callers share one transport that gates its own `exchange(_:timeout:)`, the
    /// second is cancelled while queued for that internal gate, and the holder's own exchange must
    /// still complete, with the transport left open for it. The refusal reaches the caller as
    /// ``LedgerExchangeNotStarted``, not as a plain `CancellationError`.
    func testLedgerCommandsExchangeDoesNotCloseATransportForAnExchangeThatNeverStarted() async throws {
        let transport = GatedScriptedLedgerTransport(delayNanoseconds: 500_000_000) { _ in
            LedgerReplies.firmwareVersion(3, 9, 3)
        }

        let first = Task { try await LedgerCommands.exchange(Data([0xC4]), on: transport, timeout: nil) }
        // Waits for `first` to have actually started its (stalled) exchange, so it provably holds
        // the transport's own gate once `second` is created.
        await expectEventually { await transport.exchangesStarted == 1 }

        let second = Task { try await LedgerCommands.exchange(Data([0xC4]), on: transport, timeout: nil) }
        await expectEventually { await transport.queuedCount == 1 }
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("a cancelled waiter must throw")
        } catch is LedgerExchangeNotStarted {
            // Expected: the marker comes through as it is, so `LedgerDevice` and `LedgerSigner` can
            // tell this cancellation from one that reached the device; `ledgerZcashError(_:)` turns
            // it into the `CancellationError` their callers see.
        }

        let reply = try await first.value
        XCTAssertEqual(reply, LedgerReplies.firmwareVersion(3, 9, 3), "the holder's own exchange must still complete normally")

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a cancellation that never reached the wire must not close the transport")
    }
}

/// A scripted transport with its own internal admission gate around `exchange(_:timeout:)`, sharing
/// `ledgerGatedExchange(on:_:)` with `LedgerBluetoothTransport`: one exchange on the wire at a time,
/// and a caller the gate refuses throws ``LedgerExchangeNotStarted`` rather than letting the gate's
/// own `CancellationError` read as an exchange failure. `ScriptedLedgerTransport` has no gate of its
/// own, so it cannot stand in for this.
private actor GatedScriptedLedgerTransport: LedgerAPDUTransport {
    private let gate = LedgerSerialGate()
    private let delayNanoseconds: UInt64
    private let script: @Sendable (Data) throws -> Data
    private(set) var exchangesStarted = 0
    private(set) var closeCount = 0

    var queuedCount: Int {
        get async { await gate.queuedCount }
    }

    init(delayNanoseconds: UInt64, script: @escaping @Sendable (Data) throws -> Data) {
        self.delayNanoseconds = delayNanoseconds
        self.script = script
    }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        try await ledgerGatedExchange(on: gate) {
            exchangesStarted += 1
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return try script(apdu)
        }
    }

    func close() async {
        closeCount += 1
    }
}
