//
//  OHTTPSignedConfigTests.swift
//  ZcashLightClientKitTests
//
//  Unit tests for signed OHTTP config verification.
//

import XCTest
@testable import ZcashLightClientKit
import CryptoKit

final class OHTTPSignedConfigTests: XCTestCase {
    
    // Test keypair generated with: openssl genpkey -algorithm ed25519
    // Public key (hex): testnet key from OHTTPSignedConfig.swift
    let testnetPublicKeyHex = "REDACTED-SIGNING-PUBKEY-TESTNET"
    // Private key (hex, for test signing): <redacted - not needed in client>
    
    func testValidEnvelopeSuccess() throws {
        // Build a minimal valid envelope (using test data, not real signature)
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])  // Minimal OHTTP key config
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600  // 1 hour validity
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "a3620fb6",  // testnet key ID
            sig: String(repeating: "A", count: 88)  // Placeholder (will fail real sig check)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        // This will fail signature verification, but tests the structure
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            XCTAssertTrue(error is KeyConfigVerificationError)
        }
    }
    
    func testWrongNetworkFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "mainnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "ba8a2dbd",
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        // Should fail network check BEFORE signature verification
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            XCTAssertTrue(verifyError.description.contains("Network mismatch"))
        }
    }
    
    func testExpiredConfigFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 7200  // 2 hours ago
        let notAfter = notBefore + 3600  // Expired 1 hour ago
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "a3620fb6",
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            XCTAssertTrue(verifyError.description.contains("not valid at current time"))
        }
    }
    
    func testValidityExceeds24HoursFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 90000  // > 24 hours
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "a3620fb6",
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            XCTAssertTrue(verifyError.description.contains("Validity period") && verifyError.description.contains("exceeds"))
        }
    }
    
    func testNotAfterTooFarInFutureFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) + 90000  // Far future
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "a3620fb6",
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            // Should fail either time check or future check
            XCTAssertTrue(verifyError.description.contains("notAfter") || verifyError.description.contains("not valid"))
        }
    }
    
    func testWrongKeyIdFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 1,
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "deadbeef",  // Wrong key ID
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            XCTAssertTrue(verifyError.description.contains("Key ID mismatch"))
        }
    }
    
    func testUnsupportedProtocolVersionFails() throws {
        let configBytes = Data([0x01, 0x00, 0x20, 0x04, 0x20])
        let notBefore = Int64(Date().timeIntervalSince1970) - 60
        let notAfter = notBefore + 3600
        
        let envelope = SignedOHTTPConfigEnvelope(
            v: 2,  // Unsupported version
            network: "testnet",
            configs: configBytes.base64EncodedString(),
            not_before: notBefore,
            not_after: notAfter,
            key_id: "a3620fb6",
            sig: String(repeating: "A", count: 88)
        )
        
        let jsonData = try JSONEncoder().encode(envelope)
        
        XCTAssertThrowsError(try OHTTPSignedConfigVerifier.verifyAndParse(jsonData: jsonData, network: "testnet")) { error in
            guard let verifyError = error as? KeyConfigVerificationError else {
                XCTFail("Expected KeyConfigVerificationError")
                return
            }
            XCTAssertTrue(verifyError.description.contains("protocol version"))
        }
    }
    
    func testEnvelopeDecoding() throws {
        let json = """
        {
            "v": 1,
            "network": "testnet",
            "configs": "AQAgBCA=",
            "not_before": 1700000000,
            "not_after": 2000000000,
            "key_id": "a3620fb6",
            "sig": "dGVzdHNpZ25hdHVyZTY0Ynl0ZXNwbGFjZWhvbGRlcjEyMzQ1Njc4OTBhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5eg=="
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SignedOHTTPConfigEnvelope.self, from: data)
        
        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(envelope.network, "testnet")
        XCTAssertEqual(envelope.configs, "AQAgBCA=")
        XCTAssertEqual(envelope.not_before, 1700000000)
        XCTAssertEqual(envelope.not_after, 2000000000)
        XCTAssertEqual(envelope.key_id, "a3620fb6")
    }
    
    func testDataHexStringConversion() throws {
        let hexString = "deadbeef"
        let data = Data(hexString: hexString)
        XCTAssertNotNil(data)
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }
    
    func testInvalidHexString() throws {
        let invalidHex = "xyz"
        let data = Data(hexString: invalidHex)
        XCTAssertNil(data)
    }
    
    func testOHTTPEndpointsNetworkDetection() {
        XCTAssertEqual(OHTTPEndpoints.network(for: "ohttp-gateway-testnet.example"), "testnet")
        XCTAssertEqual(OHTTPEndpoints.network(for: "ohttp-gateway.example"), "mainnet")
        XCTAssertEqual(OHTTPEndpoints.network(for: "cmc.zodl.com"), "mainnet")
        XCTAssertEqual(OHTTPEndpoints.network(for: "vote.zodl.com"), "mainnet")
    }
}
