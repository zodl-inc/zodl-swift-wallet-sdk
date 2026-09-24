import Combine
import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class TorSynchronizerAdapterTests: XCTestCase {
    func testClosureForwardsBoundedGETAndItsResponse() async throws {
        let underlying = SynchronizerMock()
        let request = URLRequest(url: URL(string: "https://example.com/confirmation")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
        underlying.httpGetOverTorForRetryLimitTimeoutMillisecondsClosure = { received, retries, timeout in
            XCTAssertEqual(received, request)
            XCTAssertEqual(retries, 0)
            XCTAssertEqual(timeout, 321)
            return (Data([5]), response)
        }
        let adapter: ClosureSynchronizer = ClosureSDKSynchronizer(synchronizer: underlying)
        let result: (data: Data, response: HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
            adapter.httpGetOverTor(for: request, retryLimit: 0, timeoutMilliseconds: 321) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(result.data, Data([5]))
        XCTAssertEqual(result.response.statusCode, 202)
    }

    func testCombineForwardsBoundedGETAndError() async {
        let underlying = SynchronizerMock()
        let request = URLRequest(url: URL(string: "https://example.com/confirmation")!)
        let release = TorAdapterGate()
        underlying.httpGetOverTorForRetryLimitTimeoutMillisecondsClosure = { received, retries, timeout in
            XCTAssertEqual(received, request)
            XCTAssertEqual(retries, 1)
            XCTAssertEqual(timeout, 654)
            await release.wait()
            throw URLError(.timedOut)
        }
        let adapter: CombineSynchronizer = CombineSDKSynchronizer(synchronizer: underlying)
        let completion = expectation(description: "bounded error forwarded")
        let subscription = adapter.httpGetOverTor(for: request, retryLimit: 1, timeoutMilliseconds: 654)
            .sink(receiveCompletion: { event in
                guard case .failure(let error) = event else { return XCTFail("Expected failure") }
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                completion.fulfill()
            }, receiveValue: { _ in XCTFail("Unexpected successful response") })
        await release.open()
        await fulfillment(of: [completion], timeout: 3)
        withExtendedLifetime(subscription) {}
    }
}

private actor TorAdapterGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
