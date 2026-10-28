//
//  FetchedTransactionHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// `LightWalletService.fetchTransaction` turns the height a server reports for a transaction into the mined
/// height and the status the rest of the SDK works with. Both the gRPC service and `TorLwdConn` (which needs a
/// live Tor connection, so it can't be exercised here) answer through `ZcashTransaction.Fetched.returned`.
/// A transaction counts as mined only at a height the SDK can use, and every other height, whether it is the
/// mempool's 0, the `UInt64.max` of a transaction mined on a fork, or a height only a broken or hostile server
/// reports, leaves it unmined.
final class FetchedTransactionHeightTests: XCTestCase {
    private let rawID = Data(repeating: 0xAB, count: 32)
    private let raw = Data([0x04, 0x00, 0x00, 0x80])

    func testATransactionAtAUsableHeightIsMined() {
        let result = ZcashTransaction.Fetched.returned(rawID: rawID, raw: raw, atServerHeight: 663_188)

        XCTAssertEqual(result.status, .mined(663_188))
        XCTAssertEqual(result.tx, ZcashTransaction.Fetched(rawID: rawID, minedHeight: 663_188, raw: raw))
    }

    func testATransactionAtInt32MaxIsMined() {
        let result = ZcashTransaction.Fetched.returned(rawID: rawID, raw: raw, atServerHeight: UInt64(Int32.max))

        XCTAssertEqual(result.status, .mined(BlockHeight(Int32.max)))
        XCTAssertEqual(result.tx.minedHeight, UInt32(Int32.max))
    }

    func testATransactionInTheMempoolIsNotInMainChain() {
        let result = ZcashTransaction.Fetched.returned(rawID: rawID, raw: raw, atServerHeight: 0)

        XCTAssertEqual(result.status, .notInMainChain)
        XCTAssertEqual(result.tx, ZcashTransaction.Fetched(rawID: rawID, minedHeight: nil, raw: raw))
    }

    func testATransactionAboveInt32MaxIsNotInMainChainButStillReturned() {
        for height in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64(Int64.max) + 1, UInt64.max] {
            let result = ZcashTransaction.Fetched.returned(rawID: rawID, raw: raw, atServerHeight: height)

            XCTAssertEqual(result.status, .notInMainChain, "\(height)")
            XCTAssertEqual(result.tx, ZcashTransaction.Fetched(rawID: rawID, minedHeight: nil, raw: raw), "\(height)")
        }
    }
}
