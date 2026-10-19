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
    /// The submission to the endpoint failed at the transport level. An endpoint that has not
    /// answered at all has no `EndpointSubmission`.
    case failed

    /// The terminal refusal this answer is, if any.
    var rejection: SubmitRejection? {
        guard case let .refused(code, message) = self else { return nil }
        return SubmitRejection(code: code, message: message)
    }
}

/// A terminal rejection as the submit-plan store records it: the recorded terminal refusal's code
/// and message.
struct StoredRejection: Equatable {
    let code: Int
    let reason: String
}

/// The key an endpoint's answer is recorded under: `host:port`, as the store records an acceptance.
func endpointKey(_ endpoint: LightWalletEndpoint) -> String {
    "\(endpoint.host):\(endpoint.port)"
}

/// Whether a transaction is rejected, given what its endpoints answered: the rejection to record,
/// or `nil` when it stays pending and is resubmitted as before.
///
/// A node that explicitly refuses a transaction for good (a ``SubmitRejection``) has rejected it,
/// and that is reported as an error rather than left pending, but only once nothing else can still
/// take it. So it is rejected when every endpoint in `planEndpoints` has answered (accepted,
/// refused, or failed at the transport level), none of `outcomes` accepted it, and at least one is
/// a terminal refusal; a transient refusal or a transport failure beside it does not prevent the
/// verdict. An endpoint with no answer (still in flight at the deadline, or ended by cancellation)
/// may yet take the transaction, so it keeps the verdict pending: no new rejection is drawn and an
/// earlier one (`previous`) merely stands, as it does without a terminal refusal in `outcomes`,
/// until an acceptance clears it. The recorded rejection is the first terminal refusal in
/// `planEndpoints` order, then any other.
func submitRejectionVerdict(
    planEndpoints: [LightWalletEndpoint],
    outcomes: [String: EndpointSubmission],
    previous: StoredRejection?
) -> StoredRejection? {
    guard !outcomes.values.contains(.accepted) else { return nil }
    guard planEndpoints.allSatisfy({ outcomes[endpointKey($0)] != nil }) else { return previous }
    let ordered = planEndpoints.compactMap { outcomes[endpointKey($0)] }
        + outcomes.keys.sorted().filter { key in !planEndpoints.contains { endpointKey($0) == key } }.compactMap { outcomes[$0] }
    if case let .refused(code, message) = ordered.first(where: { $0.rejection != nil }) {
        return StoredRejection(code: code, reason: message)
    }
    return previous
}
