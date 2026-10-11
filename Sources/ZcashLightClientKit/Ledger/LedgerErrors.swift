//
//  LedgerErrors.swift
//  ZcashLightClientKit
//

import Foundation

/// The status word the device answers from its dashboard, with no app open.
private let swDeviceDashboard: UInt16 = 0x6E01
/// The device OS's "wrong length" answer: a command's data length doesn't match the fixed length of
/// the OS instruction with the same code, so a Zcash command reached the dashboard, not the Zcash app.
private let swOsWrongLength: UInt16 = 0x6511
/// The device OS's "unknown instruction" answer: the dashboard doesn't recognize the command code at all.
private let swOsInsNotSupported: UInt16 = 0x6D01

extension LedgerFFIError {
    /// The public error for this failure.
    ///
    /// A `0x6901` refusal only reaches here once its resend budget is spent, and is then reported as a
    /// transient device refusal.
    var zcashError: ZcashError {
        switch kind {
        case .userRejected:
            return .ledgerUserRejected
        case .wrongApp:
            return .ledgerWrongApp(statusWord ?? 0)
        case .appTooOld:
            return .ledgerAppTooOld(reason)
        case .deviceMismatch:
            return .ledgerDeviceMismatch
        case .capsMismatch:
            return .ledgerCapsMismatch(reason)
        case .derivationBudgetExhausted:
            return .ledgerDerivationBudgetExhausted
        case .deviceRefused:
            // The engine reports these three answers from the device OS as a plain, unclassified
            // refusal; all three mean the Zcash app is not running, so they are `ledgerWrongApp` like
            // any other unrecognized command, not a device condition. Newer pczt-ledger releases
            // classify all three as `wrongApp` themselves, so this mapping is a backstop for an engine
            // that doesn't.
            if statusWord == swDeviceDashboard || statusWord == swOsWrongLength || statusWord == swOsInsNotSupported {
                return .ledgerWrongApp(statusWord ?? 0)
            }
            return .ledgerDeviceRefused(statusWord ?? 0, isTransient)
        case .cmdNotAccepted:
            return .ledgerDeviceRefused(statusWord ?? 0x6901, true)
        case .transactionNotSignable:
            return .ledgerTransactionNotSignable(reason)
        case .malformedReply:
            return .ledgerMalformedReply(reason)
        case .invalidInput:
            return .ledgerInvalidInput(reason)
        case .internal:
            return .ledgerInternal(reason)
        }
    }
}

/// Converts a failure inside the Ledger integration into the error the public API throws: a
/// ``ZcashError`` for every Ledger failure, a `CancellationError` passed through unchanged, and a
/// transport's ``LedgerExchangeNotStarted`` normalized to that same `CancellationError` -- it is
/// every caller's signal that nothing was sent, not a transport failure, whichever of them reaches
/// this function with it.
func ledgerZcashError(_ error: Error) -> Error {
    switch error {
    case let ffiError as LedgerFFIError:
        return ffiError.zcashError
    case is LedgerExchangeNotStarted:
        return CancellationError()
    case is ZcashError, is CancellationError:
        return error
    default:
        return ZcashError.ledgerTransportFailed(error)
    }
}

extension ZcashError {
    /// Whether a fresh attempt at the same Ledger operation could succeed, or `nil` for an error that
    /// did not come from the Ledger integration.
    ///
    /// `true` after the user declined on the device (they may approve on a second attempt), after the
    /// device is not running the Zcash app or has exhausted its derivation budget (opening or
    /// reopening the app on the device lets a fresh attempt succeed), and after a device refusal whose
    /// condition can clear, such as a locked device. `false` for every failure that is a function of
    /// the transaction or the device, where a retry fails the same way. A transport failure is `true`:
    /// the connection is closed, and a new one may succeed. It never means "resend the last command": a
    /// fresh attempt starts over.
    public var ledgerIsRestartable: Bool? {
        switch self {
        case .ledgerUserRejected, .ledgerAppOpenRejected, .ledgerWrongApp, .ledgerDerivationBudgetExhausted:
            return true
        case let .ledgerDeviceRefused(_, isTransient):
            return isTransient
        case .ledgerBluetoothDisconnected, .ledgerTimeout, .ledgerTransportClosed, .ledgerTransportFailed,
            .ledgerBluetoothConnectionFailed, .ledgerDeviceNotFound, .ledgerBluetoothPoweredOff:
            return true
        case .ledgerAppTooOld, .ledgerDeviceMismatch, .ledgerCapsMismatch,
            .ledgerTransactionNotSignable, .ledgerMalformedReply,
            .ledgerInvalidInput, .ledgerInternal, .ledgerBluetoothUnsupported, .ledgerBluetoothUnauthorized,
            .ledgerBluetoothPairingRefused, .ledgerAppNotInstalled, .ledgerTransportReplaced:
            return false
        default:
            return nil
        }
    }
}
