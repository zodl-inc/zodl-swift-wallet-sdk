//
//  OHTTPKeyConfig.swift
//  ZcashLightClientKit
//
//  OHTTP key configuration parsing (RFC 9458 §3.1).
//

import Foundation

/// One HPKE key configuration from an `application/ohttp-keys` document (RFC 9458 §3.1).
struct OHTTPKeyConfig {
    let keyId: UInt8
    let kemId: UInt16
    let publicKey: Data
    let kdfId: UInt16
    let aeadId: UInt16

    /// `hdr = key_id || kem_id || kdf_id || aead_id` (RFC 9458 §4.3).
    func header() -> Data {
        var data = Data([keyId])
        data.append(OHTTPHPKE.i2osp(kemId, 2))
        data.append(OHTTPHPKE.i2osp(kdfId, 2))
        data.append(OHTTPHPKE.i2osp(aeadId, 2))
        return data
    }

    /// Parses an `application/ohttp-keys` body and returns the first key config that uses the
    /// suite this client implements (X25519 / HKDF-SHA256 / AES-128-GCM).
    static func parseSupported(_ bytes: Data) throws -> OHTTPKeyConfig {
        var pos = 0

        func u8() throws -> UInt8 {
            guard pos < bytes.count else {
                throw OHTTPError.keyConfigError("Truncated OHTTP key config")
            }
            let value = bytes[pos]
            pos += 1
            return value
        }

        func u16() throws -> UInt16 {
            let high = try u8()
            let low = try u8()
            return (UInt16(high) << 8) | UInt16(low)
        }

        while pos + 2 <= bytes.count {
            let configLength = try u16()
            let end = pos + Int(configLength)
            guard end <= bytes.count else {
                throw OHTTPError.keyConfigError("Truncated OHTTP key config")
            }

            let keyId = try u8()
            let kemId = try u16()
            guard kemId == OHTTPHPKE.kemID else {
                pos = end
                continue
            }

            guard pos + OHTTPHPKE.nPk <= bytes.count else {
                throw OHTTPError.keyConfigError("Truncated public key")
            }
            let publicKey = bytes.subdata(in: pos..<pos + OHTTPHPKE.nPk)
            pos += OHTTPHPKE.nPk

            let suitesLength = try u16()
            let suitesEnd = pos + Int(suitesLength)
            guard suitesEnd <= end else {
                throw OHTTPError.keyConfigError("Truncated OHTTP symmetric suites")
            }

            while pos + 4 <= suitesEnd {
                let kdfId = try u16()
                let aeadId = try u16()
                if kdfId == OHTTPHPKE.kdfID && aeadId == OHTTPHPKE.aeadID {
                    return OHTTPKeyConfig(
                        keyId: keyId,
                        kemId: kemId,
                        publicKey: publicKey,
                        kdfId: kdfId,
                        aeadId: aeadId
                    )
                }
            }

            pos = end
        }

        throw OHTTPError.keyConfigError("No supported HPKE suite in OHTTP key configuration")
    }
}
