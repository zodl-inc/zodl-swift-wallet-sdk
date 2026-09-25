//
//  LocalBalanceRefreshPolicy.swift
//  ZcashLightClientKit
//

import Foundation

/// When the Slipstream poll tick re-reads the local (unmasked) balances.
///
/// The read is a full `get_wallet_summary` walk over the wallet database. It used to run on every two-second tick,
/// although the balances it produces only move when the wallet's notes do. The tick now re-reads them when something
/// that can move them changed — the transaction set, the engine's visible summary, or the recovery phase — and
/// otherwise at least every ``maximumAge`` seconds, as a backstop for a change none of those signals catches.
///
/// The age is measured on the system's uptime clock (`ProcessInfo.processInfo.systemUptime`), not the wall clock, so
/// setting the device's clock back cannot hold the backstop off.
struct LocalBalanceRefreshPolicy {
    static let maximumAge: TimeInterval = 10

    private var lastRefresh: TimeInterval?
    private var lastTxSetVersion: UInt64?
    private var lastVisibleSummary: WalletSummary?
    private var lastIsRecovering: Bool?

    func shouldRefresh(txSetVersion: UInt64, visibleSummary: WalletSummary?, isRecovering: Bool, now: TimeInterval) -> Bool {
        guard let lastRefresh else { return true }
        return txSetVersion != lastTxSetVersion
            || visibleSummary != lastVisibleSummary
            || isRecovering != lastIsRecovering
            || now - lastRefresh >= Self.maximumAge
    }

    mutating func recordRefresh(txSetVersion: UInt64, visibleSummary: WalletSummary?, isRecovering: Bool, at now: TimeInterval) {
        lastRefresh = now
        lastTxSetVersion = txSetVersion
        lastVisibleSummary = visibleSummary
        lastIsRecovering = isRecovering
    }
}
