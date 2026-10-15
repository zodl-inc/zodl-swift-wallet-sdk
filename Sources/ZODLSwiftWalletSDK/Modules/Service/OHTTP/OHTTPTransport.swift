//
//  OHTTPTransport.swift
//  ZODLSwiftWalletSDK
//
//  OHTTP (RFC 9458) client transport: seals a request to the gateway's key, POSTs it to the relay and opens
//  the gateway's response. The protocol — key selection, the signed key-configuration envelope, Binary HTTP,
//  HPKE and the rules on the relay's answer — is the shared Rust core's (see `OHTTPNative`); this actor owns
//  the I/O, the key cache and the retry loop.
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

/// Body reader of `OHTTPTransport.boundedDataViaDelegate`. The session's serial delegate queue
/// runs every callback, so the state needs no lock.
private final class BoundedBodyReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var body = Data()
    private var response: URLResponse?
    private var failure: Error?

    init(maxBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        self.maxBytes = maxBytes
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // `expectedContentLength` is -1 when the length is unknown.
        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(maxBytes) {
            failure = OHTTPError.responseTooLarge(
                "Response Content-Length (\(expectedLength) bytes) exceeds limit (\(maxBytes) bytes)"
            )
            completionHandler(.cancel)
            return
        }
        self.response = response
        if expectedLength > 0 {
            body.reserveCapacity(Int(expectedLength))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if body.count + data.count > maxBytes {
            failure = OHTTPError.responseTooLarge(
                "Response size (\(body.count + data.count) bytes) exceeded limit (\(maxBytes) bytes)"
            )
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        if let failure = failure {
            continuation.resume(throwing: failure)
        } else if let error = error {
            continuation.resume(throwing: error)
        } else if let response = response {
            continuation.resume(returning: (body, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// The task of a bounded read, cancellable before it exists (Swift task cancelled first).
private final class BoundedTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            task.cancel()
        }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

actor OHTTPTransport {
    /// Pluggable HTTP sender for the relay POST (and the key-config GET).
    /// Device → Tor → relay when Tor is enabled; device → relay otherwise.
    /// The Int parameter is the per-request maximum response size in bytes.
    typealias HTTPSender = (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    /// Test-only replacement for the native verification of the signed key configuration: the pinned
    /// signing keys have no private half to sign a test envelope with.
    typealias KeyVerifier = (_ envelope: Data, _ now: Date) throws -> OHTTPVerifiedKey

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

    /// Maximum size of a signed key-configuration response (64 KiB). ZIP MUST: clients bound the
    /// key-config response while reading.
    internal static let maxKeyConfigBytes = 64 * 1024

    /// Maximum size of an OHTTP relay response (256 MiB sealed response + 1 MiB framing overhead).
    /// ZIP MUST: "A Client MUST bound the total size of the Chunked OHTTP response it reads ... MUST
    /// enforce the limit while reading, counting the sealed octets ... and MUST abort the read and fail
    /// the call as soon as it is exceeded."
    internal static let maxRelayResponseBytes = (256 * 1024 * 1024) + (1024 * 1024)

    /// Reads response data with a size bound, enforcing the limit while reading. ZIP MUST requirement
    /// for OHTTP relay responses: abort as soon as the limit is exceeded. Uses `session.bytes(for:)`
    /// to stream and count where available (iOS 15+, macOS 12+), rejecting early if
    /// `expectedContentLength > maxBytes`. Below iOS 15 the body is counted in delegate callbacks
    /// instead (`boundedDataViaDelegate`): a post-read size check would buffer the whole body first.
    ///
    /// - Parameters:
    ///   - request: The URL request to execute
    ///   - maxBytes: Maximum allowed response size in bytes
    ///   - session: The URLSession to use (defaults to OHTTPTransport.session)
    /// - Returns: The response data and URLResponse
    /// - Throws: `OHTTPError.responseTooLarge` if the response exceeds maxBytes, or transport errors
    static func boundedData(
        for request: URLRequest,
        maxBytes: Int,
        session: URLSession = OHTTPTransport.session
    ) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, *) {
            return try await boundedDataStreaming(for: request, maxBytes: maxBytes, session: session)
        }
        return try await boundedDataViaDelegate(for: request, maxBytes: maxBytes, configuration: session.configuration)
    }

    @available(iOS 15.0, *)
    private static func boundedDataStreaming(
        for request: URLRequest,
        maxBytes: Int,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)

        // Reject early if Content-Length header exceeds the limit
        // `expectedContentLength` is -1 when the length is unknown.
        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw OHTTPError.responseTooLarge(
                "Response Content-Length (\(expectedLength) bytes) exceeds limit (\(maxBytes) bytes)"
            )
        }

        var accumulated = Data()
        if expectedLength > 0 {
            accumulated.reserveCapacity(Int(expectedLength))
        }

        for try await byte in bytes {
            accumulated.append(byte)
            if accumulated.count > maxBytes {
                bytes.task.cancel()
                throw OHTTPError.responseTooLarge(
                    "Response size (\(accumulated.count) bytes) exceeded limit (\(maxBytes) bytes)"
                )
            }
        }

        return (accumulated, response)
    }

    /// Bounded read without `bytes(for:)` (iOS 13/14): a one-task session with the same
    /// configuration, whose delegate counts the body as it arrives and cancels the task as soon as
    /// the limit is exceeded. It refuses redirects like `OHTTPTransport.session`. No connection
    /// reuse across calls, which only costs latency on the OS versions the apps do not ship to.
    /// Internal so the tests can run this path on every OS.
    static func boundedDataViaDelegate(
        for request: URLRequest,
        maxBytes: Int,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        let handle = BoundedTaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reader = BoundedBodyReader(maxBytes: maxBytes, continuation: continuation)
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: queue)
                let task = session.dataTask(with: request)
                handle.start(task)
                // Invalidates once the task completes, which releases the delegate.
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The gateway host the requests are addressed to. It picks the network, and so the pinned key the
    /// signed key configuration is checked against.
    private let gatewayHost: String
    private let relayURL: String
    private let keyConfigURL: String
    private let connectTimeoutMS: Int
    private let keyFetchTimeoutMS: Int
    private var cachedKey: OHTTPVerifiedKey?
    private let httpSender: HTTPSender
    /// Optional client trace ID prefix. When set, every outer OHTTP POST to the relay carries
    /// `X-Client-Trace-Id: <prefix>-<uuid>` so a tester can tag and follow requests end-to-end in
    /// Grafana (relay → gateway → downstream). The prefix is sanitised to `[A-Za-z0-9._:-]` and
    /// truncated so the full header value ≤ 64 chars.
    ///
    /// **Privacy warning:** a custom trace ID makes that wallet's requests linkable across relay
    /// and gateway logs. DEBUG ONLY. Never set in release builds. Off by default.
    private let clientTraceIdPrefix: String?
    /// Test-only: fixed clock for signature verification (bypasses Date()).
    private let testNow: Date?
    /// Test-only: verifies the key configuration instead of the native code.
    private let testKeyVerifier: KeyVerifier?

    private static let keyFetchSuccessStatus = 200

    init(
        gatewayHost: String,
        relayURL: String,
        keyConfigURL: String,
        connectTimeoutMS: Int = 15000,
        keyFetchTimeoutMS: Int = 15000,
        clientTraceIdPrefix: String? = nil,
        testNow: Date? = nil,
        testKeyVerifier: KeyVerifier? = nil,
        httpSender: @escaping HTTPSender = { request, maxBytes in
            let (data, response) = try await OHTTPTransport.boundedData(
                for: request,
                maxBytes: maxBytes
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OHTTPError.transportError("Invalid response type")
            }
            return (data, httpResponse)
        }
    ) {
        // Store URLs; https validation is deferred until request time (see httpGet/httpPost).
        self.gatewayHost = gatewayHost
        self.relayURL = relayURL
        self.keyConfigURL = keyConfigURL
        self.connectTimeoutMS = connectTimeoutMS
        self.keyFetchTimeoutMS = keyFetchTimeoutMS
        self.clientTraceIdPrefix = clientTraceIdPrefix
        self.testNow = testNow
        self.testKeyVerifier = testKeyVerifier
        self.httpSender = httpSender
    }

    /// Fetches (or returns the cached) gateway key using the signed envelope.
    /// Derives the signed config URL from relayURL and verifies it in the shared core.
    func keyConfig(forceRefresh: Bool = false) async throws -> OHTTPVerifiedKey {
        let profile = try OHTTPNative.profileInfo()

        // The cached key is used while the profile says it is fresh.
        if !forceRefresh, let cached = cachedKey, profile.isFresh(cached, at: Date()) {
            return cached
        }

        // Derive signed config URL from relayURL (replace path suffix /relay with /ohttp-configs/signed)
        let signedURL = try OHTTPNative.signedConfigURL(relayURL: relayURL)

        // Validate the derived URL before any network call or decoding
        guard signedURL.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(signedURL)")
        }
        guard let signedURLObj = URL(string: signedURL), let host = signedURLObj.host, !host.isEmpty else {
            throw OHTTPError.transportError("Invalid URL: \(signedURL)")
        }

        // Fetch JSON via hardened httpSender (not URLSession.shared)
        let jsonData = try await httpGet(url: signedURL, timeoutMS: keyFetchTimeoutMS, profile: profile)

        // Verify through the core (fail-closed: any verification failure throws)
        let now = testNow ?? Date()
        let verified: OHTTPVerifiedKey
        if let testKeyVerifier {
            verified = try testKeyVerifier(jsonData, now)
        } else {
            verified = try OHTTPNative.verifyKeyConfig(gatewayHost: gatewayHost, envelope: jsonData, now: now)
        }

        cachedKey = verified
        return verified
    }

    /// Performs one OHTTP call: `roundTripOnce`, and once more (sealed afresh) when the gateway refused the
    /// request as stale, an inner 400 with `ohttp-freshness: rejected` ("Request freshness" in the ZIP).
    /// That response carried the gateway clock, which the native core has already learned, so the second
    /// attempt is stamped right even on a device whose clock is off. Never more than one such retry.
    func roundTrip(request: OHTTPRequest, timeoutMS: Int) async throws -> OHTTPResponse {
        try await Self.withFreshnessRetry {
            try await self.roundTripOnce(request: request, timeoutMS: timeoutMS)
        }
    }

    /// Runs `attempt`, and once more when its answer is the gateway's freshness refusal. A second refusal
    /// is returned as it is.
    static func withFreshnessRetry(
        _ attempt: () async throws -> OHTTPResponse
    ) async throws -> OHTTPResponse {
        let first = try await attempt()
        guard first.isFreshnessRefusal else {
            return first
        }
        return try await attempt()
    }

    /// Performs one OHTTP round trip. When the relay or gateway answers 400 or 422 the key configuration is
    /// fetched again and the request is sealed afresh and sent once more; a second 400 or 422 is final.
    private func roundTripOnce(request: OHTTPRequest, timeoutMS: Int) async throws -> OHTTPResponse {
        var key = try await self.keyConfig()
        var attempt: UInt32 = 0

        while true {
            let completed = try await exchange(key: key, request: request, timeoutMS: timeoutMS, attempt: attempt)
            switch completed {
            case .response(let response):
                return response

            case .refetchKeyConfig:
                guard attempt == 0 else {
                    throw OHTTPError.transportError("OHTTP key configuration was refused twice")
                }
                // Discard the refused key before fetching the one that replaces it, so that a failed fetch
                // leaves none to be used next.
                if try OHTTPNative.profileInfo().dropBeforeRefetch {
                    cachedKey = nil
                }
                key = try await self.keyConfig(forceRefresh: true)
                attempt = 1

            case .refused(let status, let detail):
                let message = "Relay/gateway returned HTTP \(status)\(detail.isEmpty ? "" : ": \(detail)")"
                throw OHTTPError.httpStatusError(statusCode: status, message: message)

            case .wrongMediaType(let contentType):
                throw OHTTPError.transportError("Relay/gateway answered \(contentType), not a sealed response")
            }
        }
    }

    /// One attempt: seals the request afresh, posts it and lets the core classify and open the answer.
    private func exchange(
        key: OHTTPVerifiedKey,
        request: OHTTPRequest,
        timeoutMS: Int,
        attempt: UInt32
    ) async throws -> OHTTPCompleted {
        // The sealing is used for this post only. If the post fails, `sealed.pending` is released with it.
        let sealed = try OHTTPNative.encapsulate(key: key, request: request)

        let (data, httpResponse) = try await httpPost(url: relayURL, body: sealed.body, timeoutMS: timeoutMS)

        return try sealed.pending.complete(
            status: httpResponse.statusCode,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            body: data,
            attempt: attempt
        )
    }

    // MARK: - HTTP

    private func httpGet(url: String, timeoutMS: Int, profile: OHTTPProfileInfo) async throws -> Data {
        // Validate https at request time to prevent downgrade attacks without crashing the app
        guard url.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(url)")
        }

        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "GET"
        for (name, value) in profile.keyFetchHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if profile.traceOnKeyFetch, let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }

        let (data, httpResponse) = try await httpSender(request, Self.maxKeyConfigBytes)

        guard httpResponse.statusCode == Self.keyFetchSuccessStatus else {
            throw OHTTPError.transportError("Key config fetch failed: HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func httpPost(url: String, body: Data, timeoutMS: Int) async throws -> (Data, HTTPURLResponse) {
        // Validate https at request time to prevent downgrade attacks without crashing the app
        guard url.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(url)")
        }

        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        let profile = try OHTTPNative.profileInfo()
        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in profile.postHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }

        return try await httpSender(request, Self.maxRelayResponseBytes)
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
