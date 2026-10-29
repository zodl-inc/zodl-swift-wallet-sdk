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

    /// The relay POST body is a stream with no replacement, so the session cannot transparently send the
    /// same sealed bytes a second time (an `enc_request` resent byte for byte is a replay).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Process-wide state of the OHTTP transports: the verified key configuration of each relay, gateway
/// and sender kind (Tor or not), fetched once (concurrent fetches share one) and reused by every transport
/// until it expires; and the `Retry-After` of the last 429 through each relay and sender kind.
actor OHTTPKeyCache {
    static let shared = OHTTPKeyCache()

    private var keys: [String: OHTTPVerifiedKey] = [:]
    private var fetches: [String: Task<OHTTPVerifiedKey, Error>] = [:]
    private var notBefore: [String: Date] = [:]

    func store(_ key: OHTTPVerifiedKey?, for cacheKey: String) {
        keys[cacheKey] = key
    }

    /// The cached key of `cacheKey` if `accept` takes it, else the key `fetch` returns, stored. Checked and
    /// started in one step: a call while a fetch for the same entry is under way waits for that one, and
    /// one that comes after it finds its key. The fetch is shared, so a caller that is cancelled stops
    /// waiting (`CancellationError`) while the fetch runs on for the others and its key is still stored.
    func key(
        for cacheKey: String,
        accept: @Sendable (OHTTPVerifiedKey) -> Bool,
        fetch: @escaping @Sendable () async throws -> OHTTPVerifiedKey
    ) async throws -> OHTTPVerifiedKey {
        if let cached = keys[cacheKey], accept(cached) {
            return cached
        }
        let task = fetches[cacheKey] ?? startFetch(for: cacheKey, fetch)
        return try await Self.waitCancellable(task)
    }

    private func startFetch(
        for cacheKey: String,
        _ fetch: @escaping @Sendable () async throws -> OHTTPVerifiedKey
    ) -> Task<OHTTPVerifiedKey, Error> {
        let task = Task<OHTTPVerifiedKey, Error> {
            let result: Result<OHTTPVerifiedKey, Error>
            do {
                result = .success(try await fetch())
            } catch {
                result = .failure(error)
            }
            await self.finishFetch(for: cacheKey, result)
            return try result.get()
        }
        fetches[cacheKey] = task
        return task
    }

    private func finishFetch(for cacheKey: String, _ result: Result<OHTTPVerifiedKey, Error>) {
        fetches[cacheKey] = nil
        if case .success(let key) = result {
            keys[cacheKey] = key
        }
    }

    /// `task.value`, unless the caller is cancelled first: then `CancellationError`, and `task` is left
    /// running (`Task.value` itself waits for the task whatever happens to the caller).
    static func waitCancellable(_ task: Task<OHTTPVerifiedKey, Error>) async throws -> OHTTPVerifiedKey {
        let outcome = FirstOutcome()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.deliver(to: continuation)
                Task {
                    do {
                        outcome.resume(with: .success(try await task.value))
                    } catch {
                        outcome.resume(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            outcome.resume(with: .failure(CancellationError()))
        }
    }

    /// Resumes one continuation with the first of the outcomes it is given, whichever comes first, the
    /// continuation or the outcome.
    private final class FirstOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<OHTTPVerifiedKey, Error>?
        private var outcome: Result<OHTTPVerifiedKey, Error>?

        func deliver(to continuation: CheckedContinuation<OHTTPVerifiedKey, Error>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(with result: Result<OHTTPVerifiedKey, Error>) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    func backoffDeadline(for cacheKey: String) -> Date? {
        notBefore[cacheKey]
    }

    func setBackoff(until deadline: Date, for cacheKey: String) {
        notBefore[cacheKey] = max(deadline, notBefore[cacheKey] ?? deadline)
    }
}

/// The relay session in use, replaced by a fresh one (new connections) once it is `lifetime` old. The old
/// one finishes the tasks it has and is then invalidated.
final class RotatingSession: @unchecked Sendable {
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var session: URLSession?
    private var created = Date.distantPast

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func current(now: Date = Date()) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session, now.timeIntervalSince(created) < lifetime {
            return session
        }
        session?.finishTasksAndInvalidate()
        let fresh = OHTTPTransport.makeSession()
        session = fresh
        created = now
        return fresh
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
    ///
    /// The session is replaced every ``sessionLifetime``, so the relay does not see one connection for
    /// the whole life of the app: connection lifetime is linkable metadata.
    internal static var session: URLSession {
        sessionBox.current()
    }

    /// How long one relay session, and so its connections, is used before a new one replaces it.
    internal static let sessionLifetime: TimeInterval = 10 * 60

    private static let sessionBox = RotatingSession(lifetime: sessionLifetime)

    /// Makes the relay session. `timeoutIntervalForResource` (100 s) is the per-exchange deadline
    /// for non-streaming exchanges. Streaming exchanges (mempool long poll, SSE) outlive this:
    /// each task applies its `timeoutInterval` (idle timeout) only, and lasts as long as the
    /// gateway keeps the stream open (~25 s for mempool, unbounded for SSE).
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = nil
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForResource = 100
        return URLSession(configuration: cfg, delegate: RedirectRefusingDelegate.shared, delegateQueue: nil)
    }

    /// Test-only accessor for the session configuration.
    internal static var sessionConfigurationForTesting: URLSessionConfiguration {
        session.configuration
    }

    /// Fixed relay-facing `User-Agent` and `Accept-Language`, so URLSession does not add the app's name
    /// and build, the CFNetwork and Darwin versions, or the device locale.
    internal static let fixedRelayHeaders: [(name: String, value: String)] = [
        ("User-Agent", "zodl-ohttp/1.0"),
        ("Accept-Language", "en")
    ]

    /// The longest relay `Retry-After` that is honoured.
    internal static let maxRetryAfter: TimeInterval = 120

    /// The pause a 429 without a usable `Retry-After` starts: the Client's own back-off (ZIP "Outer
    /// response contract", reference default 30 s), the same value as the slipstream and Android clients.
    internal static let defaultRateLimitPause: TimeInterval = 30

    /// The most of a non-2xx relay answer (an error page) that is read, a fixed guard whatever the call's
    /// own ceiling: an error body has nothing a client needs beyond its first bytes, and the ceiling of a
    /// sealed response is no measure for it. The read stops there and the answer is reported by its
    /// status, with its headers (a 429's `Retry-After` among them) intact.
    internal static let maxErrorBodyBytes = 64 * 1024

    /// Maximum size of a signed key-configuration response (64 KiB). ZIP MUST: clients bound the
    /// key-config response while reading.
    internal static let maxKeyConfigBytes = 64 * 1024

    /// Maximum size of an OHTTP relay response (256 MiB sealed response + 1 MiB framing overhead).
    /// ZIP MUST: "A Client MUST bound the total size of the Chunked OHTTP response it reads ... MUST
    /// enforce the limit while reading, counting the sealed octets ... and MUST abort the read and fail
    /// the call as soon as it is exceeded."
    internal static let maxRelayResponseBytes = (256 * 1024 * 1024) + (1024 * 1024)

    /// The gateway host the requests are addressed to. It picks the network, and so the pinned key the
    /// signed key configuration is checked against.
    private let gatewayHost: String
    let relayURL: String
    private let connectTimeoutMS: Int
    private let keyFetchTimeoutMS: Int
    private let keyCache: OHTTPKeyCache
    /// The key-configuration entry of this relay, gateway and sender kind in ``keyCache``.
    private let cacheKey: String
    /// The back-off entry of this relay and sender kind in ``keyCache``.
    private let backoffKey: String
    private let httpSender: HTTPSender
    /// Sender of the relay POST whose answer is read as it arrives (``stream(request:timeoutMS:)``).
    let streamSender: StreamSender
    /// Makes the decoder of a sealed answer read as it arrives. Tests replace the native one.
    let streamDecoderFactory: StreamDecoderFactory
    /// Optional client trace ID prefix. When set, every outer OHTTP POST to the relay carries
    /// `X-Client-Trace-Id: <prefix>-<uuid>` so a tester can tag and follow requests end-to-end in
    /// Grafana (relay → gateway → downstream). The prefix is sanitised to `[A-Za-z0-9._:-]` and
    /// truncated so the full header value ≤ 64 chars.
    ///
    /// **Privacy warning:** a custom trace ID makes that wallet's requests linkable across relay
    /// and gateway logs. DEBUG ONLY. Never set in release builds. Off by default.
    private let clientTraceIdPrefix: String?
    /// The wallet's network. When set, a key configuration of the other network is refused.
    private let walletNetwork: NetworkType?
    /// Test-only: fixed clock for signature verification (bypasses Date()).
    private let testNow: Date?
    /// Test-only: verifies the key configuration instead of the native code.
    private let testKeyVerifier: KeyVerifier?

    private static let keyFetchSuccessStatus = 200

    init(
        gatewayHost: String,
        relayURL: String,
        connectTimeoutMS: Int = 15000,
        keyFetchTimeoutMS: Int = 15000,
        clientTraceIdPrefix: String? = nil,
        walletNetwork: NetworkType? = nil,
        testNow: Date? = nil,
        testKeyVerifier: KeyVerifier? = nil,
        viaTor: Bool = false,
        keyCache: OHTTPKeyCache = .shared,
        streamSender: @escaping StreamSender = { request, maxBytes in
            try await OHTTPTransport.streamedData(for: request, maxBytes: maxBytes)
        },
        streamDecoderFactory: @escaping StreamDecoderFactory = { try $0.streamDecoder() },
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
        // The relay URL is checked for https at request time (see httpGet/httpPost).
        self.gatewayHost = gatewayHost
        self.relayURL = relayURL
        self.connectTimeoutMS = connectTimeoutMS
        self.keyFetchTimeoutMS = keyFetchTimeoutMS
        self.clientTraceIdPrefix = clientTraceIdPrefix
        self.walletNetwork = walletNetwork
        self.testNow = testNow
        self.testKeyVerifier = testKeyVerifier
        self.keyCache = keyCache
        self.cacheKey = "\(relayURL)|\(gatewayHost.lowercased())|\(viaTor ? "tor" : "direct")"
        self.backoffKey = "\(relayURL)|\(viaTor ? "tor" : "direct")"
        self.httpSender = httpSender
        self.streamSender = streamSender
        self.streamDecoderFactory = streamDecoderFactory
    }

    /// Fetches (or returns the cached) gateway key using the signed envelope.
    /// Derives the signed config URL from relayURL and verifies it in the shared core.
    func keyConfig(forceRefresh: Bool = false) async throws -> OHTTPVerifiedKey {
        let profile = try OHTTPNative.profileInfo()

        // The cached key is used while the profile says it is fresh.
        return try await keyCache.key(
            for: cacheKey,
            accept: { !forceRefresh && profile.isFresh($0, at: Date()) },
            fetch: { [self] in try await self.fetchKeyConfig(profile: profile) }
        )
    }

    /// Fetches the signed key configuration through the relay and verifies it.
    /// On relay fetch or verification failure, tries DNS-over-HTTPS as a fallback source. A 429 is not
    /// such a failure: the relay's pause (answered now, or left by an earlier 429) is back-off, and the
    /// fetch fails with it, without any DNS query (ZIP "Outer response contract", "Key configuration").
    /// Configuration errors (non-https URLs, unknown gateway) fail closed without any network requests.
    private func fetchKeyConfig(profile: OHTTPProfileInfo) async throws -> OHTTPVerifiedKey {
        // Validate relay URL is https before any network call
        guard relayURL.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(relayURL)")
        }

        // Derive and validate signed config URL before any network call
        let signedURL = try OHTTPNative.signedConfigURL(relayURL: relayURL)
        guard signedURL.lowercased().hasPrefix("https://") else {
            throw OHTTPError.transportError("OHTTP endpoints must use https: \(signedURL)")
        }
        guard let signedURLObj = URL(string: signedURL), let host = signedURLObj.host, !host.isEmpty else {
            throw OHTTPError.transportError("Invalid URL: \(signedURL)")
        }

        // Try relay first (fetch AND verify)
        do {
            return try await fetchKeyConfigFromRelay(signedURL: signedURL, profile: profile)
        } catch OHTTPError.httpStatusError(let status, let message) where status == 429 {
            throw OHTTPError.httpStatusError(statusCode: status, message: message)
        } catch let relayError {
            return try await fetchKeyConfigFromDNS(relayError: relayError)
        }
    }

    /// Fetches the signed key configuration through the relay.
    /// The signed config URL is pre-validated by fetchKeyConfig.
    private func fetchKeyConfigFromRelay(signedURL: String, profile: OHTTPProfileInfo) async throws -> OHTTPVerifiedKey {
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

        // Network binding check: the key's network must match the wallet's network
        if let walletNetwork {
            let walletIsTestnet = (walletNetwork == .testnet)
            guard verified.isTestnet == walletIsTestnet else {
                let keyNetwork = verified.isTestnet ? "testnet" : "mainnet"
                let walletNetworkStr = walletIsTestnet ? "testnet" : "mainnet"
                throw OHTTPError.keyConfigError(
                    "Key configuration network (\(keyNetwork)) does not match wallet network (\(walletNetworkStr))"
                )
            }
        }

        return verified
    }

    /// Tries DNS-over-HTTPS as a fallback source when relay fetch or verification fails.
    /// Queries each resolver in order (Cloudflare, then Google), parses the DoH JSON
    /// response to extract the signed envelope, and verifies it.
    /// If the gateway is unknown (no DNS source), the original relay error is thrown.
    /// If all DNS resolvers fail, the original relay error is thrown (preserving its kind).
    /// The DoH request carries its own fixed headers (`httpGetForDNS`), none of the profile's relay-facing ones.
    private func fetchKeyConfigFromDNS(relayError: Error) async throws -> OHTTPVerifiedKey {
        // Check if gateway is known (has a DNS source)
        guard let dohURLs = try? OHTTPNative.dohQueryURLs(gatewayHost: gatewayHost) else {
            // Unknown gateway: fail with original relay error (configuration error)
            throw relayError
        }

        for dohURL in dohURLs {
            do {
                // Fetch DoH JSON
                let dohBody = try await httpGetForDNS(url: dohURL, timeoutMS: keyFetchTimeoutMS)

                // Parse envelope from DoH JSON
                guard let envelope = try? OHTTPNative.envelopeFromDohJSON(dohBody: dohBody, gatewayHost: gatewayHost) else {
                    continue
                }

                // Verify envelope (same path as relay)
                let now = testNow ?? Date()
                let verified: OHTTPVerifiedKey
                if let testKeyVerifier {
                    verified = try testKeyVerifier(envelope, now)
                } else {
                    verified = try OHTTPNative.verifyKeyConfig(gatewayHost: gatewayHost, envelope: envelope, now: now)
                }

                // Network binding check: the key's network must match the wallet's network
                if let walletNetwork {
                    let walletIsTestnet = (walletNetwork == .testnet)
                    guard verified.isTestnet == walletIsTestnet else {
                        let keyNetwork = verified.isTestnet ? "testnet" : "mainnet"
                        let walletNetworkStr = walletIsTestnet ? "testnet" : "mainnet"
                        throw OHTTPError.keyConfigError(
                            "Key configuration network (\(keyNetwork)) does not match wallet network (\(walletNetworkStr))"
                        )
                    }
                }

                return verified
            } catch {
                continue
            }
        }

        // All DNS resolvers failed: throw original relay error, preserving its kind
        throw relayError
    }

    /// HTTP GET for DoH queries (adds Accept: application/dns-json header).
    private func httpGetForDNS(url: String, timeoutMS: Int) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid DoH URL: \(url)")
        }

        var request = URLRequest(url: urlObj)
        request.httpMethod = "GET"
        // The fixed headers keep URLSession from naming the app build, the OS and the locale to the
        // resolver.
        for (name, value) in Self.fixedRelayHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = TimeInterval(timeoutMS) / 1000.0

        let (data, response) = try await httpSender(request, 64 * 1024) // 64 KiB limit for DoH

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OHTTPError.transportError("DoH response is not HTTP")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OHTTPError.transportError("DoH query failed: HTTP \(httpResponse.statusCode)")
        }

        return data
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
                key = try await refetchKeyConfig()
                attempt = 1

            case .refused(let status, let detail):
                let message = "Relay/gateway returned HTTP \(status)\(detail.isEmpty ? "" : ": \(detail)")"
                throw OHTTPError.httpStatusError(statusCode: status, message: message)

            case .wrongMediaType(let contentType):
                throw OHTTPError.transportError("Relay/gateway answered \(contentType), not a sealed response")
            }
        }
    }

    /// The key configuration fetched again after the gateway refused the cached one. The refused key is
    /// discarded first, so that a failed fetch leaves none to be used next.
    func refetchKeyConfig() async throws -> OHTTPVerifiedKey {
        if try OHTTPNative.profileInfo().dropBeforeRefetch {
            await keyCache.store(nil, for: cacheKey)
        }
        return try await keyConfig(forceRefresh: true)
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
        for (name, value) in Self.fixedRelayHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in profile.keyFetchHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if profile.traceOnKeyFetch, let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }

        try await checkRelayBackoff()
        let (data, httpResponse) = try await httpSender(request, Self.maxKeyConfigBytes)
        await noteRelayAnswer(status: httpResponse.statusCode, retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))

        guard httpResponse.statusCode == Self.keyFetchSuccessStatus else {
            throw OHTTPError.httpStatusError(
                statusCode: httpResponse.statusCode,
                message: "Key config fetch failed: HTTP \(httpResponse.statusCode)"
            )
        }

        return data
    }

    private func httpPost(url: String, body: Data, timeoutMS: Int) async throws -> (Data, HTTPURLResponse) {
        let request = try relayPost(url: url, body: body, timeoutMS: timeoutMS)
        try await checkRelayBackoff()
        let (data, response) = try await httpSender(request, Self.maxRelayResponseBytes)
        await noteRelayAnswer(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        return (data, response)
    }

    /// The relay POST of a sealed request: the profile's headers, the fixed relay-facing ones and, in a
    /// debug build with a prefix set, a trace id.
    func relayPost(url: String, body: Data, timeoutMS: Int) throws -> URLRequest {
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

        for (name, value) in Self.fixedRelayHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        for (name, value) in profile.postHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let prefix = clientTraceIdPrefix {
            let traceId = generateClientTraceId(prefix: prefix)
            request.setValue(traceId, forHTTPHeaderField: "X-Client-Trace-Id")
        }
        return request
    }

    /// Records the pause of a 429 through this relay, which every later post waits out: its `Retry-After`,
    /// or ``defaultRateLimitPause`` when the answer carries none that can be read (ZIP "Outer response
    /// contract": "otherwise SHOULD wait 30 s (reference default)").
    func noteRelayAnswer(status: Int, retryAfter: String?) async {
        guard status == 429 else { return }
        let delay = Self.retryAfter(retryAfter) ?? Self.defaultRateLimitPause
        await keyCache.setBackoff(until: Date().addingTimeInterval(delay), for: backoffKey)
    }

    /// Fails at once, without sending, while the pause of an earlier 429 through this relay runs
    /// (ZIP "Outer response contract": a call made during the pause is failed locally, as a 429).
    func checkRelayBackoff() async throws {
        guard let remaining = await relayPauseRemaining() else { return }
        throw OHTTPError.httpStatusError(
            statusCode: 429,
            message: "relay rate limit: not sent, \(Int(remaining.rounded(.up)))s of the relay's pause left"
        )
    }

    /// The delay of a `Retry-After` value in the delay-seconds form, capped at ``maxRetryAfter``; nil for a
    /// missing, malformed or date-form value.
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value, let seconds = UInt64(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(TimeInterval(seconds), maxRetryAfter)
    }

    /// Generates a client trace ID from the given prefix: `<sanitized-prefix>-<uuid>`, truncated to
    /// 64 chars. The prefix is sanitised to match `^[A-Za-z0-9._:-]+$` (relay/gateway requirement).
    /// Uses a default prefix "x" when the sanitized prefix is empty.
    private func generateClientTraceId(prefix: String) -> String {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        let sanitized = prefix.unicodeScalars.filter { allowedCharacters.contains($0) }.map { String($0) }.joined()
        let effectivePrefix = sanitized.isEmpty ? "x" : sanitized
        let uuid = UUID().uuidString
        let full = "\(effectivePrefix)-\(uuid)"
        return full.count <= 64 ? full : String(full.prefix(64))
    }
}

