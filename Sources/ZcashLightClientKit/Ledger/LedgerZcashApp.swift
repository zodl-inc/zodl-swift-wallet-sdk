//
//  LedgerZcashApp.swift
//  ZcashLightClientKit
//

import Foundation

/// Brings a Ledger device to the Zcash app through the device's own dashboard commands, which answer
/// whatever app is running: which app is open, close it, open another one by name.
///
/// A device returns to its dashboard after a first Bluetooth pairing, and every Zcash command then
/// fails. ``ensureZcashAppOpen(transport:reconnect:)`` opens the Zcash app for the user, who confirms
/// it on the device, before ``LedgerDevice`` is used.
///
/// Nothing handled here is logged: not the commands, not the replies, not the app names.
public enum LedgerZcashApp {
    private static let queryTimeout: TimeInterval = 10
    private static let pollTimeout: TimeInterval = 3
    private static let pollInterval: TimeInterval = 0.2
    private static let appTransitionTimeout: TimeInterval = 10
    private static let switchReconnectTimeout: TimeInterval = 10
    private static let switchReconnectWindow: TimeInterval = 10
    private static let switchReconnectFirstBackoff: TimeInterval = 0.5
    private static let switchReconnectMaxBackoff: TimeInterval = 2
    private static let switchOverallTimeout: TimeInterval = 60

    /// Reads which app the device is running. Works on the dashboard and in any app.
    ///
    /// - Throws: ``ZcashError/ledgerDeviceRefused(_:_:)`` if the device refuses the query; a locked
    ///   device's refusal is transient. ``ZcashError/ledgerMalformedReply(_:)`` if the reply is not an
    ///   app name and version. A ``ZcashError`` for a transport failure.
    public static func currentApp(transport: any LedgerAPDUTransport) async throws -> LedgerRunningApp {
        // Holds the transport for the query, like every other ceremony the SDK runs over one; see
        // `LedgerCeremony`.
        try await LedgerCeremony.run(on: transport) {
            try await launcher().currentApp(transport: transport)
        }
    }

