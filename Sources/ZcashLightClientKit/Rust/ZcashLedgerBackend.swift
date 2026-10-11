//
//  ZcashLedgerBackend.swift
//  ZcashLightClientKit
//

import Foundation
import libzcashlc

/// A structured failure of a `zcashlc_ledger_*` call, read from the Rust layer's last error.
///
/// Its `reason` is built by the Rust layer to carry no APDU or reply bytes, PCZT, viewing key,
/// address, device identity or signature. It is converted into a ``ZcashError`` by
/// `ledgerZcashError(_:)` before it leaves the SDK.
struct LedgerFFIError: Error, Equatable {
    /// Mirrors `LedgerErrorKind` in `rust/src/ledger.rs`. Raw values are part of the FFI contract.
    enum Kind: UInt32 {
        case `internal` = 0
        case userRejected = 1
        case wrongApp = 2
        case appTooOld = 3
        case deviceMismatch = 4
        case capsMismatch = 5
        case derivationBudgetExhausted = 6
        case deviceRefused = 7
        case transactionNotSignable = 8
        case malformedReply = 9
        case invalidInput = 10
        case cmdNotAccepted = 11
    }

    let kind: Kind
    let statusWord: UInt16?
    let isTransient: Bool
    let isRestartable: Bool
    let reason: String

    /// Takes the last Rust error, clearing it. Must run on the thread of the failed call, with no
    /// suspension point in between: the Rust layer's last error is thread-local.
    static func takeLast(fallback: String) -> LedgerFFIError {
        guard let errorPtr = zcashlc_ledger_take_last_error() else {
            return .local(.internal, fallback)
        }

        defer { zcashlc_ledger_free_error(errorPtr) }

        let error = errorPtr.pointee
        return LedgerFFIError(
            kind: Kind(rawValue: error.kind) ?? .internal,
            statusWord: error.has_status_word ? error.status_word : nil,
            isTransient: error.is_transient,
            isRestartable: error.is_restartable,
            reason: error.reason.map { String(cString: $0) } ?? fallback
        )
    }

    /// A failure raised by the Swift layer itself, with no status word.
    static func local(_ kind: Kind, _ reason: String) -> LedgerFFIError {
        LedgerFFIError(kind: kind, statusWord: nil, isTransient: false, isRestartable: false, reason: reason)
    }
}

extension Data {
    /// Passes the bytes to a `zcashlc_ledger_*` call as a pointer and length. An empty value passes a
    /// null pointer, which the Rust layer accepts with a zero length.
    func withLedgerBytes<T>(_ body: (UnsafePointer<UInt8>?, UInt) throws -> T) rethrows -> T {
        try withUnsafeBytes { buffer in
            try body(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(buffer.count))
        }
    }
}

/// The only caller of the `zcashlc_ledger_*` functions that need no wallet database.
enum ZcashLedgerBackend {
    /// How many consecutive `0x6901` refusals a one-shot command is resent after.
    static let maxCmdNotAcceptedRetries = Int(zcashlc_ledger_max_cmd_not_accepted_retries())

    /// The pause before resending a command the device SDK refused with `0x6901`.
    static let cmdNotAcceptedBackoffNanoseconds = UInt64(zcashlc_ledger_cmd_not_accepted_backoff_ms()) * 1_000_000

    /// The timeout for a reply that does not wait on the user, in seconds.
    static let defaultTimeout = TimeInterval(zcashlc_ledger_default_timeout_ms()) / 1000

    // MARK: - One-shot commands

    static func firmwareVersionAPDU() throws -> Data {
        try takeBytes(zcashlc_ledger_firmware_version_apdu(), fallback: "`firmwareVersionAPDU` failed")
    }

    static func parseAppVersion(_ reply: Data) throws -> LedgerAppVersion {
        let versionPtr = reply.withLedgerBytes { bytes, count in
            zcashlc_ledger_parse_app_version(bytes, count)
        }

        guard let versionPtr else {
            throw LedgerFFIError.takeLast(fallback: "`parseAppVersion` failed with unknown error")
        }

        defer { zcashlc_ledger_free_app_version(versionPtr) }

        return LedgerAppVersion(
            major: versionPtr.pointee.major,
            minor: versionPtr.pointee.minor,
            patch: versionPtr.pointee.patch,
            supportsPczt: versionPtr.pointee.supports_pczt
        )
    }

    static func deviceIdentityAPDU(networkType: NetworkType) throws -> Data {
        try takeBytes(zcashlc_ledger_device_identity_apdu(networkType.networkId), fallback: "`deviceIdentityAPDU` failed")
    }

