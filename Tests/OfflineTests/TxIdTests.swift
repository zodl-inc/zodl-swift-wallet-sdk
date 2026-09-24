//
//  TxIdTests.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 1/10/20.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

class TxIdTests: XCTestCase {
    func testTxIdAsString() {
        let transactionId = "5cf915c5d01007c39d602e08ab59d98aba366e2fb7ac01f2cdad4bf4f8f300bb"
        let expectedTxIdString = "bb00f3f8f44badcdf201acb72f6e36ba8ad959ab082e609dc30710d0c515f95c"

        XCTAssertEqual(Data(fromHexEncodedString: transactionId)!.toHexStringTxId(), expectedTxIdString)
    }

    // MARK: - Byte-order round trip (finding 12)

    /// Pins the actual conversion helpers the welding record path relies on -- `TxId.init(_:)`
    /// (display-hex string -> raw/internal bytes) and `Data.toHexStringTxId()` (raw/internal bytes ->
    /// display-hex string) -- at their own public surface, independent of the actor/mock composition
    /// covered by
    /// `OrchardMigrationCompositionTests.testExecuteNextPendingTransferRecordsTheDocumentedByteOrderForAnAsymmetricTxId`.
    ///
    /// An ascending, asymmetric 32-byte fixture (reversing it changes every byte) so a byte-order
    /// regression cannot hide behind a symmetric fixture the way it could with e.g.
    /// `Data(repeating: 0xAB, count: 32)`, whose reversal is indistinguishable from the original.
    /// `displayHex`/`expectedRawBytes` are hand-derived from the documented convention (reverse the
    /// byte order, then hex-encode -- see `PreparedMigrationTransfer.txid` and
    /// `MigrationTransferResult.success`'s doc comments) rather than produced by running the helpers
    /// under test and pasting their output.
    ///
    /// This direction starts from the string: decode, check the raw bytes against the hand-written
    /// expectation, then re-encode and check the string comes back unchanged.
    func testTxIdStringRoundTripsThroughRawBytesForAnAsymmetricFixture() throws {
        let displayHex = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
        let expectedRawBytes: [UInt8] = (0..<32).map { UInt8($0) }

        let decoded = try TxId(displayHex)
        XCTAssertEqual(decoded.id, expectedRawBytes, "TxId.init must undo the display byte-order reversal")

        let reencoded = Data(decoded.id).toHexStringTxId()
        XCTAssertEqual(reencoded, displayHex, "re-encoding through Data.toHexStringTxId() must reproduce the original display string")
    }

    /// The companion direction of the round trip above, starting from raw bytes instead: encode via
    /// `Data.toHexStringTxId()`, check the display string against the same hand-written expectation,
    /// then decode back via `TxId.init(_:)` and check the raw bytes come back unchanged.
    func testTxIdRawBytesRoundTripThroughDisplayHexStringForAnAsymmetricFixture() throws {
        let rawBytes: [UInt8] = (0..<32).map { UInt8($0) }
        let expectedDisplayHex = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"

        let displayHex = Data(rawBytes).toHexStringTxId()
        XCTAssertEqual(displayHex, expectedDisplayHex, "Data.toHexStringTxId() must produce the documented display byte order")

        let decoded = try TxId(displayHex)
        XCTAssertEqual(decoded.id, rawBytes, "round-tripping back through TxId.init(_:) must reproduce the original raw bytes")
    }
}
