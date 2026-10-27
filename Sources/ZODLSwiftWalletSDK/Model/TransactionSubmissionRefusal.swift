//
//  TransactionSubmissionRefusal.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Why the SDK refused to submit a transaction: it cannot be valid in the next block.
///
/// A block accepts only a transaction built for the consensus branch its own height is under, and
/// only one that has not expired by then. The SDK judges a submission against the next block, the
/// one after the higher of the wallet's chain tip and the height reported by the server the
/// transaction is about to go to, and refuses a transaction that fails either test before anything
/// reaches the network. A refused transaction is never submitted, and a migration transaction is
/// not recorded in the wallet either.
///
/// The server's height counts because the wallet's own chain tip can lag it by every block the
/// wallet has not synced yet, and a transaction is mined by the chain as the server sees it. When
/// that height cannot be read, nothing is submitted.
///
/// A refusal is reported where the submission is. A migration transaction throws
/// ``ZcashError/migrationSubmissionRefused(_:)``. Any other transaction is reported as
/// ``TransactionSubmitResult/submitFailure(txId:code:description:)`` when the synchronizer submits it, and,
/// when it is submitted to several endpoints, as ``TransactionSubmissionOutcome/rejected(code:message:)`` once
/// every endpoint has answered and none accepted it, with the refusal's ``code`` and ``description``.
///
/// A refused normal transaction has to be created again, after a sync: a wallet that is behind the
/// server would build one that is refused again. The refused one stays in the wallet, which stored it
/// when it was created, and its inputs return to the spendable balance at its expiry height.
public enum TransactionSubmissionRefusal: Equatable, Sendable, CustomStringConvertible {
    /// The transaction is built for another consensus branch than the next block is under. This is
    /// what a network upgrade does to a transaction created before it and not yet sent: no block
    /// of the new branch can include it, so a normal transaction has to be created again, after a
    /// sync.
    case wrongConsensusBranch
    /// The transaction's expiry height is below the next block's, so no block can include it any
    /// more (ZIP 203). A normal transaction has to be created again, after a sync.
    case expired

    /// The local code the refusal is reported under where a failure carries an integer code:
    /// `-9101` (``wrongConsensusBranch``) and `-9102` (``expired``).
    /// They are stable, and no server sends them.
    public var code: Int {
        switch self {
        case .wrongConsensusBranch:
            return -9101
        case .expired:
            return -9102
        }
    }

    /// A stable description of the refusal, for logs and diagnostics. It carries no transaction
    /// data.
    public var description: String {
        switch self {
        case .wrongConsensusBranch:
            return "The transaction is built for another consensus branch than the next block's."
        case .expired:
            return "The transaction expires before the next block."
        }
    }
}

extension TransactionSubmissionRefusal {
    /// The refusal a code of the rust layer's `MIGRATION_SUBMISSION_REFUSED:<code>` error names, or
    /// `nil` for a code this SDK does not know.
    init?(rustCode: String) {
        switch rustCode {
        case "wrong_branch":
            self = .wrongConsensusBranch
        case "expired":
            self = .expired
        default:
            return nil
        }
    }
}