    static func parseDeviceIdentity(_ reply: Data) throws -> LedgerDeviceIdentity {
        let identityPtr = reply.withLedgerBytes { bytes, count in
            zcashlc_ledger_parse_device_identity(bytes, count)
        }

        guard let identityPtr else {
            throw LedgerFFIError.takeLast(fallback: "`parseDeviceIdentity` failed with unknown error")
        }

        defer { zcashlc_string_free(identityPtr) }

        return LedgerDeviceIdentity(validatedEncoding: String(cString: identityPtr))
    }

    static func validateDeviceIdentity(_ encoding: String) throws {
        guard zcashlc_ledger_validate_device_identity([CChar](encoding.utf8CString)) else {
            throw LedgerFFIError.takeLast(fallback: "`validateDeviceIdentity` failed with unknown error")
        }
    }

    /// Throws unless the transparent item of `ufvk`, the exported key of ZIP 32 account 0, derives
    /// `identity`. The key of any other account never derives it.
    ///
    /// - Throws: A `.deviceMismatch` failure when the identities differ, and a `.malformedReply`
    ///   failure when `ufvk` has no transparent item.
    static func checkAccountZeroIdentity(
        ufvk: UnifiedFullViewingKey,
        identity: LedgerDeviceIdentity,
        networkType: NetworkType
    ) throws {
        let matches = zcashlc_ledger_check_account_zero_identity(
            networkType.networkId,
            [CChar](ufvk.stringEncoded.utf8CString),
            [CChar](identity.stringEncoded.utf8CString)
        )
        guard matches else {
            throw LedgerFFIError.takeLast(fallback: "`checkAccountZeroIdentity` failed with unknown error")
        }
    }

    static func unifiedAddressAPDU(
        networkType: NetworkType,
        accountIndex: Zip32AccountIndex,
        transparentAddressIndex: UInt32,
        display: Bool
    ) throws -> Data {
        try takeBytes(
            zcashlc_ledger_unified_address_apdu(networkType.networkId, accountIndex.index, transparentAddressIndex, display),
            fallback: "`unifiedAddressAPDU` failed"
        )
    }

    static func parseUnifiedAddress(_ reply: Data, networkType: NetworkType) throws -> String {
        let addressPtr = reply.withLedgerBytes { bytes, count in
            zcashlc_ledger_parse_unified_address(bytes, count, networkType.networkId)
        }

        guard let addressPtr else {
            throw LedgerFFIError.takeLast(fallback: "`parseUnifiedAddress` failed with unknown error")
        }

        defer { zcashlc_string_free(addressPtr) }

        return String(cString: addressPtr)
    }

    /// The address the device displays for the account whose viewing key is `ufvk`, encoded as
    /// `parseUnifiedAddress(_:networkType:)` encodes the device's reply.
    ///
    /// - Throws: An `.invalidInput` failure when `ufvk` has no Orchard item.
    static func deviceUnifiedAddress(ufvk: UnifiedFullViewingKey, networkType: NetworkType) throws -> String {
        let addressPtr = zcashlc_ledger_device_unified_address(
            networkType.networkId,
            [CChar](ufvk.stringEncoded.utf8CString)
        )

        guard let addressPtr else {
            throw LedgerFFIError.takeLast(fallback: "`deviceUnifiedAddress` failed with unknown error")
        }

        defer { zcashlc_string_free(addressPtr) }

        return String(cString: addressPtr)
    }

    // MARK: - BLE framing

    static func bleMTURequest() throws -> Data {
        try takeBytes(zcashlc_ledger_ble_mtu_request(), fallback: "`bleMTURequest` failed")
    }

    /// The frame size the device announced in its MTU-handshake response.
    static func parseBLEMTUResponse(_ response: Data) throws -> Int {
        let frameSize = response.withLedgerBytes { bytes, count in
            zcashlc_ledger_parse_ble_mtu_response(bytes, count)
        }

        guard frameSize >= 0 else {
            throw LedgerFFIError.takeLast(fallback: "`parseBLEMTUResponse` failed with unknown error")
        }

        return Int(frameSize)
    }

    /// Splits a command into the BLE frames to write, in order.
    static func bleFrames(_ apdu: Data, frameSize: Int) throws -> [Data] {
        guard let frameSize = UInt32(exactly: frameSize) else {
            throw LedgerFFIError.local(.invalidInput, "the BLE frame size is out of range")
        }

        let framesPtr = apdu.withLedgerBytes { bytes, count in
            zcashlc_ledger_ble_frames(bytes, count, frameSize)
        }

        guard let framesPtr else {
            throw LedgerFFIError.takeLast(fallback: "`bleFrames` failed with unknown error")
        }

        defer { zcashlc_ledger_free_frames(framesPtr) }

        guard let firstFrame = framesPtr.pointee.ptr else {
            return []
        }

        return UnsafeBufferPointer(start: firstFrame, count: Int(framesPtr.pointee.len)).map { frame in
            Data(bytes: frame.ptr, count: Int(frame.len))
        }
    }

