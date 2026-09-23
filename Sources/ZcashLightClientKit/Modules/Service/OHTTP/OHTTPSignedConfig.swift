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
    let configBytes: Data
    let keyId: UInt8
    let validUntil: Int64
}

/// Exception thrown when signed config verification fails.
enum KeyConfigVerificationError: Error, CustomStringConvertible {
    case networkError(String)
    case invalidEnvelope(String)
    case verificationFailed(String)
    
    var description: String {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidEnvelope(let msg): return "Invalid envelope: \(msg)"
        case .verificationFailed(let msg): return "Verification failed: \(msg)"
        }
    }
}

/// Fetches and verifies signed OHTTP key configurations.
///
/// Implements fail-closed security: any verification failure results in
/// OHTTP being unavailable (no fallback to unsigned configs in production).
enum OHTTPSignedConfigFetcher {
    // Embedded signing public keys (32 bytes raw Ed25519 public keys, hex)
    private static let mainnetPublicKeyHex = "REDACTED-SIGNING-PUBKEY-MAINNET"
    private static let testnetPublicKeyHex = "REDACTED-SIGNING-PUBKEY-TESTNET"
    
    // Expected key IDs (first 8 hex of SHA-256(public key))
    private static let mainnetKeyId = "ba8a2dbd"
    private static let testnetKeyId = "a3620fb6"
    
    // Time tolerance (±60 seconds for clock skew)
    private static let timeTolerance: Int64 = 60
    
    /// Fetches and verifies signed OHTTP configs from the relay endpoint.
    ///
    /// - Parameters:
    ///   - relayBaseURL: Base URL of the relay (e.g. "https://testnet-simulator-relay.example.invalid")
    ///   - network: Network identifier ("mainnet" or "testnet")
    ///   - allowUnsignedFallback: If true, falls back to unsigned /ohttp-configs on verification failure (DEBUG ONLY)
    /// - Returns: Verified configuration ready for use
    /// - Throws: KeyConfigVerificationError if verification fails and no fallback allowed
    static func fetchAndVerify(
        relayBaseURL: String,
        network: String,
        allowUnsignedFallback: Bool = false
    ) async throws -> VerifiedOHTTPConfig {
        let signedURL = deriveSignedConfigURL(from: relayBaseURL)
        
        do {
            let envelope = try await fetchEnvelope(from: signedURL)
            return try verifyAndExtract(envelope: envelope, expectedNetwork: network)
        } catch {
            if allowUnsignedFallback {
                print("[OHTTP] WARNING: Falling back to unsigned configs (DEBUG MODE)")
                return try await fetchUnsignedFallback(relayBaseURL: relayBaseURL)
            }
            throw KeyConfigVerificationError.verificationFailed("Failed to fetch or verify signed OHTTP configs: \(error)")
        }
    }
    
    /// Derives the signed config URL from the relay base URL.
    /// Replaces the path with /ohttp-configs/signed.
    private static func deriveSignedConfigURL(from relayBaseURL: String) -> String {
        var url = relayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let range = url.range(of: "/relay", options: .backwards) {
            url = String(url[..<range.lowerBound])
        } else if let lastSlash = url.lastIndex(of: "/") {
            url = String(url[..<lastSlash])
        }
        return url + "/ohttp-configs/signed"
    }
    
    /// Fetches the signed envelope from the given URL.
    private static func fetchEnvelope(from urlString: String) async throws -> SignedOHTTPConfigEnvelope {
        guard let url = URL(string: urlString) else {
            throw KeyConfigVerificationError.networkError("Invalid URL: \(urlString)")
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KeyConfigVerificationError.networkError("HTTP \(code) fetching signed configs")
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(SignedOHTTPConfigEnvelope.self, from: data)
    }
    
    /// Verifies the envelope signature and extracts the config.
    ///
    /// Checks:
    /// 1. Protocol version == 1
    /// 2. Network matches expected
    /// 3. Key ID matches embedded public key
    /// 4. Signature is valid (Ed25519)
    /// 5. Current time within [not_before - tolerance, not_after + tolerance]
    private static func verifyAndExtract(
        envelope: SignedOHTTPConfigEnvelope,
        expectedNetwork: String
    ) throws -> VerifiedOHTTPConfig {
        // 1. Check protocol version
        guard envelope.v == 1 else {
            throw KeyConfigVerificationError.invalidEnvelope("Unsupported protocol version: \(envelope.v)")
        }
        
        // 2. Check network
        guard envelope.network == expectedNetwork else {
            throw KeyConfigVerificationError.invalidEnvelope(
                "Network mismatch: expected \(expectedNetwork), got \(envelope.network)"
            )
        }
        
        // 3. Select public key and verify key ID
        let (publicKeyHex, expectedKeyId) = try selectKey(for: expectedNetwork)
        
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
        
        // Extract key ID from first byte of configs
        let keyId = configData.first ?? 0
        
        return VerifiedOHTTPConfig(configBytes: configData, keyId: keyId, validUntil: envelope.not_after)
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
    
    /// Unsigned fallback (DEBUG ONLY) - fetches raw RFC 9458 configs without signature verification.
    private static func fetchUnsignedFallback(relayBaseURL: String) async throws -> VerifiedOHTTPConfig {
        var url = relayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let range = url.range(of: "/relay", options: .backwards) {
            url = String(url[..<range.lowerBound])
        }
        url += "/ohttp-configs"
        
        guard let fetchURL = URL(string: url) else {
            throw KeyConfigVerificationError.networkError("Invalid unsigned config URL")
        }
        
        let (data, response) = try await URLSession.shared.data(from: fetchURL)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KeyConfigVerificationError.networkError("HTTP \(code) fetching unsigned configs")
        }
        
        let keyId = data.first ?? 0
        return VerifiedOHTTPConfig(configBytes: data, keyId: keyId, validUntil: Int64.max)
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
