//
//  Zip317.swift
//  ZcashLightClientKit
//

import Foundation

/// Constants of the [ZIP 317](https://zips.z.cash/zip-0317) fee rule, as librustzcash defines
/// them.
public enum Zip317 {
    /// The fee charged per logical action beyond the grace actions.
    ///
    /// A note worth no more than this costs at least as much to spend as it carries, so the SDK
    /// leaves such notes out of note selection. The value is read from librustzcash, so a wallet
    /// need not hardcode it. Stateless: safe to read before any ``Synchronizer`` exists.
    public static let marginalFee: Zatoshi = ZcashRustBackend.zip317MarginalFee()
}
