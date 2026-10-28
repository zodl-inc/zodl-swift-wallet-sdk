//
//  DescribeUnifiedFullViewingKeyTests.swift
//  OfflineTests
//
//  What `DerivationTool.describeUnifiedFullViewingKey(_:)` reports about the items a unified full
//  viewing key carries, and how the rust layer's bitmask maps onto `UnifiedFullViewingKeyComponents`.
//

import Testing
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

@Suite
struct DescribeUnifiedFullViewingKeyTests {
    /// A testnet unified full viewing key with a transparent and a Sapling item but no Orchard item,
    /// derived once, offline, from the all-`0x01` 32-byte seed -- nothing here ties it to a real
    /// wallet or device.
    ///
    /// The same key is `testnetUFVKWithNoOrchardItem` in `LedgerTests`, which keeps it private.
    private static let testnetUFVKWithNoOrchardItem = """
    uviewtest1pfe0uls0td9a3zvqchscp9yvv2wumu6873hg8pqfe86tqlhsq60xdspfedc90j8y4fwfshtss3xahmhcwwxr8cugndfh9hsr4\
    sq3a8pvdezz48d57s7y87uv46dyvllsfaj4n24u9mejfpelsrvfuthp6j7lnf54qw0yq57ramzqrd0rt6s9sksseqqxrjf0d3vuj7nwnqkc\
    tsrw3xs2vgc5lrtr358hxhwg9ec5jr9hvatt95mech7p249znhjk5vgytkhvllakczp5v29fvmx8jnj4hee3sj0t5ytdk30ns5r5s2kcth2\
    e30h7gpany3nhxd9ycus6rarwy634zejy0ht
    """

    private let tool = DerivationTool(networkType: .testnet)

    /// The testnet key of account 0 of the seed the derivation tool tests use.
    private func seedDerivedKey() throws -> UnifiedFullViewingKey {
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    // MARK: - Describing a key

    @Test
    func seedDerivedKeyHasEveryComponent() throws {
        let ufvk = try seedDerivedKey()
        let components = try #require(try tool.describeUnifiedFullViewingKey(ufvk))
        #expect(components.hasOrchard && components.hasSapling && components.hasP2pkh)
        #expect(!components.hasP2sh && !components.hasUnknownItems)
        #expect(components.hasTransparent)
    }

    @Test
    func keyWithoutOrchardIsReported() throws {
        let ufvk = try UnifiedFullViewingKey(encoding: Self.testnetUFVKWithNoOrchardItem, network: .testnet)
        let components = try #require(try tool.describeUnifiedFullViewingKey(ufvk))
        #expect(!components.hasOrchard)
        #expect(components.hasSapling)
        #expect(components.hasTransparent)
    }

    @Test
    func keyOfTheOtherNetworkIsNil() throws {
        let ufvk = try seedDerivedKey()
        #expect(try DerivationTool(networkType: .mainnet).describeUnifiedFullViewingKey(ufvk) == nil)
    }

    /// `UnifiedFullViewingKey`'s public initialiser refuses an encoding with a null byte, but a key built
    /// inside the SDK skips that check. Without the guard, the rust layer would read only the valid key in
    /// front of the null byte and describe it, so a key followed by a null byte and more text would pass
    /// for a key.
    @Test
    func keyWithAnEmbeddedNullByteIsNil() throws {
        let backend = ZcashKeyDerivationBackend(networkType: .testnet)
        let ufvk = try seedDerivedKey()
        let withNullByte = UnifiedFullViewingKey(validatedEncoding: "\(ufvk.stringEncoded)\u{0}trailing")

        #expect(try backend.describeUnifiedFullViewingKey(ufvk) != nil)
        #expect(try backend.describeUnifiedFullViewingKey(withNullByte) == nil)
    }

    // MARK: - Mapping of the rust layer's bitmask

    /// The bit values are defined only in the documentation of `zcashlc_describe_unified_full_viewing_key`:
    /// the C header exports no constants for them. This test is what notices a mapping that drifted from
    /// the rust layer.
    @Test
    func eachBitSetsExactlyItsOwnFlag() {
        #expect(setFlags(in: 1) == ["p2pkh"])
        #expect(setFlags(in: 2) == ["p2sh"])
        #expect(setFlags(in: 4) == ["sapling"])
        #expect(setFlags(in: 8) == ["orchard"])
        #expect(setFlags(in: 16) == ["unknown"])
    }

    @Test
    func severalBitsSetSeveralFlags() {
        #expect(setFlags(in: 1 | 4 | 8) == ["p2pkh", "sapling", "orchard"])
        #expect(setFlags(in: 2 | 16) == ["p2sh", "unknown"])
        #expect(setFlags(in: 31) == ["p2pkh", "p2sh", "sapling", "orchard", "unknown"])
        #expect(setFlags(in: 0).isEmpty)
    }

    @Test
    func transparentMeansP2pkhOrP2sh() {
        #expect(UnifiedFullViewingKeyComponents(bitmask: 1).hasTransparent)
        #expect(UnifiedFullViewingKeyComponents(bitmask: 2).hasTransparent)
        #expect(UnifiedFullViewingKeyComponents(bitmask: 3).hasTransparent)
        #expect(!UnifiedFullViewingKeyComponents(bitmask: 4 | 8 | 16).hasTransparent)
        #expect(!UnifiedFullViewingKeyComponents(bitmask: 0).hasTransparent)
    }

    /// The names of the flags that `UnifiedFullViewingKeyComponents(bitmask:)` sets for `bitmask`.
    private func setFlags(in bitmask: Int32) -> [String] {
        let components = UnifiedFullViewingKeyComponents(bitmask: bitmask)
        let named = [
            ("p2pkh", components.hasP2pkh),
            ("p2sh", components.hasP2sh),
            ("sapling", components.hasSapling),
            ("orchard", components.hasOrchard),
            ("unknown", components.hasUnknownItems)
        ]
        return named.filter { $0.1 }.map { $0.0 }
    }
}
