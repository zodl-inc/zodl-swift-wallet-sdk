//
//  Checkpoint+regtest.swift
//  ZODLSwiftWalletSDK
//
//  Birthday floor for a custom (regtest) network, which ships no bundled checkpoints.
//

import Foundation

extension Checkpoint {
    /// Regtest ships no bundled checkpoints; this directory intentionally does not exist, so bundle
    /// lookups fall back to the synthesized ``regtestMin(saplingHeight:)`` floor.
    static let regtestCheckpointDirectory = Bundle.module.bundleURL.appendingPathComponent("checkpoints/regtest/")

    /// A synthesized empty-tree birthday floor for a regtest network at its Sapling activation height.
    ///
    /// A fresh regtest wallet scans from Sapling activation, where every note-commitment tree is empty.
    /// `hash`/`time` are placeholders — for a birthday above genesis, seed a real tree state via
    /// `Synchronizer.getTreeState(height:)`. See `docs/handoffs/ZODL-regtest-activation-heights.md`.
    static func regtestMin(saplingHeight: BlockHeight) -> Checkpoint {
        Checkpoint(
            height: saplingHeight,
            hash: "0000000000000000000000000000000000000000000000000000000000000000",
            time: 0,
            saplingTree: "000000",
            orchardTree: nil,
            ironwoodTree: nil
        )
    }
}
