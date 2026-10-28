//
//  ServerReportedHeightMappingTests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// Compact blocks and UTXOs arrive from lightwalletd with a `UInt64` height. The SDK stores the
/// compact block's height as a `BlockHeight`, and hands both heights to the rust backend as 32-bit
/// values, so a height beyond `Int32.max` has to be refused where the server's message becomes an
/// SDK type, instead of trapping in a later conversion. The same goes for the height that the
/// Slipstream engine's restore anchor passes on from its server.
final class ServerReportedHeightMappingTests: XCTestCase {
    // MARK: - Compact blocks

    func testCompactBlockAtInt32MaxIsConverted() throws {
        let block = try ZcashCompactBlock(compactBlock: Self.compactBlock(height: UInt64(Int32.max)))

        XCTAssertEqual(block.height, BlockHeight(Int32.max))
        XCTAssertEqual(block.meta.time, Self.blockTime)
    }

    func testCompactBlockJustAboveInt32MaxIsRejected() {
        assertCompactBlockIsRejected(height: UInt64(Int32.max) + 1)
    }

    func testCompactBlockAtUInt32MaxIsRejected() {
        assertCompactBlockIsRejected(height: UInt64(UInt32.max))
    }

    func testCompactBlockAtUInt64MaxIsRejected() {
        assertCompactBlockIsRejected(height: UInt64.max)
    }

    private func assertCompactBlockIsRejected(height: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ZcashCompactBlock(compactBlock: Self.compactBlock(height: height)), file: file, line: line) { error in
            guard case LightWalletServiceError.generalError = error else {
                XCTFail("Expected LightWalletServiceError.generalError but got \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - UTXOs

    func testUTXOAtInt32MaxIsMapped() throws {
        let reply = Self.utxoReply(height: UInt64(Int32.max))

        let utxo = try UTXO(reply: reply)

        XCTAssertEqual(utxo.height, BlockHeight(Int32.max))
        XCTAssertEqual(utxo.address, reply.address)
        XCTAssertEqual(utxo.txid, reply.txid)
        XCTAssertEqual(utxo.index, Int(reply.index))
        XCTAssertEqual(utxo.script, reply.script)
        XCTAssertEqual(utxo.valueZat, Int(reply.valueZat))
    }

    func testUTXOJustAboveInt32MaxIsRejected() {
        assertUTXOIsRejected(height: UInt64(Int32.max) + 1)
    }

    func testUTXOAtUInt32MaxIsRejected() {
        assertUTXOIsRejected(height: UInt64(UInt32.max))
    }

    func testUTXOAtUInt64MaxIsRejected() {
        assertUTXOIsRejected(height: UInt64.max)
    }

    private func assertUTXOIsRejected(height: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UTXO(reply: Self.utxoReply(height: height)), file: file, line: line) { error in
            guard case LightWalletServiceError.generalError = error else {
                XCTFail("Expected LightWalletServiceError.generalError but got \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - Slipstream restore anchor

    /// The Slipstream engine's `restore_anchor` passes the height it got from the server on unchecked.
    func testRestoreAnchorAtInt32MaxKeepsItsTreeState() {
        var treeState = TreeState()
        treeState.height = UInt64(Int32.max)

        let anchor = SlipstreamRestoreAnchor(serverHeight: UInt64(Int32.max), treeState: treeState)

        XCTAssertEqual(anchor?.height, BlockHeight(Int32.max))
        XCTAssertEqual(anchor?.treeState, treeState)
    }

    func testRestoreAnchorWithoutATreeStateIsKept() {
        let anchor = SlipstreamRestoreAnchor(serverHeight: 3_000_000, treeState: nil)

        XCTAssertEqual(anchor?.height, 3_000_000)
        XCTAssertNil(anchor?.treeState)
    }

    func testRestoreAnchorAboveInt32MaxIsUnusable() {
        for height in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertNil(SlipstreamRestoreAnchor(serverHeight: height, treeState: nil), "\(height)")
        }
    }

    // MARK: - Fixtures

    private static let blockTime: UInt32 = 1_700_000_000

    private static func compactBlock(height: UInt64) -> CompactBlock {
        var block = CompactBlock()
        block.height = height
        block.hash = Data(repeating: 0x11, count: 32)
        block.time = blockTime
        return block
    }

    private static func utxoReply(height: UInt64) -> GetAddressUtxosReply {
        var reply = GetAddressUtxosReply()
        reply.address = "tmExampleTransparentAddress"
        reply.txid = Data(repeating: 0x22, count: 32)
        reply.index = 3
        reply.script = Data([0x76, 0xa9])
        reply.valueZat = 4_200
        reply.height = height
        return reply
    }
}
