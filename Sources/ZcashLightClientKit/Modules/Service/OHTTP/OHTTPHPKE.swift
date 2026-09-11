//
//  OHTTPHPKE.swift
//  ZcashLightClientKit
//
//  HPKE (RFC 9180) sender side, Base mode, for the OHTTP cipher suite
//  DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM.
//
//  Only what OHTTP (RFC 9458) needs is implemented: `SetupBaseS`, `Seal` and `Export`.
//  Built from CryptoKit primitives available on iOS 13+.
//

import Foundation
import CryptoKit

/// HPKE (RFC 9180) implementation for OHTTP using CryptoKit.
enum OHTTPHPKE {
    static let kemID: UInt16 = 0x0020
    static let kdfID: UInt16 = 0x0001
    static let aeadID: UInt16 = 0x0001

    static let nPk: Int = 32  // X25519 public key size
    static let nEnc: Int = 32  // Encapsulated key size
    static let nSecret: Int = 32  // KEM shared secret size
    static let nH: Int = 32  // SHA-256 output size
    static let nK: Int = 16  // AES-128-GCM key size
    static let nN: Int = 12  // AES-GCM nonce size
    static let nT: Int = 16  // AES-GCM tag size

    private static let modeBase: UInt8 = 0x00
    private static let versionLabel = "HPKE-v1".data(using: .ascii)!
    private static let kemSuiteID = "KEM".data(using: .ascii)! + i2osp(kemID, 2)
    private static let hpkeSuiteID = "HPKE".data(using: .ascii)! + i2osp(kemID, 2) + i2osp(kdfID, 2) + i2osp(aeadID, 2)

    /// Sender context returned by `setupBaseS`. Holds the AEAD key material and the exporter secret.
    struct SenderContext {
        let enc: Data
        private let key: Data
        private let baseNonce: Data
        private let exporterSecret: Data
        private var sequence: UInt64 = 0

        init(enc: Data, key: Data, baseNonce: Data, exporterSecret: Data) {
            self.enc = enc
            self.key = key
            self.baseNonce = baseNonce
            self.exporterSecret = exporterSecret
        }

        /// RFC 9180 §5.2 `ContextS.Seal(aad, pt)`.
        mutating func seal(aad: Data, plaintext: Data) throws -> Data {
            let nonce = computeNonce(baseNonce: baseNonce, sequence: sequence)
            sequence += 1
            return try aesGcmSeal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        }

        /// RFC 9180 §5.3 `Context.Export(exporter_context, L)`.
        func export(exporterContext: Data, length: Int) throws -> Data {
            return try labeledExpand(
                suiteID: OHTTPHPKE.hpkeSuiteID,
                prk: exporterSecret,
                label: "sec",
                info: exporterContext,
                length: length
            )
        }
    }

