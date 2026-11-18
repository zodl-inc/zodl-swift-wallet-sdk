//
//  OHTTPThirdPartyHostsTests.swift
//  OfflineTests
//
//  Admission of passthrough hosts by the gateway's list, the refresh of that list over the request's own
//  exchange, and the gateway's `403 unknown authority` answers.
//

import XCTest
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPThirdPartyHostsTests: XCTestCase {
    /// A host the bootstrap list does not name.
    private let unknownURL = "https://helper.example.com/status"

    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    override func tearDown() {
        OHTTPTestSupport.installExampleConfiguration()
        super.tearDown()
    }

    // MARK: - Refresh

    func testRefreshSendsTheGatewaysOwnRequestAndInstallsTheList() async throws {
        let calls = ExchangeCalls()

        let outcome = await OHTTPThirdPartyHosts.refresh(
            network: .mainnet,
            exchange: calls.exchange(answering: answer(["vote.example.org"]))
        )

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(calls.count, 1)
        let request = try XCTUnwrap(calls.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.scheme, "https")
        XCTAssertEqual(request.authority, OHTTPTestSupport.mainnetHost)
        XCTAssertEqual(request.path, "/ohttp-gateway/v1/third-party-hosts")
        XCTAssertTrue(request.headers.isEmpty)
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "vote.example.org", network: .mainnet))
    }

    func testRefreshIsNotSentWhenNoneIsDue() async {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        let calls = ExchangeCalls()

        let outcome = await OHTTPThirdPartyHosts.refresh(
            network: .mainnet,
            exchange: calls.exchange(answering: answer(["helper.example.com"]))
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(calls.count, 0)
    }

    func testAFailedExchangeKeepsTheBootstrapList() async {
        let calls = ExchangeCalls()

        let outcome = await OHTTPThirdPartyHosts.refresh(network: .mainnet, exchange: calls.exchange(answering: nil))

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "vote.zodl.com", network: .mainnet))
    }

    // MARK: - Admission

    func testAdmitPassesFixedDestinationsWithoutAnyExchange() async throws {
        let calls = ExchangeCalls()
        let exchange = calls.exchange(answering: answer([]))

        try await admit(try url("https://\(OHTTPTestSupport.mainnetHost)/x"), exchange: exchange)
        for alias in OHTTPEndpoints.proxyHostMapping.values.sorted() {
            try await admit(try url("https://\(alias)/x"), exchange: exchange)
        }

        XCTAssertEqual(calls.count, 0)
    }

    func testAdmitRefusesAnUnknownHostWhileOHTTPIsOff() async throws {
        try OHTTPEndpoints.configure(nil)
        let calls = ExchangeCalls()

        await assertRefused(try url(unknownURL), exchange: calls.exchange(answering: answer(["helper.example.com"])))

        XCTAssertEqual(calls.count, 0)
    }

    func testAdmitRefusesAPortOtherThan443() async throws {
        // A host of the bootstrap list that is not an alias host: an alias is a fixed destination, which passes
        // before the port is looked at.
        let calls = ExchangeCalls()
        let exchange = calls.exchange(answering: answer(["zvote.zodl.com"]))

        await assertRefused(try url("https://zvote.zodl.com:8443/x"), exchange: exchange)
        XCTAssertEqual(calls.count, 0)

        try await admit(try url("https://zvote.zodl.com:443/x"), exchange: exchange)
        XCTAssertEqual(calls.count, 1)
    }

    func testAdmitRunsADueRefreshFirstThenPassesACarriedHost() async throws {
        let calls = ExchangeCalls()

        try await admit(try url(unknownURL), exchange: calls.exchange(answering: answer(["helper.example.com"])))

        XCTAssertEqual(calls.count, 1)
    }

    func testAdmitRefusesAHostOnNoListAfterOneRefresh() async throws {
        let calls = ExchangeCalls()

        await assertRefused(try url(unknownURL), exchange: calls.exchange(answering: answer(["vote.example.org"])))

        XCTAssertEqual(calls.count, 1)
    }

    func testAdmitWithAFreshListRefusesWithoutAnyExchange() async throws {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        let calls = ExchangeCalls()

        await assertRefused(try url(unknownURL), exchange: calls.exchange(answering: answer(["helper.example.com"])))

        XCTAssertEqual(calls.count, 0)
    }

    func testAdmitWaitsForARunningRefresh() async throws {
        let calls = ExchangeCalls()
        let failing = calls.exchange(answering: nil)
        let unknown = try url(unknownURL)

        // Another caller's refresh is running and brings the host: the admission waits for it, then passes.
        let running = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        async let admitted: Void = OHTTPThirdPartyHosts.admit(
            url: unknown,
            host: "helper.example.com",
            network: .mainnet,
            runningRefreshWait: 2,
            exchange: failing
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            running.finish(status: 200, body: OHTTPTestSupport.hostListBody(["helper.example.com"])),
            .updated
        )
        try await admitted
        XCTAssertEqual(calls.count, 0)

        // A running refresh that does not end: the host is refused once the wait is over, not before.
        OHTTPTestSupport.installExampleConfiguration()
        let stuck = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        let started = ContinuousClock.now
        await assertRefused(unknown, runningRefreshWait: 0.3, exchange: failing)
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, Swift.Duration.milliseconds(300))
        XCTAssertLessThan(elapsed, Swift.Duration.milliseconds(1500))
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(stuck.fail(), .kept)
    }

    // MARK: - Unknown authority answers

    func testNoteAnswerIgnoresOtherStatusesAndLongBodies() throws {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        let unknownAuthority = Data("unknown authority".utf8)

        OHTTPThirdPartyHosts.noteAnswer(status: 200, body: unknownAuthority, host: "vote.example.org", network: .mainnet)
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))

        let longBody = unknownAuthority + Data(repeating: 0x20, count: 65 - unknownAuthority.count)
        XCTAssertEqual(longBody.count, 65)
        OHTTPThirdPartyHosts.noteAnswer(status: 403, body: longBody, host: "vote.example.org", network: .mainnet)
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))

        OHTTPThirdPartyHosts.noteAnswer(status: 403, body: unknownAuthority, host: "vote.example.org", network: .mainnet)
        let refresh = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        XCTAssertEqual(refresh.fail(), .kept)
    }

    func testWatchedBodyPassesBytesThroughAndReportsUnknownAuthority() async throws {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        let source = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("unknown ".utf8))
            continuation.yield(Data("authority".utf8))
            continuation.finish()
        }

        var chunks: [Data] = []
        let watched = OHTTPThirdPartyHosts.watchingForUnknownAuthority(source, host: "vote.example.org", network: .mainnet)
        for try await chunk in watched {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks, [Data("unknown ".utf8), Data("authority".utf8)])
        let refresh = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        XCTAssertEqual(refresh.fail(), .kept)
    }

    // MARK: - Voting session open

    func testRefreshesBeforeSessionOpenOnlyForADirectPredefinedSessionWithAGateway() throws {
        XCTAssertTrue(OHTTPThirdPartyHosts.refreshesBeforeSessionOpen(route: .direct, isCustomServer: false, network: .mainnet))
        XCTAssertFalse(OHTTPThirdPartyHosts.refreshesBeforeSessionOpen(route: .tor, isCustomServer: false, network: .mainnet))
        XCTAssertFalse(OHTTPThirdPartyHosts.refreshesBeforeSessionOpen(route: .direct, isCustomServer: true, network: .mainnet))

        try OHTTPEndpoints.configure(nil)
        XCTAssertFalse(OHTTPThirdPartyHosts.refreshesBeforeSessionOpen(route: .direct, isCustomServer: false, network: .mainnet))
    }

    // MARK: - Helpers

    /// The gateway's answer to a refresh: a list that names `hosts`.
    private func answer(_ hosts: [String]) -> OHTTPResponse {
        OHTTPResponse(status: 200, headers: [], body: OHTTPTestSupport.hostListBody(hosts), trailers: [])
    }

    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    /// Admits `url` on mainnet, its host taken from the URL.
    private func admit(_ url: URL, exchange: OHTTPThirdPartyHosts.Exchange) async throws {
        try await OHTTPThirdPartyHosts.admit(url: url, host: url.host ?? "", network: .mainnet, exchange: exchange)
    }

    /// Admits `url` on mainnet and expects `ZcashError.ohttpUnsupportedHost`.
    private func assertRefused(
        _ url: URL,
        runningRefreshWait: TimeInterval = OHTTPThirdPartyHosts.runningRefreshWait,
        exchange: OHTTPThirdPartyHosts.Exchange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await OHTTPThirdPartyHosts.admit(
                url: url,
                host: url.host ?? "",
                network: .mainnet,
                runningRefreshWait: runningRefreshWait,
                exchange: exchange
            )
            XCTFail("\(url) was admitted", file: file, line: line)
        } catch {
            if let zcashError = error as? ZcashError, case .ohttpUnsupportedHost = zcashError {
                return
            }
            XCTFail("\(url) was refused with \(error)", file: file, line: line)
        }
    }
}

/// The calls an exchange got: a counter and the requests, behind a lock.
private final class ExchangeCalls: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [OHTTPRequest]())

    var count: Int {
        recorded.withLock { $0.count }
    }

    var requests: [OHTTPRequest] {
        recorded.withLock { $0 }
    }

    /// An exchange that records each request and answers `answer`, or throws a transport error when it is nil.
    func exchange(answering answer: OHTTPResponse?) -> OHTTPThirdPartyHosts.Exchange {
        { request in
            self.recorded.withLock { $0.append(request) }
            guard let answer else {
                throw OHTTPError.transportError("test")
            }
            return answer
        }
    }
}
