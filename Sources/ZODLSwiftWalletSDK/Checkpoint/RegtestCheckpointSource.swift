//
//  RegtestCheckpointSource.swift
//  ZODLSwiftWalletSDK
//
//  Checkpoint source for regtest / custom-parameter networks, which ship no bundled checkpoints.
//

import Foundation

/// A ``CheckpointSource`` for regtest / custom-parameter networks. Regtest ships no bundled checkpoints,
/// so every lookup returns the synthesized empty-tree floor at the network's Sapling activation height —
/// a regtest wallet scans from Sapling activation. For a higher birthday, seed a real tree state via
/// `Synchronizer.getTreeState(height:)`. See `docs/handoffs/ZODL-regtest-activation-heights.md`.
struct RegtestCheckpointSource: CheckpointSource {
    let network: NetworkType = .regtest
    let saplingActivation: Checkpoint

    func latestKnownCheckpoint() -> Checkpoint {
        saplingActivation
    }

    func birthday(for height: BlockHeight) -> Checkpoint {
        saplingActivation
    }

    func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        saplingActivation.height
    }

    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        nil
    }
}
