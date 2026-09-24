//
//  TransactionOutputPoolTests.swift
//
//  Pins the wallet-database pool codes `ZcashTransaction.Output.Pool` decodes, which must track
//  `zcash_client_sqlite`'s `pool_code` (transparent 0, Sapling 2, Orchard 3, Ironwood 4).
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class TransactionOutputPoolTests: XCTestCase {
    func testKnownPoolCodesDecodeToTheirOwnCase() {
        XCTAssertEqual(ZcashTransaction.Output.Pool(rawValue: 0), .transaparent)
        XCTAssertEqual(ZcashTransaction.Output.Pool(rawValue: 2), .sapling)
        XCTAssertEqual(ZcashTransaction.Output.Pool(rawValue: 3), .orchard)
    }

    /// Every shielded output a wallet receives after NU6.3 activation lands in Ironwood, so this
    /// is the common case post-activation — it used to decode as `.other(4)`.
    func testIronwoodPoolCodeDecodesToIronwood() {
        XCTAssertEqual(ZcashTransaction.Output.Pool(rawValue: 4), .ironwood)
    }

    func testUnknownPoolCodeIsCarriedThroughVerbatim() {
        XCTAssertEqual(ZcashTransaction.Output.Pool(rawValue: 7), .other(7))
    }
}
