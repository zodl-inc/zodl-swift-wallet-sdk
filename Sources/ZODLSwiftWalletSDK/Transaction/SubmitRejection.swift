//
//  SubmitRejection.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Why a server refused a transaction for good: retrying the same transaction cannot succeed.
///
/// Only these refusals are terminal. Any other failure (a transport error, missing inputs that may
/// still arrive, an unrecognized refusal) is treated as transient, and the transaction stays
/// pending and is retried until it expires, as before.
public enum SubmitRejection: Equatable, Hashable {
    /// The transaction is larger than the server accepts: it exceeds the server's configured
    /// mempool size limit, or the ZIP 218 shielded action budget of the next block. The same
    /// payment needs fewer inputs, for instance a smaller amount or a tighter
    /// ``TransactionSizeBound``.
    case tooLarge
    /// The transaction has expired, or expires too soon to be mined.
    case expired
    /// The server found the transaction invalid.
    case invalid

    /// The RPC code for a transaction that failed verification (`RPC_VERIFY_ERROR`).
    static let verifyErrorCode = -25
    /// The RPC code for a transaction that was rejected (`RPC_VERIFY_REJECTED`).
    static let verifyRejectedCode = -26

    // These texts match the servers' own rejection messages; do not change them.

    /// A Zakura relay refusing a transaction above its configured mempool size limit.
    static let mempoolMaximumMarker = "exceeding the configured mempool maximum"
    /// Zebra refusing a transaction over the next block's ZIP 218 shielded action budget.
    static let zip218LimitMarker = "ZIP 218 limit"
    /// Zebra refusing a transaction past its expiry height.
    static let zebraExpiredMarker = "greater than its expiry"
    /// zcashd refusing a transaction past its expiry height.
    static let zcashdExpiredMarker = "tx-overwinter-expired"
    /// zcashd refusing a transaction that expires within the next few blocks.
    static let zcashdExpiringSoonMarker = "tx-expiring-soon"
    /// Refusals zcashd reports with ``verifyRejectedCode`` that are nonetheless transient.
    static let transientRejectionMarkers = ["mempool full", "already in", "already-in"]

    /// Classifies a server's refusal of a submitted transaction, or returns `nil` when the refusal
    /// may be transient: anything this does not recognize as final.
    ///
    /// - `-25` naming the configured mempool maximum or the ZIP 218 limit is ``tooLarge``;
    /// - `-25` or `-26` naming an expiry is ``expired``;
    /// - any other `-26`, except a full mempool or a transaction already known, is ``invalid``.
    ///
    /// - Parameters:
    ///   - code: the error code the server returned.
    ///   - message: the error message the server returned.
    public init?(code: Int, message: String) {
        func mentions(_ marker: String) -> Bool {
            message.range(of: marker, options: .caseInsensitive) != nil
        }
        let verificationCode = code == Self.verifyErrorCode || code == Self.verifyRejectedCode
        if code == Self.verifyErrorCode && (mentions(Self.mempoolMaximumMarker) || mentions(Self.zip218LimitMarker)) {
            self = .tooLarge
        } else if verificationCode
            && [Self.zebraExpiredMarker, Self.zcashdExpiredMarker, Self.zcashdExpiringSoonMarker].contains(where: mentions) {
            self = .expired
        } else if code == Self.verifyRejectedCode && !Self.transientRejectionMarkers.contains(where: mentions) {
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
    /// may be transient. `.rejected` carries the first refusal observed; the transaction is
    /// recorded as rejected when any endpoint refused it terminally and none accepted it.
    var rejection: SubmitRejection? {
        guard case let .rejected(code, message) = self else { return nil }
        return SubmitRejection(code: code, message: message)
    }
}
