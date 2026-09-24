//
//  OHTTPRetryTests.swift
//  OfflineTests
//
//  C-08 audit fix verification: Documents that OHTTP ciphertext is not retried on transport errors.
//  Without the fix, retries would send the same sealed ciphertext multiple times, violating the
//  nonce-once invariant and triggering gateway replay cache (409) on the second attempt.
//
//  F-09: Grep-based tests replaced with behavioral tests in OHTTPBehavioralTests.swift.
//

import XCTest
@testable import ZcashLightClientKit

final class OHTTPRetryTests: XCTestCase {

    /// C-08 fix documentation: OHTTP requests over Tor use retryLimit: 0 to prevent ciphertext replay.
    ///
    /// The fix is in SDKSynchronizer.swift (~line 1368) and SlipstreamSynchronizer.swift (~line 2821):
    ///   return try await self.httpRequestOverTor(for: request, retryLimit: 0)
    ///
    /// Without this fix, Tor transport retries would resend the same sealed ciphertext up to 3 times,
    /// violating nonce-once and triggering gateway 409 on duplicate nonce.
    ///
    /// The OHTTP layer has its own safe retry for key rotation (HTTP 400/422), which re-encapsulates
    /// with fresh ciphertext. Transport-level retries are not safe for OHTTP.
    ///
    /// **Behavioral tests** for this fix are in OHTTPBehavioralTests:
    /// - testNoRetryOn409ReplayCache: verifies no retry when gateway returns 409
    /// - test422TriggersConfigRefetchAndSingleRetry: verifies safe retry with new ciphertext
    ///
    /// This test exists as documentation only - the behavioral tests prove the fix works.
    func testOHTTPRetryDocumentation() {
        // This test documents the C-08 fix location and rationale.
        // Actual verification is in OHTTPBehavioralTests.swift (F-09 behavioral tests).
        XCTAssertTrue(true, "See OHTTPBehavioralTests for behavioral verification of retry behavior")
    }
}
