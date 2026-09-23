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
    let v: Int
    let network: String
    let configs: String  // Base64-encoded RFC 9458 key config bytes
    let not_before: Int64
    let not_after: Int64
    let key_id: String
    let sig: String  // Base64-encoded Ed25519 signature
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
    /// - Returns: Verified config and expiry time
    /// - Throws: KeyConfigVerificationError if verification fails
    static func verifyAndParse(jsonData: Data, network: String) throws -> VerifiedOHTTPConfig {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(SignedOHTTPConfigEnvelope.self, from: jsonData)
        
        // 1. Check protocol version
        guard envelope.v == 1 else {
            throw KeyConfigVerificationError.invalidEnvelope("Unsupported protocol version: \(envelope.v)")
        }
        
        // 2. Check network
        guard envelope.network == network else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Network mismatch: expected \(network), got \(envelope.network)"
            )
        }
        
        // 3. Select public key and verify key ID
        let (publicKeyHex, expectedKeyId) = try selectKey(for: network)
        
        guard envelope.key_id == expectedKeyId else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Key ID mismatch: expected \(expectedKeyId), got \(envelope.key_id)"
            )
        }
        
        // 4. Decode and verify Ed25519 signature
        guard let configData = Data(base64Encoded: envelope.configs),
              let signatureData = Data(base64Encoded: envelope.sig),
              let publicKeyData = Data(hexString: publicKeyHex) else {
            throw KeyConfigVerificationError.invalidEnvelope("Failed to decode base64/hex data")
        }
        
        let message = buildSignedMessage(
            network: envelope.network,
            notBefore: envelope.not_before,
            notAfter: envelope.not_after,
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
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let minValid = envelope.not_before - timeTolerance
        let maxValid = envelope.not_after + timeTolerance
        
        guard nowSeconds >= minValid && nowSeconds <= maxValid else {
            throw KeyConfigVerificationError.verificationFailed(
                "Config not valid at current time: now=\(nowSeconds), valid=[\(minValid), \(maxValid)]"
            )
        }
        
        // 6. Enforce maximum validity period (24 hours)
        let validityPeriod = envelope.not_after - envelope.not_before
        guard validityPeriod <= maxValiditySeconds else {
            throw KeyConfigVerificationError.verificationFailed(
                "Validity period \(validityPeriod)s exceeds maximum \(maxValiditySeconds)s"
            )
        }
        
        // Additional check: notAfter must not be more than 24h in the future
        let maxFutureTime = nowSeconds + maxValiditySeconds
        guard envelope.not_after <= maxFutureTime else {
            throw KeyConfigVerificationError.verificationFailed(
                "notAfter \(envelope.not_after) exceeds maximum future time \(maxFutureTime)"
            )
        }
        
        // 7. Parse the config bytes into OHTTPKeyConfig
        let parsedConfig = try OHTTPKeyConfig.parseSupported(configData)
        
        return VerifiedOHTTPConfig(
            keyConfig: parsedConfig,
            validUntil: Date(timeIntervalSince1970: TimeInterval(envelope.not_after))
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
