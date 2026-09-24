//
//  OHTTPSignedConfig.swift
//  ZcashLightClientKit
//
//  Signed OHTTP configuration envelope (RFC 9458 key configs with Ed25519 signature).
//
//  Prevents MITM attacks on key configuration by requiring a valid signature from
//  the ZODL signing key. The envelope includes network context, validity period,
//  and key ID for crypto-agility.
//

import Foundation
import CryptoKit

/// Signed OHTTP configuration envelope.
struct SignedOHTTPConfigEnvelope: Codable {
    let version: Int
    let network: String
    let configs: String  // Base64-encoded RFC 9458 key config bytes
    let notBefore: Int64
    let notAfter: Int64
    let keyId: String
    let signature: String  // Base64-encoded Ed25519 signature

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case network
        case configs
        case notBefore = "not_before"
        case notAfter = "not_after"
        case keyId = "key_id"
        case signature = "sig"
    }
}

/// Verified OHTTP configuration from signed envelope.
struct VerifiedOHTTPConfig {
    let keyConfig: OHTTPKeyConfig
    let validUntil: Date
}

/// Exception thrown when signed config verification fails.
enum KeyConfigVerificationError: Error, CustomStringConvertible {
    case invalidEnvelope(String)
    case verificationFailed(String)
    
    var description: String {
        switch self {
        case .invalidEnvelope(let msg): return "Invalid envelope: \(msg)"
        case .verificationFailed(let msg): return "Verification failed: \(msg)"
        }
    }
}

/// Pure verifier for signed OHTTP key configurations. No network I/O.
enum OHTTPSignedConfigVerifier {
    // Embedded signing public keys (32 bytes raw Ed25519 public keys, hex)
    private static let mainnetPublicKeyHex = "REDACTED-SIGNING-PUBKEY-MAINNET"
    private static let testnetPublicKeyHex = "REDACTED-SIGNING-PUBKEY-TESTNET"
    
    // Expected key IDs (first 8 hex of SHA-256(public key))
    private static let mainnetKeyId = "ba8a2dbd"
    private static let testnetKeyId = "a3620fb6"
    
    // Time tolerance (±60 seconds for clock skew)
    private static let timeTolerance: Int64 = 60
    
    // Maximum validity period (24 hours)
    private static let maxValiditySeconds: Int64 = 86400
    
    /// Verifies and parses a signed OHTTP config envelope (pure function, no network I/O).
    ///
    /// - Parameters:
    ///   - jsonData: Raw JSON envelope bytes
    ///   - network: Expected network identifier ("mainnet" or "testnet")
    ///   - now: Clock for time validation (default: system time; tests inject fixed clock)
    ///   - testKeyId: Test key ID (for tests only; bypasses production key selection)
    ///   - testPublicKeyHex: Test public key hex (for tests only; bypasses production key)
    /// - Returns: Verified config and expiry time
    /// - Throws: KeyConfigVerificationError if verification fails
    static func verifyAndParse(
        jsonData: Data,
        network: String,
        now: @autoclosure () -> Date = Date(),
        testKeyId: String? = nil,
        testPublicKeyHex: String? = nil
    ) throws -> VerifiedOHTTPConfig {
        // P6: Detect duplicate JSON keys before decoding
        try validateNoDuplicateKeys(jsonData)

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SignedOHTTPConfigEnvelope.self, from: jsonData)

        // 1. Check protocol version
        guard envelope.version == 1 else {
            throw KeyConfigVerificationError.invalidEnvelope("Unsupported protocol version: \(envelope.version)")
        }