    // MARK: - Helpers

    /// Copies a boxed slice returned by a `zcashlc_ledger_*` call and frees it.
    static func takeBytes(_ slicePtr: UnsafeMutablePointer<FfiBoxedSlice>?, fallback: String) throws -> Data {
        guard let slicePtr else {
            throw LedgerFFIError.takeLast(fallback: "\(fallback) with unknown error")
        }

        defer { zcashlc_free_boxed_slice(slicePtr) }

        guard let bytes = slicePtr.pointee.ptr else {
            return Data()
        }

        return Data(bytes: bytes, count: Int(slicePtr.pointee.len))
    }
}

/// An in-progress export of one account's unified full viewing key.
///
/// The export is terminal on any error but `0x6901`: once it has failed it hands out no further
/// command, so the approval screen is never put back in front of a user who declined it.
final class LedgerUFVKExport {
    enum Step: Equatable {
        case moreChunks
        case retrySameAPDU
        case complete(String)
    }

    private let exportPtr: OpaquePointer

    init(networkType: NetworkType, accountIndex: Zip32AccountIndex) throws {
        guard let exportPtr = zcashlc_ledger_ufvk_export_new(networkType.networkId, accountIndex.index) else {
            throw LedgerFFIError.takeLast(fallback: "`LedgerUFVKExport.init` failed with unknown error")
        }

        self.exportPtr = exportPtr
    }

    deinit {
        zcashlc_ledger_free_ufvk_export(exportPtr)
    }

    /// Whether the reply to the next command waits on the user: until the device has answered the
    /// request that shows the export approval screen.
    var waitsForUser: Bool {
        zcashlc_ledger_ufvk_export_waits_for_user(exportPtr)
    }

    func nextAPDU() throws -> Data {
        try ZcashLedgerBackend.takeBytes(zcashlc_ledger_ufvk_export_next_apdu(exportPtr), fallback: "`LedgerUFVKExport.nextAPDU` failed")
    }

    func processResponse(_ reply: Data) throws -> Step {
        let stepPtr = reply.withLedgerBytes { bytes, count in
            zcashlc_ledger_ufvk_export_process_response(exportPtr, bytes, count)
        }

        guard let stepPtr else {
            throw LedgerFFIError.takeLast(fallback: "`LedgerUFVKExport.processResponse` failed with unknown error")
        }

        defer { zcashlc_ledger_free_ufvk_export_step(stepPtr) }

        switch Int32(bitPattern: stepPtr.pointee.status) {
        case ZCASHLC_LEDGER_UFVK_EXPORT_MORE_CHUNKS:
            return .moreChunks
        case ZCASHLC_LEDGER_UFVK_EXPORT_RETRY_SAME_APDU:
            return .retrySameAPDU
        case ZCASHLC_LEDGER_UFVK_EXPORT_COMPLETE:
            guard let ufvk = stepPtr.pointee.ufvk else {
                throw LedgerFFIError.local(.internal, "the viewing key export completed without a key")
            }
            return .complete(String(cString: ufvk))
        default:
            throw LedgerFFIError.local(.internal, "the viewing key export reported an unknown status")
        }
    }
}

/// Reassembles the notification frames of one BLE reply.
///
/// Not thread-safe on its own; ``LedgerBluetoothTransport`` confines it to its Bluetooth queue.
final class LedgerBLEDeframer {
    private let deframerPtr: OpaquePointer

    init() throws {
        guard let deframerPtr = zcashlc_ledger_ble_deframer_new() else {
            throw LedgerFFIError.takeLast(fallback: "`LedgerBLEDeframer.init` failed with unknown error")
        }

        self.deframerPtr = deframerPtr
    }

    deinit {
        zcashlc_ledger_free_ble_deframer(deframerPtr)
    }

    /// Absorbs one frame, returning the complete reply on the frame that finishes it.
    ///
    /// A refused frame poisons the deframer: the connection it belongs to must be closed.
    func push(_ frame: Data) throws -> Data? {
        let replyPtr = frame.withLedgerBytes { bytes, count in
            zcashlc_ledger_ble_deframer_push(deframerPtr, bytes, count)
        }

        guard let replyPtr else {
            throw LedgerFFIError.takeLast(fallback: "`LedgerBLEDeframer.push` failed with unknown error")
        }

        defer { zcashlc_free_boxed_slice(replyPtr) }

        guard let bytes = replyPtr.pointee.ptr else {
            return nil
        }

        return Data(bytes: bytes, count: Int(replyPtr.pointee.len))
    }
}
