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

/// Whether a transaction is rejected, given what its endpoints just answered: the rejection to
/// record, or `nil` when it stays pending and is resubmitted as before.
///
/// A node that explicitly refuses a transaction for good (a ``SubmitRejection``) has rejected it,
/// and that is reported as an error rather than left pending. So it is rejected when none of
/// `outcomes` accepted it and at least one is a terminal refusal; an endpoint that did not answer,
/// timed out, failed at the transport level or refused transiently neither counts as an
/// acceptance nor prevents the verdict. Without a terminal refusal in `outcomes` an earlier
/// rejection (`previous`) stands, until an acceptance clears it. The recorded rejection is the
/// first terminal refusal in `planEndpoints` order, then any other.
func submitRejectionVerdict(
    planEndpoints: [LightWalletEndpoint],
    outcomes: [String: EndpointSubmission],
    previous: StoredRejection?
) -> StoredRejection? {
    guard !outcomes.values.contains(.accepted) else { return nil }
    let ordered = planEndpoints.compactMap { outcomes[endpointKey($0)] }
        + outcomes.keys.sorted().filter { key in !planEndpoints.contains { endpointKey($0) == key } }.compactMap { outcomes[$0] }
    if case let .refused(code, message) = ordered.first(where: { $0.rejection != nil }) {
        return StoredRejection(code: code, reason: message)
    }
    return previous
}