        // 2. Check network
        guard envelope.network == network else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Network mismatch: expected \(network), got \(envelope.network)"
            )
        }

        // 3. Select public key and verify key ID
        let (publicKeyHex, expectedKeyId): (String, String)
        if let testKey = testPublicKeyHex, let testId = testKeyId {
            (publicKeyHex, expectedKeyId) = (testKey, testId)
        } else {
            (publicKeyHex, expectedKeyId) = try selectKey(for: network)
        }

        guard envelope.keyId == expectedKeyId else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Key ID mismatch: expected \(expectedKeyId), got \(envelope.keyId)"
            )
        }
        
        // 4. Decode and verify Ed25519 signature
        guard let configData = Data(base64Encoded: envelope.configs),
              let signatureData = Data(base64Encoded: envelope.signature),
              let publicKeyData = Data(hexString: publicKeyHex) else {
            throw KeyConfigVerificationError.invalidEnvelope("Failed to decode base64/hex data")
        }

        // P4: Reject configs exceeding 4096 bytes (decoded)
        guard configData.count <= 4096 else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Decoded configs size \(configData.count) exceeds 4096 byte limit"
            )
        }
        
        let message = buildSignedMessage(
            network: envelope.network,
            notBefore: envelope.notBefore,
            notAfter: envelope.notAfter,
            configBytes: configData
        )
        
        guard try verifyEd25519Signature(
            publicKey: publicKeyData,
            message: message,
            signature: signatureData
        ) else {
            throw KeyConfigVerificationError.verificationFailed("Invalid Ed25519 signature")
        }
        
        // 5. Check time validity
        let nowSeconds = Int64(now().timeIntervalSince1970)
        let minValid = envelope.notBefore - timeTolerance
        let maxValid = envelope.notAfter + timeTolerance

        // P5: Strict ordering check (not_before < not_after)
        guard envelope.notBefore < envelope.notAfter else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Invalid time bounds: not_before (\(envelope.notBefore)) must be < not_after (\(envelope.notAfter))"
            )
        }

        guard nowSeconds >= minValid && nowSeconds <= maxValid else {
            throw KeyConfigVerificationError.verificationFailed(
                "Config not valid at current time: now=\(nowSeconds), valid=[\(minValid), \(maxValid)]"
            )
        }

        // 6. Enforce maximum validity period (24 hours)
        let validityPeriod = envelope.notAfter - envelope.notBefore
        guard validityPeriod <= maxValiditySeconds else {
            throw KeyConfigVerificationError.verificationFailed(
                "Validity period \(validityPeriod)s exceeds maximum \(maxValiditySeconds)s"
            )
        }

        // Additional check: notAfter must not be more than 24h in the future
        let maxFutureTime = nowSeconds + maxValiditySeconds
        guard envelope.notAfter <= maxFutureTime else {
            throw KeyConfigVerificationError.verificationFailed(
                "notAfter \(envelope.notAfter) exceeds maximum future time \(maxFutureTime)"
            )
        }
        
        // 7. Parse the config bytes into OHTTPKeyConfig
        let parsedConfig = try OHTTPKeyConfig.parseSupported(configData)
        
        return VerifiedOHTTPConfig(
            keyConfig: parsedConfig,
            validUntil: Date(timeIntervalSince1970: TimeInterval(envelope.notAfter))
        )
    }
    
    /// Selects the public key and expected key ID for the given network.
    private static func selectKey(for network: String) throws -> (String, String) {
        switch network {
        case "mainnet":
            return (mainnetPublicKeyHex, mainnetKeyId)
        case "testnet":
            return (testnetPublicKeyHex, testnetKeyId)
        default:
            throw KeyConfigVerificationError.invalidEnvelope("Unknown network: \(network)")
        }
    }
    
    /// Builds the message that was signed: "zodl-ohttp-configs-v1" || 0x00 || network || 0x00 || not_before || not_after || configs
    private static func buildSignedMessage(
        network: String,
        notBefore: Int64,
        notAfter: Int64,
        configBytes: Data
    ) -> Data {
        var message = Data()
        message.append("zodl-ohttp-configs-v1".data(using: .ascii)!)
        message.append(0x00)
        message.append(network.data(using: .ascii)!)
        message.append(0x00)
        message.append(contentsOf: withUnsafeBytes(of: notBefore.bigEndian) { Data($0) })
        message.append(contentsOf: withUnsafeBytes(of: notAfter.bigEndian) { Data($0) })
        message.append(configBytes)
        return message
    }
    
    /// Verifies an Ed25519 signature using CryptoKit.
    private static func verifyEd25519Signature(
        publicKey: Data,
        message: Data,
        signature: Data
    ) throws -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw KeyConfigVerificationError.verificationFailed("Invalid Ed25519 public key")
        }

        return key.isValidSignature(signature, for: message)
    }

    /// P6: Validates that JSON contains no duplicate keys by parsing with JSONSerialization
    /// and checking that re-serialization matches in key count.
    private static func validateNoDuplicateKeys(_ jsonData: Data) throws {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData),
              let dict = jsonObject as? [String: Any] else {
            throw KeyConfigVerificationError.invalidEnvelope("Invalid JSON structure")
        }

        // Parse the raw JSON string to count actual keys (including duplicates)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KeyConfigVerificationError.invalidEnvelope("JSON data not UTF-8")
        }

        // Simple heuristic: count occurrences of quoted keys vs dictionary size
        // A proper check would require a streaming parser, but for the envelope's 7 known keys,
        // we can detect duplicates by checking if JSONSerialization's dict has fewer keys than
        // the number of key patterns in the raw string.
        let expectedKeys = ["v", "network", "configs", "not_before", "not_after", "key_id", "sig"]
        var keyCount = 0
        for key in expectedKeys {
            // Count occurrences of "key": in the JSON (simple pattern, assumes standard formatting)
            let pattern = "\"\(key)\""
            keyCount += jsonString.components(separatedBy: pattern).count - 1
        }

        // If we found more key occurrences than dictionary entries, there are duplicates
        guard keyCount == dict.count else {
            throw KeyConfigVerificationError.invalidEnvelope("Duplicate JSON keys detected")
        }
    }
}

// MARK: - Helper Extensions

extension Data {
    /// Initializes Data from a hex string.
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
