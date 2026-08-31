//
//  ServerSwitchDecisionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

final class ServerSwitchDecisionTests: XCTestCase {
    private func endpoint(_ host: String, port: Int = 443) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: port, secure: true, streamingCallTimeoutInMillis: 10000)
    }

    private func measured(_ host: String, port: Int = 443, score: TimeInterval) -> ServerSwitchDecision.MeasuredEndpoint {
        ServerSwitchDecision.MeasuredEndpoint(endpoint: endpoint(host, port: port), score: score)
    }

    // Rule 1: nothing measurable → stay.
    func testEmptyResultsStays() {
        let outcome = ServerSwitchDecision.decide(current: endpoint("current.example"), ranked: [])
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Rule 2: the fastest survivor is the current server → stay.
    func testBestIsCurrentStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("current.example", score: 0.1), measured("other.example", score: 0.3)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Rule 3: current produced no score (unhealthy / not benchmarked) → switch regardless of magnitude.
    func testCurrentUnmeasuredSwitches() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.5), measured("other.example", score: 0.6)]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.host, "best.example")
    }

    // Rule 4, the ticket case: ~5 ms faster is not worth a synchronizer teardown.
    func testMarginalImprovementStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.100), measured("current.example", score: 0.105)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Rule 4: absolute gate passes (250 ms) but relative fails (12.5% < 25%) → stay (Tor-noise guard).
    func testAbsolutePassRelativeFailStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 1.75), measured("current.example", score: 2.0)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Rule 4: relative gate passes (89%) but absolute fails (170 ms < 200 ms) → stay.
    func testRelativePassAbsoluteFailStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.02), measured("current.example", score: 0.19)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Rule 4: both gates pass → switch.
    func testSubstantialImprovementSwitches() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.15), measured("current.example", score: 0.4)]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.host, "best.example")
    }

    // Rule 4 boundary: improvement exactly 200 ms and exactly 25% → both gates inclusive → switch.
    func testExactThresholdBoundarySwitches() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.6), measured("current.example", score: 0.8)]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.host, "best.example")
    }

    // Equal scores with a different server ranked first → improvement 0 → stay.
    func testEqualScoresStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.3), measured("current.example", score: 0.3)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Identity is host+port: same host on a different port is NOT the current server.
    func testSameHostDifferentPortIsADifferentServer() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("host.example", port: 443),
            ranked: [measured("host.example", port: 9067, score: 0.1), measured("host.example", port: 443, score: 0.9)]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.port, 9067)
    }

    // Current mid-list: its own score is what the comparison uses.
    func testCurrentMidListUsesItsOwnScore() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [
                measured("best.example", score: 0.1),
                measured("second.example", score: 0.2),
                measured("current.example", score: 0.5)
            ]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.host, "best.example")
    }

    // Single survivor that IS current → stay.
    func testOnlyCurrentSurvivedStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("current.example", score: 0.4)]
        )
        XCTAssertNil(outcome.endpointToSwitchTo)
    }

    // Every outcome must render a log line mentioning the decisive fact.
    func testLogDescriptionsAreNonEmpty() {
        let stay = ServerSwitchDecision.decide(current: endpoint("a.example"), ranked: [])
        let go = ServerSwitchDecision.decide(current: endpoint("a.example"), ranked: [measured("b.example", score: 0.1)])
        XCTAssertFalse(stay.logDescription.isEmpty)
        XCTAssertFalse(go.logDescription.isEmpty)
    }
}
