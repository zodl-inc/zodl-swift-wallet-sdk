//
//  OHTTPTransport.swift
//  ZcashLightClientKit
//
//  OHTTP (RFC 9458) client transport: encapsulates a Binary HTTP request with HPKE, POSTs it to the
//  relay and decapsulates the gateway's response.
//

import Foundation

/// Delegate that refuses HTTP redirects to prevent tracking and fingerprinting.
/// A relay or key-config server attempting a redirect is an attack vector.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectRefusingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refuse all redirects by passing nil to the completion handler.
        // The task will complete with the redirect response instead of following it.
        completionHandler(nil)
    }
}

actor OHTTPTransport {
    /// Pluggable HTTP sender for the relay POST (and the key-config GET).
    /// Device → Tor → relay when Tor is enabled; device → relay otherwise.
    typealias HTTPSender = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Dedicated session for the OHTTP hops. Ephemeral + no cookies + no cache so that nothing a relay
    /// or gateway returns (e.g. Set-Cookie) can be stored and replayed, which would link a wallet's
    /// requests across IPs / Tor circuits. Delegate refuses redirects (3xx responses surface as errors
    /// rather than being followed). Scoped to this transport; the app's URLSession.shared is untouched.
    internal static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = nil
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: RedirectRefusingDelegate.shared, delegateQueue: nil)
    }()

    /// Test-only accessor for the session configuration.
    internal static var sessionConfigurationForTesting: URLSessionConfiguration {
        session.configuration
    }

    private let relayURL: String
    private let keyConfigURL: String
    private let connectTimeoutMS: Int
    private let keyFetchTimeoutMS: Int
    private var cachedKeyConfig: OHTTPKeyConfig?
    private let httpSender: HTTPSender
    /// Optional client trace ID prefix. When set, every outer OHTTP POST to the relay carries
    /// `X-Client-Trace-Id: <prefix>-<uuid>` so a tester can tag and follow requests end-to-end in
    /// Grafana (relay → gateway → downstream). The prefix is sanitised to `[A-Za-z0-9._:-]` and
    /// truncated so the full header value ≤ 64 chars.
    ///
    /// **Privacy warning:** a custom trace ID makes that wallet's requests linkable across relay
    /// and gateway logs. DEBUG ONLY. Never set in release builds. Off by default.
    private let clientTraceIdPrefix: String?
    /// Network identifier for signed config verification ("mainnet" or "testnet").
    private let network: String
    /// Expiry time for the cached key configuration.
    private var cachedExpiry: Date?
    /// Test-only: fixed clock for signature verification (bypasses Date()).
    private let testNow: Date?
    /// Test-only: expected key ID for test vectors (bypasses production keys).
    private let testKeyId: String?
    /// Test-only: public key hex for test vectors (bypasses production keys).
    private let testPublicKeyHex: String?

    private static let requestMediaType = "message/ohttp-req"
    private static let responseMediaType = "message/ohttp-res"
    private static let keysMediaType = "application/ohttp-keys"
    private static let requestLabel = "message/bhttp request".data(using: .ascii)!
    private static let responseLabel = "message/bhttp response".data(using: .ascii)!

    init(
        network: String,
        relayURL: String,
        keyConfigURL: String,
        connectTimeoutMS: Int = 15000,
        keyFetchTimeoutMS: Int = 15000,
        clientTraceIdPrefix: String? = nil,
        testNow: Date? = nil,
        testKeyId: String? = nil,
        testPublicKeyHex: String? = nil,
        httpSender: @escaping HTTPSender = { request in
            let (data, response) = try await OHTTPTransport.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OHTTPError.transportError("Invalid response type")
            }
            return (data, httpResponse)
        }
    ) {
        // Store URLs; https validation is deferred until request time (see httpGet/httpPost).
        self.network = network
        self.relayURL = relayURL
        self.keyConfigURL = keyConfigURL
        self.connectTimeoutMS = connectTimeoutMS
        self.keyFetchTimeoutMS = keyFetchTimeoutMS
        self.clientTraceIdPrefix = clientTraceIdPrefix
        self.testNow = testNow
        self.testKeyId = testKeyId
        self.testPublicKeyHex = testPublicKeyHex
        self.httpSender = httpSender
    }

    /// Fetches (or returns the cached) gateway key configuration using signed envelope.
    /// Derives the signed config URL from relayURL and verifies via the pure verifier.
    func keyConfig(forceRefresh: Bool = false) async throws -> OHTTPKeyConfig {
        // Check cache validity (both config and expiry must be present and not expired)
        if !forceRefresh, let cached = cachedKeyConfig, let expiry = cachedExpiry, Date() < expiry {
            return cached
        }

        // Derive signed config URL from relayURL (replace path suffix /relay with /ohttp-configs/signed)
        var signedURL = relayURL
        if signedURL.hasSuffix("/relay") {
            signedURL.removeLast("/relay".count)
            signedURL += "/ohttp-configs/signed"
        } else {
            // Fallback: relay URL doesn't end with /relay (unexpected, but handle gracefully)
            signedURL += "/ohttp-configs/signed"
        }

        // Validate the derived URL before any network call or decoding
        guard signedURL.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(signedURL)")
        }
        guard let signedURLObj = URL(string: signedURL), signedURLObj.host != nil, !(signedURLObj.host!.isEmpty) else {
            throw OHTTPError.transportError("Invalid URL: \(signedURL)")
        }

        // Fetch JSON via hardened httpSender (not URLSession.shared)
        let jsonData = try await httpGet(url: signedURL, timeoutMS: keyFetchTimeoutMS)

        // Verify and parse through pure verifier (fail-closed: any verification failure throws)
        let verified = try OHTTPSignedConfigVerifier.verifyAndParse(
            jsonData: jsonData,
            network: network,
            now: testNow ?? Date(),
            testKeyId: testKeyId,
            testPublicKeyHex: testPublicKeyHex
        )

        // Cache both config and expiry
        cachedKeyConfig = verified.keyConfig
        cachedExpiry = verified.validUntil

        return verified.keyConfig
    }

    /// Performs one OHTTP round trip. A gateway rejection (HTTP 400 from the relay/gateway pair) is
    /// retried once after refreshing the key configuration, which handles gateway key rotation.
    func roundTrip(request: BinaryHTTP.Request, timeoutMS: Int) async throws -> BinaryHTTP.Response {
        var keyConfig = try await self.keyConfig()

        do {
            return try await roundTripWith(keyConfig: keyConfig, request: request, timeoutMS: timeoutMS)
        } catch let error as OHTTPError {
            // Check if it's a 400 error
            if case .transportError(let message) = error, message.contains("HTTP 400") {
                // Refresh key config and retry
                keyConfig = try await self.keyConfig(forceRefresh: true)
                return try await roundTripWith(keyConfig: keyConfig, request: request, timeoutMS: timeoutMS)
            }
            throw error
        }
    }

    private func roundTripWith(
        keyConfig: OHTTPKeyConfig,
        request: BinaryHTTP.Request,
        timeoutMS: Int
    ) async throws -> BinaryHTTP.Response {
        // RFC 9458 §4.3 — Encapsulation of Requests
        let header = keyConfig.header()
        let info = Self.requestLabel + Data([0x00]) + header
        var context = try OHTTPHPKE.setupBaseS(recipientPublicKey: keyConfig.publicKey, info: info)
        let plaintext = try BinaryHTTP.encodeRequest(request)
        let ciphertext = try context.seal(aad: Data(), plaintext: plaintext)
        let encapsulatedRequest = header + context.enc + ciphertext

        let encapsulatedResponse = try await httpPost(
            url: relayURL,
            body: encapsulatedRequest,
            timeoutMS: timeoutMS
        )

        // RFC 9458 §4.4 — Encapsulation of Responses (client side: decapsulate)
        let nonceLength = max(OHTTPHPKE.nN, OHTTPHPKE.nK)
        guard encapsulatedResponse.count >= nonceLength + OHTTPHPKE.nT else {
            throw OHTTPError.transportError("OHTTP response too short (\(encapsulatedResponse.count) bytes)")
        }

        let responseNonce = encapsulatedResponse.prefix(nonceLength)
        let responseCiphertext = encapsulatedResponse.suffix(from: nonceLength)

        let secret = try context.export(exporterContext: Self.responseLabel, length: OHTTPHPKE.nK)
        let salt = context.enc + responseNonce
        let prk = OHTTPHPKE.hkdfExtract(salt: salt, ikm: secret)
        let aeadKey = try OHTTPHPKE.hkdfExpand(prk: prk, info: "key".data(using: .ascii)!, length: OHTTPHPKE.nK)
        let aeadNonce = try OHTTPHPKE.hkdfExpand(prk: prk, info: "nonce".data(using: .ascii)!, length: OHTTPHPKE.nN)

        let decrypted: Data
        do {
            decrypted = try OHTTPHPKE.aesGcmOpen(key: aeadKey, nonce: aeadNonce, aad: Data(), ciphertext: responseCiphertext)
        } catch {
            throw OHTTPError.transportError("OHTTP response authentication failed")
        }

        return try BinaryHTTP.decodeResponse(decrypted)
    }

    // MARK: - HTTP

    private func httpGet(url: String, timeoutMS: Int) async throws -> Data {
        // Validate https at request time to prevent downgrade attacks without crashing the app
        guard url.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(url)")
        }

        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "GET"
        request.setValue(Self.keysMediaType, forHTTPHeaderField: "Accept")

        if let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }

        let (data, httpResponse) = try await httpSender(request)

        guard httpResponse.statusCode == 200 else {
            throw OHTTPError.transportError("Key config fetch failed: HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func httpPost(url: String, body: Data, timeoutMS: Int) async throws -> Data {
        // Validate https at request time to prevent downgrade attacks without crashing the app
        guard url.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(url)")
        }

        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(Self.requestMediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.responseMediaType, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }

        let (data, httpResponse) = try await httpSender(request)

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw OHTTPError.transportError("Relay/gateway returned HTTP \(httpResponse.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        return data
    }

    /// Generates a client trace ID from the given prefix: `<sanitized-prefix>-<uuid>`, truncated to
    /// 64 chars. The prefix is sanitised to match `^[A-Za-z0-9._:-]+$` (relay/gateway requirement).
    private func generateClientTraceId(prefix: String) -> String {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        let sanitized = prefix.unicodeScalars.filter { allowedCharacters.contains($0) }.map { String($0) }.joined()
        let uuid = UUID().uuidString
        let full = "\(sanitized)-\(uuid)"
        return full.count <= 64 ? full : String(full.prefix(64))
    }
}
