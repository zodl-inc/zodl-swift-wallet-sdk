//
//  ServerBlockHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// Heights from lightwalletd arrive as `UInt64`, and the SDK's Rust FFI takes them as `Int32`, so
/// `BlockHeight(serverHeight:)` is what turns one into a `BlockHeight`. A value it rejects can only
/// come from a broken or hostile server, and converting it with a trapping initializer would crash
/// the app.
final class ServerBlockHeightTests: XCTestCase {
    func testZeroConverts() {
        XCTAssertEqual(BlockHeight(serverHeight: 0), 0)
    }

    func testARealisticHeightConverts() {
        XCTAssertEqual(BlockHeight(serverHeight: 3_000_000), 3_000_000)
    }

    func testInt32MaxConverts() {
        XCTAssertEqual(BlockHeight(serverHeight: UInt64(Int32.max)), BlockHeight(Int32.max))
    }

    func testOneAboveInt32MaxIsRejected() {
        XCTAssertNil(BlockHeight(serverHeight: UInt64(Int32.max) + 1))
    }

    func testUInt32MaxIsRejected() {
        XCTAssertNil(BlockHeight(serverHeight: UInt64(UInt32.max)))
    }

    func testTwoToThe63IsRejected() {
        XCTAssertNil(BlockHeight(serverHeight: UInt64(Int64.max) + 1))
    }

    func testUInt64MaxIsRejected() {
        XCTAssertNil(BlockHeight(serverHeight: UInt64.max))
    }

    // MARK: - The height a transaction is mined at

    // lightwalletd reports 0 for a transaction in the mempool and `UInt64.max` for one that was mined on a fork.
    // A height the SDK can't use is not a block the SDK can look at either, so it counts the same way.

    func testMinedHeightConvertsAUsableHeight() {
        XCTAssertEqual(BlockHeight(minedServerHeight: 1), 1)
        XCTAssertEqual(BlockHeight(minedServerHeight: 3_000_000), 3_000_000)
        XCTAssertEqual(BlockHeight(minedServerHeight: UInt64(Int32.max)), BlockHeight(Int32.max))
    }

    func testMinedHeightIsNilForATransactionInTheMempool() {
        XCTAssertNil(BlockHeight(minedServerHeight: 0))
    }

    func testMinedHeightIsNilForATransactionMinedOnAFork() {
        XCTAssertNil(BlockHeight(minedServerHeight: UInt64.max))
    }

    func testMinedHeightIsNilAboveInt32Max() {
        for height in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64(Int64.max) + 1] {
            XCTAssertNil(BlockHeight(minedServerHeight: height), "\(height)")
        }
    }
}
