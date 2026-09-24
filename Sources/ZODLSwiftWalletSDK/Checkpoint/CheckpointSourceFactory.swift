//
//  CheckpointSourceFactory.swift
//
//
//  Created by Francisco Gindre on 2023-10-30.
//

import Foundation

enum CheckpointSourceFactory {
    static func fromBundle(
        for network: NetworkType,
        regtestActivationHeights: NetworkActivationHeights? = nil
    ) -> CheckpointSource {
        switch network {
        case .mainnet, .testnet:
            return BundleCheckpointSource(network: network)
        case .regtest:
            // Regtest ships no bundled checkpoints; the birthday floor is a synthesized empty-tree
            // checkpoint at the configured Sapling activation height (default 1).
            let saplingHeight = regtestActivationHeights?.sapling ?? 1
            return RegtestCheckpointSource(saplingActivation: .regtestMin(saplingHeight: saplingHeight))
        }
    }
}
