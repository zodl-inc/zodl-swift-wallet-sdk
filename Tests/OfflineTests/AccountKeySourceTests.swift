//
//  AccountKeySourceTests.swift
//  OfflineTests
//
//  `Account.keystoneKeySource` must match `KEYSTONE_KEY_SOURCE` in rust/src/migration_engine.rs.
//  Drift between the two would silently fall every Keystone account back to the in-process
//  note-cap sizing.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class AccountKeySourceTests: XCTestCase {
    func testKeystoneKeySourceIsTheLiteralTheRustSeamMatches() {
        XCTAssertEqual(Account.keystoneKeySource, "keystone")
        XCTAssertEqual(Account.keystoneKeySource, Account.keystoneKeySource.lowercased())
    }
}
