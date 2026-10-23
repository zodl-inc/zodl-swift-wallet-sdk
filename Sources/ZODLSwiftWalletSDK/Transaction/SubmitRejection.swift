//
//  SubmitRejection.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Why a server refused a transaction for good: retrying the same transaction cannot succeed.
///
/// Only these refusals are terminal, and each is recognized from an explicit list of server
/// messages (see ``init(code:message:)``). Any other failure (a transport error, missing inputs
/// that may still arrive, a fee or mempool policy refusal, an unrecognized refusal) is treated as
/// transient, and the transaction stays pending and is retried until it expires, as before.
public enum SubmitRejection: Equatable, Hashable {
    /// The transaction is larger than the server accepts: it exceeds the server's configured
    /// mempool size limit, the ZIP 218 shielded action budget of the next block, or the
    /// transaction size limit. The same payment needs fewer inputs, for instance a smaller amount
    /// or a tighter ``TransactionSizeBound``.
    case tooLarge
    /// The transaction has expired, or expires too soon to be mined.
    case expired
    /// The server found the transaction invalid.
    case invalid

    /// The RPC code for a transaction that failed verification (`RPC_VERIFY_ERROR`).
    static let verifyErrorCode = -25
    /// The RPC code for a transaction that was rejected (`RPC_VERIFY_REJECTED`).
    static let verifyRejectedCode = -26

    // These texts match the servers' own rejection messages; do not change them. The lists are
    // the SDK's current reading of zcashd, Zebra and Zakura refusals and still need confirmation
    // from the node implementers: anything they leave out stays transient, which keeps the
    // pre-classification behaviour (resubmission until expiry).

    /// Refusals of a transaction above a size limit: a Zakura relay's configured mempool
    /// maximum, Zebra's ZIP 218 shielded action budget of the next block, and zcashd's
    /// transaction size limit (`tx-size`, `bad-txns-oversize`).
    static let tooLargeMarkers = [
        "exceeding the configured mempool maximum",
        "ZIP 218 limit",
        "tx-size",
        "bad-txns-oversize",
        "too large",
        "too-large",
    ]
    /// Refusals of a transaction past, or too close to, its expiry height: Zebra's
    /// `greater than its expiry`, zcashd's `tx-overwinter-expired` and `tx-expiring-soon`.
    static let expiredMarkers = ["greater than its expiry", "tx-overwinter-expired", "tx-expiring-soon"]
    /// Refusals that may pass on a later attempt, whatever else their message says: a full
    /// mempool or a fee below its current minimum, a transaction it already holds or that
    /// conflicts with one it holds, a chain of unconfirmed ancestors over its limit, and inputs it
    /// does not know yet. Checked before ``invalidMarkers``, which some of them would match.
    static let transientMarkers = [
        "mempool full",
        "fee",
        "already in",
        "already-in",
        "already known",
        "already-known",
        "txn-mempool-conflict",
        "too-long-mempool-chain",
        "chain limit",
        "missing inputs",
        "missing-inputs",
        "inputs-missingorspent",
        "inputs-spent",
    ]
    /// Known permanent refusals of an invalid transaction under `-26`.
    static let invalidMarkers = ["bad-txns-", "invalid", "non-final", "mandatory-script-verify-flag"]

    /// Classifies a server's refusal of a submitted transaction, or returns `nil` when the refusal
    /// may be transient: anything this does not recognize as final.
    ///
    /// - `-25` or `-26` naming a size limit (``tooLargeMarkers``) is ``tooLarge``;
    /// - `-25` or `-26` naming an expiry (``expiredMarkers``) is ``expired``;
    /// - `-26` naming a known permanent refusal (``invalidMarkers``) is ``invalid``, unless it also
    ///   names a transient condition (``transientMarkers``);
    /// - anything else is transient.
    ///
    /// The marker lists still need confirmation from the node implementers.
    ///
    /// - Parameters:
    ///   - code: the error code the server returned.
    ///   - message: the error message the server returned.
    public init?(code: Int, message: String) {
        func mentions(_ marker: String) -> Bool {
            message.range(of: marker, options: .caseInsensitive) != nil
        }
        let verificationCode = code == Self.verifyErrorCode || code == Self.verifyRejectedCode
        guard verificationCode else { return nil }
        if Self.tooLargeMarkers.contains(where: mentions) {
            self = .tooLarge
        } else if Self.expiredMarkers.contains(where: mentions) {
            self = .expired
        } else if code == Self.verifyRejectedCode
            && !Self.transientMarkers.contains(where: mentions)
            && Self.invalidMarkers.contains(where: mentions) {
            self = .invalid
        } else {
            return nil
        }
    }
}

public extension TransactionSubmitResult {
    /// The terminal refusal this result reports, or `nil` for a success, a transport failure, a
    /// transaction not attempted, or a refusal that may be transient.
    var rejection: SubmitRejection? {
        guard case let .submitFailure(_, code, description) = self else { return nil }
        return SubmitRejection(code: code, message: description)
    }
}

public extension TransactionSubmissionOutcome {
    /// The terminal refusal this outcome reports, or `nil` for any other outcome or a refusal that
    /// may be transient.
    ///
    /// From `Broadcaster.submit(transaction:to:timing:)` this is the SDK's own verdict: non-`nil`
    /// exactly when the SDK recorded the transaction as rejected
    /// (``TransactionSubmissionStatus/rejected(_:)``) and stopped resubmitting it, which it does
    /// when every endpoint gave an explicit answer, none accepted and at least one refused for good.
    /// `.rejected` then carries that terminal refusal, whichever endpoint gave it and in whatever
    /// order the answers arrived. A transaction an endpoint had not answered by the deadline, or
    /// whose submission to an endpoint failed at the transport level, is `.timedOut` (pending)
    /// instead, and one a server has accepted (in this submission or earlier) is `.accepted(by:)`
    /// whatever another endpoint refused. An Orchard migration preparation is never recorded as
    /// rejected, and its outcome reports the first refusal observed, as before.
    var rejection: SubmitRejection? {
        guard case let .rejected(code, message) = self else { return nil }
        return SubmitRejection(code: code, message: message)
    }
}
