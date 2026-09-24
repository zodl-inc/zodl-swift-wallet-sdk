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
        let (signingKey, testKeyId, testPublicKeyHex) = makeTestKeyParams()

        // Mock HTTP sender that returns HTTP 500 with "HTTP 400" in body (attack scenario)
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                // Return a signed config JSON
                let keyConfig = try! self.generateMockSignedConfig(keyId: testKeyId, signingKey: signingKey)
                return (keyConfig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                // Relay POST - return HTTP 500 with malicious body
                roundTripAttempts += 1
                let maliciousBody = "Internal Server Error: HTTP 400 Bad Request from upstream".data(using: .utf8)!
                return (maliciousBody, HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
        }

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
        let (signingKey, testKeyId, testPublicKeyHex) = makeTestKeyParams()

        // Mock HTTP sender that returns HTTP 400 on first attempt, then 200
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                let keyConfig = try! self.generateMockSignedConfig(keyId: testKeyId, signingKey: signingKey)
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
            // Success after retry (decryption may fail with mock response, but retry logic executed)
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

    // MARK: - Helper Methods

    /// Generate a fresh signing key and corresponding test parameters for injection.
    private func makeTestKeyParams() -> (key: Curve25519.Signing.PrivateKey, keyId: String, publicKeyHex: String) {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = signingKey.publicKey.rawRepresentation

        var hasher = SHA256()
        hasher.update(data: publicKeyData)
        let hash = hasher.finalize()
        let keyId = Data(hash.prefix(4)).map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()

        return (signingKey, keyId, publicKeyHex)
    }

    /// Generates a minimal mock signed config JSON for testing.
    private func generateMockSignedConfig(keyId: String, signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        // Generate key config bytes
        let keyConfigBytes = generateMockKeyConfig()

        // Current time + 1 hour validity
        let notBefore = Int64(Date().timeIntervalSince1970)
        let notAfter = notBefore + 3600
        let network = "testnet"

        // Build signature message per spec
        var message = Data()
        message.append("zodl-ohttp-configs-v1".data(using: .ascii)!)
        message.append(0x00)
        message.append(network.data(using: .ascii)!)
        message.append(0x00)
        message.append(contentsOf: withUnsafeBytes(of: notBefore.bigEndian) { Data($0) })
        message.append(contentsOf: withUnsafeBytes(of: notAfter.bigEndian) { Data($0) })
        message.append(keyConfigBytes)

        // Sign the message
        let signature = try signingKey.signature(for: message)

        // Build JSON envelope
        let envelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: network,
            configs: keyConfigBytes.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: keyId,
            signature: Data(signature).base64EncodedString()
        )

        return try JSONEncoder().encode(envelope)
    }

    /// Generates a minimal mock key config for testing.
    private func generateMockKeyConfig() -> Data {
        // Build a valid 43-byte OHTTP key config
        // Format: [length: u16] [keyId: u8] [kem_id: u16] [public_key: 32 bytes] [suites_length: u16] [kdf_id: u16] [aead_id: u16]
        var config = Data()
        config.append(contentsOf: [0x00, 0x29])  // length = 41 bytes
        config.append(0x01)  // key_id
        config.append(contentsOf: [0x00, 0x20])  // kem_id = 0x0020 (X25519)

        // Generate a random X25519 public key for the config
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        config.append(privateKey.publicKey.rawRepresentation)

        config.append(contentsOf: [0x00, 0x04])  // suites_length = 4 bytes
        config.append(contentsOf: [0x00, 0x01])  // kdf_id = 0x0001 (HKDF-SHA256)
        config.append(contentsOf: [0x00, 0x01])  // aead_id = 0x0001 (AES-128-GCM)

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
