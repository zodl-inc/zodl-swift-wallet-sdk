//
//  SubmitRejection.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Why a server refused a transaction for good: retrying the same transaction cannot succeed.
///
/// A refusal is terminal only if the transaction can never become valid on a later attempt, to any
/// server. Each kind is recognized from an explicit list of server messages (see
/// ``SubmitRefusal``, which holds every list in one place). Any other failure (a transport error, a
/// refusal that depends on the server's view of the chain or its mempool, an unrecognized refusal)
/// is inconclusive, and the transaction stays pending and is retried until it expires, as before.
public enum SubmitRejection: Equatable, Hashable {
    /// The transaction is larger than the server accepts: it exceeds the server's configured
    /// mempool size limit, the ZIP 218 shielded action budget of the next block, or the
    /// transaction size limit. The same payment needs fewer inputs, for instance a smaller amount
    /// or a tighter ``TransactionSizeBound``.
    case tooLarge
    /// The transaction has expired, or expires too soon to be mined.
    case expired
    /// The server found the transaction invalid for good: a signature, proof or structural
    /// failure.
    case invalid

    /// Classifies a server's refusal of a submitted transaction, or returns `nil` when the refusal
    /// is not terminal: a refusal saying the server already holds the transaction, and anything
    /// inconclusive. See ``SubmitRefusal`` for the lists and the order they are checked in.
    ///
    /// - Parameters:
    ///   - code: the error code the server returned.
    ///   - message: the error message the server returned.
    public init?(code: Int, message: String) {
        guard case let .rejected(rejection) = SubmitRefusal(code: code, message: message) else { return nil }
        self = rejection
    }
}

/// What a server's refusal of a submitted transaction means for the SDK: the one place the
/// refusal lists live.
///
/// The principle: a refusal is terminal only if the transaction can never become valid on a later
/// attempt. A refusal that depends on the server's state (an anchor or inputs it has not seen yet,
/// a nullifier or conflict in its mempool, its fee floor, its mempool limits, a lock time) may pass
/// later, or at another server, and stays inconclusive.
///
/// Matching ignores case. The lists are checked in this order:
///
/// 1. ``acceptedMarkers``, under any error code: the server already holds the transaction. This
///    counts exactly like an acceptance by that endpoint.
/// 2. Under `-25` or `-26` only: ``tooLargeMarkers`` (``SubmitRejection/tooLarge``), then
///    ``expiredMarkers`` (``SubmitRejection/expired``), then ``inconclusiveMarkers`` (never
///    terminal, whatever else the message says), then ``invalidMarkers``
///    (``SubmitRejection/invalid``).
/// 3. Anything else is inconclusive.
///
/// The texts match the servers' own messages; do not change them. Each comes from zcashd
/// (`src/main.cpp`, `src/rpc/rawtransaction.cpp` at 558f686599586f55def3db86955d74d3be44605e), Zebra
/// (`zebra-consensus/src/error.rs`, `zebrad/src/components/mempool/error.rs`) or a Zakura relay, as
/// noted per entry. The lists are the SDK's reading of those sources, identical to the Android
/// SDK's, and still need confirmation from the node teams.
enum SubmitRefusal: Equatable {
    /// The server already holds the transaction, in its mempool or its chain.
    case accepted
    /// The server refused the transaction for good.
    case rejected(SubmitRejection)
    /// The refusal may pass on a later attempt, or is not recognized.
    case inconclusive

    /// The RPC code for a transaction that failed verification (`RPC_VERIFY_ERROR`, Zebra's code
    /// for every mempool refusal).
    static let verifyErrorCode = -25
    /// The RPC code for a transaction that was rejected (`RPC_VERIFY_REJECTED`).
    static let verifyRejectedCode = -26

