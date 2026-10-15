//
//  OHTTPAuditFixTests.swift
//  OfflineTests
//
//  Tests for OHTTP security audit fixes (C-07, C-09).
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPAuditFixTests: XCTestCase {

    // MARK: - C-07: 400-retry substring match vulnerability

    /// Tests that a relay returning HTTP 500 with body containing "HTTP 400" does NOT trigger retry.
    /// C-07: A hostile relay could embed "HTTP 400" in the error body to force key refresh + duplicate sends.
    /// The retry is decided by the outer status alone, in the shared core.
    func testRetryDoesNotTriggerOnBodyContainingHTTP400() async throws {
        var keyConfigFetchCount = 0
        var roundTripAttempts = 0

        // Mock HTTP sender that returns HTTP 500 with "HTTP 400" in body (attack scenario)
        let transport = OHTTPTestSupport.makeTransport { request, _ in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            // Relay POST - return HTTP 500 with malicious body
            roundTripAttempts += 1
            let maliciousBody = Data("Internal Server Error: HTTP 400 Bad Request from upstream".utf8)
            return (maliciousBody, OHTTPTestSupport.response(for: request.url, status: 500))
        }

        let testRequest = OHTTPRequest(
            method: "GET",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/test",
            headers: [],
            body: Data()
        )

        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            XCTFail("Expected error but got success")
        } catch let error as OHTTPError {
            // Verify we got an httpStatusError with status 500, not 400
            if case .httpStatusError(statusCode: let code, message: let msg) = error {
                XCTAssertEqual(code, 500, "Expected status code 500")
                XCTAssertTrue(msg.contains("HTTP 400"), "Body should contain 'HTTP 400' (attack scenario)")
            } else {
                XCTFail("Expected httpStatusError, got \(error)")
            }
        }

        // Verify key config was fetched only ONCE (no retry)
        XCTAssertEqual(keyConfigFetchCount, 1, "Key config should be fetched only once (no retry)")
        XCTAssertEqual(roundTripAttempts, 1, "Should attempt round trip only once (no retry on non-400)")
    }

    /// Tests that a legitimate HTTP 400 from relay DOES trigger retry with key refresh.
    func testRetryTriggersOnRealHTTP400() async throws {
        var keyConfigFetchCount = 0
        var roundTripAttempts = 0

        // Mock HTTP sender that returns HTTP 400 on first attempt, then 200
        let transport = OHTTPTestSupport.makeTransport { request, _ in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            roundTripAttempts += 1
            if roundTripAttempts == 1 {
                // First attempt: return HTTP 400 (gateway key rotation)
                return (Data(), OHTTPTestSupport.response(for: request.url, status: 400))
            }
            // Second attempt: success status (the body cannot open without a gateway)
            return (OHTTPTestSupport.unopenableSealedResponse(), OHTTPTestSupport.response(for: request.url, status: 200))
        }

        let testRequest = OHTTPRequest(
            method: "GET",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/test",
            headers: [],
            body: Data()
        )

        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            // Success after retry (decryption fails with the mock response, but retry logic executed)
        } catch {
            // Allow decryption errors - we're testing retry logic, not end-to-end HPKE
            // The counters below prove retry happened correctly
        }

        // Verify key config was fetched TWICE (initial + retry after 400)
        XCTAssertEqual(keyConfigFetchCount, 2, "Key config should be fetched twice (initial + refresh after 400)")
        XCTAssertEqual(roundTripAttempts, 2, "Should attempt round trip twice (initial + retry after 400)")
    }

    // MARK: - C-09: Header stripping misses aliases

    /// Tests that header stripping works for alias URLs (cmc.zodl.com, near.zodl.com, vote.zodl.com).
    func testHeaderStrippingForAliasHosts() {
        // Alias hosts that should have headers stripped
        let aliasHosts = ["cmc.zodl.com", "near.zodl.com", "vote.zodl.com"]

        for host in aliasHosts {
            XCTAssertTrue(
                OHTTPEndpoints.needsHeaderStripping(host: host),
                "Header stripping should be enabled for alias host \(host)"
            )
        }

        // Non-alias hosts should not strip headers
        let nonAliasHosts = ["gateway.zodl.com", "operator-relay.example.invalid", "example.com"]

        for host in nonAliasHosts {
            XCTAssertFalse(
                OHTTPEndpoints.needsHeaderStripping(host: host),
                "Header stripping should be disabled for non-alias host \(host)"
            )
        }
    }

    /// Tests that header stripping is case-insensitive.
    func testHeaderStrippingIsCaseInsensitive() {
        let hostVariants = [
            "cmc.zodl.com",
            "CMC.ZODL.COM",
            "Cmc.Zodl.Com",
            "CMC.zodl.com"
        ]

        for host in hostVariants {
            XCTAssertTrue(
                OHTTPEndpoints.needsHeaderStripping(host: host),
                "Header stripping should be case-insensitive for \(host)"
            )
        }
    }

    /// Tests that the original (non-alias) hosts still work with proxyHost lookup.
    func testProxyHostLookupStillWorks() {
        // Original hosts should map to their aliases
        guard let url1 = URL(string: "https://pro-api.coinmarketcap.com/v1/test") else {
            XCTFail("Failed to create URL")
            return
        }
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url1), "cmc.zodl.com")

        guard let url2 = URL(string: "https://1click.chaindefuser.com/test") else {
            XCTFail("Failed to create URL")
            return
        }
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url2), "near.zodl.com")

        guard let url3 = URL(string: "https://voting.valargroup.dev/test") else {
            XCTFail("Failed to create URL")
            return
        }
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url3), "vote.zodl.com")
    }

}