    /// RFC 9180 §5.1.1 `SetupBaseS(pkR, info)`.
    static func setupBaseS(recipientPublicKey: Data, info: Data) throws -> SenderContext {
        guard recipientPublicKey.count == nPk else {
            throw OHTTPError.hpkeError("Recipient public key must be \(nPk) bytes")
        }

        // DHKEM(X25519).Encap(pkR) — RFC 9180 §4.1
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let pkE = ephemeralPrivate.publicKey.rawRepresentation
        let pkR = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)

        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: pkR)

        // Extract the raw DH result
        let dh = sharedSecret.withUnsafeBytes { Data($0) }

        let enc = pkE
        let kemContext = enc + recipientPublicKey
        let eaePrk = try labeledExtract(
            suiteID: kemSuiteID,
            salt: Data(count: 0),
            label: "eae_prk",
            ikm: dh
        )
        let sharedSecretDerived = try labeledExpand(
            suiteID: kemSuiteID,
            prk: eaePrk,
            label: "shared_secret",
            info: kemContext,
            length: nSecret
        )

        // KeySchedule(mode_base, shared_secret, info, psk="", psk_id="") — RFC 9180 §5.1
        let pskIdHash = try labeledExtract(
            suiteID: hpkeSuiteID,
            salt: Data(count: 0),
            label: "psk_id_hash",
            ikm: Data(count: 0)
        )
        let infoHash = try labeledExtract(
            suiteID: hpkeSuiteID,
            salt: Data(count: 0),
            label: "info_hash",
            ikm: info
        )
        let keyScheduleContext = Data([modeBase]) + pskIdHash + infoHash
        let secret = try labeledExtract(
            suiteID: hpkeSuiteID,
            salt: sharedSecretDerived,
            label: "secret",
            ikm: Data(count: 0)
        )
        let key = try labeledExpand(
            suiteID: hpkeSuiteID,
            prk: secret,
            label: "key",
            info: keyScheduleContext,
            length: nK
        )
        let baseNonce = try labeledExpand(
            suiteID: hpkeSuiteID,
            prk: secret,
            label: "base_nonce",
            info: keyScheduleContext,
            length: nN
        )
        let exporterSecret = try labeledExpand(
            suiteID: hpkeSuiteID,
            prk: secret,
            label: "exp",
            info: keyScheduleContext,
            length: nH
        )

        return SenderContext(enc: enc, key: key, baseNonce: baseNonce, exporterSecret: exporterSecret)
    }

    // MARK: - HKDF primitives (RFC 5869)

    /// `Extract(salt, ikm)` = HMAC-SHA256(salt, ikm).
    static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let actualSalt = salt.isEmpty ? Data(count: nH) : salt
        let key = SymmetricKey(data: actualSalt)
        let hmac = HMAC<SHA256>.authenticationCode(for: ikm, using: key)
        return Data(hmac)
    }

    /// `Expand(prk, info, L)`.
    static func hkdfExpand(prk: Data, info: Data, length: Int) throws -> Data {
        let key = SymmetricKey(data: prk)
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1

        while output.count < length {
            var current = previous + info + Data([counter])
            let hmac = HMAC<SHA256>.authenticationCode(for: current, using: key)
            previous = Data(hmac)
            output.append(previous)
            counter += 1
        }

        return output.prefix(length)
    }

    private static func labeledExtract(suiteID: Data, salt: Data, label: String, ikm: Data) throws -> Data {
        let labelData = label.data(using: .ascii)!
        let combined = versionLabel + suiteID + labelData + ikm
        return hkdfExtract(salt: salt, ikm: combined)
    }

    private static func labeledExpand(
        suiteID: Data,
        prk: Data,
        label: String,
        info: Data,
        length: Int
    ) throws -> Data {
        let labelData = label.data(using: .ascii)!
        let combined = i2osp(UInt16(length), 2) + versionLabel + suiteID + labelData + info
        return try hkdfExpand(prk: prk, info: combined, length: length)
    }

    // MARK: - AEAD

    static func aesGcmSeal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
        guard key.count == nK, nonce.count == nN else {
            throw OHTTPError.hpkeError("Invalid key or nonce size")
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonceValue = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonceValue, authenticating: aad)

        // Combine ciphertext and tag
        return sealedBox.ciphertext + sealedBox.tag
    }

    static func aesGcmOpen(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
        guard key.count == nK, nonce.count == nN else {
            throw OHTTPError.hpkeError("Invalid key or nonce size")
        }
        guard ciphertext.count >= nT else {
            throw OHTTPError.hpkeError("Ciphertext too short")
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonceValue = try AES.GCM.Nonce(data: nonce)

        let actualCiphertext = ciphertext.prefix(ciphertext.count - nT)
        let tag = ciphertext.suffix(nT)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonceValue, ciphertext: actualCiphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
    }

    private static func computeNonce(baseNonce: Data, sequence: UInt64) -> Data {
        var nonce = baseNonce
        let seq = i2osp(sequence, nN)
        for i in 0..<nonce.count {
            nonce[i] ^= seq[i]
        }
        return nonce
    }

    // MARK: - Encoding

    static func i2osp(_ value: UInt16, _ length: Int) -> Data {
        return i2osp(UInt64(value), length)
    }

    static func i2osp(_ value: UInt64, _ length: Int) -> Data {
        var data = Data(count: length)
        for i in 0..<length {
            let shift = (length - 1 - i) * 8
            data[i] = UInt8((value >> shift) & 0xFF)
        }
        return data
    }
}

/// OHTTP-specific errors.
enum OHTTPError: Error {
    case hpkeError(String)
    case binaryHttpError(String)
    case transportError(String)
    case keyConfigError(String)
}
