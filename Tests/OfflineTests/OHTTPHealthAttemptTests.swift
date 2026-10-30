import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthAttemptTests: XCTestCase {
    private func session() throws -> OHTTPHealthSession {
        try OHTTPHealthSession(route: OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false), generation: UUID())
    }

    private func completion(_ stream: AsyncStream<OHTTPHealthUpdate>) async -> [OHTTPHealthObservation] {
        for await update in stream {
            if case .operationCompleted(_, _, let observations) = update { return observations }
        }
        XCTFail("Missing completion")
        return []
    }

    func testLocalFailureDoesNotAttributeEarlierOptionalNetworkFailure() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(operation) {
            OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testOnlyFinalExplicitAttemptSuppliesReminderEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let earlier = OHTTPHealthAttempt(operation: operation)
        let final = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(earlier) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.withAttempt(final) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: final)
        let observations = await completion(stream)
        XCTAssertEqual(observations.map(\.outcome), [.policyRejected])
    }

    func testOverlappingAttemptsCannotReplaceSelectedAttemptsEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let first = OHTTPHealthAttempt(operation: operation)
        let second = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await OHTTPHealthContext.withAttempt(first) {
                        OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                    }
                }
                group.addTask {
                    await OHTTPHealthContext.withAttempt(second) {
                        OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
                    }
                }
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: first)
        let observations = await completion(stream)
        XCTAssertEqual(observations.map(\.outcome), [.transportUnavailable])
    }
    func testReusedAttemptCannotAttributeAnEarlierFailure() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
    }

    func testForeignAttemptCannotSupplyCurrentOperationsEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let foreign = OHTTPHealthAttempt(operation: OHTTPHealthOperation())
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(foreign) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: foreign)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
    }

}
