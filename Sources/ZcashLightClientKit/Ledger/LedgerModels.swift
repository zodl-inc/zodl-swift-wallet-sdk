//
//  LedgerModels.swift
//  ZcashLightClientKit
//

import Foundation

/// The stable name of one Ledger device on one network: `tpk0-` followed by 64 lowercase hex digits.
///
/// It is a hash of the public key the device derives at `m/44'/coin'/0'/0/0`, so two devices restored
/// from the same seed share it and devices with different seeds do not. The signing ceremony reads it
/// back from the connected device before it sends anything of a transaction, and refuses a device
/// that answers with another identity.
///
/// The value is not a secret, but it is linkable: once the first transparent address of the device's
/// first account has spent on chain, anyone can match the identity to that address. Store it next to
/// the paired account and never log it. `description` and reflection print a placeholder; the value
/// itself is available through ``stringEncoded`` for persistence.
public struct LedgerDeviceIdentity: Equatable, Hashable, Sendable, StringEncoded, Undescribable {
    let encoding: String

    public var stringEncoded: String { encoding }

    /// Validates a stored device identity.
    ///
    /// - Parameter encoding: The value ``stringEncoded`` returned when the identity was stored.
    /// - Throws: ``ZcashError/ledgerInvalidInput(_:)`` when the value is not a well-formed identity. The
    ///   error never repeats the value.
    public init(encoding: String) throws {
        do {
            try ZcashLedgerBackend.validateDeviceIdentity(encoding)
        } catch {
            throw ledgerZcashError(error)
        }
        self.encoding = encoding
    }

    /// Wraps an identity the Rust layer produced or validated.
    init(validatedEncoding: String) {
        self.encoding = validatedEncoding
    }
}

extension LedgerDeviceIdentity: Codable {
    /// Decodes the identity from its string encoding, validating it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(encoding: try container.decode(String.self))
    }

    /// Encodes the identity as its string encoding.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoding)
    }
}

/// The version of the Zcash app running on a Ledger device.
public struct LedgerAppVersion: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: UInt8
    public let minor: UInt8
    public let patch: UInt8

    /// Whether this version can sign transactions for this SDK.
    ///
    /// Zcash app 3.6.0 introduced the PCZT instructions; a transaction with Ironwood outputs further
    /// needs 3.9.0. The signing session applies both rules.
    public let supportsPczt: Bool

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}

/// What a wallet stores next to an account imported from a Ledger device, and passes back when the
/// account signs.
public struct LedgerAccountBinding: Equatable, Hashable, Codable, Sendable {
    /// The device the account was paired with.
    public let deviceIdentity: LedgerDeviceIdentity

    /// The ZIP 32 account index the account was exported at.
    public let zip32AccountIndex: Zip32AccountIndex

    public init(deviceIdentity: LedgerDeviceIdentity, zip32AccountIndex: Zip32AccountIndex) {
        self.deviceIdentity = deviceIdentity
        self.zip32AccountIndex = zip32AccountIndex
    }
}

/// The result of pairing an account on a Ledger device.
///
/// Import ``ufvk`` with `Synchronizer.importAccount(ufvk:seedFingerprint:zip32AccountIndex:purpose:name:keySource:birthday:)`,
/// passing `nil` for the seed fingerprint and the ZIP 32 account index (a Ledger never reveals its seed
/// fingerprint), `.spending` as the purpose and ``Account/ledgerKeySource`` as the key source, and store
/// ``binding`` next to the imported account.
public struct LedgerAccountPairing: Equatable, Sendable {
    /// The account's unified full viewing key, exported by the device after the user approved it.
    public let ufvk: UnifiedFullViewingKey

    /// The device and account index, to store next to the imported account.
    public let binding: LedgerAccountBinding

    /// The Zcash app version the device was running when the account was paired.
    public let appVersion: LedgerAppVersion
}

/// Where a Ledger signing ceremony is.
public enum LedgerSigningProgress: Equatable, Sendable {
    /// Checking that the connected device runs a suitable Zcash app and is the paired device.
    case identifyingDevice
    /// Sending the transaction to the device: `sent` of `total` commands acknowledged.
    case streaming(sent: Int, total: Int)
    /// The device is showing the transaction for the user to review. No timeout applies until the user
    /// approves or rejects it on the device.
    case awaitingReviewOnDevice
    /// The user approved the transaction and the device is producing its signatures.
    case signing
    /// Every signature has been collected and applied.
    case complete
}