    /// Makes sure the device is running the Zcash app, opening it if needed, and returns the
    /// transport to keep using.
    ///
    /// The first query waits up to 10 seconds; if it stalls or the link fails, it is asked once more
    /// on a fresh connection from `reconnect` before anything else is sent. The open command itself is
    /// never sent twice.
    ///
    /// If the Zcash app is already open, nothing is sent beyond the query and the transport it was
    /// answered on is returned. Otherwise any other app is closed, the device is asked to open the
    /// Zcash app — it asks the user to confirm, and the reply waits for that without a timeout — and
    /// the device is polled until it reports the Zcash app, for up to 10 seconds after the reply, each
    /// poll waiting up to 3 seconds for its answer. The time a reconnect that succeeds takes does not
    /// count towards those 10 seconds. The Bluetooth link may drop while the device switches apps; a
    /// dropped link is then replaced with a transport from `reconnect`, and the transport returned may
    /// be one of those. A poll that loses the link or gets no answer is always
    /// followed by such a reconnect before the 10 seconds can end the wait; once they have passed, a
    /// link replaced after them gets one more poll. Each of those reconnects gets 10 seconds of its own,
    /// enforced for a `reconnect` that honors cancellation: past them it is cancelled, and any transport
    /// it still produces is closed, unless another ceremony already holds it, rather than used. One
    /// that ignores cancellation is waited for. None
    /// of it waits on Bluetooth pairing, since the phone has already bonded with the device. A
    /// reconnect that fails is tried again, since the device may still be
    /// rebooting into the app: first after 500 milliseconds, then after twice the previous wait, at
    /// most 2 seconds, and never past 10 seconds from the first of the reconnects that failed in a row.
    /// The first reconnect that fails once those 10 seconds have passed propagates its own failure; one
    /// that succeeds ends the row, and the next failure starts over from 500 milliseconds and a new
    /// 10 seconds. A reconnect that fails also starts the 10 seconds of polling over. The reconnect
    /// after a failed first query also has 10 seconds, and is not retried.
    ///
    /// Each wait for the device to report the new app — for the dashboard once the running app is
    /// closed, and for the Zcash app once it is asked to open — is itself capped at 60 seconds of its
    /// own, timed from that wait's own start regardless of how many times the 10-second deadlines above
    /// get reset along the way by a reconnect that keeps failing, backing off, and then succeeding. In
    /// the non-dashboard path both waits run, with the user's on-device confirmation between them, so
    /// the whole call can take longer than 60 seconds; that confirmation still has no timeout of its
    /// own, as above.
    ///
    /// A transport whose link fails during the call is closed when it fails, before it is replaced.
    /// The caller closes the one returned, and `transport` if the call fails; a transport opened
    /// through `reconnect` is closed here when the call fails.
    ///
    /// - Parameters:
    ///   - transport: A transport connected to the device.
    ///   - reconnect: Opens a new transport to the same device.
    /// - Throws: ``ZcashError/ledgerAppNotInstalled`` if the Zcash app is not installed.
    ///   ``ZcashError/ledgerAppOpenRejected`` if the user declines opening it on the device.
    ///   ``ZcashError/ledgerDeviceRefused(_:_:)`` if the device is locked (transient) or refuses a
    ///   command. ``ZcashError/ledgerWrongApp(_:)`` if the device does not reach the Zcash app in
    ///   time, or cannot open it; the user has to open it on the device.
    ///   ``ZcashError/ledgerBluetoothConnectionFailed(_:)`` if the reconnect after a failed first
    ///   query, or the last reconnect during the switch, runs out of its own 10 seconds; another
    ///   failure from `reconnect` propagates as it is. A ``ZcashError`` for any other failure.
    public static func ensureZcashAppOpen(
        transport: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport {
        // Holds `transport` for the whole switch, so no other ceremony the SDK runs over it can put a
        // command between the query and the open; see `LedgerCeremony`. A transport `reconnect`
        // returns is new and is not under this hold while `reconnect` runs; the switch takes that
        // transport's own ceremony before its first command on it and keeps it until it is replaced
        // in turn or the switch is over, exactly as `LedgerDevice.pairAccount` does.
        try await LedgerCeremony.run(on: transport) {
            try await launcher().ensureZcashAppOpen(transport: transport, reconnect: reconnect)
        }
    }

    private static func launcher() -> LedgerAppLauncher {
        LedgerAppLauncher(
            queryTimeout: queryTimeout,
            pollTimeout: pollTimeout,
            pollInterval: pollInterval,
            transitionTimeout: appTransitionTimeout,
            switchReconnectTimeout: switchReconnectTimeout,
            switchReconnectWindow: switchReconnectWindow,
            switchReconnectFirstBackoff: switchReconnectFirstBackoff,
            switchReconnectMaxBackoff: switchReconnectMaxBackoff,
            switchOverallTimeout: switchOverallTimeout
        )
    }
}

/// `LedgerZcashApp`'s orchestration, with its timings and its clock as parameters.
final class LedgerAppLauncher {
    // Not `private`: `AppSwitch` and `SwitchWait` below, separate sibling types in this same file,
    // read these and call `transitionDeadline()`.
    let queryTimeout: TimeInterval
    let pollTimeout: TimeInterval
    let pollInterval: TimeInterval
    let switchReconnectTimeout: TimeInterval
    let switchReconnectWindow: TimeInterval
    let switchReconnectFirstBackoff: TimeInterval
    let switchReconnectMaxBackoff: TimeInterval
    let switchOverallTimeout: TimeInterval
    let now: @Sendable () -> TimeInterval
    let sleep: @Sendable (TimeInterval) async throws -> Void
    private let transitionTimeout: TimeInterval

