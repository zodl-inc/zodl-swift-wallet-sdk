//
//  OHTTPBehavioralTests.swift
//  OfflineTests
//
//  F-09: Behavioral tests replacing grep-based tests. Uses URLProtocol-based mock or 
//  protocol-injected transport to verify OHTTP transport behavior without reading source files.
//
//  Tests:
//  - No retry after request bytes sent (409 replay cache path)
//  - 422 ohttp-key triggers config refetch once + single retry
//  - Signed-config validation rejects invalid envelopes
//

import XCTest
@testable import ZcashLightClientKit
import CryptoKit

final class OHTTPBehavioralTests: XCTestCase {
    
    // MARK: - 409 Replay Cache (No Retry After Send)
    
    /// Tests that OHTTP transport does NOT retry when gateway returns 409 (duplicate nonce).
    /// A 409 means the ciphertext was already received, so retrying with the same ciphertext
    /// would fail the same way. The transport should fail immediately without retry.
    func testNoRetryOn409ReplayCache() async throws {
        var requestCount = 0
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                // Return mock signed config
                return (self.generateMockSignedConfig(), 
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                // Gateway POST - return 409 Conflict
                requestCount += 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
        }
        
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
            method: "POST",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/submit",
            headers: [],
            body: Data([0x01, 0x02, 0x03])
        )
        
        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            XCTFail("Expected 409 error, got success")
        } catch let error as OHTTPError {
            if case .httpStatusError(statusCode: let code, message: _) = error {
                XCTAssertEqual(code, 409, "Expected 409 Conflict")
            } else {
                XCTFail("Expected httpStatusError with 409, got \(error)")
            }
        }
        
        // Verify only ONE request was made (no retry on 409)
        XCTAssertEqual(requestCount, 1, "409 should not trigger retry (ciphertext already received)")
    }
    
    // MARK: - 422 OHTTP Key Error (Config Refetch + Single Retry)
    
    /// Tests that HTTP 422 (unprocessable entity, typically "ohttp-key" error) triggers
    /// config refetch once and retries exactly once with the new config.
    /// This differs from 400 (bad request) which may indicate various client errors.
    func test422TriggersConfigRefetchAndSingleRetry() async throws {
        var keyConfigFetchCount = 0
        var roundTripAttempts = 0
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                keyConfigFetchCount += 1
                return (self.generateMockSignedConfig(), 
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                roundTripAttempts += 1
                if roundTripAttempts == 1 {
                    // First attempt: 422 (gateway doesn't recognize key)
                    let errorBody = "{\"error\":\"ohttp-key\"}".data(using: .utf8)!
                    return (errorBody, HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!)
                } else if roundTripAttempts == 2 {
                    // Second attempt after key refresh: success
                    return (self.generateMockEncapsulatedResponse(), 
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                } else {
                    // Should not reach here (only one retry expected)
                    XCTFail("Unexpected third attempt - should only retry once after 422")
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
                }
            }
        }
        
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
            method: "POST",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/submit",
            headers: [],
            body: Data([0x01, 0x02, 0x03])
        )
        
        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            // Success after retry
        } catch {
            XCTFail("Expected success after 422 retry, got error: \(error)")
        }
        
        // Verify config was fetched twice (initial + refresh after 422)
        XCTAssertEqual(keyConfigFetchCount, 2, "Config should be fetched twice (initial + refresh after 422)")
        // Verify exactly 2 round trip attempts (initial + one retry)
        XCTAssertEqual(roundTripAttempts, 2, "Should attempt round trip exactly twice (initial + single retry after 422)")
    }
    
    /// Tests that 422 without successful retry propagates the error correctly.
    func test422RetryFailurePropagatesError() async throws {
        var roundTripAttempts = 0
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                return (self.generateMockSignedConfig(), 
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                roundTripAttempts += 1
                // Both attempts return 422 (key still not recognized after refresh)
                let errorBody = "{\"error\":\"ohttp-key\"}".data(using: .utf8)!
                return (errorBody, HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!)
            }
        }
        
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
            method: "POST",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/submit",
            headers: [],
            body: Data([0x01, 0x02, 0x03])
        )
        
        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            XCTFail("Expected 422 error after failed retry")
        } catch let error as OHTTPError {
            if case .httpStatusError(statusCode: let code, message: _) = error {
                XCTAssertEqual(code, 422, "Expected 422 after retry failure")
            } else {
                XCTFail("Expected httpStatusError with 422, got \(error)")
            }
        }
        
        // Verify exactly 2 attempts (initial + one retry)
        XCTAssertEqual(roundTripAttempts, 2, "Should attempt exactly twice before giving up")
    }
    
    // MARK: - Signed Config Validation
    
    /// Tests that signed config >4096 bytes is rejected.
    func testSignedConfigRejectsOversizedPayload() throws {
        // Generate a config that exceeds 4096 bytes
        let oversizedConfigBytes = Data(repeating: 0x42, count: 5000)
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "testnet",
            configs: oversizedConfigBytes.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: "a3620fb6",
            signature: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for oversized config")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("size") || verifyError.description.contains("4096"),
                "Error should mention size limit: \(verifyError.description)"
            )
        }
    }
    
    /// Tests that signed config with not_before >= not_after is rejected.
    func testSignedConfigRejectsInvalidTimeRange() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970)
        let notAfter = notBefore  // Equal (invalid)
        
        let envelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: "a3620fb6",
            signature: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for invalid time range")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("time") || verifyError.description.contains("validity"),
                "Error should mention time validity: \(verifyError.description)"
            )
        }
        
        // Also test not_before > not_after
        let invalidEnvelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            notBefore: notBefore + 1000,
            notAfter: notBefore,
            keyId: "a3620fb6",
            signature: String(repeating: "A", count: 88)
        )
        
        let invalidJsonData = try JSONEncoder().encode(invalidEnvelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: invalidJsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for not_before > not_after")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("time") || verifyError.description.contains("validity"),
                "Error should mention time validity: \(verifyError.description)"
            )
        }
    }
    
    /// Tests that signed config with duplicate key IDs is rejected.
    /// This requires creating a configs blob with multiple key configs having the same keyId.
    func testSignedConfigRejectsDuplicateKeyIds() throws {
        // Create two OHTTP key configs with the same keyId (both using keyId=1)
        var configsData = Data()
        
        // First config: keyId=1, minimal X25519 config
        configsData.append(1)  // keyId
        configsData.append(contentsOf: [0x00, 0x20])  // KEM: DHKEM(X25519, HKDF-SHA256)
        let privateKey1 = Curve25519.KeyAgreement.PrivateKey()
        configsData.append(privateKey1.publicKey.rawRepresentation)
        configsData.append(contentsOf: [0x00, 0x01])  // KDF: HKDF-SHA256
        configsData.append(contentsOf: [0x00, 0x01])  // AEAD: AES-128-GCM
        
        // Second config: SAME keyId=1 (duplicate)
        configsData.append(1)  // keyId (duplicate!)
        configsData.append(contentsOf: [0x00, 0x20])  // KEM: DHKEM(X25519, HKDF-SHA256)
        let privateKey2 = Curve25519.KeyAgreement.PrivateKey()
        configsData.append(privateKey2.publicKey.rawRepresentation)
        configsData.append(contentsOf: [0x00, 0x01])  // KDF: HKDF-SHA256
        configsData.append(contentsOf: [0x00, 0x01])  // AEAD: AES-128-GCM
        
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "testnet",
            configs: configsData.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: "a3620fb6",
            signature: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for duplicate keyIds")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("duplicate") || verifyError.description.contains("key"),
                "Error should mention duplicate keys: \(verifyError.description)"
            )
        }
    }

    /// Tests that signed config with wrong network is rejected.
    /// A mainnet config should be rejected when verifying for testnet and vice versa.
    func testSignedConfigRejectsWrongNetwork() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600

        // Create mainnet envelope
        let mainnetEnvelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "mainnet",
            configs: configBytes.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: "ba8a2dbd",
            signature: String(repeating: "A", count: 88)
        )

        let mainnetJsonData = try JSONEncoder().encode(mainnetEnvelope)

        // Verify for testnet should reject mainnet envelope
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: mainnetJsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for wrong network")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("Network") || verifyError.description.contains("network"),
                "Error should mention network mismatch: \(verifyError.description)"
            )
        }

        // Create testnet envelope
        let testnetEnvelope = SignedOHTTPConfigEnvelope(
            version: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            notBefore: notBefore,
            notAfter: notAfter,
            keyId: "a3620fb6",
            signature: String(repeating: "A", count: 88)
        )

        let testnetJsonData = try JSONEncoder().encode(testnetEnvelope)

        // Verify for mainnet should reject testnet envelope
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: testnetJsonData, network: "mainnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError for wrong network")
                return
            }
            XCTAssertTrue(
                verifyError.description.contains("Network") || verifyError.description.contains("network"),
                "Error should mention network mismatch: \(verifyError.description)"
            )
        }
    }

    // MARK: - Helper Methods (reused from OHTTPAuditFixTests)
    
    private func generateMockSignedConfig() -> Data {
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
            "key_id": "a3620fb6",
            "sig": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
        }
        """
        return json.data(using: .utf8)!
    }
    
    private func generateMockKeyConfig() -> Data {
        var config = Data()
        config.append(1)  // keyId
        config.append(contentsOf: [0x00, 0x20])  // KEM ID
        
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        config.append(publicKeyData)
        
        config.append(contentsOf: [0x00, 0x01])  // KDF
        config.append(contentsOf: [0x00, 0x01])  // AEAD
        
        return config
    }
    
    private func generateMockEncapsulatedResponse() -> Data {
        var response = Data()
        response.append(Data(repeating: 0, count: 16))  // nonce
        
        var bhttpResponse = Data()
        BinaryHTTP.writeVarint(&bhttpResponse, 1)   // framing
        BinaryHTTP.writeVarint(&bhttpResponse, 200) // status
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // headers
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // body
        BinaryHTTP.writeVarint(&bhttpResponse, 0)   // trailers
        
        response.append(bhttpResponse)
        response.append(Data(repeating: 0, count: 16))  // auth tag
        
        return response
    }
}
