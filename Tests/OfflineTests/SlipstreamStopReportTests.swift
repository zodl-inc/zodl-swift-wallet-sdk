//
//  SlipstreamStopReportTests.swift
//  OfflineTests
//

import libzcashlc
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// [MOB-2184] What a stop of the Slipstream engine reports, from the C struct the FFI returns by
/// value to the `SlipstreamStopReport` the synchronizer acts on.
final class SlipstreamStopReportTests: ZcashTestCase {
    /// Each verdict arrives as 1 or 0 and each wait as whole milliseconds; a wait the engine could
    /// not count in a `UInt64` of milliseconds arrives saturated, and must not trap on the way in.
    func testTheCReportBecomesTheSwiftReportFieldByField() {
        let report = SlipstreamStopReport(FfiSlipstreamStopReport(settled: 1, drained: 0, settle_ms: 1_500, drain_ms: UInt64.max))

        XCTAssertTrue(report.settled)
        XCTAssertFalse(report.drained)
        XCTAssertEqual(report.settleWait, .milliseconds(1_500))
        XCTAssertEqual(report.drainWait, .milliseconds(UInt64.max))
    }

    /// One wait that ran out is enough to leave the wallet file unproved.
    func testAReportIsQuiescentOnlyWhenBothWaitsFinished() {
        for (settled, drained) in [(false, false), (false, true), (true, false), (true, true)] {
            let report = SlipstreamStopReport(settled: settled, drained: drained, settleWait: .zero, drainWait: .zero)
            XCTAssertEqual(report.isQuiescent, settled && drained, "\(report)")
        }
    }

    /// With no handle there is no engine to be writing, so the stop is quiescent by definition and
    /// has nothing to wait for.
    func testAStopWithoutAnOpenHandleIsQuiescent() async {
        let engine = SlipstreamEngine(dbURL: testTempDirectory.appendingPathComponent("data.db"), server: LightWalletEndpointBuilder.default)

        let report = await engine.stop()

        XCTAssertEqual(report, .quiescent)
    }

    /// The real FFI, end to end: an open handle with no pass running has nothing to settle and
    /// nothing to drain. A Swift call site that disagreed with the generated header about the
    /// struct's layout would compile cleanly and read garbage here instead.
    func testTheEngineReportsAQuiescentStopForAnIdleHandle() async throws {
        let dbURL = testTempDirectory.appendingPathComponent("data.db")
        let backend = ZcashRustBackend.makeForTests(dbData: dbURL, fsBlockDbRoot: testTempDirectory, networkType: .testnet)
        _ = try await backend.initDataDb(seed: nil)
        let engine = SlipstreamEngine(dbURL: dbURL, server: LightWalletEndpointBuilder.default)
        try await engine.open(network: ZcashNetworkBuilder.network(for: .testnet))

        let report = await engine.stop()
        await engine.close()

        XCTAssertTrue(report.isQuiescent, "\(report)")
        XCTAssertLessThan(report.settleWait, .seconds(1), "\(report)")
        XCTAssertLessThan(report.drainWait, .seconds(1), "\(report)")
    }

    /// [MOB-2184] The reason names the wait that ran out and how long it took, in each of the three
    /// shapes a refusal can take, and names nothing when nothing was refused.
    func testTheRefusalReasonNamesTheWaitThatRanOutAndHowLong() {
        let bothRanOut = SlipstreamStopReport(
            settled: false,
            drained: false,
            settleWait: .milliseconds(10_004),
            drainWait: .milliseconds(12_345)
        )

        XCTAssertEqual(SlipstreamStopReport.passStillRunning.refusalReason, "a sync pass was still running after 10.0 s")
        XCTAssertEqual(SlipstreamStopReport.writeStillRunning.refusalReason, "a wallet write was still running after 10.0 s")
        XCTAssertEqual(
            bothRanOut.refusalReason,
            "a sync pass was still running after 10.0 s, and a wallet write after a further 12.3 s"
        )
        XCTAssertNil(SlipstreamStopReport.quiescent.refusalReason, "a quiescent stop refuses nothing")
    }

    /// A stop that could not run at all — the FFI answers it with both verdicts false and no wait —
    /// must not read as a timeout of zero seconds.
    func testAStopThatCouldNotRunSaysSoRatherThanNamingAWait() {
        let report = SlipstreamStopReport(FfiSlipstreamStopReport(settled: 0, drained: 0, settle_ms: 0, drain_ms: 0))

        XCTAssertFalse(report.isQuiescent)
        XCTAssertEqual(report.refusalReason, "the engine's stop failed before it could wait")
    }

    /// The app shows a refusal through `localizedDescription`, so that is where the reason has to
    /// arrive: after the code and the case's fixed message, as the error's detail.
    func testARefusalSaysInItsDescriptionWhichWaitRanOut() {
        let error = ZcashError.slipstreamEngineNotQuiescent(.passStillRunning)

        XCTAssertEqual(error.code, .slipstreamEngineNotQuiescent)
        XCTAssertEqual(error.detail, "a sync pass was still running after 10.0 s")
        XCTAssertEqual(
            error.localizedDescription,
            "ZRUST0155: \(error.message) (a sync pass was still running after 10.0 s)"
        )
    }
}
