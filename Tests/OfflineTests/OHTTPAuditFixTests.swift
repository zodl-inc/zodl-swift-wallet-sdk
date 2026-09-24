//
//  OHTTPAuditFixTests.swift
//  OfflineTests
//
//  Tests for OHTTP security audit fixes (C-07, C-09).
//

import XCTest
@testable import ZcashLightClientKit
import CryptoKit

final class OHTTPAuditFixTests: XCTestCase {

    // MARK: - C-07: 400-retry substring match vulnerability

    /// Tests that a relay returning HTTP 500 with body containing "HTTP 400" does NOT trigger retry.
    /// C-07: A hostile relay could embed "HTTP 400" in the error body to force key refresh + duplicate sends.
    func testRetryDoesNotTriggerOnBodyContainingHTTP400() async throws {
        var keyConfigFetchCount = 0
        var roundTripAttempts = 0

        // Mock HTTP sender that returns HTTP 500 with "HTTP 400" in body (attack scenario)
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                // Return a signed config JSON (mock - tests don't actually verify signature)
                let keyConfig = self.generateMockSignedConfig()
                return (keyConfig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                // Relay POST - return HTTP 500 with malicious body
                roundTripAttempts += 1
                let maliciousBody = "Internal Server Error: HTTP 400 Bad Request from upstream".data(using: .utf8)!
                return (maliciousBody, HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
        }

        // Use test key parameters to bypass signature verification
        let testKeyId = "test-key-2099"
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let testPublicKeyHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let transport = OHTTPTransport(
            network: "testnet",
            relayURL: "https://testnet-operator-relay.example.invalid/relay",
            keyConfigURL: "https://testnet-operator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: nil,
            testKeyId: testKeyId,
            testPublicKeyHex: testPublicKeyHex,
            httpSender: mockSender
        )

        let testRequest = BinaryHTTP.Request(
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
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                let keyConfig = self.generateMockSignedConfig()
                return (keyConfig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                roundTripAttempts += 1
                if roundTripAttempts == 1 {
                    // First attempt: return HTTP 400 (gateway key rotation)
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
                } else {
                    // Second attempt: success
                    let mockResponse = self.generateMockEncapsulatedResponse()
                    return (mockResponse, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
        }

        // Use test key parameters to bypass signature verification
        let testKeyId = "test-key-2099"
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let testPublicKeyHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let transport = OHTTPTransport(
            network: "testnet",
            relayURL: "https://testnet-operator-relay.example.invalid/relay",
            keyConfigURL: "https://testnet-operator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: nil,
            testKeyId: testKeyId,
            testPublicKeyHex: testPublicKeyHex,
            httpSender: mockSender
        )

        let testRequest = BinaryHTTP.Request(
            method: "GET",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/test",
            headers: [],
            body: Data()
        )

        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            // Success after retry
        } catch {
            XCTFail("Expected success after retry, got error: \(error)")
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

    // MARK: - Helper Methods

    /// Generates a minimal mock signed config JSON for testing.
    private func generateMockSignedConfig() -> Data {
        // Generate key config bytes
        let keyConfigBytes = generateMockKeyConfig()
        let keyConfigBase64 = keyConfigBytes.base64EncodedString()

        // Current time + 1 hour validity
        let notBefore = Int64(Date().timeIntervalSince1970)
        let notAfter = notBefore + 3600

        let json = """
        {
            "v": 1,
            "network": "testnet",
            "configs": "\(keyConfigBase64)",
            "not_before": \(notBefore),
            "not_after": \(notAfter),
            "key_id": "test-key-2099",
            "sig": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
        }
        """
        return json.data(using: .utf8)!
    }

    /// Generates a minimal mock key config for testing.
    private func generateMockKeyConfig() -> Data {
        // Minimal key config: keyId=1, KEM=0x0020 (DHKEM(X25519, HKDF-SHA256)), 32-byte public key
        var config = Data()
        config.append(1)  // keyId
        config.append(contentsOf: [0x00, 0x20])  // KEM ID (DHKEM X25519)

        // Generate a random 32-byte X25519 public key for testing
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        config.append(publicKeyData)

        // KDF and AEAD suite IDs (HKDF-SHA256, AES-128-GCM)
        config.append(contentsOf: [0x00, 0x01])  // KDF: HKDF-SHA256
        config.append(contentsOf: [0x00, 0x01])  // AEAD: AES-128-GCM

        return config
    }

    /// Generates a minimal mock encapsulated response for testing.
    private func generateMockEncapsulatedResponse() -> Data {
        // A minimal encrypted response: nonce (16 bytes) + ciphertext (minimal valid BHTTP response + auth tag)
        var response = Data()

        // Nonce (16 bytes, matching max(nN, nK) for AES-128-GCM)
        response.append(Data(repeating: 0, count: 16))

        // Mock ciphertext: minimal BHTTP response (framing=1, status=200, empty headers/body/trailers)
        var bhttpResponse = Data()
        BinaryHTTP.writeVarint(&bhttpResponse, 1)   // framing
        BinaryHTTP.writeVarint(&bhttpResponse, 200) // status
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // headers length
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // body length
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // trailers length

        // In real OHTTP, this would be encrypted + authenticated with a 16-byte tag
        // For testing, we just append dummy ciphertext + tag
        response.append(bhttpResponse)
        response.append(Data(repeating: 0, count: 16))  // mock auth tag

        return response
    }
}
