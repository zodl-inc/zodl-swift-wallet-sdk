//
//  OHTTPStreaming.swift
//  ZODLSwiftWalletSDK
//
//  OHTTP exchanges whose answer is read as it arrives: the relay's sealed answer is decoded chunk by
//  chunk by the shared core, and the backend's body comes out while the gateway is still sending it
//  (a server-sent event stream). Key selection, sealing, the classification of the relay's answer and
//  the retries are those of `roundTrip`.
//

import Foundation
import libzcashlc

/// The relay's answer to a sealed request: its head, and its body as it arrives.
struct OHTTPOuterStream {
    let status: Int
    let contentType: String?
    let retryAfter: String?
    let body: AsyncThrowingStream<Data, Error>
}

/// The backend's answer to an ``OHTTPRequest``: its head, and its body as the gateway sends it. The body
/// fails if the sealed answer breaks off before its end or does not open.
struct OHTTPStreamedInner {
    let status: Int
    let headers: [(String, String)]
    let body: AsyncThrowingStream<Data, Error>
    /// The trailers, available after the body completes. When the response has trailers, they are yielded
    /// after all body chunks. S2: grpc-status may be in trailers, not headers.
    let trailers: AsyncThrowingStream<[(String, String)], Error>

    /// Whether this is the gateway's freshness refusal (see ``OHTTPResponse/isFreshnessRefusal``).
    var isFreshnessRefusal: Bool {
        OHTTPResponse(status: status, headers: headers, body: Data(), trailers: []).isFreshnessRefusal
    }
}

/// What the bytes given to a stream decoder decoded to.
struct OHTTPStreamEvents {
    /// The response head, when it was decoded by this call.
    var head: (status: Int, headers: [(String, String)])?
    var body = Data()
    /// The trailer fields, when the trailer section was decoded by this call.
    var trailers: [(String, String)]?
    /// The response is complete and authenticated.
    var end = false
}

/// Decodes the sealed answer to one request as it arrives.
protocol OHTTPStreamDecoding: AnyObject {
    func push(_ bytes: Data) throws -> OHTTPStreamEvents
    /// The answer has ended: fails when it ended before its final chunk or the message is cut short.
    func finish() throws -> OHTTPStreamEvents
}

/// The core's stream decoder. The response secret stays in the core.
final class OHTTPNativeStreamDecoder: OHTTPStreamDecoding, @unchecked Sendable {
    private var decoder: OpaquePointer?

    init(_ decoder: OpaquePointer) {
        self.decoder = decoder
    }

    deinit {
        zcashlc_ohttp_stream_decoder_free(decoder)
    }

    func push(_ bytes: Data) throws -> OHTTPStreamEvents {
        guard let decoder else {
            throw OHTTPError.transportError("OHTTP stream decoder was already used up")
        }
        let result = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<OhttpStreamEvents>? in
            zcashlc_ohttp_stream_push(decoder, buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count))
        }
        return try events(result)
    }

    func finish() throws -> OHTTPStreamEvents {
        guard let decoder else {
            throw OHTTPError.transportError("OHTTP stream decoder was already used up")
        }
        defer { release() }
        return try events(zcashlc_ohttp_stream_finish(decoder))
    }

    private func release() {
        zcashlc_ohttp_stream_decoder_free(decoder)
        decoder = nil
    }

    private func events(_ result: UnsafeMutablePointer<OhttpStreamEvents>?) throws -> OHTTPStreamEvents {
        guard let result else {
            OHTTPHealthTraffic.current?.nativeFailure(zcashlc_ohttp_last_failure_kind())
            let error = OHTTPError.native(lastErrorMessage(fallback: "OHTTP response could not be opened"))
            release()
            throw error
        }
        defer { zcashlc_free_ohttp_stream_events(result) }

        let value = result.pointee
        var events = OHTTPStreamEvents()
        if value.status != 0 {
            events.head = (Int(value.status), try OHTTPPendingResponse.fields(value.headers, value.headers_len))
        }
        events.body = OHTTPNative.copyBytes(value.body, value.body_len)
        if value.has_trailers {
            events.trailers = try OHTTPPendingResponse.fields(value.trailers, value.trailers_len)
        }
        events.end = value.end
        return events
    }
}

extension OHTTPTransport {
    /// Sender of a relay POST whose answer is read as it arrives. The Int is the most body bytes it reads.
    typealias StreamSender = (URLRequest, Int) async throws -> OHTTPOuterStream

    /// Makes the decoder of a sealed answer out of the handle that opens it.
    typealias StreamDecoderFactory = (OHTTPPendingResponse) throws -> OHTTPStreamDecoding

