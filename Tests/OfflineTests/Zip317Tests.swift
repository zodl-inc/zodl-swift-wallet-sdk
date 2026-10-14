//
//  Zip317Tests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class Zip317Tests: XCTestCase {
    func testMarginalFeeIsTheZip317Value() {
        XCTAssertEqual(Zip317.marginalFee, Zatoshi(5_000))
    }
}