// MARK: - Bounded reading of the relay's answers

extension OHTTPTransport {
    /// Reads response data with a size bound, enforcing the limit while reading. ZIP MUST requirement
    /// for OHTTP relay responses: abort as soon as the limit is exceeded. Streams the body with
    /// `session.bytes(for:)` and counts it, rejecting early if `expectedContentLength > maxBytes`.
    /// A non-2xx answer (an error page) is read up to ``maxErrorBodyBytes`` at most, whatever `maxBytes`:
    /// the read stops there and the answer is returned with the body read so far, its status and headers
    /// intact, so that it is reported by its status (see ``bodyBound(for:maxBytes:)``).
    ///
    /// - Parameters:
    ///   - request: The URL request to execute
    ///   - maxBytes: Maximum allowed response size in bytes
    ///   - session: The URLSession to use (defaults to OHTTPTransport.session)
    /// - Returns: The response data and URLResponse
    /// - Throws: `OHTTPError.responseTooLarge` if a 2xx response exceeds maxBytes, or transport errors
    static func boundedData(
        for request: URLRequest,
        maxBytes: Int,
        session: URLSession = OHTTPTransport.session
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: oneShotBody(request))
        let bound = bodyBound(for: response, maxBytes: maxBytes)

        // Reject early if Content-Length header exceeds the limit
        // `expectedContentLength` is -1 when the length is unknown.
        let expectedLength = response.expectedContentLength
        if expectedLength > Int64(bound.maxBytes), !bound.truncates {
            bytes.task.cancel()
            throw OHTTPError.responseTooLarge(
                "Response Content-Length (\(expectedLength) bytes) exceeds limit (\(bound.maxBytes) bytes)"
            )
        }