    init(
        queryTimeout: TimeInterval,
        pollTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transitionTimeout: TimeInterval,
        switchReconnectTimeout: TimeInterval,
        switchReconnectWindow: TimeInterval,
        switchReconnectFirstBackoff: TimeInterval,
        switchReconnectMaxBackoff: TimeInterval,
        switchOverallTimeout: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.queryTimeout = queryTimeout
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
        self.transitionTimeout = transitionTimeout
        self.switchReconnectTimeout = switchReconnectTimeout
        self.switchReconnectWindow = switchReconnectWindow
        self.switchReconnectFirstBackoff = switchReconnectFirstBackoff
        self.switchReconnectMaxBackoff = switchReconnectMaxBackoff
        self.switchOverallTimeout = switchOverallTimeout
        self.now = now
        self.sleep = sleep
    }

    func currentApp(transport: any LedgerAPDUTransport) async throws -> LedgerRunningApp {
        try await queryApp(transport: transport, timeout: queryTimeout)
    }

    /// Queries which app is running, with its own timeout: `queryTimeout` for `currentApp(transport:)`
    /// and the first query in `AppSwitch.queryOnFreshConnectionOnce()`, `pollTimeout` for a poll inside
    /// `AppSwitch.awaitApp(reached:)`.
    func queryApp(transport: any LedgerAPDUTransport, timeout: TimeInterval) async throws -> LedgerRunningApp {
        let reply = try await exchangeWithoutClosing(getAppAndVersionAPDU(), timeout: timeout, on: transport)
        let bytes = [UInt8](reply)
        let statusWord = try dashboardStatusWord(bytes)
        guard statusWord == swOK else {
            throw dashboardRefusal(statusWord)
        }
        return try parseRunningApp(bytes)
    }

    /// Makes sure the device is running the Zcash app; see `LedgerZcashApp.ensureZcashAppOpen(transport:reconnect:)`.
    func ensureZcashAppOpen(
        transport: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport {
        let appSwitch = AppSwitch(original: transport, reconnect: reconnect, launcher: self)
        do {
            let running = try await appSwitch.queryOnFreshConnectionOnce()
            if !running.isZcash {
                if !running.isDashboard {
                    try await appSwitch.closeRunningApp()
                    try await appSwitch.awaitApp { $0.isDashboard }
                }
                try await appSwitch.openZcashApp()
                try await appSwitch.awaitApp { $0.isZcash }
            }
        } catch {
            await appSwitch.closeReplacement()
            await appSwitch.releaseReplacementHold()
            throw error
        }
        // The caller gets the transport to run its own ceremony on, so the switch's hold on a
        // replacement ends here; the caller's original stays held by the public wrapper until this
        // returns.
        await appSwitch.releaseReplacementHold()
        return appSwitch.current
    }

    /// A fresh deadline for a wait of `transitionTimeout`, starting now.
    func transitionDeadline() -> TimeInterval {
        now() + transitionTimeout
    }
}

/// The transport through an app switch that `LedgerAppLauncher.ensureZcashAppOpen(transport:reconnect:)`
/// drives: `current` is the caller's transport until a dropped link is replaced with one from
/// `reconnect`.
///
/// The caller's transport is held for the switch by `LedgerZcashApp.ensureZcashAppOpen`. Every
/// replacement is held here instead, from before the switch's first command on it until the next
/// replacement takes over or the switch ends (`releaseReplacementHold()`), so no other ceremony over
/// a replacement can put a command between two of the switch's; see `LedgerCeremony.adopt(_:)`.
private final class AppSwitch {
    private let original: any LedgerAPDUTransport
    private let reconnect: @Sendable () async throws -> any LedgerAPDUTransport
    private let launcher: LedgerAppLauncher

    private(set) var current: any LedgerAPDUTransport
    private var usable = true
    private var didReplaceTransport = false
    /// The switch's hold on `current` while it is a replacement; `nil` while `current` is the
    /// caller's own transport.
    private var replacementHold: LedgerCeremonyHold?

