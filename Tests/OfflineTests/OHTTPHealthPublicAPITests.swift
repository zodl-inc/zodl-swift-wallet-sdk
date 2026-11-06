import XCTest
import ZODLSwiftWalletSDK

final class OHTTPHealthPublicAPITests: XCTestCase {
    func testConsumerCanProvideDiagnosticResult() {
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "gateway.test", relayURL: "https://relay.test", viaTor: false)
        let generation = UUID()
        let result = OHTTPHealthProbeResult(
            outcome: .usable, route: route, generation: generation,
            startedAtNanoseconds: 10, observedAtNanoseconds: 20
        )
        XCTAssertEqual(result.route, route)
        XCTAssertEqual(result.generation, generation)
        XCTAssertEqual(result.startedAtNanoseconds, 10)
        XCTAssertEqual(result.observedAtNanoseconds, 20)
        XCTAssertEqual(result.outcome, .usable)
    }
    func testConsumerCanCompleteSingleAndAllFailedAttempts() async {
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {}
        }
        await OHTTPHealthContext.complete(operation, failed: false)
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        await OHTTPHealthContext.complete(operation, failed: true, allFailedAttempts: [attempt, nil])
    }
}
