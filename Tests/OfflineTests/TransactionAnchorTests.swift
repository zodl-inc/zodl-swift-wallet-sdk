//
//  TransactionAnchorTests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class TransactionAnchorTests: XCTestCase {
    private let nu7: BlockHeight = 4_465_026
    private let mainnet = ZcashNetworkBuilder.network(for: .mainnet)
    private let testnet = ZcashNetworkBuilder.network(for: .testnet)

    func testAnUnminedTransactionIsAnchoredBehindTheTargetItsExpiryImplies() {
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: 3_000_040).anchor(network: mainnet), 2_999_990)
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: nu7 + 39).anchor(network: testnet), nu7 - 11)
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: nu7 + 120).anchor(network: testnet), nu7 - 10)
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: nu7 + 1_120).anchor(network: testnet), nu7 + 990)
        // The 130 is the 120-block expiry delta plus the 10-block stale tolerance.
        for expiry in (nu7 + 40)...(nu7 + 119) {
            XCTAssertEqual(overview(minedHeight: -1, expiryHeight: expiry).anchor(network: testnet), expiry - 130, "expiry \(expiry)")
        }
    }

    func testTheAnchorNeverFallsBelowSaplingActivation() {
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: 280_045).anchor(network: testnet), 280_000)
        XCTAssertEqual(overview(minedHeight: -1, expiryHeight: 100).anchor(network: testnet), 280_000)
    }

    func testMinedAndHeightlessTransactionsAreUnchanged() {
        XCTAssertEqual(overview(minedHeight: 3_000_000, expiryHeight: 3_000_040).anchor(network: mainnet), 2_999_990)
        XCTAssertNil(overview(minedHeight: nil, expiryHeight: 3_000_040).anchor(network: mainnet))
        XCTAssertNil(overview(minedHeight: -1, expiryHeight: nil).anchor(network: mainnet))
        XCTAssertNil(overview(minedHeight: -1, expiryHeight: -1).anchor(network: mainnet))
    }

    private func overview(minedHeight: BlockHeight?, expiryHeight: BlockHeight?) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
            blockTime: nil,
            expiryHeight: expiryHeight,
            fee: Zatoshi(10_000),
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: nil,
            rawID: Data(repeating: 1, count: 32),
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-10_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 1,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }
}
