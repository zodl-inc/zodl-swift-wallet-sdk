//
//  LedgerZcashAppTests.swift
//  OfflineTests
//
//  `LedgerAppLauncher`, driven through `ScriptedLedgerTransport` with small timings so the polling
//  and transition-timeout paths run quickly.
//

import XCTest
@testable import ZODLSwiftWalletSDK

// MARK: - Fixtures

private let getAppAPDU = Data([0xB0, 0x01, 0x00, 0x00, 0x00])
private let closeAppAPDU = Data([0xB0, 0xA7, 0x00, 0x00, 0x00])
private let openZcashAPDU = Data([0xE0, 0xD8, 0x00, 0x00, 0x05]) + Data("Zcash".utf8)

/// An app-query reply: `format ‖ nameLen ‖ name ‖ versionLen ‖ version ‖ [flagsLen ‖ flags] ‖ SW`.
private func app(_ name: String, version: String = "1.0.0", flags: [UInt8]? = nil) -> Data {
    var reply = Data([0x01, UInt8(name.utf8.count)])
    reply.append(Data(name.utf8))
    reply.append(UInt8(version.utf8.count))
    reply.append(Data(version.utf8))
    if let flags {
        reply.append(UInt8(flags.count))
        reply.append(Data(flags))
    }
    reply.append(LedgerReplies.status(0x9000))
    return reply
}

private let dashboardReply = app("BOLOS", version: "2.2.3", flags: [0x02])
private let zcashReply = app("Zcash", version: "4.2.0")

/// A transport that answers each call with the next reply in `replies`, in order.
///
/// Throws `ZcashError.ledgerTransportClosed` once `replies` runs out, rather than indexing past the
/// end of the array: a test whose timing assumption turns out wrong then fails with a clear, catchable
/// error instead of trapping the whole test process.
private func scripted(_ replies: [Data]) -> ScriptedLedgerTransport {
    ScriptedLedgerTransport { _, history in
        guard history.count < replies.count else { throw ZcashError.ledgerTransportClosed }
        return replies[history.count]
    }
}

private struct UnexpectedReconnect: Error {}

/// The scripted reconnect's own safety limit in the overall-switch-timeout tests: proof that the
/// overall cap, not this sentinel, is what ends a flapping link's wait. Against code that does not yet
/// enforce the cap, a flapping link never ends on its own, so this is what turns that red run into a
/// clear, fast failure instead of a hang.
private struct WaitNeverEnded: Error {}

/// A `reconnect` that fails the test if it is ever called.
private func noReconnect() -> @Sendable () async throws -> any LedgerAPDUTransport {
    { throw UnexpectedReconnect() }
}

private struct TestTimedOut: Error {}

/// Races `operation` against a real wall-clock `seconds`, so a red run against code that never ends
/// fails this test at once instead of hanging the whole suite.
private func withTestTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimedOut()
        }
        guard let result = try await group.next() else {
            throw ZcashError.ledgerInternal("withTestTimeout produced no result")
        }
        group.cancelAll()
        return result
    }
}

/// Polls `condition` with a short yield between checks, failing the test after `timeoutSeconds` if
/// it never becomes true. Not named `waitUntil`: `XCTestCase` has a member of that name (from
/// `TestUtils`) that returns the outcome instead of failing, and member lookup would win.
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

/// A one-shot signal: `wait()` returns once `open()` has been called, at once if it already has.
private actor Latch {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}

private func isSame(_ lhs: any LedgerAPDUTransport, _ rhs: any LedgerAPDUTransport) -> Bool {
    (lhs as AnyObject) === (rhs as AnyObject)
}

/// Counts calls from a `@Sendable` closure, such as a `reconnect` callback.
private actor CallCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

/// A monotonic clock a test drives by hand: `sleep` advances `now` by exactly the requested amount
/// instead of waiting, so a test asserts exact timings without running in real time. `NSLock`
/// dates from the SDK's iOS 13 / macOS 12 floor, below `OSAllocatedUnfairLock`'s iOS 16 / macOS 13,
/// as does `LedgerAppLauncher`'s own default clock.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0

    func now() -> TimeInterval {
        lock.withLock { elapsed }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { elapsed += seconds }
    }
}

/// A distinct failure per reconnect attempt, so a test can prove by reference which attempt's own
/// error propagated.
private final class ReconnectAttemptFailure: Error {}

/// Records each reconnect attempt's virtual time and its own `ReconnectAttemptFailure`, from a
/// `@Sendable` closure such as a `reconnect` callback.
private actor ReconnectAttemptLog {
    private(set) var attempts: [(time: TimeInterval, failure: ReconnectAttemptFailure)] = []

    func record(at time: TimeInterval) -> ReconnectAttemptFailure {
        let failure = ReconnectAttemptFailure()
        attempts.append((time, failure))
        return failure
    }
}

/// Records each call's virtual time, from a `@Sendable` closure such as a `reconnect` callback.
private actor TimeLog {
    private(set) var times: [TimeInterval] = []

    @discardableResult
    func record(_ time: TimeInterval) -> Int {
        times.append(time)
        return times.count
    }
}

