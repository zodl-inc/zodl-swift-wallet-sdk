//
//  LedgerSignSession.swift
//  ZcashLightClientKit
//

import Foundation
import libzcashlc

/// Where a Ledger signing ceremony is, as the Rust session reports it.
enum LedgerSignStage: String, Equatable {
    case identifyingDevice
    case streaming
    case signingOrchard
    case signingIronwood
    case signingTransparent
    case complete
    case failed

    init?(ffiValue: UInt32) {
        switch Int32(bitPattern: ffiValue) {
        case ZCASHLC_LEDGER_STAGE_IDENTIFYING_DEVICE: self = .identifyingDevice
        case ZCASHLC_LEDGER_STAGE_STREAMING: self = .streaming
        case ZCASHLC_LEDGER_STAGE_SIGNING_ORCHARD: self = .signingOrchard
        case ZCASHLC_LEDGER_STAGE_SIGNING_IRONWOOD: self = .signingIronwood
        case ZCASHLC_LEDGER_STAGE_SIGNING_TRANSPARENT: self = .signingTransparent
        case ZCASHLC_LEDGER_STAGE_COMPLETE: self = .complete
        case ZCASHLC_LEDGER_STAGE_FAILED: self = .failed
        default: return nil
        }
    }

    var isSigning: Bool {
        switch self {
        case .signingOrchard, .signingIronwood, .signingTransparent:
            return true
        case .identifyingDevice, .streaming, .complete, .failed:
            return false
        }
    }
}

/// A command the signing session hands out.
struct LedgerSignCommand: Equatable {
    /// The APDU to send. It carries the transaction's per-action secrets: never log it.
    let apdu: Data
    /// Whether the reply may wait on the user, so that no timeout applies.
    let waitsForUser: Bool
    /// Whether this command opens the on-device review. Reported once per session.
    let startsReview: Bool
    let stage: LedgerSignStage
    let streamAcknowledged: Int
    let streamTotal: Int
}

/// What the signing session asks of the transport next.
enum LedgerSignStep: Equatable {
    case send(LedgerSignCommand)
    /// A command is outstanding whose reply was never processed; the session cannot continue.
    case awaitingReply
    /// Nothing more will be sent.
    case done
}

/// What a reply did to the signing session.
enum LedgerSignStatus: Equatable {
    case moreAPDUs
    /// The device SDK refused the frame (`0x6901`); the next step is the same command, after the backoff.
    case retrySameAPDU
    /// The next command opens the on-device review.
    case awaitingUser
    /// Every command has been answered.
    case complete
}

/// A PCZT signing ceremony against one paired Ledger device.
///
/// The session performs no I/O: the caller exchanges each command it hands out and hands the reply
/// back. Every method throws ``LedgerFFIError``.
protocol LedgerSigningSession: AnyObject {
    func nextStep() throws -> LedgerSignStep
    func processResponse(_ reply: Data) throws -> LedgerSignStatus
    /// Applies the collected signatures and returns the signed PCZT. Valid once, after `.complete`.
    func finish() throws -> Pczt
}

/// The signing session backed by the Rust `FfiLedgerSignSession` handle.
final class LedgerFFISignSession: LedgerSigningSession {
    private let sessionPtr: OpaquePointer

    init(sessionPtr: OpaquePointer) {
        self.sessionPtr = sessionPtr
    }

    deinit {
        zcashlc_ledger_free_sign_session(sessionPtr)
    }

    func nextStep() throws -> LedgerSignStep {
        guard let stepPtr = zcashlc_ledger_sign_session_next_step(sessionPtr) else {
            throw LedgerFFIError.takeLast(fallback: "`LedgerSignSession.nextStep` failed with unknown error")
        }

        defer { zcashlc_ledger_free_sign_step(stepPtr) }

        let step = stepPtr.pointee
        switch Int32(bitPattern: step.kind) {
        case ZCASHLC_LEDGER_SIGN_STEP_SEND:
            guard let apdu = step.apdu, let stage = LedgerSignStage(ffiValue: step.stage) else {
                throw LedgerFFIError.local(.internal, "the signing session handed out a malformed command")
            }
            return .send(
                LedgerSignCommand(
                    apdu: Data(bytes: apdu, count: Int(step.apdu_len)),
                    waitsForUser: step.waits_for_user,
                    startsReview: step.starts_review,
                    stage: stage,
                    streamAcknowledged: Int(step.stream_acknowledged),
                    streamTotal: Int(step.stream_total)
                )
            )
        case ZCASHLC_LEDGER_SIGN_STEP_AWAITING_REPLY:
            return .awaitingReply
        case ZCASHLC_LEDGER_SIGN_STEP_DONE:
            return .done
        default:
            throw LedgerFFIError.local(.internal, "the signing session reported an unknown step")
        }
    }

    func processResponse(_ reply: Data) throws -> LedgerSignStatus {
        let status = reply.withLedgerBytes { bytes, count in
            zcashlc_ledger_sign_session_process_response(sessionPtr, bytes, count)
        }

        switch status {
        case ZCASHLC_LEDGER_SIGN_STATUS_MORE_APDUS:
            return .moreAPDUs
        case ZCASHLC_LEDGER_SIGN_STATUS_RETRY_SAME_APDU:
            return .retrySameAPDU
        case ZCASHLC_LEDGER_SIGN_STATUS_AWAITING_USER:
            return .awaitingUser
        case ZCASHLC_LEDGER_SIGN_STATUS_COMPLETE:
            return .complete
        default:
            throw LedgerFFIError.takeLast(fallback: "`LedgerSignSession.processResponse` failed with unknown error")
        }
    }

    func finish() throws -> Pczt {
        try ZcashLedgerBackend.takeBytes(zcashlc_ledger_sign_session_finish(sessionPtr), fallback: "`LedgerSignSession.finish` failed")
    }
}