    init(
        original: any LedgerAPDUTransport,
        reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport,
        launcher: LedgerAppLauncher
    ) {
        self.original = original
        self.reconnect = reconnect
        self.launcher = launcher
        self.current = original
    }

    /// The running app before anything else is sent. A query that stalls past its deadline or loses
    /// the link is asked once more on a fresh connection from `reconnect`, which has the same
    /// `launcher.switchReconnectTimeout` cap as a reconnect during `awaitApp(reached:)`; a second
    /// failure, and any answer from the device, is final.
    func queryOnFreshConnectionOnce() async throws -> LedgerRunningApp {
        if let running = try await queryAllowingDisconnect(timeout: launcher.queryTimeout) {
            return running
        }

        let replacement = try await raceReconnect()
        try await adopt(replacement)
        return try await launcher.currentApp(transport: current)
    }

    func closeRunningApp() async throws {
        guard let reply = try await exchangeAllowingDisconnect(closeAppAPDU(), timeout: launcher.queryTimeout) else {
            return
        }

        let statusWord = try dashboardStatusWord([UInt8](reply))
        guard statusWord == swOK else {
            throw dashboardRefusal(statusWord)
        }
    }

    func openZcashApp() async throws {
        guard let reply = try await exchangeAllowingDisconnect(openZcashAppAPDU(), timeout: nil) else {
            return
        }

        if let failure = openFailure(try dashboardStatusWord([UInt8](reply))) {
            throw failure
        }
    }

    /// Polls the device, reconnecting when the link is down, until it runs an app `reached` accepts.
    ///
    /// The wait has `launcher`'s transition timeout from this call, not counting the time a
    /// successful reconnect itself takes, checked after each poll the device answers, so it ends at
    /// most one poll past it. A poll that loses the link or stalls past `launcher.pollTimeout` is
    /// always followed by a reconnect instead, however late it ends; once the transition timeout has
    /// passed, a link replaced after it gets one more poll. A reconnect that fails resets that wait
    /// from the failure, since the device may still be rebooting into the app, and is retried after a
    /// backoff that starts at `launcher.switchReconnectFirstBackoff` and doubles up to
    /// `launcher.switchReconnectMaxBackoff`. Once `launcher.switchReconnectWindow` has passed since
    /// the wait's first failed reconnect, the next one to fail throws its own failure instead of the
    /// generic timeout; a reconnect that succeeds ends that run of failures, and the next one starts a
    /// new window, with the first backoff.
    ///
    /// None of that alone is bounded: a link that alternates a stalled or lost poll with a reconnect
    /// that fails, backs off, and then succeeds never trips the transition deadline or the reconnect
    /// window, since each success resets both. `launcher.switchOverallTimeout` is the outer bound for
    /// that — measured once, from this call's own start, and never reset or extended by anything
    /// above. It is checked at the top of every loop iteration, so it ends the wait at most one more
    /// poll or reconnect past it; once it has passed, this throws the most recent reconnect's own
    /// failure if the last reconnect failed, or `ZcashError.ledgerWrongApp(0)` otherwise.
    func awaitApp(reached: (LedgerRunningApp) -> Bool) async throws {
        let wait = SwitchWait(launcher: launcher)
        let overallDeadline = launcher.now() + launcher.switchOverallTimeout
        var lastReconnectFailure: ZcashError?
        while true {
            if launcher.now() >= overallDeadline {
                throw lastReconnectFailure ?? ZcashError.ledgerWrongApp(0)
            }
            if usable {
                let running = try await queryAllowingDisconnect(timeout: launcher.pollTimeout)
                if let running, reached(running) {
                    return
                }
                if running != nil || wait.replacedPastDeadline {
                    try await wait.beforeNextPoll()
                }
            } else {
                let reconnectStart = launcher.now()
                let reconnectFailure = try await replace()
                lastReconnectFailure = reconnectFailure
                if let reconnectFailure {
                    try await wait.reconnectFailed(reconnectFailure)
                } else {
                    wait.reconnected(took: launcher.now() - reconnectStart)
                }
            }
        }
    }

