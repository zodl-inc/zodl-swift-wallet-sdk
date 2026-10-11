//
//  LedgerAPDUTransport.swift
//  ZcashLightClientKit
//

import Foundation

/// A channel that carries commands (APDUs) to a Ledger device and brings back its replies.
///
/// ``LedgerBluetoothTransport`` is the SDK's implementation. The protocol exists so that the pairing
/// and signing code depends on nothing but this contract, and can be driven by a test double.
///
/// An implementation must keep these rules, which the signing ceremony relies on:
///
/// - One transport talks to one peripheral for its whole lifetime. The pairing and signing code
///   reads the connected device's identity once, through this transport, and trusts every later
///   reply on it to come from that same device; a transport that could redirect to a different
///   peripheral partway through its life would invalidate that binding for every exchange after
///   the switch.
/// - One exchange at a time. A reply is only ever the answer to the command last sent, and nothing
///   in a reply says which command it answers. The SDK goes further on its own side: every pairing,
///   signing ceremony and app switch holds the transport for all of its commands, so two of them
///   over one transport run one after the other, whichever `LedgerDevice`, `Synchronizer` or
///   `LedgerZcashApp` call started them. Only the SDK's own entry points hold that ceremony-wide
///   ownership; a caller that exchanges with a transport directly, while one of them runs, can
///   still interleave its command with theirs.
/// - The reply is the raw payload: the response data followed by the two-byte status word. A
///   transport never inspects the status word; a device that answers "denied" is a successful
///   exchange.
/// - An exchange that fails once its command has started onto the wire (a timeout, a disconnect, a
///   reply that does not reassemble, a cancelled task) leaves the device's reply uncollected. The
///   transport must then refuse every later exchange and close the connection, so that a late reply
///   is never taken for the answer to the next command. It never resends a command on its own.
public protocol LedgerAPDUTransport: AnyObject, Sendable {
    /// Sends one command and returns the device's reply.
    ///
    /// - Parameters:
    ///   - apdu: The command to send.
    ///   - timeout: How long to wait for the reply, in seconds. `nil` waits indefinitely: the reply
    ///     arrives only once the user has acted on the device.
    /// - Returns: The response data followed by the two-byte status word.
    /// - Throws: Any error from this method is treated as an exchange that may have reached the
    ///   device. ``LedgerDevice``'s commands and signing close the transport before the error
    ///   reaches their caller. `LedgerZcashApp.ensureZcashAppOpen` closes the caller's transport
    ///   only when its link fails, and closes a transport its `reconnect` opened whenever the call
    ///   fails; `LedgerZcashApp.currentApp` never closes the transport it is given. The one
    ///   exception is ``LedgerExchangeNotStarted``, which an implementation throws instead to report
    ///   that it refused this exchange before sending anything: ``LedgerDevice``'s commands and the
    ///   signing ceremony both report it as a cancellation and leave the transport open, since the
    ///   device never received the command.
    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data

    /// Closes the connection. Every later exchange fails. Closing twice has no effect.
    func close() async
}
