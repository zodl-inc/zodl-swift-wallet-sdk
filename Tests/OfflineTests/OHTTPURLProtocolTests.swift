//
//  OHTTPURLProtocolTests.swift
//  OfflineTests
//
//  `OHTTPURLProtocol` in a real `URLSession`: how a request is mapped to its gateway alias, that a body
//  reaches the session as it is streamed, and the errors the session sees.
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// What the protocol handed to its streamer.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { stored.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { stored }
    }
}

/// Records what a data task delivers, as the Flexa SSE client's delegate sees it.
private final class RecordingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chunks: [Data] = []
    private(set) var response: HTTPURLResponse?
    private(set) var error: Error?
    let firstChunk = XCTestExpectation(description: "first chunk")
    let completed = XCTestExpectation(description: "completed")

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock { self.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isFirst = lock.withLock { () -> Bool in
            chunks.append(data)
            return chunks.count == 1
        }
        if isFirst {
            firstChunk.fulfill()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { self.error = error }
        completed.fulfill()
    }

    var received: Data {
        lock.withLock { chunks.reduce(Data(), +) }
    }
}

final class OHTTPURLProtocolTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    override func tearDown() {
        OHTTPURLProtocol.streamer = nil
        super.tearDown()
    }

    private func response(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func body(_ chunks: [Data], failing error: Error? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish(throwing: error)
        }
    }

    private func session() -> URLSession {
        URLSession(configuration: OHTTPURLProtocol.configuration(.ephemeral))
    }

    func testARequestGoesToTheGatewayAliasWithItsMethodFieldsAndBody() async throws {
        let captured = Captured()
        OHTTPURLProtocol.streamer = { [self] request in
            captured.append(request)
            return OHTTPStreamedResponse(
                response: response(request, headers: ["Content-Type": "application/vnd.flexa+json"]),
                body: body([Data("{\"id\":\"tok_1\"}".utf8)])
            )
        }

        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.flexa.co/tokens")))
        request.httpMethod = "POST"
        request.setValue("Basic OnB1Ymxpc2hhYmxl", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"email\":\"a@b.c\"}".utf8)

        let (data, urlResponse) = try await session().data(for: request)
        let http = try XCTUnwrap(urlResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.url?.host, "api.flexa.co", "the session sees the host it asked for")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/vnd.flexa+json")
        XCTAssertEqual(data, Data("{\"id\":\"tok_1\"}".utf8))

        let sent = try XCTUnwrap(captured.requests.first)
        XCTAssertEqual(captured.requests.count, 1)
        XCTAssertEqual(sent.url?.absoluteString, "https://flexa.zodl.com/tokens")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Basic OnB1Ymxpc2hhYmxl")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.httpBody, Data("{\"email\":\"a@b.c\"}".utf8))
    }

    func testTheSessionsHeadersReachAnEventStreamRequest() async throws {
        let captured = Captured()
        OHTTPURLProtocol.streamer = { [self] request in
            captured.append(request)
            return OHTTPStreamedResponse(response: response(request), body: body([]))
        }

        let delegate = RecordingDelegate()
        let session = OHTTPURLProtocol.session(
            configuration: .default,
            headers: ["Last-Event-ID": "evt_42"],
            delegate: delegate,
            delegateQueue: nil
        )
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.flexa.co/events?type=commerce_session.closed")))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        await fulfillment(of: [delegate.completed], timeout: 10)
        XCTAssertNil(delegate.error)
        session.invalidateAndCancel()

        let sent = try XCTUnwrap(captured.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://flexa.zodl.com/events?type=commerce_session.closed")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Last-Event-ID"), "evt_42")
        XCTAssertGreaterThanOrEqual(sent.timeoutInterval, OHTTPURLProtocol.eventStreamTimeout)
    }

    func testAStreamedBodyReachesTheSessionAsItArrivesAndEndsCleanly() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        OHTTPURLProtocol.streamer = { [self] request in
            OHTTPStreamedResponse(response: response(request, headers: ["Content-Type": "text/event-stream"]), body: stream)
        }

        let delegate = RecordingDelegate()
        let session = OHTTPURLProtocol.session(configuration: .default, headers: [:], delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.flexa.co/events")))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()

        continuation.yield(Data("event: commerce_session.created\ndata: {}\n\n".utf8))
        await fulfillment(of: [delegate.firstChunk], timeout: 10)
        XCTAssertEqual(delegate.chunks.count, 1, "the first event is delivered while the stream is still open")
        XCTAssertEqual(delegate.response?.statusCode, 200)

        continuation.yield(Data("event: commerce_session.closed\ndata: {}\n\n".utf8))
        continuation.finish()
        await fulfillment(of: [delegate.completed], timeout: 10)
        XCTAssertNil(delegate.error, "the gateway's cut of a stream is a clean end: the SSE client reconnects")
        XCTAssertEqual(
            delegate.received,
            Data("event: commerce_session.created\ndata: {}\n\nevent: commerce_session.closed\ndata: {}\n\n".utf8)
        )
        session.invalidateAndCancel()
    }

    func testAHostWithNoGatewayAliasFailsAndNeverGoesOut() async throws {
        let captured = Captured()
        OHTTPURLProtocol.streamer = { [self] request in
            captured.append(request)
            return OHTTPStreamedResponse(response: response(request), body: body([]))
        }
        do {
            _ = try await session().data(from: try XCTUnwrap(URL(string: "https://example.com/")))
            XCTFail("a host with no alias must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .unsupportedURL)
        }
        XCTAssertTrue(captured.requests.isEmpty)
    }

    func testAFailureBeforeTheResponseCannotConnect() async throws {
        OHTTPURLProtocol.streamer = { _ in
            throw OHTTPError.httpStatusError(statusCode: 503, message: "Relay/gateway returned HTTP 503")
        }
        do {
            _ = try await session().data(from: try XCTUnwrap(URL(string: "https://api.flexa.co/assets")))
            XCTFail("a refused OHTTP request must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
            XCTAssertNotNil((error as NSError).userInfo[NSUnderlyingErrorKey])
        }
    }

    func testABodyThatBreaksOffLosesTheConnection() async throws {
        OHTTPURLProtocol.streamer = { [self] request in
            OHTTPStreamedResponse(
                response: response(request, headers: ["Content-Type": "text/event-stream"]),
                body: body([Data("partial".utf8)], failing: OHTTPError.transportError("the gateway's answer ended before its final chunk"))
            )
        }
        let delegate = RecordingDelegate()
        let session = OHTTPURLProtocol.session(configuration: .default, headers: [:], delegate: delegate, delegateQueue: nil)
        session.dataTask(with: try XCTUnwrap(URL(string: "https://api.flexa.co/events"))).resume()
        await fulfillment(of: [delegate.completed], timeout: 10)
        XCTAssertEqual((delegate.error as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(delegate.response?.statusCode, 200, "the SSE client sees a 200 that broke off, and reconnects")
        session.invalidateAndCancel()
    }

    func testErrorMapping() {
        XCTAssertEqual(OHTTPURLProtocol.urlError(for: URLError(.timedOut), afterResponse: false).code, .timedOut)
        XCTAssertEqual(OHTTPURLProtocol.urlError(for: CancellationError(), afterResponse: true).code, .cancelled)
        XCTAssertEqual(OHTTPURLProtocol.urlError(for: ZcashError.ohttpUnsupportedHost, afterResponse: false).code, .unsupportedURL)
        XCTAssertEqual(OHTTPURLProtocol.urlError(for: OHTTPError.keyConfigError("x"), afterResponse: false).code, .cannotConnectToHost)
        XCTAssertEqual(OHTTPURLProtocol.urlError(for: OHTTPError.binaryHttpError("x"), afterResponse: true).code, .networkConnectionLost)
    }

    func testWithNoStreamerEveryRequestFails() async throws {
        OHTTPURLProtocol.streamer = nil
        do {
            _ = try await session().data(from: try XCTUnwrap(URL(string: "https://api.flexa.co/assets")))
            XCTFail("with no streamer a request must fail, not go out directly")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }
}