    /// The running app, or `nil` if the link dropped or no answer came within `timeout`.
    private func queryAllowingDisconnect(timeout: TimeInterval) async throws -> LedgerRunningApp? {
        do {
            return try await launcher.queryApp(transport: current, timeout: timeout)
        } catch {
            guard isLinkFailure(error) else { throw error }
            await markUnusable()
            return nil
        }
    }

    /// Replaces the dropped transport, which `markUnusable()` already closed, with one from
    /// `reconnect`, racing it against `launcher.switchReconnectTimeout`. Returns the link failure when
    /// the device cannot be reached yet, and `nil` once replaced. The caller's own cancellation
    /// propagates uncaught, never as a reconnect failure.
    private func replace() async throws -> ZcashError? {
        do {
            let replacement = try await raceReconnect()
            try await adopt(replacement)
            return nil
        } catch {
            guard isLinkFailure(error), let zcashError = error as? ZcashError else { throw error }
            return zcashError
        }
    }

    /// Races `reconnect()` against `launcher.switchReconnectTimeout`. See `raceReconnect(_:timeout:)`.
    private func raceReconnect() async throws -> any LedgerAPDUTransport {
        try await ZcashLightClientKit.raceReconnect(reconnect, timeout: launcher.switchReconnectTimeout)
    }

    private func exchangeAllowingDisconnect(_ apdu: Data, timeout: TimeInterval?) async throws -> Data? {
        do {
            return try await exchangeWithoutClosing(apdu, timeout: timeout, on: current)
        } catch {
            guard isLinkFailure(error) else { throw error }
            await markUnusable()
            return nil
        }
    }

    private func markUnusable() async {
        usable = false
        await closeQuietly(current)
    }

    /// Makes `replacement` the switch's transport, once the switch holds its ceremony. A replacement
    /// nothing else uses is taken at once; one another ceremony holds is waited for, and a
    /// cancellation while queued throws without adopting it, so the switch's cleanup closes nothing
    /// of the holder's -- `current` is still the transport that dropped, already closed.
    ///
    /// `reconnect` may hand back a transport the switch already holds, in either of two ways. The
    /// switch's own current replacement, from a transport that reconnects internally and whose
    /// `close()` only drops the link, keeps the hold it already has: releasing it and taking it again
    /// would open a gap in which a ceremony queued behind it is handed the gate and runs its commands
    /// on a transport that is open again, before the switch gets it back. The caller's own transport
    /// is not taken at all, since the public wrapper holds it for the whole switch; taking it here
    /// would wait on this switch itself. Anything else releases whatever hold the switch currently
    /// has, if any, and takes the new replacement fresh, the same as a first reconnect.
    private func adopt(_ replacement: any LedgerAPDUTransport) async throws {
        if ObjectIdentifier(replacement) == ObjectIdentifier(current), replacementHold != nil {
            didReplaceTransport = true
            usable = true
            return
        }
        await releaseReplacementHold()
        if ObjectIdentifier(replacement) != ObjectIdentifier(original) {
            replacementHold = try await LedgerCeremony.adopt(replacement)
        }
        current = replacement
        didReplaceTransport = true
        usable = true
    }

    /// Ends the switch's hold on its current replacement, if any: when the next replacement takes
    /// over, when the switch hands the replacement to the caller, or when the switch fails.
    func releaseReplacementHold() async {
        await replacementHold?.release()
        replacementHold = nil
    }

