//
//  OvkPolicy.swift
//  ZcashLightClientKit
//

/// How a created transaction's shielded outputs are encrypted to an outgoing viewing key (OVK).
///
/// The OVK lets the holder of a wallet's viewing keys recover the recipients, amounts and memos
/// of the wallet's own outgoing payments from the chain, for instance after restoring from seed.
public enum OvkPolicy: Equatable, Sendable {
    /// Encrypt outputs to the sending account's OVK. Anyone holding the account's full viewing key
    /// or seed can later recover the recipients, amounts and memos of these transactions. This is
    /// the default for every transaction the SDK creates.
    case sender

    /// Encrypt outputs to no OVK. Once created, the outputs can only be read by their recipients:
    /// not even the sending wallet's own seed recovers who was paid. The sending wallet keeps its
    /// local record of the transaction, but a wallet restored from the same seed shows it without
    /// recipients or amounts.
    ///
    /// Use it when other parties may hold the sending account's keys and must not learn where the
    /// funds went, such as when sweeping a gift card whose key its issuer can rederive.
    case discard

    /// The value `zcashlc_create_proposed_transactions` expects for this policy.
    var ffiValue: UInt32 {
        switch self {
        case .sender: return 0
        case .discard: return 1
        }
    }
}
