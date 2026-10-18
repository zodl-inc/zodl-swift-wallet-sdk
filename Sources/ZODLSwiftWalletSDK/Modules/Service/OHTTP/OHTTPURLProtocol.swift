//
//  OHTTPURLProtocol.swift
//  ZODLSwiftWalletSDK
//
//  A `URLProtocol` that sends every request of the sessions it is registered in through the OHTTP relay
//  and gateway, for a third-party SDK whose `URLSession` can be replaced but whose requests cannot. The
//  request's host is mapped to its gateway alias (`OHTTPEndpoints.proxyURL(for:)`, e.g. `api.flexa.co` to
//  `flexa.zodl.com`); a host with none fails, it never goes out directly. The body reaches the session as
//  the gateway sends it, so a server-sent event stream is delivered event by event.
//

import Foundation

public final class OHTTPURLProtocol: URLProtocol {
    /// Sends a request to a gateway host through OHTTP, as ``Synchronizer/httpStreamOverOHTTP(for:viaTor:)`` does.
    public typealias Streamer = @Sendable (URLRequest) async throws -> OHTTPStreamedResponse

    /// The relay wait of a server-sent event stream: longer than the gateway keeps one open, so that its
    /// end is the gateway's and not a timeout here.
    static let eventStreamTimeout: TimeInterval = 120

    private static let lock = NSLock()
    private static var installedStreamer: Streamer?
    private static let taskHeaders = NSMapTable<URLSessionTask, NSDictionary>.weakToStrongObjects()

    /// The function the requests go through. Until one is set every request fails.
    public static var streamer: Streamer? {
        get { lock.withLock { installedStreamer } }
        set { lock.withLock { installedStreamer = newValue } }
    }