    /// Closes a transport opened through `reconnect` that is still open; one that failed was closed
    /// then.
    func closeReplacement() async {
        guard didReplaceTransport, usable else { return }
        await closeQuietly(current)
    }
}

/// The clock of one `AppSwitch.awaitApp(reached:)` wait: its deadline, and the run of reconnects that
/// failed in a row.
///
/// A failed reconnect is tried again after a backoff that starts at
/// `launcher.switchReconnectFirstBackoff` and doubles up to `launcher.switchReconnectMaxBackoff`.
/// Once `launcher.switchReconnectWindow` has passed since the first of the failed reconnects in a
/// row, the next failed reconnect propagates its failure. A reconnect that succeeds ends the row:
/// the next failure starts a new window, with the first backoff; the time the successful reconnect
/// itself took does not count against the deadline.
///
/// `deadline` here is this wait's own, reset by `reconnectFailed(_:)` and pushed forward by
/// `reconnected(took:)`; neither bounds the wait by itself, since a link that keeps recovering just
/// before each of those resets it again. `awaitApp(reached:)` holds a separate, outer
/// `switchOverallTimeout` deadline of its own for that, fixed once at the wait's start and never
/// touched by this class.
private final class SwitchWait {
    private let launcher: LedgerAppLauncher
    private var deadline: TimeInterval
    private var failingSince: TimeInterval?
    private var backoff: TimeInterval

    /// Whether the link was last replaced once the deadline had passed; it then gets one more poll.
    private(set) var replacedPastDeadline = false

    init(launcher: LedgerAppLauncher) {
        self.launcher = launcher
        self.deadline = launcher.transitionDeadline()
        self.backoff = launcher.switchReconnectFirstBackoff
    }

    /// Throws once the deadline has passed, and otherwise waits the poll interval.
    func beforeNextPoll() async throws {
        if launcher.now() >= deadline {
            throw ZcashError.ledgerWrongApp(0)
        }
        try await launcher.sleep(launcher.pollInterval)
    }

    /// Ends the run of failures, since a reconnect just succeeded, moves the deadline by the time it
    /// `took` so that time is not charged against the wait, and records whether it landed after the
    /// (moved) deadline.
    func reconnected(took: TimeInterval) {
        failingSince = nil
        backoff = launcher.switchReconnectFirstBackoff
        deadline += took
        replacedPastDeadline = launcher.now() >= deadline
    }

