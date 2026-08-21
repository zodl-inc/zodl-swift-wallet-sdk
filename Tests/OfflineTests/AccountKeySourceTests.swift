//
//  AccountKeySourceTests.swift
//  OfflineTests
//
//  Pins the Swift half of the Keystone run-sizing contract: `Account.keystoneKeySource` is the
//  literal the Rust side (`KEYSTONE_KEY_SOURCE` in rust/src/migration_engine.rs) matches,
//  case-insensitively, against an account row's `key_source`. A host that stamps this constant on
//  a Keystone import gets one-signing-round migration runs; a drift between the two literals would
//  silently fall every Keystone account back to the in-process note-cap sizing, which is why the
//  value is pinned here rather than only documented.
//

import XCTest
@testable import ZcashLightClientKit

final class AccountKeySourceTests: XCTestCase {
    /// The literal the Rust seam matches. Lowercase, because that is what the platform layer
    /// stamps (`.lowercased()`) and what the case-insensitive match normalizes to.
    func testKeystoneKeySourceIsTheLiteralTheRustSeamMatches() {
        XCTAssertEqual(Account.keystoneKeySource, "keystone")
        XCTAssertEqual(Account.keystoneKeySource, Account.keystoneKeySource.lowercased())
    }
}
