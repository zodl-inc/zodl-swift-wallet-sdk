//
//  SubmitRejectionVerdict.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// What one endpoint answered when a transaction was submitted to it.
enum EndpointSubmission: Equatable {
    /// The endpoint took the transaction into its mempool.
    case accepted
    /// The endpoint refused the transaction with this code and message.
    case refused(code: Int, message: String)
    /// The endpoint could not be reached, or did not answer.
    case failed

    /// The terminal refusal this answer is, if any.
    var rejection: SubmitRejection? {
        guard case let .refused(code, message) = self else { return nil }
        return SubmitRejection(code: code, message: message)
    }
}

/// A terminal rejection as the submit-plan store records it: the first terminal refusal's code and
/// message.
struct StoredRejection: Equatable {
    let code: Int
    let reason: String
}

/// The key an endpoint's answer is recorded under: `host:port`, as the store records an acceptance.
func endpointKey(_ endpoint: LightWalletEndpoint) -> String {
    "\(endpoint.host):\(endpoint.port)"
}

/// Whether a transaction is rejected for good, given its stored plan and what its endpoints just
/// answered: the rejection to record, or `nil` when it should stay pending and be resubmitted as
/// before.
///
/// It is rejected only when every endpoint of its plan (`planEndpoints`) refused it terminally and
/// none of `outcomes` accepted it. An endpoint with no answer here counts as having refused when the
/// transaction was already rejected (`previous`). The recorded rejection is the first terminal
/// refusal among `outcomes` in plan order, or `previous`.
func submitRejectionVerdict(
    planEndpoints: [LightWalletEndpoint],
    outcomes: [String: EndpointSubmission],
    previous: StoredRejection?
) -> StoredRejection? {
    guard !planEndpoints.isEmpty, !outcomes.values.contains(.accepted) else { return nil }
    let refusedByAll = planEndpoints.allSatisfy { endpoint in
        guard let outcome = outcomes[endpointKey(endpoint)] else { return previous != nil }
        return outcome.rejection != nil
    }
    guard refusedByAll else { return nil }
    let first = planEndpoints.lazy
        .compactMap { outcomes[endpointKey($0)] }
        .first { $0.rejection != nil }
    if case let .refused(code, message) = first {
        return StoredRejection(code: code, reason: message)
    }
    return previous
}
