//
//  OHTTPNative.swift
//  ZODLSwiftWalletSDK
//
//  Swift side of the shared OHTTP client core (`zodl-ohttp-client`, profile 2 = iOS), reached through
//  the `zcashlc_ohttp_*` C functions. The core owns everything that is protocol: the signed
//  key-configuration envelope and the key selection, the Binary HTTP codec, HPKE sealing, the
//  classification of the relay's answer and the opening of the sealed response. The transport keeps the
//  I/O (URLSession or Tor), the key cache and the retry loop.
//

import Foundation
import libzcashlc

/// The gateway's key, once the signed envelope it came in has been verified.
struct OHTTPVerifiedKey: Equatable {
    /// The length of ``bytes``.
    static let byteCount = 33

    /// `key_id || X25519 public key`. Public data, kept by the transport next to ``notAfter``.
    let bytes: Data
    /// The end of the envelope's validity, in Unix seconds.
    let notAfter: UInt64
    /// Whether the envelope was checked for the testnet gateway.
    let isTestnet: Bool
}

/// The client's own request headers and key-cache rules, as the core's iOS profile sets them.
struct OHTTPProfileInfo {
    /// Headers of the post of a sealed request, without a trace id.
    let postHeaders: [(name: String, value: String)]
    /// Headers of the fetch of the signed key configuration, without a trace id.
    let keyFetchHeaders: [(name: String, value: String)]
    /// Seconds before `not_after` from which a cached key is no longer used.
    let cacheRefreshMarginSecs: UInt64
    /// Whether the cached key is dropped before the fetch that replaces it.
    let dropBeforeRefetch: Bool
    /// Whether the key-configuration fetch carries the trace id as the post does.
    let traceOnKeyFetch: Bool

    /// Whether `key` may still be sealed to at `now`.
    func isFresh(_ key: OHTTPVerifiedKey, at now: Date) -> Bool {
        now.timeIntervalSince1970 + Double(cacheRefreshMarginSecs) < Double(key.notAfter)
    }
}

/// What the relay's answer came to, as ``OHTTPPendingResponse/complete(status:contentType:body:attempt:)``
/// reports it.
enum OHTTPCompleted {
    /// The sealed answer opened: the backend's response.
    case response(OHTTPResponse)
    /// The gateway does not know the key configuration: fetch it again, seal the request afresh and post
    /// once more.
    case refetchKeyConfig
    /// The relay or the gateway refused the request.
    case refused(status: Int, detail: String)
    /// A success status not labelled `message/ohttp-chunked-res`.
    case wrongMediaType(contentType: String)
}

enum OHTTPNative {
    /// `ClientProfile::IOS` of the shared core.
    static let profile: UInt32 = 2

