//
//  NetworkActivationHeights.swift
//  ZODLSwiftWalletSDK
//
//  Network-upgrade activation heights for a custom (regtest) network.
//

import Foundation

/// The activation heights of each Zcash network upgrade for a **custom / regtest** network, mirroring
/// the Rust core's `LocalNetwork`. A `nil` height means "not activated on this network".
///
/// Use this with ``ZcashNetworkBuilder/regtest(activationHeights:)`` to point the SDK at a
/// custom-parameter `lightwalletd` (for example an Ironwood testing backend) whose network upgrades
/// activate at arbitrary heights instead of the hardcoded mainnet/testnet values. See `MIGRATING.md`.
///
/// The heights are not validated by the SDK — set them to match the full node / `lightwalletd` you are
/// connecting to (mirroring that node's `nuparams`).
public struct NetworkActivationHeights: Equatable, Hashable, Sendable {
    public var overwinter: BlockHeight?
    public var sapling: BlockHeight?
    public var blossom: BlockHeight?
    public var heartwood: BlockHeight?
    public var canopy: BlockHeight?
    public var nu5: BlockHeight?
    public var nu6: BlockHeight?
    public var nu6_1: BlockHeight?
    public var nu6_2: BlockHeight?
    /// NU6.3 — the "Ironwood" (Orchard note-version V3) activation height.
    public var nu6_3: BlockHeight?

    public init(
        overwinter: BlockHeight? = nil,
        sapling: BlockHeight? = nil,
        blossom: BlockHeight? = nil,
        heartwood: BlockHeight? = nil,
        canopy: BlockHeight? = nil,
        nu5: BlockHeight? = nil,
        nu6: BlockHeight? = nil,
        nu6_1: BlockHeight? = nil,
        nu6_2: BlockHeight? = nil,
        nu6_3: BlockHeight? = nil
    ) {
        self.overwinter = overwinter
        self.sapling = sapling
        self.blossom = blossom
        self.heartwood = heartwood
        self.canopy = canopy
        self.nu5 = nu5
        self.nu6 = nu6
        self.nu6_1 = nu6_1
        self.nu6_2 = nu6_2
        self.nu6_3 = nu6_3
    }

    /// Every network upgrade active from height 1 — the default set used when a regtest network is
    /// built without explicit heights (``ZcashNetworkBuilder/network(for:)`` with ``NetworkType/regtest``).
    public static let allActiveFromGenesis = NetworkActivationHeights(
        overwinter: 1,
        sapling: 1,
        blossom: 1,
        heartwood: 1,
        canopy: 1,
        nu5: 1,
        nu6: 1,
        nu6_1: 1,
        nu6_2: 1,
        nu6_3: 1
    )
}
