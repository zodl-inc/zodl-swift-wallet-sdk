//
//  LedgerCommands.swift
//  ZcashLightClientKit
//

import Foundation

/// Thrown by a transport's `exchange(_:timeout:)` to report that this one exchange never sent
/// anything: nothing reached the device, so no reply on the wire can be mistaken for its answer, and
/// the transport does not need to be closed over it.
///
/// A transport throws this, instead of letting the failure read as an ordinary exchange failure,
/// when its own admission logic refuses a caller before its turn -- ``LedgerBluetoothTransport``
/// does this for a caller cancelled while still queued behind another exchange on the same
/// transport. The SDK's own commands let it through untouched until the error leaves them, where
/// `ledgerZcashError(_:)` turns it into a plain `CancellationError`; ``LedgerDevice``'s commands and
/// the signing ceremony both leave the transport open for it, unlike for a cancellation of an
/// exchange that did start. A caller that exchanges with a transport directly, outside those
/// commands, sees this type itself.
public struct LedgerExchangeNotStarted: Error {
    public init() {}
}

/// The exchange rules the pairing commands and the signing ceremony share.
enum LedgerCommands {
    /// Exchanges one command, closing the transport when the exchange fails.
    ///
    /// A failed exchange may have put its command on the wire and left the reply uncollected, so the
    /// transport cannot be trusted with another command: it is closed, whatever the failure, before
    /// the error is rethrown. A cancelled task counts as a failed exchange -- unless it is cancelled
    /// before this call even reaches the transport (checked up front, not inside the `do` below), or
    /// the transport itself reports, via ``LedgerExchangeNotStarted``, that its own admission gate
    /// refused the caller before anything was sent: neither one put anything on the wire, so neither
    /// is a failure of the transport, and the transport is left open. ``LedgerExchangeNotStarted`` is
    /// rethrown as it is, so that ``LedgerDevice`` and ``LedgerSigner`` can tell a cancellation that
    /// never reached the transport from one that did, and close the transport only for the latter;
    /// `ledgerZcashError(_:)` turns it into a `CancellationError` once that decision is made.
    static func exchange(_ apdu: Data, on transport: LedgerAPDUTransport, timeout: TimeInterval?) async throws -> Data {
        try Task.checkCancellation()

        do {
            return try await transport.exchange(apdu, timeout: timeout)
        } catch is LedgerExchangeNotStarted {
            throw LedgerExchangeNotStarted()
        } catch {
            await transport.close()
            throw ledgerZcashError(error)
        }
    }

    /// Sends a one-shot command and parses its reply, resending it while the device SDK refuses the
    /// frame with `0x6901`.
    ///
    /// `0x6901` means the frame never reached the Zcash app, so a resend is not a repeat. The command
    /// is sent at most `maxCmdNotAcceptedRetries + 1` times, with the engine's backoff before each
    /// resend. Stateful exchanges do not belong here: the viewing key export and the signing session
    /// absorb their own refusals.
    static func query<T>(
        _ apdu: Data,
        on transport: LedgerAPDUTransport,
        timeout: TimeInterval?,
        parse: (Data) throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            let reply = try await exchange(apdu, on: transport, timeout: timeout)
            do {
                return try parse(reply)
            } catch let error as LedgerFFIError where error.kind == .cmdNotAccepted && retries < ZcashLedgerBackend.maxCmdNotAcceptedRetries {
                retries += 1
                try await backOff(transport: transport)
            }
        }
    }

    /// Waits out a `0x6901` refusal before the identical command is resent. A cancelled wait closes the
    /// transport like a cancelled exchange.
    static func backOff(transport: LedgerAPDUTransport) async throws {
        do {
            try await Task.sleep(nanoseconds: ZcashLedgerBackend.cmdNotAcceptedBackoffNanoseconds)
        } catch {
            await transport.close()
            throw error
        }
    }
}

/// Admits async operations one at a time, in arrival order.
///
/// An actor alone does not serialize them: it is reentrant at every suspension point, so two exchanges
/// awaiting a device reply would interleave their commands. A caller brackets its operation with
/// ``acquire()`` and ``release()``, releasing on every path it takes once ``acquire()`` returns. A
/// cancelled caller never comes out of ``acquire()`` holding the gate: either it throws before ever
/// queuing, or it throws after being handed the gate and passes it straight on, so it must call
/// ``release()`` only when ``acquire()`` itself returned normally.
///
/// This depends on `withTaskCancellationHandler` and the continuation it wraps inheriting this
/// actor's isolation: every read and write of `waiters`, from `acquire()`, `release()` and
/// `cancelWaiter(_:)` alike, runs on the actor, so none of them race the array directly.
actor LedgerSerialGate {
    private var isBusy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    /// How many callers are queued behind the one currently holding the gate. Test-only visibility
    /// into otherwise-private state, so a test can wait for a caller to actually be queued instead
    /// of guessing with a sleep.
    var queuedCount: Int { waiters.count }

    /// Holds the gate at once when nothing holds it, whether or not the calling task is cancelled,
    /// and returns `false` without waiting when something does.
    func tryAcquire() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        return true
    }

    /// Waits until no other operation holds the gate, then holds it.
    ///
    /// Throws `CancellationError` instead of holding the gate when the calling task is already
    /// cancelled, or becomes cancelled while queued. Admission otherwise stays in arrival order.
    func acquire() async throws {
        try Task.checkCancellation()

        guard isBusy else {
            isBusy = true
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }

            // The continuation above resumed normally, so `release()` reached this waiter and
            // handed it the gate -- but `cancelWaiter(id)` runs in a separate `Task` hop off
            // `onCancel` below, which may not have run yet. A caller cancelled in that narrow
            // window must not come out of this call holding the gate: pass it on to whoever is
            // next, instead of returning normally to a cancelled task whose own operation would
            // fail later and close the transport out from under the caller it was just handed to.
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the gate to the next waiter, or frees it.
    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }

        waiters.removeFirst().continuation.resume()
    }

    /// Removes a cancelled waiter and resumes it with `CancellationError`, unless it has already been
    /// admitted by ``release()``: whichever of the two reaches it first wins, and the other finds it
    /// already gone.
    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Brackets `exchange` with `gate`: acquires it, runs `exchange`, and releases it whether `exchange`
/// succeeds or fails. A transport with its own internal admission queue -- serializing its own
/// exchanges the way ``LedgerBluetoothTransport`` does -- calls this from its `exchange(_:timeout:)`
/// instead of repeating the acquire/release bracket itself.
///
/// Refused before anything was sent (a cancellation while only queued for this transport's own
/// gate): not a failure of the exchange, so a failed `acquire()` throws ``LedgerExchangeNotStarted``
/// here instead of letting the gate's own `CancellationError` read as one -- the caller must not
/// close the transport out from under whoever is holding the gate now.
///
/// - Parameters:
///   - gate: The transport's own admission gate.
///   - isolation: Keeps `exchange` running on the caller's own actor, exactly as if it were inlined
///     there, rather than on whatever executor this free function would otherwise run on.
///   - exchange: The transport's own exchange, run once the gate admits it.
func ledgerGatedExchange(
    on gate: LedgerSerialGate,
    isolation: isolated (any Actor)? = #isolation,
    _ exchange: () async throws -> Data
) async throws -> Data {
    do {
        try await gate.acquire()
    } catch {
        throw LedgerExchangeNotStarted()
    }

    do {
        let reply = try await exchange()
        await gate.release()
        return reply
    } catch {
        await gate.release()
        throw error
    }
}
