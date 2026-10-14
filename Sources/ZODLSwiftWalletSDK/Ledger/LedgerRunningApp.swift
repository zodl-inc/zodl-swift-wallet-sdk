//
//  LedgerRunningApp.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// The app a Ledger device is running, as its dashboard query reports it.
public struct LedgerRunningApp: Equatable, Sendable {
    /// The app's name: `Zcash` for the Zcash app, `BOLOS` (or a truncated form of it on some
    /// firmware) for the device's dashboard.
    public let name: String

    /// The app's version, as the device reports it.
    public let version: String

    init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// Whether the device is on its dashboard, running no app.
    public var isDashboard: Bool {
        Self.dashboardNames.contains(name)
    }

    /// Whether the device is running the Zcash app.
    public var isZcash: Bool {
        name == Self.zcashAppName
    }

    /// The name the Zcash app reports, and the name the device opens it by.
    static let zcashAppName = "Zcash"

    /// The names the device's dashboard reports, across firmware versions.
    private static let dashboardNames: Set<String> = ["BOLOS", "OLOS", "OLOS\u{0}"]
}
