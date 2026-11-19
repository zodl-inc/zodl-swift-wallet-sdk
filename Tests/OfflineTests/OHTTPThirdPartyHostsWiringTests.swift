//
//  OHTTPThirdPartyHostsWiringTests.swift
//  OfflineTests
//
//  The host-list admission as the request paths run it: the list is refreshed over the request's own senders,
//  Tor in Tor mode, and a host the list does not carry is refused before any request is sent for it.
//

import XCTest
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPThirdPartyHostsWiringTests: XCTestCase {
    /// A host the bootstrap list does not name.
    private let unknownURL = "https://helper.example.com/x"

    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    override func tearDown() {
        OHTTPTestSupport.installExampleConfiguration()
        super.tearDown()
    }

    func testInTorModeTheListRefreshUsesTheTorSender() async throws {
        // A host of the bootstrap list that is not an alias host: an alias is a fixed destination, which never
        // touches the list.
        let senders = RecordingTorSenders()

        let error = await streamError(for: "https://zvote.zodl.com/x", senders: senders)

        XCTAssertFalse(Self.isUnsupportedHost(error), "the bootstrap host was refused: \(error)")
        XCTAssertEqual(senders.calls.first, .http)
        let refresh = OHTTPNative.thirdPartyBeginRefresh(network: .mainnet)
        XCTAssertNil(refresh, "no refresh of the list was attempted")
        _ = refresh?.fail()
    }

    func testAnUnknownHostGetsOneRefreshOnTheRequestsSenderBeforeItIsRefused() async throws {
        let senders = RecordingTorSenders()

        let error = await streamError(for: unknownURL, senders: senders)

        XCTAssertTrue(Self.isUnsupportedHost(error), "the unknown host was not refused: \(error)")
        XCTAssertTrue(senders.calls.contains(.http), "the list was not refreshed over the Tor sender")
        XCTAssertFalse(senders.calls.contains(.stream), "a request was streamed for a refused host")
    }

    func testAnUnlistedHostIsRefusedBeforeAnyRelayRequest() async throws {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        let senders = RecordingTorSenders()

        let error = await streamError(for: unknownURL, senders: senders)

        XCTAssertTrue(Self.isUnsupportedHost(error), "the unlisted host was not refused: \(error)")
        XCTAssertEqual(senders.calls, [])
    }

    func testAnUnknownHostIsRefusedWhileOHTTPIsOff() async throws {
        try OHTTPEndpoints.configure(nil)
        let senders = RecordingTorSenders()

        let error = await streamError(for: unknownURL, senders: senders)

        XCTAssertTrue(Self.isUnsupportedHost(error), "the unknown host was not refused: \(error)")
        XCTAssertEqual(senders.calls, [])
    }

    func testAnAliasHostNeverTouchesTheList() async throws {
        let alias = try XCTUnwrap(OHTTPEndpoints.proxyHostMapping.values.sorted().first)
        let senders = RecordingTorSenders()

        let error = await streamError(for: "https://\(alias)/x", senders: senders)

        if case OHTTPError.transportError(let message) = error {
            XCTAssertEqual(message, "test")
        } else {
            XCTFail("the alias request did not end with the sender's error: \(error)")
        }
        let refresh = OHTTPNative.thirdPartyBeginRefresh(network: .mainnet)
        XCTAssertNotNil(refresh, "a refresh of the list was begun for an alias host")
        XCTAssertEqual(refresh?.fail(), .kept)
    }

    // MARK: - Helpers

    /// The error `OHTTPExternalHTTP.stream` ends with for a GET of `text` on mainnet in Tor mode, over `senders`.
    private func streamError(
        for text: String,
        senders: RecordingTorSenders,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error {
        guard let url = URL(string: text) else {
            XCTFail("\(text) is not a URL", file: file, line: line)
            return OHTTPError.transportError("not a URL")
        }
        do {
            _ = try await OHTTPExternalHTTP.stream(
                URLRequest(url: url),
                network: .mainnet,
                viaTor: true,
                torSender: senders.torSender,
                torStreamSender: senders.torStreamSender
            )
            XCTFail("\(text) was answered", file: file, line: line)
            return OHTTPError.transportError("answered")
        } catch {
            return error
        }
    }

    private static func isUnsupportedHost(_ error: Error) -> Bool {
        if let zcashError = error as? ZcashError, case .ohttpUnsupportedHost = zcashError {
            return true
        }
        return false
    }
}

/// Tor senders that record each call, in order, behind a lock, and then fail it with a transport error.
private final class RecordingTorSenders: Sendable {
    enum Call: Equatable {
        /// A call of the Tor `HTTPSender`: a key-configuration GET, or a relay POST answered whole.
        case http
        /// A call of the Tor `StreamSender`: a relay POST whose answer is read as it arrives.
        case stream
    }

    private let recorded = OSAllocatedUnfairLock(initialState: [Call]())

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    var torSender: OHTTPTransport.HTTPSender {
        { _, _ in
            self.recorded.withLock { $0.append(.http) }
            throw OHTTPError.transportError("test")
        }
    }

    var torStreamSender: OHTTPTransport.StreamSender {
        { _, _ in
            self.recorded.withLock { $0.append(.stream) }
            throw OHTTPError.transportError("test")
        }
    }
}
