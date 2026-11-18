//
//  OHTTPNativeThirdPartyHosts.swift
//
//  Swift wrappers of the gateway's third-party host list FFI.
//

import Foundation
import os
import libzcashlc

/// What ending a refresh of a gateway host list did.
enum OHTTPHostListRefreshOutcome: UInt32, Equatable {
    /// The list was replaced.
    case updated = 0
    /// The gateway confirmed the list held.
    case notModified = 1
    /// The list held was kept, and a backoff began.
    case kept = 2
    /// Nothing was changed: the refresh was already ended or superseded.
    case superseded = 3
}

/// One begun refresh. Finish or fail it once; releasing it unfinished fails it.
final class OHTTPHostListRefresh: @unchecked Sendable {
    let authority: String
    let path: String
    let ifNoneMatch: String?

    private let pointer: OSAllocatedUnfairLock<OpaquePointer?>

    init(pointer: OpaquePointer) {
        self.authority = OHTTPHostListRefresh.string(zcashlc_ohttp_third_party_refresh_authority(pointer)) ?? ""
        self.path = OHTTPHostListRefresh.string(zcashlc_ohttp_third_party_refresh_path(pointer)) ?? ""
        self.ifNoneMatch = OHTTPHostListRefresh.string(zcashlc_ohttp_third_party_refresh_if_none_match(pointer))
        self.pointer = OSAllocatedUnfairLock<OpaquePointer?>(uncheckedState: pointer)
    }

    deinit {
        if let remaining = takePointer() {
            zcashlc_ohttp_third_party_free_refresh(remaining)
        }
    }

    /// Ends the refresh with the gateway's answer. A status outside `0...65535` is passed as `0`.
    func finish(status: Int, body: Data) -> OHTTPHostListRefreshOutcome {
        guard let taken = takePointer() else {
            return .superseded
        }
        let code = UInt16(exactly: status) ?? 0
        let result: UInt32 = body.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt32 in
            zcashlc_ohttp_third_party_finish_refresh(
                taken,
                code,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        return OHTTPHostListRefreshOutcome(rawValue: result) ?? .superseded
    }

    /// Ends the refresh as failed: the list held is kept.
    func fail() -> OHTTPHostListRefreshOutcome {
        guard let taken = takePointer() else {
            return .superseded
        }
        return OHTTPHostListRefreshOutcome(rawValue: zcashlc_ohttp_third_party_fail_refresh(taken)) ?? .superseded
    }

    private func takePointer() -> OpaquePointer? {
        pointer.withLockUnchecked { (state: inout OpaquePointer?) -> OpaquePointer? in
            let taken = state
            state = nil
            return taken
        }
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else {
            return nil
        }
        return String(cString: pointer)
    }
}

extension OHTTPNative {
    /// The `:authority` to send a request for `host` with, in lower case, when the gateway of `network` carries
    /// `host`; nil when it does not, or when OHTTP is off for the network.
    static func thirdPartyCarriedAuthority(host: String, network: NetworkType) -> String? {
        let bytes = Array(host.utf8)
        let result: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { buffer in
            zcashlc_ohttp_third_party_carried_authority(network == .testnet, buffer.baseAddress, UInt(buffer.count))
        }
        guard let result else {
            return nil
        }
        defer { zcashlc_string_free(result) }
        return String(cString: result)
    }

    /// Whether a refresh is worth running before a host that is not carried is refused.
    static func thirdPartyRefreshBeforeRefusing(network: NetworkType) -> Bool {
        zcashlc_ohttp_third_party_refresh_before_refusing(network == .testnet)
    }

    /// Whether a refresh of the list is running.
    static func thirdPartyIsRefreshing(network: NetworkType) -> Bool {
        zcashlc_ohttp_third_party_is_refreshing(network == .testnet)
    }

    /// Reports the gateway's answer to a request for `host`. True when a refresh was asked for by it.
    @discardableResult
    static func thirdPartyNoteAnswer(host: String, network: NetworkType, status: Int, body: Data) -> Bool {
        let hostBytes = Array(host.utf8)
        let code = UInt16(exactly: status) ?? 0
        return hostBytes.withUnsafeBufferPointer { hostBuffer in
            body.withUnsafeBytes { (bodyBuffer: UnsafeRawBufferPointer) -> Bool in
                zcashlc_ohttp_third_party_note_answer(
                    network == .testnet,
                    hostBuffer.baseAddress,
                    UInt(hostBuffer.count),
                    code,
                    bodyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(bodyBuffer.count)
                )
            }
        }
    }

    /// Begins a refresh of the list of `network` when one is due; nil when none is due, one is running, or
    /// OHTTP is off for the network.
    static func thirdPartyBeginRefresh(network: NetworkType) -> OHTTPHostListRefresh? {
        guard let pointer = zcashlc_ohttp_third_party_begin_refresh(network == .testnet) else {
            return nil
        }
        return OHTTPHostListRefresh(pointer: pointer)
    }
}
