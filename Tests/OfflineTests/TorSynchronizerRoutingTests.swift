import Foundation
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class TorSynchronizerRoutingTests: ZcashTestCase {
    func testSDKSynchronizerUsesPreparedRootAndBoundedGET() async throws {
        try await assertRouting(slipstream: false)
    }

    func testSlipstreamUsesPreparedRootAndBoundedGET() async throws {
        try await assertRouting(slipstream: true)
    }

    private func assertRouting(slipstream: Bool) async throws {
        let runtimes = TorTestRuntimes()
        let fixture = TorResponseFixture()
        let native = TorHTTPGetNative(
            get: { runtime, _, _, _, retries, timeout in
                XCTAssertNotEqual(runtime, runtimes.parent)
                XCTAssertTrue(runtimes.isAlive(runtime))
                XCTAssertEqual(retries, 3)
                XCTAssertGreaterThan(timeout, 0)
                XCTAssertLessThanOrEqual(timeout, 500)
                return fixture.pointer
            },
            freeResponse: { _ in fixture.free() },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) }
        )
        let client = TorClient(runtimePtr: runtimes.parent, torDir: testTempDirectory, httpGetNative: native)
        let initializer = try makeInitializer(client: client)
        let synchronizer: Synchronizer = slipstream ? SlipstreamSynchronizer(initializer: initializer) : SDKSynchronizer(initializer: initializer)
        let result = try await synchronizer.httpGetOverTor(
            for: URLRequest(url: URL(string: "https://example.com")!),
            retryLimit: 3,
            timeoutMilliseconds: 500
        )
        XCTAssertEqual(result.data, Data([3, 1, 4]))
        XCTAssertEqual(result.response.statusCode, 201)
        try await client.close()
    }

    func testSlipstreamActorAdmissionDoesNotRenewExpiredGETBudget() async throws {
        try await assertActorAdmissionBudget(elapsedNanoseconds: 1_000_000_000, expectedNativeBudget: nil)
    }

    func testSlipstreamActorAdmissionReducesRemainingNativeGETBudget() async throws {
        try await assertActorAdmissionBudget(elapsedNanoseconds: 25_000_000, expectedNativeBudget: 75)
    }

    private func assertActorAdmissionBudget(elapsedNanoseconds: UInt64, expectedNativeBudget: UInt64?) async throws {
        let clock = TorTestClock()
        let start: UInt64 = UInt64.max - 10_000_000_000
        clock.advance(to: start)
        let captured = expectation(description: "deadline sampled outside actor")
        let actorEntered = expectation(description: "Slipstream actor occupied")
        let releaseActor = DispatchSemaphore(value: 0)
        let runtimes = TorTestRuntimes()
        let fixture = TorResponseFixture()
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, timeout in
                guard let expectedNativeBudget else {
                    XCTFail("Expired actor waiter entered native GET")
                    return fixture.pointer
                }
                XCTAssertEqual(timeout, expectedNativeBudget)
                return fixture.pointer
            },
            freeResponse: { _ in },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) }
        )
        defer { fixture.free() }
        let client = TorClient(
            runtimePtr: runtimes.parent,
            torDir: testTempDirectory,
            httpGetNative: native,
            httpExecutor: TorHTTPRequestExecutor(now: { clock.now })
        )
        let initializer = try makeInitializer(client: client)
        let synchronizer = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: SlipstreamEngine(dbURL: initializer.dataDbURL, server: initializer.endpoint, alternates: []),
            torHTTPUptime: {
                let now = clock.now
                captured.fulfill()
                return now
            }
        )
        let blocker = Task { await synchronizer.holdActorForTorDeadlineTest(entered: actorEntered, release: releaseActor) }
        await fulfillment(of: [actorEntered], timeout: 3)
        let publicAPI: Synchronizer = synchronizer
        let request = Task {
            try await publicAPI.httpGetOverTor(
                for: URLRequest(url: URL(string: "https://example.com")!),
                retryLimit: 0,
                timeoutMilliseconds: 100
            )
        }
        await fulfillment(of: [captured], timeout: 3)
        // Advance the same monotonic clock while actor admission is blocked.
        // A deadline captured after admission would instead receive another 100 ms.
        clock.advance(to: start + elapsedNanoseconds)
        releaseActor.signal()
        await blocker.value
        do {
            let result = try await request.value
            XCTAssertNotNil(expectedNativeBudget, "Actor admission renewed an expired caller budget")
            XCTAssertEqual(result.data, Data([3, 1, 4]))
        } catch {
            XCTAssertNil(expectedNativeBudget, "A request with remaining time should succeed")
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        try await client.close()
    }

    private func makeInitializer(client: TorClient) throws -> Initializer {
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }
        return Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: true,
            isExchangeRateEnabled: false
        )
    }
}

private extension SlipstreamSynchronizer {
    func holdActorForTorDeadlineTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}