/// A transport that stands in for one reconnecting internally: `reconnect` hands the very same
/// instance back, as its own `close()` only drops the link rather than ending it. Parks on its first
/// reply, for `releaseFirstReply()`, so a test can queue another ceremony behind the switch's hold
/// before anything proceeds; its third call fails on the connection, to drive a second reconnect onto
/// this same instance, and every call after that succeeds.
private actor SelfReconnectingTransport: LedgerAPDUTransport {
    private(set) var received: [Data] = []
    private(set) var closeCount = 0
    private(set) var isWaitingForFirstReply = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    var instructions: [UInt8] { received.map { $0[1] } }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        let index = received.count
        received.append(apdu)
        if index == 0, !released {
            isWaitingForFirstReply = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuation = continuation
            }
            isWaitingForFirstReply = false
        }
        switch index {
        case 0: return dashboardReply
        case 1: return LedgerReplies.status(0x9000)
        case 2: throw ZcashError.ledgerTimeout
        default: return zcashReply
        }
    }

    func close() async {
        closeCount += 1
    }

    /// Lets the first reply, parked in `exchange(_:timeout:)`, proceed.
    func releaseFirstReply() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

// MARK: - Tests

final class LedgerZcashAppTests: XCTestCase {
    private let queryTimeout: TimeInterval = 5
    private let pollTimeout: TimeInterval = 3
    private let pollInterval: TimeInterval = 0.001
    private let transitionTimeout: TimeInterval = 0.2
    private let switchReconnectTimeout: TimeInterval = 1
    private let switchReconnectWindow: TimeInterval = 0.2
    private let switchReconnectFirstBackoff: TimeInterval = 0.001
    private let switchReconnectMaxBackoff: TimeInterval = 0.004
    private let switchOverallTimeout: TimeInterval = 60

    private lazy var launcher = LedgerAppLauncher(
        queryTimeout: queryTimeout,
        pollTimeout: pollTimeout,
        pollInterval: pollInterval,
        transitionTimeout: transitionTimeout,
        switchReconnectTimeout: switchReconnectTimeout,
        switchReconnectWindow: switchReconnectWindow,
        switchReconnectFirstBackoff: switchReconnectFirstBackoff,
        switchReconnectMaxBackoff: switchReconnectMaxBackoff,
        switchOverallTimeout: switchOverallTimeout
    )

    // MARK: currentApp

    func testTheAppQueryIsParsed() async throws {
        let transport = scripted([dashboardReply])

        let running = try await launcher.currentApp(transport: transport)

        XCTAssertEqual(running.name, "BOLOS")
        XCTAssertEqual(running.version, "2.2.3")
        XCTAssertTrue(running.isDashboard)
        XCTAssertFalse(running.isZcash)
        let received = await transport.received
        XCTAssertEqual(received, [getAppAPDU])
        let timeouts = await transport.timeouts
        XCTAssertEqual(timeouts, [queryTimeout])
    }

    func testEveryDashboardNameIsRecognized() async throws {
        for name in ["BOLOS", "OLOS", "OLOS\u{0}"] {
            let running = try await launcher.currentApp(transport: scripted([app(name)]))
            XCTAssertTrue(running.isDashboard, name)
        }
    }

