//
//  TransactionSizeBound.swift
//  ZODLSwiftWalletSDK
//

import Foundation
import libzcashlc

/// Caps that hold a proposal's transactions below what consensus allows.
///
/// Consensus limits a transaction to the size of a block, and the SDK always enforces that. A
/// wallet often needs a tighter bound: relays refuse transactions well below a block, proving a
/// transaction takes memory in proportion to its shielded actions, and an external signer can
/// only sign so many inputs or outputs in one transaction. Pass a bound to
/// `Synchronizer.proposeSendMax(accountUUID:recipient:memo:mode:sizeBound:)` and the other
/// proposal and creation calls that take one; a proposal that exceeds it throws
/// ``ZcashError/rustProposalTransactionTooLarge``, the same error a transaction too large for a
/// block throws. A send-max is never cut down to fit: it sends everything spendable or fails.
///
/// Every cap is optional; `nil` leaves that dimension to consensus. ``consensus`` caps nothing.
/// Combine bounds from different sources with ``intersect(_:)``.
///
/// The counts are librustzcash's: actions are those the transaction builder produces, padding
/// included (the ZIP 218 measure), and the byte size is its conservative estimate of the
/// serialized transactions.
public struct TransactionSizeBound: Equatable, Hashable {
    /// The estimated serialized size of each transaction, in bytes. A cap above a block is a block.
    public var maxBytes: Int?
    /// Sapling, Orchard and Ironwood actions together, in each transaction.
    public var maxShieldedActions: Int?
    /// Sapling spends and outputs in each transaction. `0` forbids the Sapling pool.
    public var maxSaplingActions: Int?
    /// Orchard actions in each transaction. `0` forbids the Orchard pool.
    public var maxOrchardActions: Int?
    /// Ironwood actions in each transaction. `0` forbids the Ironwood pool.
    public var maxIronwoodActions: Int?
    /// Transparent inputs in each transaction.
    public var maxTransparentInputs: Int?
    /// Transparent outputs in each transaction, change included.
    public var maxTransparentOutputs: Int?
    /// Shielded outputs in each transaction that pay a recipient, as opposed to change.
    public var maxShieldedPaymentOutputs: Int?

    /// No cap beyond consensus. This is what every call taking a bound uses by default, and what
    /// those calls did before they took one.
    public static let consensus = TransactionSizeBound()

    /// A bound with the given caps; each omitted cap is left to consensus. A negative cap is
    /// treated as `0`.
    public init(
        maxBytes: Int? = nil,
        maxShieldedActions: Int? = nil,
        maxSaplingActions: Int? = nil,
        maxOrchardActions: Int? = nil,
        maxIronwoodActions: Int? = nil,
        maxTransparentInputs: Int? = nil,
        maxTransparentOutputs: Int? = nil,
        maxShieldedPaymentOutputs: Int? = nil
    ) {
        self.maxBytes = maxBytes
        self.maxShieldedActions = maxShieldedActions
        self.maxSaplingActions = maxSaplingActions
        self.maxOrchardActions = maxOrchardActions
        self.maxIronwoodActions = maxIronwoodActions
        self.maxTransparentInputs = maxTransparentInputs
        self.maxTransparentOutputs = maxTransparentOutputs
        self.maxShieldedPaymentOutputs = maxShieldedPaymentOutputs
    }

    /// The tighter of `self` and `other` in every dimension, so that, for instance, a relay
    /// bound, a proving-memory bound and a signer's bound can be combined into one.
    public func intersect(_ other: TransactionSizeBound) -> TransactionSizeBound {
        func tighter(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return min(lhs, rhs)
        }
        return TransactionSizeBound(
            maxBytes: tighter(maxBytes, other.maxBytes),
            maxShieldedActions: tighter(maxShieldedActions, other.maxShieldedActions),
            maxSaplingActions: tighter(maxSaplingActions, other.maxSaplingActions),
            maxOrchardActions: tighter(maxOrchardActions, other.maxOrchardActions),
            maxIronwoodActions: tighter(maxIronwoodActions, other.maxIronwoodActions),
            maxTransparentInputs: tighter(maxTransparentInputs, other.maxTransparentInputs),
            maxTransparentOutputs: tighter(maxTransparentOutputs, other.maxTransparentOutputs),
            maxShieldedPaymentOutputs: tighter(maxShieldedPaymentOutputs, other.maxShieldedPaymentOutputs)
        )
    }
}

extension TransactionSizeBound {
    /// The memory proving takes regardless of the transaction, in bytes.
    public static let provingBaselineBytes: UInt64 = 550 * 1024 * 1024
    /// The memory proving takes for each shielded action, in bytes.
    public static let provingBytesPerAction: UInt64 = 20 * 1024 * 1024
    /// The most shielded actions ``forProvingMemory(availableBytes:)`` admits however much memory
    /// is available: about what a relay's 250 kB transaction limit admits.
    public static let maxProvingActions = 75
    /// The fewest shielded actions ``forProvingMemory(availableBytes:)`` admits, however little
    /// memory is reported, so that an ordinary small payment is never refused on memory grounds.
    /// An app that wants a lower cap intersects the result with its own bound.
    public static let minProvingActions = 16

    /// The bound on shielded actions under which proving a transaction fits in `availableBytes` of
    /// memory: `(availableBytes - provingBaselineBytes) / provingBytesPerAction`, rounded down, at
    /// most ``maxProvingActions`` and at least ``minProvingActions``.
    ///
    /// This is the only sizing policy in the SDK. Which memory figure to pass (for instance what
    /// `os_proc_available_memory()` reports when the payment is proposed, or a per-device profile),
    /// and any floor below which the app would rather try anyway, is the app's decision. Intersect
    /// the result with any other bound that applies.
    public static func forProvingMemory(availableBytes: UInt64) -> TransactionSizeBound {
        let spare = availableBytes > provingBaselineBytes ? availableBytes - provingBaselineBytes : 0
        let actions = min(max(Int(clamping: spare / provingBytesPerAction), minProvingActions), maxProvingActions)
        return TransactionSizeBound(maxShieldedActions: actions)
    }

    /// The bound as the rust layer takes it: `-1` for each cap left to consensus.
    var ffiValue: FfiTransactionSizeBound {
        func cap(_ value: Int?) -> Int64 {
            guard let value else { return -1 }
            return Int64(max(value, 0))
        }
        return FfiTransactionSizeBound(
            max_bytes: cap(maxBytes),
            max_shielded_actions: cap(maxShieldedActions),
            max_sapling_actions: cap(maxSaplingActions),
            max_orchard_actions: cap(maxOrchardActions),
            max_ironwood_actions: cap(maxIronwoodActions),
            max_transparent_inputs: cap(maxTransparentInputs),
            max_transparent_outputs: cap(maxTransparentOutputs),
            max_shielded_payment_outputs: cap(maxShieldedPaymentOutputs)
        )
    }
}

/// Thrown by the default `sizeBound:` overloads of `Synchronizer` when a conformer that does not
/// override them is asked for a bound other than ``TransactionSizeBound/consensus``: it refuses
/// rather than silently propose or create something the caller asked to bound.
struct SizeBoundUnsupported: LocalizedError {
    /// The member that has no bounded implementation.
    let member: String

    var errorDescription: String? {
        """
        \(member) has no implementation for a TransactionSizeBound other than .consensus. \
        Override it in your conformer to support bounding proposals.
        """
    }
}
