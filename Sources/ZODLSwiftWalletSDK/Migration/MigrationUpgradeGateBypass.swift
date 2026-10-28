//
//  MigrationUpgradeGateBypass.swift
//  ZODLSwiftWalletSDK
//

import Foundation
import os

/// The host's opt-out of the NU7 network-upgrade gate, held in one place so that one switch reaches
/// every backend that reads it.
///
/// The gate keeps the migration from starting, or driving, a run that the upgrade would strand; the
/// bypass is for internal builds that need to exercise the migration on a network before the
/// upgrade activates. It is off unless a host turns it on, and a production build never does.
///
/// Each account's migration builds its own `ZcashRustBackend`, so a flag stored in a backend would
/// reach only that account. The ``OrchardMigrationHost`` instead owns one holder, hands it to every
/// migration it builds, and each backend reads it on every gated FFI call. Setting it therefore
/// reaches migrations that already exist and the ones built later, and no gated welding signature
/// has to carry the flag.
///
/// - Note: The bypass lifts the pause on new scheduled work. It does not lift the check that keeps
///   a transaction the next block cannot include from being submitted, nor the detection of a run
///   the upgrade has stranded.
final class MigrationUpgradeGateBypass: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Whether the gate is bypassed.
    var isBypassed: Bool {
        state.withLock { $0 }
    }

    /// Turns the bypass on or off, for every reader of this holder, from its next gated call on.
    func setBypassed(_ isBypassed: Bool) {
        state.withLock { $0 = isBypassed }
    }
}