    /// Verifies the signed key-configuration `envelope` fetched for `gatewayHost` and selects the gateway's
    /// key out of it. The network, and so the pinned signing key, follows from the host.
    static func verifyKeyConfig(gatewayHost: String, envelope: Data, now: Date) throws -> OHTTPVerifiedKey {
        let seconds = UInt64(max(0, now.timeIntervalSince1970))
        let host = Array(gatewayHost.lowercased().utf8)
        let result: UnsafeMutablePointer<OhttpKey>? = host.withUnsafeBufferPointer { hostBuffer in
            envelope.withUnsafeBytes { (json: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpKey>? in
                zcashlc_ohttp_verify_key_config(
                    profile,
                    hostBuffer.baseAddress,
                    UInt(hostBuffer.count),
                    json.bindMemory(to: UInt8.self).baseAddress,
                    UInt(json.count),
                    seconds
                )
            }
        }
        guard let result else {
            throw OHTTPError.keyConfigError(
                lastErrorMessage(fallback: "OHTTP key configuration could not be verified")
            )
        }
        defer { zcashlc_free_ohttp_key(result) }

        let key = result.pointee
        return OHTTPVerifiedKey(
            bytes: withUnsafeBytes(of: key.key) { Data($0) },
            notAfter: key.not_after,
            isTestnet: key.network == 1
        )
    }

    /// Encodes `request` as Binary HTTP and seals it to `key`, with a fresh ephemeral key. Call it again for
    /// every attempt, a retry included: the gateway answers a repeated nonce with 409.
    ///
    /// The returned ``OHTTPPendingResponse`` is what opens the answer to this request, and no other.
    static func encapsulate(
        key: OHTTPVerifiedKey,
        request: OHTTPRequest
    ) throws -> (body: Data, pending: OHTTPPendingResponse) {
        guard key.bytes.count == OHTTPVerifiedKey.byteCount else {
            throw OHTTPError.keyConfigError("Malformed OHTTP gateway key")
        }
        let parts = try request.nativeBytes()

        // The control data and the header list share one buffer, so that the call needs three pinned
        // regions rather than seven.
        var head = Data()
        var offsets: [Int] = []
        for part in [parts.method, parts.scheme, parts.authority, parts.path, parts.headers] {
            offsets.append(head.count)
            head.append(part)
        }
        let lengths = [parts.method, parts.scheme, parts.authority, parts.path, parts.headers].map { UInt($0.count) }

        let sealed: UnsafeMutablePointer<OhttpSealed>? = key.bytes.withUnsafeBytes { (keyBuffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpSealed>? in
            head.withUnsafeBytes { (headBuffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpSealed>? in
                request.body.withUnsafeBytes { (bodyBuffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpSealed>? in
                    let base = headBuffer.bindMemory(to: UInt8.self).baseAddress
                    return zcashlc_ohttp_encapsulate(
                        profile,
                        keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                        base?.advanced(by: offsets[0]), lengths[0],
                        base?.advanced(by: offsets[1]), lengths[1],
                        base?.advanced(by: offsets[2]), lengths[2],
                        base?.advanced(by: offsets[3]), lengths[3],
                        base?.advanced(by: offsets[4]), lengths[4],
                        bodyBuffer.bindMemory(to: UInt8.self).baseAddress, UInt(bodyBuffer.count)
                    )
                }
            }
        }
        guard let sealed else {
            let error = OHTTPError.native(lastErrorMessage(fallback: "OHTTP request could not be sealed"))
            if case .responseTooLarge(let message) = error {
                throw OHTTPError.requestTooLarge(message)
            }
            throw error
        }
        defer { zcashlc_free_ohttp_sealed(sealed) }

        // Ownership of the opener moves to the Swift wrapper: the field is cleared so that freeing the
        // sealed request below does not free it too.
        guard let opener = sealed.pointee.opener else {
            throw OHTTPError.transportError("OHTTP request was sealed without a response context")
        }
        sealed.pointee.opener = nil
        let pending = OHTTPPendingResponse(opener: opener)

        return (copyBytes(sealed.pointee.body, sealed.pointee.body_len), pending)
    }

    /// Whether the relay's answer with `status` and `contentType` is a sealed response, as the core's iOS
    /// rule has it: a reader of the answer as it arrives must know before it has the body. An answer that
    /// is not goes whole to ``OHTTPPendingResponse/complete(status:contentType:body:attempt:)``.
    static func answerIsSealed(status: Int, contentType: String?, attempt: UInt32) throws -> Bool {
        guard let status16 = UInt16(exactly: status) else {
            throw OHTTPError.transportError("OHTTP outer status out of range")
        }
        let result: Int32 = withOptionalCString(contentType) {
            zcashlc_ohttp_answer_is_sealed(profile, status16, $0, attempt)
        }
        guard result >= 0 else {
            throw OHTTPError.native(lastErrorMessage(fallback: "OHTTP answer could not be classified"))
        }
        return result == 1
    }

    static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }

    /// The URL of the signed key configuration of the relay at `relayURL`.
    static func signedConfigURL(relayURL: String) throws -> String {
        let bytes = Array(relayURL.utf8)
        let result: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { buffer in
            zcashlc_ohttp_signed_config_url(profile, buffer.baseAddress, UInt(buffer.count))
        }
        guard let result else {
            throw OHTTPError.transportError(
                lastErrorMessage(fallback: "OHTTP signed configuration URL could not be derived")
            )
        }
        defer { zcashlc_string_free(result) }
        return String(cString: result)
    }

    /// The profile's request headers and key-cache rules. They do not change, so they are read once.
    static func profileInfo() throws -> OHTTPProfileInfo {
        try cachedProfileInfo.get()
    }

    private static let cachedProfileInfo: Result<OHTTPProfileInfo, Error> = Result { try loadProfileInfo() }

    private static func loadProfileInfo() throws -> OHTTPProfileInfo {
        guard let info = zcashlc_ohttp_profile_info(profile) else {
            throw OHTTPError.transportError(lastErrorMessage(fallback: "OHTTP profile is unavailable"))
        }
        defer { zcashlc_free_ohttp_profile_info(info) }

        let value = info.pointee
        func fields(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: UInt) throws -> [(name: String, value: String)] {
            try OHTTPFieldList.unpack(copyBytes(pointer, count)).map {
                (OHTTPFieldList.latin1($0.0), OHTTPFieldList.latin1($0.1))
            }
        }
        return OHTTPProfileInfo(
            postHeaders: try fields(value.post_headers, value.post_headers_len),
            keyFetchHeaders: try fields(value.key_fetch_headers, value.key_fetch_headers_len),
            cacheRefreshMarginSecs: value.cache_refresh_margin_secs,
            dropBeforeRefetch: value.drop_before_refetch,
            traceOnKeyFetch: value.trace_on_key_fetch
        )
    }

    /// Returns the relay URL for a given gateway host, or nil if the host is not a known gateway.
    /// The built-in mapping can be overridden at build time via environment variables
    /// `ZODL_OHTTP_RELAY_URL_MAINNET` and `ZODL_OHTTP_RELAY_URL_TESTNET`.
    static func relayURL(for gatewayHost: String) -> String? {
        let host = Array(gatewayHost.lowercased().utf8)
        let result: UnsafeMutablePointer<CChar>? = host.withUnsafeBufferPointer { hostBuffer in
            zcashlc_ohttp_relay_url_for(
                hostBuffer.baseAddress,
                UInt(hostBuffer.count)
            )
        }
        guard let result else {
            return nil
        }
        defer { zcashlc_string_free(result) }
        return String(cString: result)
    }

    static func copyBytes(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: UInt) -> Data {
        guard let pointer, count > 0 else { return Data() }
        return Data(bytes: pointer, count: Int(count))
    }

    /// The DoH query URLs of the signed key configuration of `gatewayHost`'s network, in resolver
    /// order (Cloudflare, then Google). Only for the DNS source, after the relay source failed.
    static func dohQueryURLs(gatewayHost: String) throws -> [String] {
        let host = Array(gatewayHost.lowercased().utf8)
        return try (0..<zcashlc_ohttp_doh_resolver_count()).map { index in
            let url: UnsafeMutablePointer<CChar>? = host.withUnsafeBufferPointer {
                zcashlc_ohttp_doh_query_url(index, $0.baseAddress, UInt($0.count))
            }
            guard let url else {
                throw OHTTPError.transportError(lastErrorMessage(fallback: "DoH query URL could not be built"))
            }
            defer { zcashlc_string_free(url) }
            return String(cString: url)
        }
    }

    /// The signed envelope carried by a DoH JSON response for `gatewayHost`'s network; verify it with
    /// `verifyKeyConfig` like one fetched through the relay.
    static func envelopeFromDohJSON(dohBody: Data, gatewayHost: String) throws -> Data {
        let host = Array(gatewayHost.lowercased().utf8)
        var envelopeLen: UInt = 0
        let result: UnsafeMutablePointer<UInt8>? = dohBody.withUnsafeBytes { bodyBuffer in
            host.withUnsafeBufferPointer { hostBuffer in
                zcashlc_ohttp_envelope_from_doh_json(
                    bodyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(bodyBuffer.count),
                    hostBuffer.baseAddress,
                    UInt(hostBuffer.count),
                    &envelopeLen
                )
            }
        }
        guard let result else {
            throw OHTTPError.transportError(lastErrorMessage(fallback: "DoH response could not be parsed"))
        }
        defer { zcashlc_ohttp_free_bytes(result, envelopeLen) }
        return Data(bytes: result, count: Int(envelopeLen))
    }
}

/// What opens the response to one sealed request, and no other: a handle to the core's single-use response
/// context. The response secret never enters Swift memory, where it could not be zeroized.
///
/// ``complete(status:contentType:body:attempt:)`` consumes it whatever the outcome, so an answer is opened once.
/// A handle whose post failed before that is released when it is deallocated.
final class OHTTPPendingResponse: @unchecked Sendable {
    private var opener: OpaquePointer?

    init(opener: OpaquePointer) {
        self.opener = opener
    }

    deinit {
        if let opener {
            zcashlc_ohttp_opener_free(opener)
        }
    }

    /// Classifies the relay's answer and, for a sealed one, opens it and decodes the Binary HTTP response.
    ///
    /// - Parameters:
    ///   - status: The outer HTTP status.
    ///   - contentType: The outer `Content-Type`, if any.
    ///   - body: The whole outer body.
    ///   - attempt: 0 for the first post of a request, 1 for the post after ``OHTTPCompleted/refetchKeyConfig``.
    func complete(status: Int, contentType: String?, body: Data, attempt: UInt32) throws -> OHTTPCompleted {
        // Nothing has been consumed yet: a throw here leaves the handle to be released by `deinit`.
        guard let status16 = UInt16(exactly: status) else {
            throw OHTTPError.transportError("OHTTP outer status out of range")
        }
        guard let taken = opener else {
            throw OHTTPError.transportError("OHTTP response context was already used")
        }
        // The native call consumes the opener in every case, errors included.
        defer { opener = nil }

        let result: UnsafeMutablePointer<OhttpOutcome>? = Self.withOptionalCString(contentType) { typePointer in
            body.withUnsafeBytes { (bodyBuffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpOutcome>? in
                zcashlc_ohttp_complete(
                    OHTTPNative.profile,
                    taken,
                    status16,
                    typePointer,
                    bodyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(bodyBuffer.count),
                    attempt
                )
            }
        }
        guard let result else {
            OHTTPHealthTraffic.current?.nativeFailure(zcashlc_ohttp_last_failure_kind())
            throw OHTTPError.native(lastErrorMessage(fallback: "OHTTP response could not be opened"))
        }
        defer { zcashlc_free_ohttp_outcome(result) }

        let outcome = result.pointee
        switch outcome.kind {
        case 0:
            return .response(
                OHTTPResponse(
                    status: Int(outcome.status),
                    headers: try Self.fields(outcome.headers, outcome.headers_len),
                    body: OHTTPNative.copyBytes(outcome.body, outcome.body_len),
                    trailers: try Self.fields(outcome.trailers, outcome.trailers_len)
                )
            )
        case 1:
            return .refetchKeyConfig
        case 2:
            return .refused(status: Int(outcome.status), detail: Self.detail(outcome.detail))
        case 3:
            return .wrongMediaType(contentType: Self.detail(outcome.detail))
        default:
            throw OHTTPError.transportError("Unknown OHTTP outcome")
        }
    }

    /// A decoder of the sealed answer as it arrives, for an answer ``OHTTPNative/answerIsSealed(status:contentType:attempt:)``
    /// says is sealed. Consumes this handle whatever the outcome, as `complete` does.
    func streamDecoder() throws -> OHTTPNativeStreamDecoder {
        guard let taken = opener else {
            throw OHTTPError.transportError("OHTTP response context was already used")
        }
        opener = nil
        guard let decoder = zcashlc_ohttp_stream_decoder(taken) else {
            throw OHTTPError.native(lastErrorMessage(fallback: "OHTTP response could not be opened"))
        }
        return OHTTPNativeStreamDecoder(decoder)
    }

    static func fields(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: UInt) throws -> [(String, String)] {
        try OHTTPFieldList.unpack(OHTTPNative.copyBytes(pointer, count)).map {
            (OHTTPFieldList.latin1($0.0), OHTTPFieldList.latin1($0.1))
        }
    }

    private static func detail(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        OHTTPNative.withOptionalCString(string, body)
    }

}