    /// The server already holds the transaction.
    static let acceptedMarkers = [
        "already-in", // zcashd main.cpp `txn-already-in-mempool`
        "txn-already-known", // zcashd main.cpp:1911
        "already in block chain", // zcashd rawtransaction.cpp:1315 (`-27`)
        "already exists in mempool" // Zebra mempool/error.rs:55
    ]
    /// The transaction is above a size limit.
    static let tooLargeMarkers = [
        "exceeding the configured mempool maximum", // Zakura relay
        "ZIP 218", // Zebra consensus error.rs:256, the next block's ZIP 218 limit
        "oversize" // zcashd main.cpp:1007, 1561 `bad-txns-oversize`
    ]
    /// The transaction is past, or too close to, its expiry height.
    static let expiredMarkers = [
        "tx-overwinter-expired", // zcashd main.cpp:943
        "tx-expiring-soon", // zcashd main.cpp:1861
        "expired", // zcashd `tx-overwinter-expired`
        "greater than its expiry" // Zebra consensus error.rs:110
    ]
    /// State-dependent refusals that may pass on a later attempt or at another server. Checked
    /// before ``invalidMarkers`` so that they never stop resubmission; anything on no list is
    /// inconclusive too.
    ///
    /// This includes zcashd's version and consensus-branch checks (`bad-tx-*`, such as
    /// `bad-tx-consensus-branch-id-mismatch` or `bad-tx-zip225-version-too-low`, and the
    /// `*-tx-version-group-id` family). They are judged against the server's own view of which
    /// network upgrade is active, so a node lagging near an upgrade can refuse a transaction that
    /// becomes valid once it catches up; by the principle they cannot be terminal. The cost is that
    /// a transaction that really is invalid this way keeps its funds reserved until it expires.
    static let inconclusiveMarkers = [
        "unknown-anchor", // zcashd main.cpp:168-172, an anchor the server has not reached yet
        "duplicate-nullifier", // zcashd main.cpp:167-171
        "inputs-spent", // zcashd main.cpp:1926
        "inputs-missingorspent", // zcashd main.cpp:3585
        "txn-mempool-conflict", // zcashd main.cpp:1897
        "missing inputs", // zcashd rawtransaction.cpp:1309
        "min relay fee", // zcashd main.cpp:2008
        "too-long-mempool-chain", // zcashd main.cpp:2040
        "non-final", // zcashd main.cpp:1877
        "tx-version", // zcashd main.cpp `bad-*-tx-version-group-id`, upgrade-dependent
        "bad-tx-" // zcashd main.cpp:954-1627, upgrade-dependent version and branch checks
    ]
    /// Signature, proof and structural failures: the transaction itself is invalid.
    static let invalidMarkers = [
        "bad-txns-invalid-joinsplit-signature", // zcashd main.cpp:1413
        "bad-txns-joinsplit-", // zcashd main.cpp:1451
        "bad-txns-sapling-bundle-invalid", // zcashd main.cpp:1423
        "bad-sapling-bundle-authorization", // zcashd main.cpp:2106
        "bad-orchard-bundle-authorization", // zcashd main.cpp:2109
        "bad-txns-vout-", // zcashd main.cpp:1568, 1570
        "bad-txns-txouttotal-toolarge", // zcashd main.cpp:1573
        "bad-txns-txintotal-toolarge", // zcashd main.cpp:1695
        "bad-txns-oversize", // zcashd main.cpp:1561 (``tooLargeMarkers`` match it first)
        "mandatory-script-verify-flag-failed", // zcashd main.cpp:2876
        "bad-txns-no-", // zcashd main.cpp:1539, 1554
        "MUST represent a valid signature", // Zebra consensus error.rs:154, 159, 163
        "proof MUST be valid", // Zebra consensus error.rs:146
        "proof is malformed", // Zebra consensus error.rs:150
        "proof or signature verification failed", // Zebra consensus error.rs:167
        "proof verification failed", // Zebra consensus error.rs:170
        "proof has a non-canonical size" // Zebra consensus error.rs:297, 300
    ]

    /// Classifies a server's refusal of a submitted transaction.
    ///
    /// - Parameters:
    ///   - code: the error code the server returned.
    ///   - message: the error message the server returned.
    init(code: Int, message: String) {
        func mentions(_ marker: String) -> Bool {
            message.range(of: marker, options: .caseInsensitive) != nil
        }
        if Self.acceptedMarkers.contains(where: mentions) {
            self = .accepted
        } else if code != Self.verifyErrorCode && code != Self.verifyRejectedCode {
            self = .inconclusive
        } else if Self.tooLargeMarkers.contains(where: mentions) {
            self = .rejected(.tooLarge)
        } else if Self.expiredMarkers.contains(where: mentions) {
            self = .rejected(.expired)
        } else if Self.inconclusiveMarkers.contains(where: mentions) {
            self = .inconclusive
        } else if Self.invalidMarkers.contains(where: mentions) {
            self = .rejected(.invalid)
        } else {
            self = .inconclusive
        }
    }

    /// Whether a refusal with this code and message says the server already holds the
    /// transaction, so it counts as that endpoint's acceptance.
    static func meansAccepted(code: Int, message: String) -> Bool {
        SubmitRefusal(code: code, message: message) == .accepted
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
