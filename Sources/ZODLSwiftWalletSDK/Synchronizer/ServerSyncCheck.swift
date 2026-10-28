//
//  ServerSyncCheck.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// The loose "is this server synced?" check both server benchmarks apply to a candidate's `getInfo`:
/// a tip that trails the server's own chain-tip estimate by too much means it is syncing, stuck, or
/// probably on the wrong fork.
enum ServerSyncCheck {
    /// Six hours of target block time, the 288 blocks the check allowed at 75-second blocks. Loose
    /// because `estimatedHeight` may be quite inaccurate, and measured in time so it keeps its meaning
    /// when NU7 shortens blocks to 25 seconds.
    static let maxTipLag: TimeInterval = 6 * 60 * 60

    /// Whether a server reporting `blockHeight` as its tip and `estimatedHeight` as the chain's is close
    /// enough to serve a wallet. A tip at or past the estimate passes.
    static func isSynced(blockHeight: UInt64, estimatedHeight: UInt64, spacing: TargetBlockSpacing) -> Bool {
        spacing.seconds(from: BlockHeight(clamping: blockHeight), to: BlockHeight(clamping: estimatedHeight)) <= maxTipLag
    }
}
