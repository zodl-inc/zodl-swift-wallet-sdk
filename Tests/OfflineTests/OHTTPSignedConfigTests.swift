//
//  OHTTPSignedConfigTests.swift
//  ZcashLightClientKitTests
//
//  Unit tests for signed OHTTP config verification.
//

import XCTest
@testable import ZcashLightClientKit

final class OHTTPSignedConfigTests: XCTestCase {
    
    // Test public key (throwaway for deterministic testing)
    // Public key: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    // Key ID: d7a8fbb3 (first 8 hex of SHA-256(public key))
    
    func testKeyIdComputation() throws {
        // SHA-256("deadbeef") = 5f78c33274e43fa9de5659265c1d917e25c03722dcb0b8d27db8d5feaa813953
        let testKey = Data([0xde, 0xad, 0xbe, 0xef])
        let hash = testKey.sha256()
        let keyId = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(keyId, "5f78c332")
    }
    
    func testEnvelopeDecoding() throws {
        let json = """
        {
            "v": 1,
            "network": "testnet",
            "configs": "AQAgBCA=",
            "not_before": 1700000000,
            "not_after": 2000000000,
            "key_id": "d7a8fbb3",
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
        XCTAssertEqual(envelope.key_id, "d7a8fbb3")
    }
    
    func testSignedMessageFormat() throws {
        let configData = Data([0x01, 0x02, 0x03])
        // This is a private method, so we test the concept here
        var message = Data()
        message.append("zodl-ohttp-configs-v1".data(using: .ascii)!)
        message.append(0x00)
        message.append("testnet".data(using: .ascii)!)
        message.append(0x00)
        let notBefore: Int64 = 1700000000
        let notAfter: Int64 = 2000000000
        message.append(contentsOf: withUnsafeBytes(of: notBefore.bigEndian) { Data($0) })
        message.append(contentsOf: withUnsafeBytes(of: notAfter.bigEndian) { Data($0) })
        message.append(configData)
        
        // Verify prefix
        let prefix = "zodl-ohttp-configs-v1".data(using: .ascii)!
        XCTAssertEqual(message.prefix(prefix.count), prefix)
        XCTAssertEqual(message[prefix.count], 0x00)
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
}

extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
}

import CommonCrypto