    func testAMalformedAppQueryReplyIsRefused() async throws {
        let malformed: [Data] = [
            LedgerReplies.status(0x9000),
            Data([0x90]),
            Data([0x02, 0x01, 0x5A, 0x00]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x09, 0x5A]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x01, 0x5A]) + LedgerReplies.status(0x9000),
            Data([0x01, 0x01, 0x5A, 0x04, 0x31]) + LedgerReplies.status(0x9000)
        ]

        for (index, reply) in malformed.enumerated() {
            do {
                _ = try await launcher.currentApp(transport: scripted([reply]))
                XCTFail("reply \(index) must be refused as malformed")
            } catch let error as ZcashError {
                guard case .ledgerMalformedReply = error else {
                    return XCTFail("Unexpected error \(error.code) for reply \(index)")
                }
            }
        }
    }

    func testALockedDeviceRefusesTheAppQueryTransiently() async throws {
        do {
            _ = try await launcher.currentApp(transport: scripted([LedgerReplies.status(0x5515)]))
            XCTFail("A locked device must refuse the query")
        } catch let error as ZcashError {
            guard case let .ledgerDeviceRefused(statusWord, isTransient) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x5515)
            XCTAssertTrue(isTransient)
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }
    }

    // MARK: ensureZcashAppOpen

    func testAnOpenZcashAppIsLeftAlone() async throws {
        let transport = scripted([zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let received = await transport.received
        XCTAssertEqual(received.count, 1, "no open command is sent")
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    func testTheDashboardOpensTheZcashAppAndPollsUntilItRuns() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x9000), dashboardReply, dashboardReply, zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let received = await transport.received
        XCTAssertEqual(received.count, 5)
        XCTAssertEqual(received[0], getAppAPDU)
        XCTAssertEqual(received[1], openZcashAPDU)
        let timeouts = await transport.timeouts
        XCTAssertNil(timeouts[1], "opening waits on the user")
        for command in received[2...] {
            XCTAssertEqual(command, getAppAPDU)
        }
        XCTAssertEqual(timeouts[0], queryTimeout, "the first query keeps queryTimeout")
        for timeout in timeouts[2...] {
            XCTAssertEqual(timeout, pollTimeout, "a poll inside awaitApp uses pollTimeout")
        }
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    func testAnotherAppIsClosedBeforeTheZcashAppIsOpened() async throws {
        let transport = scripted([
            app("Bitcoin"), LedgerReplies.status(0x9000), app("Bitcoin"), dashboardReply, LedgerReplies.status(0x9000), zcashReply
        ])

        let result = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())

        XCTAssertTrue(isSame(result, transport))
        let expected = [getAppAPDU, closeAppAPDU, getAppAPDU, getAppAPDU, openZcashAPDU, getAppAPDU]
        let received = await transport.received
        XCTAssertEqual(received, expected)
    }

    func testALinkDroppedWhileOpeningIsReconnectedAndPolled() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let afterSwitch = scripted([dashboardReply, zcashReply])
        let reconnects = CallCounter()

        let result = try await launcher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 { throw ZcashError.ledgerBluetoothConnectionFailed(nil) }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 2)
        let originalReceived = await original.received
        XCTAssertEqual(originalReceived[1], openZcashAPDU)
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1, "the dropped transport is closed once")
        let afterSwitchCloseCount = await afterSwitch.closeCount
        XCTAssertEqual(afterSwitchCloseCount, 0)
        let afterSwitchReceived = await afterSwitch.received
        XCTAssertEqual(afterSwitchReceived.count, 2)
    }

    func testALinkDroppedWhilePollingIsReconnected() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 2 { throw ZcashError.ledgerTimeout }
            return history.isEmpty ? dashboardReply : LedgerReplies.status(0x9000)
        }
        let afterSwitch = scripted([zcashReply])

        let result = try await launcher.ensureZcashAppOpen(transport: original) { afterSwitch }

        XCTAssertTrue(isSame(result, afterSwitch))
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
    }

    /// John's scenario: the deadline must not be checked in the same iteration in which a poll lost
    /// the link. `pollTimeout` is pinned to the transition timeout (10 s) so this isolates the loop
    /// fix from the shorter poll timeout `LedgerZcashApp` actually uses.
    func testAPollThatStallsThroughTheWholeTransitionIsFollowedByAReconnect() async throws {
        let clock = VirtualClock()
        let original = ScriptedLedgerTransport(
            stallBeforeFailing: { try await clock.sleep($0 ?? 0) },
            script: { _, history in
                if history.count == 2 { throw ZcashError.ledgerTimeout }
                return history.isEmpty ? dashboardReply : LedgerReplies.status(0x9000)
            }
        )
        let afterSwitch = scripted([zcashReply])
        let stallLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 10,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            switchOverallTimeout: 60,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )
        let reconnects = CallCounter()

        let result = try await stallLauncher.ensureZcashAppOpen(transport: original) {
            await reconnects.increment()
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1)
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
    }

    func testDecliningToOpenTheAppIsRestartable() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x5501)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("Declining to open the app must fail")
        } catch let error as ZcashError {
            guard case .ledgerAppOpenRejected = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }

        let received = await transport.received
        XCTAssertEqual(received.count, 2)
    }

    func testAMissingZcashAppIsReported() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x6807)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A missing Zcash app must fail")
        } catch let error as ZcashError {
            guard case .ledgerAppNotInstalled = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(error.ledgerIsRestartable, false)
        }
    }

    func testADeviceLockedWhileOpeningIsATransientRefusal() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x5515)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A locked device must fail")
        } catch let error as ZcashError {
            guard case let .ledgerDeviceRefused(statusWord, isTransient) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x5515)
            XCTAssertTrue(isTransient)
        }
    }

    func testAnUnknownRefusalToOpenAsksForTheZcashApp() async throws {
        let transport = scripted([dashboardReply, LedgerReplies.status(0x6D00)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("An unknown refusal must fail")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x6D00)
        }
    }

    func testADeviceThatNeverReachesTheZcashAppTimesOut() async throws {
        let openAck = LedgerReplies.status(0x9000)
        let transport = ScriptedLedgerTransport { _, history in
            history.count == 1 ? openAck : dashboardReply
        }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A device that never switches apps must time out")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0)
        }

        let received = await transport.received
        XCTAssertGreaterThan(received.count, 3, "the device was polled")
    }

    func testAReconnectedTransportIsClosedWhenTheSwitchTimesOut() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let replacement = ScriptedLedgerTransport { _, _ in dashboardReply }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: original) { replacement }
            XCTFail("A switch that never reaches the Zcash app must time out")
        } catch let error as ZcashError {
            guard case .ledgerWrongApp = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
        let replacementCloseCount = await replacement.closeCount
        XCTAssertEqual(replacementCloseCount, 1)
    }

    func testADroppedReplacementIsClosedOnceWhenTheSwitchTimesOut() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let dropped = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let replacement = ScriptedLedgerTransport { _, _ in dashboardReply }
        let transports = [dropped, replacement]
        let reconnects = CallCounter()

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: original) {
                let count = await reconnects.increment()
                return transports[count - 1]
            }
            XCTFail("A switch that never reaches the Zcash app must time out")
        } catch let error as ZcashError {
            guard case .ledgerWrongApp = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
        let droppedCloseCount = await dropped.closeCount
        XCTAssertEqual(droppedCloseCount, 1, "the first replacement, dropped in turn, is not closed again")
        let replacementCloseCount = await replacement.closeCount
        XCTAssertEqual(replacementCloseCount, 1)
    }

    func testAFatalReconnectFailurePropagates() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: original) {
                throw ZcashError.ledgerBluetoothPoweredOff
            }
            XCTFail("A fatal reconnect failure must propagate")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothPoweredOff = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }
    }

    // MARK: Bounded reconnects while waiting for an app

    func testAFailedReconnectThatOutlastsTheDeadlineStillReachesTheZcashApp() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let afterSwitch = scripted([zcashReply])
        let reconnects = CallCounter()

        let result = try await launcher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 {
                // Slower than the 0.2 s transition timeout, but still under the 1 s reconnect budget:
                // this reconnect fails on its own, not by being cut off.
                try await Task.sleep(nanoseconds: 300_000_000)
                throw ZcashError.ledgerBluetoothConnectionFailed(nil)
            }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 2)
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
        let afterSwitchCloseCount = await afterSwitch.closeCount
        XCTAssertEqual(afterSwitchCloseCount, 0)
    }

    func testAReconnectThatHangsIsCutOffAndTriedAgain() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let afterSwitch = scripted([zcashReply])
        let hangingLauncher = LedgerAppLauncher(
            queryTimeout: queryTimeout,
            pollTimeout: pollTimeout,
            pollInterval: pollInterval,
            transitionTimeout: transitionTimeout,
            switchReconnectTimeout: 0.05,
            switchReconnectWindow: switchReconnectWindow,
            switchReconnectFirstBackoff: switchReconnectFirstBackoff,
            switchReconnectMaxBackoff: switchReconnectMaxBackoff,
            switchOverallTimeout: 60
        )
        let reconnects = CallCounter()

        let result = try await hangingLauncher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 {
                // Cancellation-aware, like the live Bluetooth connect: cut off by the race rather than
                // ever producing a transport.
                try await Task.sleep(nanoseconds: 999_000_000_000)
            }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 2)
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
        let afterSwitchCloseCount = await afterSwitch.closeCount
        XCTAssertEqual(afterSwitchCloseCount, 0)
    }

    func testAReconnectThatIgnoresCancellationIsClosedWhenItLaterCompletes() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let late = scripted([dashboardReply])
        let afterSwitch = scripted([zcashReply])
        let hangingLauncher = LedgerAppLauncher(
            queryTimeout: queryTimeout,
            pollTimeout: pollTimeout,
            pollInterval: pollInterval,
            transitionTimeout: transitionTimeout,
            switchReconnectTimeout: 0.05,
            switchReconnectWindow: switchReconnectWindow,
            switchReconnectFirstBackoff: switchReconnectFirstBackoff,
            switchReconnectMaxBackoff: switchReconnectMaxBackoff,
            switchOverallTimeout: 60
        )
        let reconnects = CallCounter()

        let result = try await hangingLauncher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 {
                // Unlike the live Bluetooth connect (see the report), ignores its own cancellation and
                // returns a transport anyway after losing the race: proves the loser is drained and
                // closed rather than leaked. 2 s against the 50 ms cap is a 40x margin, so scheduling
                // noise on a loaded runner cannot flip which one wins.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return late
            }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let lateCloseCount = await late.closeCount
        XCTAssertEqual(lateCloseCount, 1, "a transport produced after losing the race is closed, not leaked")
        let lateReceived = await late.received
        XCTAssertEqual(lateReceived.count, 0, "the loser is closed before anything is sent on it")
    }

    /// The caller's own cancellation, not the race's timeout, is what the reconnect ignores here: the
    /// race's first result is `CancellationError` from the timeout child (cancellation reaches it
    /// immediately), while the reconnect itself keeps running on a detached task — unaffected by the
    /// caller's cancellation, since a detached task is not its child — and later produces a transport
    /// anyway. That transport must be drained and closed like any other loser, not left for the task
    /// group's implicit cleanup to silently await and drop.
    func testACancelledCallerClosesALateTransportFromAReconnectThatIgnoresCancellation() async throws {
        actor Entered {
            private(set) var didEnter = false
            func mark() { didEnter = true }
        }
        let entered = Entered()
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let late = scripted([dashboardReply])

        let task = Task {
            try await launcher.ensureZcashAppOpen(transport: original) {
                await entered.mark()
                // Unlike the live Bluetooth connect, ignores the caller's own cancellation: a detached
                // task does not inherit it, so this keeps running past the caller's cancel and proves
                // the late transport it eventually produces is drained and closed rather than leaked.
                await Task.detached {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }.value
                return late
            }
        }
        // Spins until the reconnect has actually started, so the cancel below always lands while the
        // race is in flight — deterministic, unlike racing a fixed delay against it.
        while await !entered.didEnter {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("The caller's own cancellation must propagate")
        } catch is CancellationError {
            // Expected: the cancellation reaches the caller unchanged.
        }

        let lateCloseCount = await late.closeCount
        XCTAssertEqual(lateCloseCount, 1, "a transport produced after the caller cancels is closed, not leaked")
        let lateReceived = await late.received
        XCTAssertEqual(lateReceived.count, 0, "the loser is closed before anything is sent on it")
    }

    // MARK: - A late reconnect result another ceremony holds

    /// The transport `reconnect` hands back after losing the race to the timeout can already be held
    /// by another ceremony. Closing it then would disconnect that ceremony, so it is left open
    /// instead, and the ceremony holding it finishes undisturbed.
    func testALateReconnectResultFromATimedOutRaceIsLeftOpenWhenAnotherCeremonyHoldsIt() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let late = scripted([dashboardReply])
        let afterSwitch = scripted([zcashReply])
        let hangingLauncher = LedgerAppLauncher(
            queryTimeout: queryTimeout,
            pollTimeout: pollTimeout,
            pollInterval: pollInterval,
            transitionTimeout: transitionTimeout,
            switchReconnectTimeout: 0.05,
            switchReconnectWindow: switchReconnectWindow,
            switchReconnectFirstBackoff: switchReconnectFirstBackoff,
            switchReconnectMaxBackoff: switchReconnectMaxBackoff,
            switchOverallTimeout: 60
        )
        let reconnects = CallCounter()
        let entered = Latch()
        let release = Latch()
        let holder = holdCeremony(on: late, entered: entered, release: release)
        await entered.wait()

        let result = try await hangingLauncher.ensureZcashAppOpen(transport: original) {
            let count = await reconnects.increment()
            if count == 1 {
                // Loses the race to the 50 ms timeout, then ignores its own cancellation and
                // returns `late` anyway, same as the sibling test without a holder.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return late
            }
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let lateCloseCount = await late.closeCount
        XCTAssertEqual(lateCloseCount, 0, "a late result another ceremony holds is not closed")

        await release.open()
        try await holder.value
        await expectEventually { await LedgerCeremonyGates.shared.transportsInUse == 0 }
    }

    /// The same, but the caller's own cancellation ends the race instead of the timeout: `reconnect`
    /// ignores that cancellation and hands back `late` anyway, which is left open just the same when
    /// another ceremony holds it.
    func testALateReconnectResultFromACancelledCallerIsLeftOpenWhenAnotherCeremonyHoldsIt() async throws {
        actor Entered {
            private(set) var didEnter = false
            func mark() { didEnter = true }
        }
        let entered = Entered()
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let late = scripted([dashboardReply])
        let holdEntered = Latch()
        let holdRelease = Latch()
        let holder = holdCeremony(on: late, entered: holdEntered, release: holdRelease)
        await holdEntered.wait()

        let task = Task {
            try await launcher.ensureZcashAppOpen(transport: original) {
                await entered.mark()
                // Unlike the live Bluetooth connect, ignores the caller's own cancellation: a
                // detached task does not inherit it, so this keeps running past the caller's cancel
                // and still hands back `late`, held by another ceremony the whole time.
                await Task.detached {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }.value
                return late
            }
        }
        // Spins until the reconnect has actually started, so the cancel below always lands while the
        // race is in flight.
        while await !entered.didEnter {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("The caller's own cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        }

        let lateCloseCount = await late.closeCount
        XCTAssertEqual(lateCloseCount, 0, "a late result another ceremony holds is not closed")

        await holdRelease.open()
        try await holder.value
        await expectEventually { await LedgerCeremonyGates.shared.transportsInUse == 0 }
    }

    /// `reconnectRaceNanoseconds(_:)`'s mapping from `timeout` to the race's `Task.sleep` bound: not
    /// finite or too large for `UInt64` nanoseconds maps to `nil` (no cap), a negative or zero
    /// `timeout` maps to `0`, and an ordinary value converts to nanoseconds.
    func testReconnectRaceNanosecondsMapsTimeoutToASleepBound() {
        let cases: [(TimeInterval, UInt64?)] = [
            (.infinity, nil),
            (-.infinity, nil),
            (.nan, nil),
            (1e300, nil),
            (-1, 0),
            (0, 0),
            (0.5, 500_000_000),
            (10, 10_000_000_000)
        ]
        for (timeout, expected) in cases {
            XCTAssertEqual(reconnectRaceNanoseconds(timeout), expected, "timeout \(timeout)")
        }
    }

    func testAnInstantlyFailingReconnectIsRetriedWithBackoffUntilTheWindowRunsOut() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let clock = VirtualClock()
        let attempts = ReconnectAttemptLog()
        let backoffLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 10,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            switchOverallTimeout: 60,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )

        do {
            _ = try await backoffLauncher.ensureZcashAppOpen(transport: original) {
                let failure = await attempts.record(at: clock.now())
                throw ZcashError.ledgerBluetoothConnectionFailed(failure)
            }
            XCTFail("Reconnects that keep failing instantly must propagate once the window runs out")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothConnectionFailed(let underlying) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            let recorded = await attempts.attempts
            XCTAssertTrue(
                (underlying as? ReconnectAttemptFailure) === recorded.last?.failure,
                "the last attempt's own error instance propagates"
            )
        }

        let recorded = await attempts.attempts
        XCTAssertEqual(recorded.map(\.time), [0, 0.5, 1.5, 3.5, 5.5, 7.5, 9.5, 10.0])
        XCTAssertEqual(clock.now(), 10.0)
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1)
    }

    func testARecoveredLinkStartsTheReconnectBackoffAndWindowOver() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 2 { throw ZcashError.ledgerBluetoothDisconnected }
            return history.isEmpty ? dashboardReply : LedgerReplies.status(0x9000)
        }
        let recovered = ScriptedLedgerTransport { _, history in
            if history.count == 12 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let afterSwitch = scripted([zcashReply])
        let clock = VirtualClock()
        let attempts = TimeLog()
        let productionTimedLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 3,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            switchOverallTimeout: 60,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )

        let result = try await productionTimedLauncher.ensureZcashAppOpen(transport: original) {
            let count = await attempts.record(clock.now())
            switch count {
            case 1...6, 8: throw ZcashError.ledgerBluetoothConnectionFailed(nil)
            case 7: return recovered
            default: return afterSwitch
            }
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let recordedTimes = await attempts.times
        let expectedTimes: [TimeInterval] = [0, 0.5, 1.5, 3.5, 5.5, 7.5, 9.5, 11.9, 12.4]
        XCTAssertEqual(recordedTimes.count, expectedTimes.count)
        for (index, expected) in expectedTimes.enumerated() where index < recordedTimes.count {
            XCTAssertEqual(
                recordedTimes[index],
                expected,
                accuracy: 0.000_001,
                "the failure after the recovery waits the first backoff, in a window of its own (attempt \(index))"
            )
        }
    }

    func testASlowSuccessfulReconnectLeavesTheWholePollingTime() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 2 { throw ZcashError.ledgerBluetoothDisconnected }
            return history.isEmpty ? dashboardReply : LedgerReplies.status(0x9000)
        }
        let afterSwitch = scripted(Array(repeating: dashboardReply, count: 25) + [zcashReply])
        let clock = VirtualClock()
        let productionTimedLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 3,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            switchOverallTimeout: 60,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )

        let result = try await productionTimedLauncher.ensureZcashAppOpen(transport: original) {
            try await clock.sleep(9)
            return afterSwitch
        }

        XCTAssertTrue(isSame(result, afterSwitch))
        let sent = await afterSwitch.received
        XCTAssertEqual(sent.count, 26, "the 9-second reconnect left the whole 10 seconds to poll the 25 dashboards before the Zcash app")
    }

    func testTheCallersOwnTimeoutDuringAReconnectPropagatesAsCancellation() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.count == 1 { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let reconnects = CallCounter()

        let task = Task {
            try await launcher.ensureZcashAppOpen(transport: original) {
                await reconnects.increment()
                try await Task.sleep(nanoseconds: 999_000_000_000)
                fatalError("unreachable: cancelled well before the sleep completes")
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("The caller's own cancellation must propagate")
        } catch is CancellationError {
            // Expected: the cancellation reaches the caller unchanged.
        }

        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1, "the caller's own cancellation is not a failed reconnect to retry")
    }

    // MARK: Overall switch timeout

    /// John's flapping link: a poll that stalls and loses the link, a reconnect that fails, a backoff,
    /// a reconnect that then succeeds, and the cycle repeats. Each success clears `SwitchWait`'s own
    /// run of failures and each failure restarts its transition deadline, so neither ever throws on its
    /// own — only `switchOverallTimeout`, measured once from the wait's own start, can end this. The
    /// cutoff lands right after a poll (the reconnect before it succeeded), so the thrown error is the
    /// generic `ledgerWrongApp(0)`, not a reconnect failure; `testAFlappingLinkThatEndsOnAFailedReconnectThrowsIt`
    /// below covers the other half of that choice.
    ///
    /// The scripted reconnect refuses its own 501st attempt with `WaitNeverEnded`: against code that
    /// does not yet enforce the cap this flapping link never ends, and without that limit the call
    /// would spin forever on the virtual clock rather than fail. 34 reconnects are expected once the
    /// cap is enforced, so 500 is a comfortable margin that proves the new cap, not this backstop, is
    /// what ends the wait. `withTestTimeout` adds a real 5 s backstop of its own, so a logic error that
    /// defeats both of the above still fails this test instead of hanging the whole suite.
    func testAFlappingLinkIsCutOffByTheOverallSwitchTimeout() async throws {
        let clock = VirtualClock()
        let original = ScriptedLedgerTransport(
            stallBeforeFailing: { try await clock.sleep($0 ?? 0) },
            script: { _, history in
                switch history.count {
                case 0: return dashboardReply
                case 1: return LedgerReplies.status(0x9000)
                default: throw ZcashError.ledgerTimeout
                }
            }
        )
        let flapping = ScriptedLedgerTransport(
            stallBeforeFailing: { try await clock.sleep($0 ?? 0) },
            script: { _, _ in throw ZcashError.ledgerTimeout }
        )
        let capLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 3,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            switchOverallTimeout: 60,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )
        let attemptCount = CallCounter()

        do {
            _ = try await withTestTimeout(5) {
                try await capLauncher.ensureZcashAppOpen(transport: original) {
                    let count = await attemptCount.increment()
                    guard count <= 500 else { throw WaitNeverEnded() }
                    if count % 2 == 1 {
                        throw ZcashError.ledgerBluetoothConnectionFailed(nil)
                    }
                    return flapping
                }
            }
            XCTFail("A flapping link must not let the switch succeed")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0, "the cutoff lands right after a poll, with no reconnect failure of its own")
        } catch is WaitNeverEnded {
            XCTFail("The overall switch timeout must cut a flapping link off; the wait never ended")
        } catch is TestTimedOut {
            XCTFail("The overall switch timeout must cut a flapping link off well under the test's own 5 s backstop")
        }

        let finalCount = await attemptCount.count
        XCTAssertEqual(finalCount, 34, "the overall cap, not the test's own 500-attempt safety limit, must end the wait")
        XCTAssertGreaterThanOrEqual(clock.now(), 60, "the wait runs at least the whole overall cap")
        XCTAssertLessThanOrEqual(clock.now(), 63, "the wait ends within the overall cap, plus at most one more poll")
    }

    /// The same flapping link, with the overall cap set to land right after a failed reconnect instead
    /// of after a poll: proves the other half of the choice — the thrown error is that reconnect's own
    /// failure, by reference, not a fresh `ledgerWrongApp(0)`.
    func testAFlappingLinkThatEndsOnAFailedReconnectThrowsIt() async throws {
        let clock = VirtualClock()
        let original = ScriptedLedgerTransport(
            stallBeforeFailing: { try await clock.sleep($0 ?? 0) },
            script: { _, history in
                switch history.count {
                case 0: return dashboardReply
                case 1: return LedgerReplies.status(0x9000)
                default: throw ZcashError.ledgerTimeout
                }
            }
        )
        let flapping = ScriptedLedgerTransport(
            stallBeforeFailing: { try await clock.sleep($0 ?? 0) },
            script: { _, _ in throw ZcashError.ledgerTimeout }
        )
        let capLauncher = LedgerAppLauncher(
            queryTimeout: 10,
            pollTimeout: 3,
            pollInterval: 0.2,
            transitionTimeout: 10,
            switchReconnectTimeout: 10,
            switchReconnectWindow: 10,
            switchReconnectFirstBackoff: 0.5,
            switchReconnectMaxBackoff: 2,
            // Lands the cap 0.3 s after the first reconnect's own failure (at t=3.5) but before the
            // poll that would follow the next cycle, so the cutoff is unambiguously mid-backoff.
            switchOverallTimeout: 3.2,
            now: { clock.now() },
            sleep: { try await clock.sleep($0) }
        )
        let attempts = ReconnectAttemptLog()
        let attemptCount = CallCounter()

        do {
            _ = try await withTestTimeout(5) {
                try await capLauncher.ensureZcashAppOpen(transport: original) {
                    let count = await attemptCount.increment()
                    guard count <= 500 else { throw WaitNeverEnded() }
                    if count % 2 == 1 {
                        let failure = await attempts.record(at: clock.now())
                        throw ZcashError.ledgerBluetoothConnectionFailed(failure)
                    }
                    return flapping
                }
            }
            XCTFail("A flapping link must not let the switch succeed")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothConnectionFailed(let underlying) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            let recorded = await attempts.attempts
            XCTAssertEqual(recorded.count, 1)
            XCTAssertTrue(
                (underlying as? ReconnectAttemptFailure) === recorded.last?.failure,
                "the overall cap throws the most recent reconnect failure, by reference"
            )
        } catch is WaitNeverEnded {
            XCTFail("The overall switch timeout must cut a flapping link off; the wait never ended")
        } catch is TestTimedOut {
            XCTFail("The overall switch timeout must cut a flapping link off well under the test's own 5 s backstop")
        }

        let finalCount = await attemptCount.count
        XCTAssertEqual(finalCount, 1, "the cap fires before the reconnect that would have followed the one failure")
        XCTAssertGreaterThanOrEqual(clock.now(), 3.2, "the wait runs at least the whole overall cap")
        XCTAssertLessThanOrEqual(clock.now(), 3.7, "the wait ends within the overall cap, plus at most one more backoff step")
    }

    // MARK: First-query retry

    func testAStalledFirstQueryIsAskedOnceMoreOnAFreshConnection() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let fresh = scripted([zcashReply])
        let reconnects = CallCounter()

        let result = try await launcher.ensureZcashAppOpen(transport: stalled) {
            await reconnects.increment()
            return fresh
        }

        XCTAssertTrue(isSame(result, fresh))
        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1)
        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1, "the stalled transport is closed")
        let freshReceived = await fresh.received
        XCTAssertEqual(freshReceived, [getAppAPDU])
    }

    func testAFirstQueryThatStallsTwiceFailsWithoutSendingAnythingElse() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let stalledAgain = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let reconnects = CallCounter()

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: stalled) {
                await reconnects.increment()
                return stalledAgain
            }
            XCTFail("A first query that stalls twice must fail")
        } catch let error as ZcashError {
            guard case .ledgerTimeout = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let reconnectCount = await reconnects.count
        XCTAssertEqual(reconnectCount, 1)
        let stalledAgainReceived = await stalledAgain.received
        XCTAssertEqual(stalledAgainReceived.count, 1)
        let stalledAgainCloseCount = await stalledAgain.closeCount
        XCTAssertEqual(stalledAgainCloseCount, 1, "the fresh transport is closed when the call fails")
    }

    func testAReconnectThatHangsAfterAFailedFirstQueryIsCutOff() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        // Answers as the Zcash app if it is ever actually queried, so the pre-fix (uncapped) path
        // succeeds cleanly instead of running out of scripted replies.
        let late = scripted([zcashReply])
        let hangingLauncher = LedgerAppLauncher(
            queryTimeout: queryTimeout,
            pollTimeout: pollTimeout,
            pollInterval: pollInterval,
            transitionTimeout: transitionTimeout,
            switchReconnectTimeout: 0.05,
            switchReconnectWindow: switchReconnectWindow,
            switchReconnectFirstBackoff: switchReconnectFirstBackoff,
            switchReconnectMaxBackoff: switchReconnectMaxBackoff,
            switchOverallTimeout: 60
        )

        do {
            // 2 s against the 50 ms cap is a 40x margin, so scheduling noise on a loaded runner cannot
            // flip which one wins.
            _ = try await hangingLauncher.ensureZcashAppOpen(transport: stalled) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return late
            }
            XCTFail("A reconnect that hangs after a failed first query must be cut off at the cap")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothConnectionFailed(nil) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1)
        let lateCloseCount = await late.closeCount
        XCTAssertEqual(lateCloseCount, 1, "a transport produced after losing the race is closed, not leaked")
        let lateReceived = await late.received
        XCTAssertEqual(lateReceived.count, 0, "the loser is closed before anything is sent on it")
    }

    func testALockedDeviceIsNotRetriedOnAFreshConnection() async throws {
        let locked = scripted([LedgerReplies.status(0x5515)])

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: locked, reconnect: noReconnect())
            XCTFail("A locked device must fail without a retry")
        } catch let error as ZcashError {
            guard case .ledgerDeviceRefused = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }
    }

    // MARK: The app switch's own exchanges

    func testANonZcashErrorFromTheAppSwitchsOwnExchangeIsNormalized() async throws {
        struct BoomError: Error {}
        let transport = ScriptedLedgerTransport { _, _ in throw BoomError() }

        do {
            _ = try await launcher.ensureZcashAppOpen(transport: transport, reconnect: noReconnect())
            XCTFail("A non-ZcashError from the app switch's own exchange must be normalized")
        } catch let error as ZcashError {
            guard case .ledgerTransportFailed = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        } catch {
            XCTFail("Expected a ZcashError, got \(error)")
        }
    }

    func testACancelledCallerSendsNothingOnTheAppQuery() async throws {
        // A transport that would succeed if the query ever actually reached it, so a failure to
        // check cancellation first would go unnoticed as a passing call rather than a hang.
        let transport = ScriptedLedgerTransport { _, _ in dashboardReply }

        let task = Task { () -> LedgerRunningApp in
            // Spins until this task's own cancellation is visible, so `currentApp` below is entered
            // only once cancellation is guaranteed to be observed by `Task.checkCancellation()` —
            // deterministic, unlike racing a fixed delay against `task.cancel()`.
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await launcher.currentApp(transport: transport)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled caller must not receive a result")
        } catch is CancellationError {
            // Expected.
        }

        let received = await transport.received
        XCTAssertTrue(received.isEmpty, "a cancelled caller sends nothing")
    }

    // MARK: - A replacement another ceremony holds

    /// Holds `transport`'s ceremony from another task until `release` opens, and reports through
    /// `entered` once it does hold it.
    private func holdCeremony(on transport: any LedgerAPDUTransport, entered: Latch, release: Latch) -> Task<Void, Error> {
        Task {
            try await LedgerCeremony.run(on: transport) {
                await entered.open()
                await release.wait()
            }
        }
    }

    /// The transport `reconnect` returns can already be in use by another ceremony. The switch then
    /// waits for it before its first command on it, instead of putting that command in the middle of
    /// the other ceremony, and its hold on the replacement ends when the switch hands it back.
    func testTheSwitchWaitsForACeremonyAlreadyHoldingItsReplacement() async throws {
        let original = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerBluetoothDisconnected }
        let afterSwitch = scripted([zcashReply])
        let entered = Latch()
        let release = Latch()
        let holder = holdCeremony(on: afterSwitch, entered: entered, release: release)
        await entered.wait()

        let switching = Task { try await launcher.ensureZcashAppOpen(transport: original) { afterSwitch } }
        // Waits for the switch to have actually queued on the replacement's ceremony gate.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: afterSwitch) == 1 }
        let receivedWhileHeld = await afterSwitch.received
        XCTAssertTrue(receivedWhileHeld.isEmpty, "the switch sends nothing on a replacement another ceremony holds")

        await release.open()
        try await holder.value
        let result = try await switching.value

        XCTAssertTrue(isSame(result, afterSwitch))
        let received = await afterSwitch.received
        XCTAssertEqual(received.count, 1, "the query ran once the holder was done")

        // The switch's hold ended with the switch: a ceremony on the returned transport is admitted.
        let afterwards = Latch()
        let next = holdCeremony(on: afterSwitch, entered: afterwards, release: afterwards)
        await expectEventually { await afterwards.isOpen }
        try await next.value
    }

    /// The same, but the switch is cancelled while it waits for the replacement: it fails with the
    /// cancellation, and closes nothing -- the replacement it never came to hold least of all.
    func testTheSwitchCancelledWhileQueuedForAHeldReplacementClosesNothing() async throws {
        let original = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerBluetoothDisconnected }
        let afterSwitch = scripted([zcashReply])
        let entered = Latch()
        let release = Latch()
        let holder = holdCeremony(on: afterSwitch, entered: entered, release: release)
        await entered.wait()

        let switching = Task { try await launcher.ensureZcashAppOpen(transport: original) { afterSwitch } }
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: afterSwitch) == 1 }
        switching.cancel()

        do {
            _ = try await switching.value
            XCTFail("a switch cancelled while queued must fail")
        } catch is CancellationError {
            // Expected.
        }

        await release.open()
        try await holder.value

        let afterSwitchCloseCount = await afterSwitch.closeCount
        XCTAssertEqual(afterSwitchCloseCount, 0, "a replacement the cancelled switch never came to hold is not closed")
        let received = await afterSwitch.received
        XCTAssertTrue(received.isEmpty, "the cancelled switch never sent anything on the replacement")
        let originalCloseCount = await original.closeCount
        XCTAssertEqual(originalCloseCount, 1, "the dropped original was closed when its link failed, and only then")
    }

    // MARK: - A reconnect that hands back the replacement the switch already holds

    /// `reconnect` can hand back the very transport the switch already holds as its replacement: one
    /// that reconnects internally, whose `close()` only drops the link. The switch's hold on it must
    /// not be released and retaken in that case: doing so would hand the gate to whatever ceremony is
    /// queued behind it, letting that ceremony's command land on the transport between the switch's
    /// own commands, on a connection the ceremony finds open again.
    func testASecondReconnectToTheSameReplacementKeepsTheSwitchsHold() async throws {
        let original = ScriptedLedgerTransport { _, history in
            if history.isEmpty { throw ZcashError.ledgerBluetoothDisconnected }
            return dashboardReply
        }
        let flapping = SelfReconnectingTransport()

        let switching = Task { try await launcher.ensureZcashAppOpen(transport: original) { flapping } }
        // The switch has adopted `flapping` and sent its first query, which is parked here: it still
        // holds `flapping`'s ceremony, giving this test all the time it needs before anything races.
        await expectEventually { await flapping.isWaitingForFirstReply }

        let otherCeremony = Task {
            try await LedgerCeremony.run(on: flapping) {
                _ = try await flapping.exchange(Data([0xFF, 0xEE, 0x00, 0x00, 0x00]), timeout: 1)
            }
        }
        // Waits for the other ceremony to have actually queued behind the switch's hold before
        // letting the parked reply go.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: flapping) == 1 }
        await flapping.releaseFirstReply()

        let result = try await switching.value
        try await otherCeremony.value

        XCTAssertTrue(isSame(result, flapping))
        let instructions = await flapping.instructions
        XCTAssertEqual(
            instructions,
            [0x01, 0xD8, 0x01, 0x01, 0xEE],
            "the other ceremony's command runs only once the switch is completely done with the transport, not between its own"
        )
    }
}
