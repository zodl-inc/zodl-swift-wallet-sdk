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
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }
        let initializer = Initializer(
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
}
