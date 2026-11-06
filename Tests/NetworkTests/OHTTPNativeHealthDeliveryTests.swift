import XCTest
import os
import libzcashlc
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class OHTTPNativeHealthDeliveryTests: ZcashTestCase {
    func testNativeDeliveryWhileProductionWalletSummaryIsBlocked() async throws {
        let endpoint = LightWalletEndpoint(address: OHTTPEndpoints.gatewayHost(for: .testnet), port: 443, secure: true)
        let engine = GatedFakeSlipstreamEngine()
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        let route = OHTTPHealthRoute(
            network: .testnet,
            gatewayHost: endpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: endpoint.host),
            viaTor: false
        )
        let session = try await synchronizer.makeOHTTPHealthSession(route: route, generation: UUID())
        let entered = expectation(description: "production walletSummary entered")
        let delivered = expectation(description: "fresh native callback delivered through C and Swift")
        let workerFinished = expectation(description: "read-only native anchor worker drained")
        let release = DispatchSemaphore(value: 0)
        let summaryReturned = OSAllocatedUnfairLock(initialState: false)
        let evidence = OSAllocatedUnfairLock<OHTTPHealthObservation?>(initialState: nil)
        defer {
            release.signal()
            session.close()
            synchronizer.stop()
        }
        await engine.onCall("walletSummary") {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 75), .success, "Bounded summary cleanup")
        }
        let summary = Task {
            defer { summaryReturned.withLock { $0 = true } }
            return try await synchronizer.getAccountsBalances()
        }
        await fulfillment(of: [entered], timeout: 5)
        let triggeredAt = OHTTPHealthClock.nowNanoseconds
        let observer = Task {
            for await update in session.updates() {
                guard case .snapshot(let snapshot) = update,
                      let observation = snapshot.observations.first(where: {
                          $0.source == .native && !$0.historical && $0.route == route &&
                          $0.generation == session.generation && $0.startedAtNanoseconds >= triggeredAt &&
                          $0.observedAtNanoseconds >= $0.startedAtNanoseconds
                      }) else { continue }
                XCTAssertFalse(summaryReturned.withLock { $0 }, "Delivery cannot wait for the real summary owner")
                evidence.withLock { $0 = observation }
                delivered.fulfill()
                break
            }
        }
        DispatchQueue.global().async {
            let host = Array(endpoint.host.utf8)
            let anchor = host.withUnsafeBufferPointer {
                zcashlc_slipstream_restore_anchor($0.baseAddress, UInt($0.count), 443, true, 0, 1, 3_100_000, 3_100_000, nil, 0)
            }
            if let anchor { zcashlc_slipstream_free_restore_anchor(anchor) }
            workerFinished.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 60)
        XCTAssertFalse(summaryReturned.withLock { $0 })
        if let observation = evidence.withLock({ $0 }) {
            XCTAssertTrue(session.snapshot().observations.contains(observation))
            XCTAssertGreaterThan(observation.requestID, 0)
            XCTAssertGreaterThan(observation.version, 0)
        } else {
            XCTFail("No fresh native observation from the authorized read-only request")
        }
        release.signal()
        _ = try await summary.value
        await fulfillment(of: [workerFinished], timeout: 15)
        session.close()
        observer.cancel()
        await observer.value
        await synchronizer.stopAndWait()
    }
}
