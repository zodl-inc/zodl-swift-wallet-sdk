//
//  OHTTPBoundedResponseTests.swift
//  OfflineTests
//
//  Tests for the ZIP MUST requirement: OHTTP relay responses must be bounded while reading.
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// Mock URLProtocol that serves responses of a specified size for testing bounded data reading.
class MockResponseURLProtocol: URLProtocol {
    static var responseSize: Int = 0
    static var shouldSimulateStreaming: Bool = false

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // Send a mock HTTP 200 response
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Send the body data
        let data = Data(repeating: 0x42, count: Self.responseSize)

        if Self.shouldSimulateStreaming {
            // Send in chunks to simulate streaming
            let chunkSize = 1024
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset..<end]
                client?.urlProtocol(self, didLoad: chunk)
                offset = end
            }
        } else {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Nothing to clean up
    }
}

final class OHTTPBoundedResponseTests: XCTestCase {
    var testSession: URLSession!

    override func setUp() {
        super.setUp()

        // Create a session that uses our mock protocol
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockResponseURLProtocol.self]
        testSession = URLSession(configuration: config)

        MockResponseURLProtocol.shouldSimulateStreaming = false
    }

    override func tearDown() {
        testSession = nil
        MockResponseURLProtocol.responseSize = 0
        MockResponseURLProtocol.shouldSimulateStreaming = false
        super.tearDown()
    }

    /// Test that a response under the limit succeeds.
    func testResponseUnderLimitSucceeds() async throws {
        MockResponseURLProtocol.responseSize = 1024 // 1 KiB
        let maxBytes = 2048 // 2 KiB limit

        let request = URLRequest(url: URL(string: "https://example.com/test")!)
        let (data, response) = try await OHTTPTransport.boundedData(
            for: request,
            maxBytes: maxBytes,
            session: testSession
        )

        XCTAssertEqual(data.count, 1024, "Should receive all data when under limit")
        XCTAssertNotNil(response as? HTTPURLResponse, "Response should be HTTPURLResponse")
    }

    /// Test that a response exactly at the limit succeeds.
    func testResponseAtLimitSucceeds() async throws {
        MockResponseURLProtocol.responseSize = 2048 // 2 KiB
        let maxBytes = 2048 // 2 KiB limit

        let request = URLRequest(url: URL(string: "https://example.com/test")!)
        let (data, response) = try await OHTTPTransport.boundedData(
            for: request,
            maxBytes: maxBytes,
            session: testSession
        )

        XCTAssertEqual(data.count, 2048, "Should receive all data when exactly at limit")
        XCTAssertNotNil(response as? HTTPURLResponse, "Response should be HTTPURLResponse")
    }

    /// Test that a response over the limit throws responseTooLarge error.
    func testResponseOverLimitThrows() async throws {
        MockResponseURLProtocol.responseSize = 3072 // 3 KiB
        let maxBytes = 2048 // 2 KiB limit
        MockResponseURLProtocol.shouldSimulateStreaming = true

        let request = URLRequest(url: URL(string: "https://example.com/test")!)

        do {
            _ = try await OHTTPTransport.boundedData(
                for: request,
                maxBytes: maxBytes,
                session: testSession
            )
            XCTFail("Should have thrown responseTooLarge error")
        } catch let error as OHTTPError {
            switch error {
            case .responseTooLarge(let message):
                XCTAssertTrue(
                    message.contains("exceeded limit"),
                    "Error message should mention exceeded limit: \(message)"
                )
            default:
                XCTFail("Expected responseTooLarge error, got \(error)")
            }
        }
    }

    /// Test that the key config size limit constant is reasonable (64 KiB).
    func testKeyConfigSizeLimitIsReasonable() {
        XCTAssertEqual(OHTTPTransport.maxKeyConfigBytes, 64 * 1024, "Key config limit should be 64 KiB")
    }

    /// Test that the relay response size limit constant is correct (256 MiB + 1 MiB overhead).
    func testRelayResponseSizeLimitIsCorrect() {
        let expected = (256 * 1024 * 1024) + (1024 * 1024)
        XCTAssertEqual(
            OHTTPTransport.maxRelayResponseBytes,
            expected,
            "Relay response limit should be 256 MiB + 1 MiB overhead"
        )
    }

    /// Test that streaming large response aborts early (not buffering entire body before checking).
    func testStreamingLargeResponseAbortsEarly() async throws {
        // This test ensures we don't buffer the entire response before checking size
        MockResponseURLProtocol.responseSize = 10 * 1024 * 1024 // 10 MiB
        let maxBytes = 1024 * 1024 // 1 MiB limit
        MockResponseURLProtocol.shouldSimulateStreaming = true

        let request = URLRequest(url: URL(string: "https://example.com/test")!)

        do {
            _ = try await OHTTPTransport.boundedData(
                for: request,
                maxBytes: maxBytes,
                session: testSession
            )
            XCTFail("Should have thrown responseTooLarge error")
        } catch let error as OHTTPError {
            switch error {
            case .responseTooLarge:
                // Success - we aborted early
                break
            default:
                XCTFail("Expected responseTooLarge error, got \(error)")
            }
        }
    }

    // MARK: iOS 13/14 path (delegate callbacks instead of `bytes(for:)`), run on every OS

    func testDelegatePathUnderAndAtLimitSucceeds() async throws {
        let request = URLRequest(url: URL(string: "https://example.com/test")!)
        for size in [1024, 2048] {
            MockResponseURLProtocol.responseSize = size
            let (data, response) = try await OHTTPTransport.boundedDataViaDelegate(
                for: request,
                maxBytes: 2048,
                configuration: testSession.configuration
            )
            XCTAssertEqual(data.count, size, "Should receive all data up to the limit")
            XCTAssertNotNil(response as? HTTPURLResponse, "Response should be HTTPURLResponse")
        }
    }

    func testDelegatePathStreamingLargeResponseAbortsEarly() async throws {
        MockResponseURLProtocol.responseSize = 10 * 1024 * 1024 // 10 MiB
        MockResponseURLProtocol.shouldSimulateStreaming = true
        let request = URLRequest(url: URL(string: "https://example.com/test")!)

        do {
            _ = try await OHTTPTransport.boundedDataViaDelegate(
                for: request,
                maxBytes: 1024 * 1024,
                configuration: testSession.configuration
            )
            XCTFail("Should have thrown responseTooLarge error")
        } catch let error as OHTTPError {
            switch error {
            case .responseTooLarge(let message):
                XCTAssertTrue(message.contains("exceeded limit"), "Error message should mention exceeded limit: \(message)")
            default:
                XCTFail("Expected responseTooLarge error, got \(error)")
            }
        }
    }

    // MARK: Finding A - Key config limit enforcement

    /// Test that a 64 KiB key-config response succeeds through the production sender.
    func testKeyConfigAtLimitSucceedsViaSender() async throws {
        MockResponseURLProtocol.responseSize = 64 * 1024 // 64 KiB
        let request = URLRequest(url: URL(string: "https://example.com/ohttp-configs")!)

        // Production sender with key-config limit
        let sender: OHTTPTransport.HTTPSender = { request, maxBytes in
            let (data, response) = try await OHTTPTransport.boundedData(
                for: request,
                maxBytes: maxBytes,
                session: self.testSession
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OHTTPError.transportError("Invalid response type")
            }
            return (data, httpResponse)
        }

        let (data, response) = try await sender(request, OHTTPTransport.maxKeyConfigBytes)
        XCTAssertEqual(data.count, 64 * 1024, "Should receive all data at limit")
        XCTAssertEqual(response.statusCode, 200, "Should get 200 response")
    }

    /// Test that a 65 KiB key-config response fails with responseTooLarge through the production sender.
    func testKeyConfigOverLimitFailsViaSender() async throws {
        MockResponseURLProtocol.responseSize = 65 * 1024 // 65 KiB
        MockResponseURLProtocol.shouldSimulateStreaming = true
        let request = URLRequest(url: URL(string: "https://example.com/ohttp-configs")!)

        // Production sender with key-config limit
        let sender: OHTTPTransport.HTTPSender = { request, maxBytes in
            let (data, response) = try await OHTTPTransport.boundedData(
                for: request,
                maxBytes: maxBytes,
                session: self.testSession
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OHTTPError.transportError("Invalid response type")
            }
            return (data, httpResponse)
        }

        do {
            _ = try await sender(request, OHTTPTransport.maxKeyConfigBytes)
            XCTFail("Should have thrown responseTooLarge error")
        } catch let error as OHTTPError {
            switch error {
            case .responseTooLarge(let message):
                XCTAssertTrue(
                    message.contains("exceeded limit"),
                    "Error message should mention exceeded limit: \(message)"
                )
            default:
                XCTFail("Expected responseTooLarge error, got \(error)")
            }
        }
    }
}
