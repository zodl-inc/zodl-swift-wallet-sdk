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
    /// The transaction is larger than the server's mempool accepts. It spends too many notes; the
    /// same payment needs fewer inputs, for instance a smaller amount or a tighter
    /// ``TransactionSizeBound``.
    case tooLarge
    /// The transaction has expired, or expires too soon to be mined.
    case expired
    /// The server found the transaction invalid.
    case invalid

    /// The lightwalletd error code for a transaction the node failed to verify.
    static let verifyErrorCode = -25
    /// The lightwalletd error code for a transaction the node rejected.
    static let verifyRejectedCode = -26
    /// The text a node reports, with ``verifyErrorCode``, for a transaction over its mempool limit.
    static let mempoolMaximumText = "exceeding the configured mempool maximum"

    /// Classifies a server's refusal of a submitted transaction, or returns `nil` when the refusal
    /// is not one of the terminal kinds.
    ///
    /// - Parameters:
    ///   - code: the error code the server returned.
    ///   - message: the error message the server returned.
    public init?(code: Int, message: String) {
        let text = message.lowercased()
        if code == Self.verifyErrorCode && text.contains(Self.mempoolMaximumText) {
            self = .tooLarge
        } else if text.contains("expired") || text.contains("expiring") {
            self = .expired
        } else if code == Self.verifyRejectedCode {
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
    /// recorded as rejected only when every endpoint refused it terminally.
    var rejection: SubmitRejection? {
        guard case let .rejected(code, message) = self else { return nil }
        return SubmitRejection(code: code, message: message)
    }
}