        var accumulated = Data()
        if expectedLength > 0 {
            accumulated.reserveCapacity(Int(min(expectedLength, Int64(bound.maxBytes))))
        }

        for try await byte in bytes {
            accumulated.append(byte)
            if accumulated.count > bound.maxBytes {
                bytes.task.cancel()
                guard bound.truncates else {
                    throw OHTTPError.responseTooLarge(
                        "Response size (\(accumulated.count) bytes) exceeded limit (\(bound.maxBytes) bytes)"
                    )
                }
                accumulated.removeLast()
                break
            }
        }

        return (accumulated, response)
    }

    /// The bound on one answer's body. For a 2xx: `maxBytes`, the call's ceiling, past which the read
    /// fails as `responseTooLarge`. For anything else: ``maxErrorBodyBytes``, fixed, past which the read
    /// stops and the answer is returned with what it has (`truncates`), its status and headers intact.
    struct BodyBound: Equatable {
        let maxBytes: Int
        let truncates: Bool
    }

    static func bodyBound(for response: URLResponse, maxBytes: Int) -> BodyBound {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) else {
            return BodyBound(maxBytes: maxBytes, truncates: false)
        }
        return BodyBound(maxBytes: maxErrorBodyBytes, truncates: true)
    }

    /// `request` with its body as a stream the session cannot rewind: with no replacement stream on offer
    /// (`needNewBodyStream` answers nil), URLSession fails the task rather than repeat the body on its
    /// own, for example on a reused connection that turns out to be closed.
    static func oneShotBody(_ request: URLRequest) -> URLRequest {
        guard let body = request.httpBody else { return request }
        var streamed = request
        streamed.httpBody = nil
        streamed.httpBodyStream = InputStream(data: body)
        streamed.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        return streamed
    }

    /// How much of the relay's pause is left, capped at ``maxRetryAfter``; nil when none runs.
    func relayPauseRemaining() async -> TimeInterval? {
        guard let deadline = await keyCache.backoffDeadline(for: backoffKey) else { return nil }
        let remaining = min(deadline.timeIntervalSinceNow, Self.maxRetryAfter)
        return remaining > 0 ? remaining : nil
    }
}
