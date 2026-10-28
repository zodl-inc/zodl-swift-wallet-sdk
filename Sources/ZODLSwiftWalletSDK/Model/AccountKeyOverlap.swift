//
//  AccountKeyOverlap.swift
//  ZODLSwiftWalletSDK
//

/// The account in the wallet that shares a viewing key component (Orchard, Sapling or transparent P2PKH) with a
/// ``UnifiedFullViewingKey``, and what importing that key would do to it.
///
/// ``Synchronizer/findAccountSharingKeyComponents(_:)`` reports it, so that a wallet can tell, before it imports a key,
/// that the import would not add an account.
public struct AccountKeyOverlap: Equatable {
    /// What importing the key would do to ``account``.
    public enum Kind: Equatable, Sendable {
        /// The account's viewing key already covers every item of the key: the key is identical to it, or carries a subset
        /// of its items. Importing the key fails.
        case alreadyImported

        /// The key carries every incoming viewing key item of the account, and something the account's viewing key does not
        /// cover: another item, or an item with a different outgoing viewing key. Importing the key adds no account: it
        /// replaces the account's viewing key with the key.
        case wouldUpgrade

        /// The key shares at least one component with the account, but lacks or changes another. Importing the key fails.
        case conflicting
    }

    /// The account that shares a viewing key component with the key.
    public let account: Account

    /// What importing the key would do to ``account``.
    public let kind: Kind

    /// Whether importing the key would fail: every kind except `wouldUpgrade`, which would instead
    /// widen `account`'s viewing key.
    public var importWouldFail: Bool { kind != .wouldUpgrade }
}
