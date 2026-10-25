//
//  UnifiedFullViewingKeyComponents.swift
//  ZODLSwiftWalletSDK
//

/// The kinds of item a ``UnifiedFullViewingKey`` carries.
///
/// ``DerivationTool/describeUnifiedFullViewingKey(_:)`` reports them, so that a wallet can check
/// that a key it was handed has the items it needs before it uses the key, for instance an Orchard
/// item.
public struct UnifiedFullViewingKeyComponents: Equatable, Sendable {
    /// The key carries a transparent P2PKH item.
    public let hasP2pkh: Bool

    /// The key carries a transparent P2SH item.
    public let hasP2sh: Bool

    /// The key carries a Sapling item.
    public let hasSapling: Bool

    /// The key carries an Orchard item.
    public let hasOrchard: Bool

    /// The key carries at least one item of a type this version of the SDK does not recognize.
    public let hasUnknownItems: Bool

    /// The key carries a transparent item of either kind.
    public var hasTransparent: Bool { hasP2pkh || hasP2sh }

    /// The bits of the mask `zcashlc_describe_unified_full_viewing_key` returns for a key.
    ///
    /// Only that function's documentation defines the values: the C header exports no constants for
    /// them, so a test pins this mapping.
    private enum Bit {
        static let p2pkh: Int32 = 1
        static let p2sh: Int32 = 2
        static let sapling: Int32 = 4
        static let orchard: Int32 = 8
        static let unknown: Int32 = 16
    }

    /// Maps the mask `zcashlc_describe_unified_full_viewing_key` returns for a key. A bit that the
    /// mask does not define is ignored.
    init(bitmask: Int32) {
        hasP2pkh = bitmask & Bit.p2pkh != 0
        hasP2sh = bitmask & Bit.p2sh != 0
        hasSapling = bitmask & Bit.sapling != 0
        hasOrchard = bitmask & Bit.orchard != 0
        hasUnknownItems = bitmask & Bit.unknown != 0
    }
}