    /// Performs one OHTTP call whose answer is read as it arrives: the same exchange as ``roundTrip(request:timeoutMS:)``
    /// (a key refetch after an outer 400 or 422, the relay's `Retry-After`, one more attempt after a freshness
    /// refusal), returning once the backend's head has been decoded.
    ///
    /// `timeoutMS` bounds each wait for the relay, not the whole answer: a stream lasts as long as the gateway
    /// keeps it open.
    nonisolated func stream(request: OHTTPRequest, timeoutMS: Int) async throws -> OHTTPStreamedInner {
        var health = OHTTPHealthTraffic(route: healthRoute, request: request)
        do {
            let first = try await OHTTPHealthTraffic.$current.withValue(health) {
                try await streamOnce(request: request, timeoutMS: timeoutMS, health: health)
            }
            if first.isFreshnessRefusal {
                health = OHTTPHealthTraffic(ticket: health.ticket)
                let retry = try await OHTTPHealthTraffic.$current.withValue(health) {
                    try await streamOnce(request: request, timeoutMS: timeoutMS, health: health)
                }
                return Self.observed(retry, health: health)
            }
            return Self.observed(first, health: health)
        } catch {
            health.failed(error)
            throw error
        }
    }

    private nonisolated static func observed(_ response: OHTTPStreamedInner, health: OHTTPHealthTraffic) -> OHTTPStreamedInner {
        health.received(OHTTPResponse(status: response.status, headers: response.headers, body: Data(), trailers: []), stage: .responseHead)
        health.advance(.responseBody)
        let (body, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let (trailers, trailerContinuation) = AsyncThrowingStream.makeStream(of: [(String, String)].self, throwing: Error.self)
        let task = Task {
            do {
                for try await chunk in response.body { continuation.yield(chunk) }
                try Task.checkCancellation()
                var fields: [(String, String)] = []
                for try await chunk in response.trailers {
                    fields.append(contentsOf: chunk)
                    trailerContinuation.yield(chunk)
                }
                health.received(OHTTPResponse(status: response.status, headers: response.headers, body: Data(), trailers: fields), stage: .complete)
                continuation.finish()
                trailerContinuation.finish()
            } catch {
                health.failed(error)
                continuation.finish(throwing: error)
                trailerContinuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return OHTTPStreamedInner(status: response.status, headers: response.headers, body: body, trailers: trailers)
    }

    private func streamOnce(request: OHTTPRequest, timeoutMS: Int, health: OHTTPHealthTraffic) async throws -> OHTTPStreamedInner {
        health.advance(.keyConfiguration)
        var key = try await keyConfig()
        var attempt: UInt32 = 0

        while true {
            let sealed = try OHTTPNative.encapsulate(key: key, request: request)
            let post = try relayPost(url: relayURL, body: sealed.body, timeoutMS: timeoutMS)
            try await checkRelayBackoff()
            health.advance(.connection)
            let outer = try await streamSender(post, Self.maxRelayResponseBytes)
            await noteRelayAnswer(status: outer.status, retryAfter: outer.retryAfter)

            if try OHTTPNative.answerIsSealed(status: outer.status, contentType: outer.contentType, attempt: attempt) {
                return try await Self.open(outer.body, with: streamDecoderFactory(sealed.pending))
            }

            var body = Data()
            for try await chunk in outer.body {
                body.append(chunk)
            }
            let completed = try sealed.pending.complete(
                status: outer.status,
                contentType: outer.contentType,
                body: body,
                attempt: attempt
            )
            switch completed {
            case .response(let response):
                return OHTTPStreamedInner(
                    status: response.status,
                    headers: response.headers,
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(response.body)
                        continuation.finish()
                    },
                    trailers: AsyncThrowingStream { continuation in
                        continuation.yield(response.trailers)
                        continuation.finish()
                    }
                )

            case .refetchKeyConfig:
                guard attempt == 0 else {
                    throw OHTTPError.transportError("OHTTP key configuration was refused twice")
                }
                health.advance(.keyConfiguration)
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

    /// Decodes `outer` with `decoder` and returns once the backend's head is out, the body following as it
    /// is decoded. Iterating the body no longer, or cancelling the caller before the head, stops the read.
    static func open(
        _ outer: AsyncThrowingStream<Data, Error>,
        with decoder: OHTTPStreamDecoding
    ) async throws -> OHTTPStreamedInner {
        let (heads, headContinuation) = AsyncThrowingStream.makeStream(of: OHTTPStreamedHead.self, throwing: Error.self)
        let (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let (trailers, trailersContinuation) = AsyncThrowingStream.makeStream(of: [(String, String)].self, throwing: Error.self)

        let pump = Task {
            var headSent = false
            func deliver(_ events: OHTTPStreamEvents) {
                if let head = events.head, !headSent {
                    headSent = true
                    headContinuation.yield(OHTTPStreamedHead(status: head.status, headers: head.headers))
                    headContinuation.finish()
                }
                if headSent, !events.body.isEmpty {
                    bodyContinuation.yield(events.body)
                }
                // S2: surface trailers after body chunks
                if let responseTrailers = events.trailers {
                    trailersContinuation.yield(responseTrailers)
                }
            }
            do {
                for try await chunk in outer {
                    deliver(try decoder.push(chunk))
                }
                deliver(try decoder.finish())
                guard headSent else {
                    throw OHTTPError.binaryHttpError("The gateway's answer has no response head")
                }
                bodyContinuation.finish()
                trailersContinuation.finish()
            } catch {
                if headSent {
                    bodyContinuation.finish(throwing: error)
                    trailersContinuation.finish(throwing: error)
                } else {
                    headContinuation.finish(throwing: error)
                    bodyContinuation.finish(throwing: error)
                    trailersContinuation.finish(throwing: error)
                }
            }
        }
        bodyContinuation.onTermination = { _ in pump.cancel() }

        return try await withTaskCancellationHandler {
            var iterator = heads.makeAsyncIterator()
            guard let head = try await iterator.next() else {
                throw CancellationError()
            }
            return OHTTPStreamedInner(status: head.status, headers: head.headers, body: body, trailers: trailers)
        } onCancel: {
            pump.cancel()
        }
    }

    /// Posts `request` on the relay session and returns once the relay's head has arrived, the body
    /// following as it arrives. The body fails beyond `maxBytes`; a non-2xx one is cut at ``maxErrorBodyBytes``
    /// and the answer kept, status and headers intact (see ``bodyBound(for:maxBytes:)``); redirects are
    /// refused, and the body is never sent twice (see ``oneShotBody(_:)``).
    static func streamedData(
        for request: URLRequest,
        maxBytes: Int,
        session: URLSession = OHTTPTransport.session
    ) async throws -> OHTTPOuterStream {
        let reader = OHTTPStreamReader(maxBytes: maxBytes)
        let task = session.dataTask(with: oneShotBody(request))
        task.delegate = reader
        return try await reader.start(task)
    }
}

struct OHTTPStreamedHead {
    let status: Int
    let headers: [(String, String)]
}

/// Delegate of one relay task read as it arrives.
private final class OHTTPStreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    /// The bound of this answer's body, set with its head (``OHTTPTransport/bodyBound(for:maxBytes:)``).
    private var bound: OHTTPTransport.BodyBound?
    private var head: CheckedContinuation<OHTTPOuterStream, Error>?
    private var received = 0
    private let body: AsyncThrowingStream<Data, Error>
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
        let pair = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        body = pair.stream
        bodyContinuation = pair.continuation
        super.init()
    }

    func start(_ task: URLSessionDataTask) async throws -> OHTTPOuterStream {
        bodyContinuation.onTermination = { _ in task.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { head = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func takeHead() -> CheckedContinuation<OHTTPOuterStream, Error>? {
        lock.withLock {
            defer { head = nil }
            return head
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            takeHead()?.resume(throwing: OHTTPError.transportError("Invalid response type"))
            return
        }
        let bound = OHTTPTransport.bodyBound(for: response, maxBytes: maxBytes)
        lock.withLock { self.bound = bound }
        if response.expectedContentLength > Int64(bound.maxBytes), !bound.truncates {
            completionHandler(.cancel)
            takeHead()?.resume(throwing: OHTTPError.responseTooLarge(
                "Response Content-Length (\(response.expectedContentLength) bytes) exceeds limit (\(bound.maxBytes) bytes)"
            ))
            return
        }
        completionHandler(.allow)
        takeHead()?.resume(returning: OHTTPOuterStream(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            body: body
        ))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (total, bound) = lock.withLock {
            received += data.count
            return (received, self.bound ?? OHTTPTransport.BodyBound(maxBytes: maxBytes, truncates: false))
        }
        guard total <= bound.maxBytes else {
            dataTask.cancel()
            guard bound.truncates else {
                bodyContinuation.finish(throwing: OHTTPError.responseTooLarge(
                    "Response size (\(total) bytes) exceeded limit (\(bound.maxBytes) bytes)"
                ))
                return
            }
            // An error page past the guard: keep what fits, end the body there, the answer stands by its status.
            let room = bound.maxBytes - (total - data.count)
            if room > 0 {
                bodyContinuation.yield(data.prefix(room))
            }
            bodyContinuation.finish()
            return
        }
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let head = takeHead() {
            head.resume(throwing: error ?? OHTTPError.transportError("The relay closed the connection without an answer"))
        }
        if let error {
            bodyContinuation.finish(throwing: error)
        } else {
            bodyContinuation.finish()
        }
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(nil)
    }
}