    /// Throws `failure` once the retry window has passed; otherwise starts the deadline over and
    /// waits the backoff, never past the end of the window.
    func reconnectFailed(_ failure: ZcashError) async throws {
        let now = launcher.now()
        let since = failingSince ?? now
        failingSince = since
        let remaining = launcher.switchReconnectWindow - (now - since)
        guard remaining > 0 else {
            throw failure
        }
        deadline = launcher.transitionDeadline()
        try await launcher.sleep(min(backoff, remaining))
        backoff = min(backoff * 2, launcher.switchReconnectMaxBackoff)
    }
}

// MARK: - Dashboard protocol

private let swOK: UInt16 = 0x9000
private let swUserRefused: UInt16 = 0x5501
private let swLocked: UInt16 = 0x5515
private let swAppNotInstalled: UInt16 = 0x6807

private func getAppAndVersionAPDU() -> Data {
    Data([0xB0, 0x01, 0x00, 0x00, 0x00])
}

private func closeAppAPDU() -> Data {
    Data([0xB0, 0xA7, 0x00, 0x00, 0x00])
}

private func openZcashAppAPDU() -> Data {
    let name = Data(LedgerRunningApp.zcashAppName.utf8)
    return Data([0xE0, 0xD8, 0x00, 0x00, UInt8(name.count)]) + name
}

private func dashboardStatusWord(_ reply: [UInt8]) throws -> UInt16 {
    guard reply.count >= 2 else {
        throw ZcashError.ledgerMalformedReply("the device's reply has no status word")
    }
    return UInt16(reply[reply.count - 2]) << 8 | UInt16(reply[reply.count - 1])
}

/// Parses `format ‖ nameLen ‖ name ‖ versionLen ‖ version ‖ [flagsLen ‖ flags]` followed by the status
/// word. Trailing flags are not read.
private func parseRunningApp(_ reply: [UInt8]) throws -> LedgerRunningApp {
    let end = reply.count - 2
    var cursor = 0

    func malformed() -> ZcashError {
        .ledgerMalformedReply("the device's app query reply is malformed")
    }

    func readField() throws -> String {
        guard cursor < end else { throw malformed() }
        let length = Int(reply[cursor])
        let start = cursor + 1
        guard start + length <= end else { throw malformed() }
        cursor = start + length
        return String(decoding: reply[start..<start + length], as: UTF8.self)
    }

    guard end >= 1, reply[cursor] == 0x01 else { throw malformed() }
    cursor += 1
    let name = try readField()
    let version = try readField()
    return LedgerRunningApp(name: name, version: version)
}

/// The locked-device refusal as the Ledger engine reports it: transient. Any other status word
/// reaching here is final.
private func dashboardRefusal(_ statusWord: UInt16) -> ZcashError {
    .ledgerDeviceRefused(statusWord, statusWord == swLocked)
}

/// What an answer to the open command means: nothing to raise when the device is opening the app,
/// else the failure.
private func openFailure(_ statusWord: UInt16) -> ZcashError? {
    switch statusWord {
    case swOK:
        return nil
    case swUserRefused:
        return .ledgerAppOpenRejected
    case swAppNotInstalled:
        return .ledgerAppNotInstalled
    case swLocked:
        return dashboardRefusal(statusWord)
    default:
        return .ledgerWrongApp(statusWord)
    }
}

/// A failure of the link rather than an answer from the device: expected while it switches apps.
///
/// Not `private`: shared with `LedgerDevice`'s pairing retry, which asks the same question about a
/// stalled read before the export, rather than duplicating the four cases there.
func isLinkFailure(_ error: Error) -> Bool {
    guard let zcashError = error as? ZcashError else { return false }
    switch zcashError {
    case .ledgerBluetoothDisconnected, .ledgerTimeout, .ledgerBluetoothConnectionFailed, .ledgerDeviceNotFound:
        return true
    default:
        return false
    }
}

/// The result of racing `reconnect()` against its own timeout in `raceReconnect(_:timeout:)`.
private enum ReconnectOutcome {
    case connected(any LedgerAPDUTransport)
    case timedOut
}

/// The nanoseconds `raceReconnect(_:timeout:)` races `reconnect` against, or `nil` when `timeout`
/// cannot bound a race at all: not finite (`.infinity` or `.nan`), or too large to fit `UInt64`
/// nanoseconds. `Task.sleep(nanoseconds:)` needs a `UInt64`, and converting such a `timeout` to one
/// directly traps; `raceReconnect(_:timeout:)` treats `nil` here as no timeout instead, awaiting
/// `reconnect()` with no cap of its own. A negative or zero `timeout` is a 0 ns sleep, i.e. an
/// immediate timeout, `0`.
func reconnectRaceNanoseconds(_ timeout: TimeInterval) -> UInt64? {
    guard timeout.isFinite else { return nil }
    guard timeout > 0 else { return 0 }
    let nanoseconds = timeout * 1_000_000_000
    guard nanoseconds < TimeInterval(UInt64.max) else { return nil }
    return UInt64(nanoseconds)
}

/// Races `reconnect` against `timeout`; the first to finish cancels the other. `reconnect` is
/// caller-supplied and may ignore that cancellation, so a transport it still produces after losing the
/// race — to the timeout, or to an error such as the caller's own cancellation — is drained explicitly
/// so it can be closed, unless another ceremony already holds it (`LedgerCeremony.closeIfUnowned(_:)`),
/// rather than leaked; the task group's own implicit cleanup would await that transport just the same,
/// but only this explicit drain closes it. The caller's own cancellation is read from
/// `Task.checkCancellation()` so a coincidental race at the deadline is never misreported as this
/// timeout firing.
///
/// A `timeout` that is not finite, or not representable in `UInt64` nanoseconds (see
/// `reconnectRaceNanoseconds(_:)`), races nothing: this just awaits `reconnect()` directly, with no cap
/// of its own, instead of trapping — pass `.infinity` for that. A negative or zero `timeout` behaves as
/// a 0 ns sleep, i.e. an immediate timeout.
///
/// With no timer, the caller's cancellation reaches `reconnect` only through `reconnect`'s own
/// cancellation checks. A `reconnect` that ignores cancellation keeps the caller waiting until it
/// returns; the transport it returns is then owned by whichever caller asked for it. The pairing
/// read adopts it onto `LedgerDevice`'s `transport` right away, under that transport's own ceremony;
/// a cancellation reaching the read that follows throws without the read itself closing anything,
/// since `LedgerCommands.exchange` checks cancellation before its `do` instead of inside it -- but
/// `pairAccount`'s own serializing wrapper closes whichever transport the call is on once its
/// operation fails this way, so a cancelled `pairAccount` closes the adopted transport rather than
/// leaving it open for its caller. `ensureZcashAppOpen` closes a replacement transport itself,
/// through `closeReplacement()`, if the overall call fails.
///
/// Not `private`: shared by `AppSwitch`'s own app-switch reconnects and by `LedgerDevice`'s
/// pairing-read reconnect, rather than duplicating this race in both places.
func raceReconnect(
    _ reconnect: @escaping @Sendable () async throws -> any LedgerAPDUTransport,
    timeout: TimeInterval
) async throws -> any LedgerAPDUTransport {
    guard let sleepNanoseconds = reconnectRaceNanoseconds(timeout) else {
        return try await reconnect()
    }
    return try await withThrowingTaskGroup(of: ReconnectOutcome.self) { group in
        group.addTask {
            .connected(try await reconnect())
        }
        group.addTask {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
            return .timedOut
        }

        let firstResult: ReconnectOutcome?
        do {
            firstResult = try await group.next()
        } catch {
            // The first result is an error rather than a timeout or a connected transport — most
            // often the caller's own cancellation. `reconnect` may still ignore that and produce a
            // transport later; drain for it here too, the same as the `.timedOut` branch below,
            // rather than let the group's implicit cleanup await and silently drop it.
            group.cancelAll()
            while let result = await group.nextResult() {
                if case .success(.connected(let late)) = result {
                    await LedgerCeremony.closeIfUnowned(late)
                }
            }
            throw error
        }
        guard let outcome = firstResult else {
            // Unreachable: exactly two child tasks were just added, so a first result always exists.
            throw ZcashError.ledgerInternal("the reconnect race produced no result")
        }
        group.cancelAll()

        switch outcome {
        case .connected(let transport):
            return transport
        case .timedOut:
            // The reconnect may still complete, now cancelled, after losing the race; close what it
            // produces, unless another ceremony has already taken it, rather than let a live
            // transport leak.
            while let result = await group.nextResult() {
                if case .success(.connected(let late)) = result {
                    await LedgerCeremony.closeIfUnowned(late)
                }
            }
            try Task.checkCancellation()
            throw ZcashError.ledgerBluetoothConnectionFailed(nil)
        }
    }
}

/// Exchanges one command on `transport` without closing it on failure: unlike `LedgerCommands.exchange`,
/// closing stays with `AppSwitch.markUnusable()`, exactly once, so this must not be used where that
/// exclusive ownership does not hold.
///
/// Checks `Task.checkCancellation()` before the command is put on the wire, and normalizes a thrown
/// error through `ledgerZcashError(_:)`, so a third-party ``LedgerAPDUTransport`` that throws
/// something other than a ``ZcashError`` still meets this file's `ZcashError` contract instead of
/// propagating verbatim and being silently treated as not a link failure.
private func exchangeWithoutClosing(_ apdu: Data, timeout: TimeInterval?, on transport: any LedgerAPDUTransport) async throws -> Data {
    try Task.checkCancellation()
    do {
        return try await transport.exchange(apdu, timeout: timeout)
    } catch {
        throw ledgerZcashError(error)
    }
}

private func closeQuietly(_ transport: any LedgerAPDUTransport) async {
    await transport.close()
}