    /// `configuration` with this protocol first in its protocol classes.
    public static func configuration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let others = (configuration.protocolClasses ?? []).filter { ObjectIdentifier($0) != ObjectIdentifier(OHTTPURLProtocol.self) }
        configuration.protocolClasses = [OHTTPURLProtocol.self] + others
        return configuration
    }

    /// A session on `configuration` (see ``configuration(_:)``) whose tasks also send `headers`. Header fields
    /// of a session's configuration (`httpAdditionalHeaders`) are not part of the request a `URLProtocol` is
    /// given, so a field such as `Last-Event-ID` set there is passed this way.
    public static func session(
        configuration: URLSessionConfiguration,
        headers: [String: String],
        delegate: URLSessionDelegate?,
        delegateQueue: OperationQueue?
    ) -> URLSession {
        URLSession(
            configuration: Self.configuration(configuration),
            delegate: OHTTPTaskHeadersDelegate(headers: headers, inner: delegate),
            delegateQueue: delegateQueue
        )
    }

    static func setHeaders(_ headers: [String: String], for task: URLSessionTask) {
        lock.withLock { taskHeaders.setObject(headers as NSDictionary, forKey: task) }
    }

    static func headers(for task: URLSessionTask?) -> [String: String] {
        guard let task else { return [:] }
        return lock.withLock { taskHeaders.object(forKey: task) as? [String: String] } ?? [:]
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased())
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private var worker: Task<Void, Never>?
    private let stateLock = NSLock()
    private var stopped = false

    override public func startLoading() {
        let original = request
        let extraHeaders = Self.headers(for: task)
        let runLoop = ClientRunLoop()
        worker = Task { [weak self] in
            var responded = false
            do {
                let request = try Self.ohttpRequest(for: original, extraHeaders: extraHeaders)
                guard let streamer = Self.streamer else {
                    throw URLError(.cannotConnectToHost)
                }
                let streamed = try await streamer(request)
                guard let url = original.url, let response = HTTPURLResponse(
                    url: url,
                    statusCode: streamed.response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: streamed.response.allHeaderFields as? [String: String]
                ) else {
                    throw URLError(.badServerResponse)
                }
                self?.deliver(on: runLoop) { $0.urlProtocol($1, didReceive: response, cacheStoragePolicy: .notAllowed) }
                responded = true
                for try await chunk in streamed.body {
                    self?.deliver(on: runLoop) { $0.urlProtocol($1, didLoad: chunk) }
                }
                self?.deliver(on: runLoop) { $0.urlProtocolDidFinishLoading($1) }
            } catch {
                let mapped = Self.urlError(for: error, afterResponse: responded)
                self?.deliver(on: runLoop) { $0.urlProtocol($1, didFailWithError: mapped) }
            }
        }
    }

    override public func stopLoading() {
        stateLock.withLock { stopped = true }
        worker?.cancel()
    }

    /// Runs `callback` with the client on the thread that started the load, in order, unless the load was
    /// stopped.
    private func deliver(on runLoop: ClientRunLoop, _ callback: @escaping (URLProtocolClient, URLProtocol) -> Void) {
        runLoop.perform { [weak self] in
            guard let self, !self.stateLock.withLock({ self.stopped }), let client = self.client else { return }
            callback(client, self)
        }
    }

    /// The request to the gateway alias of `request`'s host, with the same method, header fields (and
    /// `extraHeaders` the request lacks) and body.
    static func ohttpRequest(for request: URLRequest, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let proxyURL = OHTTPEndpoints.proxyURL(for: url) else {
            throw URLError(.unsupportedURL)
        }
        var mapped = URLRequest(url: proxyURL)
        mapped.httpMethod = request.httpMethod ?? "GET"
        var headers = request.allHTTPHeaderFields ?? [:]
        for (name, value) in extraHeaders where !headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[name] = value
        }
        mapped.allHTTPHeaderFields = headers
        mapped.httpBody = try OHTTPExternalHTTP.body(of: request)
        let isEventStream = headers.contains {
            $0.key.caseInsensitiveCompare("Accept") == .orderedSame && $0.value.lowercased().contains("text/event-stream")
        }
        mapped.timeoutInterval = isEventStream ? max(request.timeoutInterval, eventStreamTimeout) : request.timeoutInterval
        return mapped
    }

    /// The error the session sees: a `URLError` as it is; a cancelled load `.cancelled`; a host with no
    /// gateway alias `.unsupportedURL`; a failure once the response has begun `.networkConnectionLost` (the
    /// body is incomplete); any other `.cannotConnectToHost`. The cause is the underlying error.
    static func urlError(for error: Error, afterResponse: Bool) -> URLError {
        if let error = error as? URLError {
            return error
        }
        let userInfo: [String: Any] = [NSUnderlyingErrorKey: error as NSError]
        if error is CancellationError {
            return URLError(.cancelled, userInfo: userInfo)
        }
        if let error = error as? ZcashError, case .ohttpUnsupportedHost = error {
            return URLError(.unsupportedURL, userInfo: userInfo)
        }
        return URLError(afterResponse ? .networkConnectionLost : .cannotConnectToHost, userInfo: userInfo)
    }
}

/// The run loop, and its mode, of the thread a load was started on: the client is called there.
private struct ClientRunLoop: @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let modes: CFArray

    init() {
        runLoop = CFRunLoopGetCurrent()
        let current = CFRunLoopCopyCurrentMode(runLoop) ?? CFRunLoopMode("kCFRunLoopDefaultMode" as CFString)
        modes = [current.rawValue, CFRunLoopMode.commonModes.rawValue] as CFArray
    }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, modes, block)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Session delegate that records the extra header fields of every task the session creates and passes
/// every other delegate message on to the session's own delegate.
final class OHTTPTaskHeadersDelegate: NSObject, URLSessionDataDelegate {
    private let headers: [String: String]
    private let inner: URLSessionDelegate?

    init(headers: [String: String], inner: URLSessionDelegate?) {
        self.headers = headers
        self.inner = inner
    }

    /// Called synchronously when the task is created, so before it can start loading.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        OHTTPURLProtocol.setHeaders(headers, for: task)
        (inner as? URLSessionTaskDelegate)?.urlSession?(session, didCreateTask: task)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner, inner.responds(to: aSelector) {
            return inner
        }
        return super.forwardingTarget(for: aSelector)
    }
}
