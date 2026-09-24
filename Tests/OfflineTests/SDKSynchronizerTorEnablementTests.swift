import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SDKSynchronizerTorEnablementTests: ZcashTestCase {
    func testTorEnablePreparesColdRootWhenExchangeRateIsAlreadyEnabled() async throws {
        try await assertColdRootEnablement(.tor)
    }

    func testExchangeRateEnablePreparesColdRootWhenTorIsAlreadyEnabled() async throws {
        try await assertColdRootEnablement(.exchangeRate)
    }

    func testTorEnablePropagatesPreparationFailureWithExchangeRateEnabled() async throws {
        try await assertPreparationFailure(.tor)
    }

    func testExchangeRateEnablePropagatesPreparationFailureWithTorEnabled() async throws {
        try await assertPreparationFailure(.exchangeRate)
    }

    func testRepeatedEnablementReusesAnAlreadyPreparedRuntime() async throws {
        let fixture = TorEnablementFixture()
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: fixture.native)
        let synchronizer = try makeSynchronizer(client: client, torEnabled: false, exchangeRateEnabled: false)
        try await synchronizer.tor(enabled: true)
        try await synchronizer.exchangeRateOverTor(enabled: true)
        try await synchronizer.tor(enabled: true)
        try await synchronizer.exchangeRateOverTor(enabled: true)
        await assertBoundedGETSucceeds(synchronizer)
        XCTAssertEqual(fixture.creationCount, 0)
        try await client.close()
    }

    func testDisablingTorKeepsPreparedRootWhileExchangeRateIsEnabled() async throws {
        try await assertDisablingPreservesOtherConsumer(.tor)
    }

    func testDisablingExchangeRateKeepsPreparedRootWhileTorIsEnabled() async throws {
        try await assertDisablingPreservesOtherConsumer(.exchangeRate)
    }

    private func assertColdRootEnablement(_ consumer: TorConsumer) async throws {
        let fixture = TorEnablementFixture()
        let client = TorClient(torDir: testTempDirectory.appendingPathComponent("tor-enablement"), httpGetNative: fixture.native)
        let synchronizer = try makeSynchronizer(client: client, torEnabled: true, exchangeRateEnabled: true)
        try await consumer.update(synchronizer, enabled: true)
        // Constructor flags alone never prepare the runtime. A successful explicit enable
        // must make the real bounded route usable despite the sibling's initial true flag.
        await assertBoundedGETSucceeds(synchronizer)
        XCTAssertEqual(fixture.creationCount, 1)
        try await client.close()
    }

    private func assertPreparationFailure(_ consumer: TorConsumer) async throws {
        let fixture = TorEnablementFixture(failCreation: true)
        let client = TorClient(torDir: testTempDirectory.appendingPathComponent("tor-enablement-failure"), httpGetNative: fixture.native)
        let synchronizer = try makeSynchronizer(
            client: client,
            torEnabled: consumer == .exchangeRate,
            exchangeRateEnabled: consumer == .tor
        )
        do {
            try await consumer.update(synchronizer, enabled: true)
            XCTFail("Enabling must propagate preparation failure even when the sibling is enabled")
        } catch {
            guard case ZcashError.rustTorClientInit = error else {
                return XCTFail("Expected the native runtime preparation error")
            }
        }
        XCTAssertEqual(fixture.creationCount, 1)
        let torEnabled = await synchronizer.sdkFlags.torEnabled
        let exchangeRateEnabled = await synchronizer.sdkFlags.exchangeRateEnabled
        XCTAssertEqual(torEnabled, consumer == .exchangeRate)
        XCTAssertEqual(exchangeRateEnabled, consumer == .tor)
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 500)
            XCTFail("Failed preparation must leave the bounded route unavailable")
        } catch {
            guard case ZcashError.torClientUnavailable = error else { return XCTFail("Expected unavailable runtime") }
        }
        try await client.close()
    }

    private func assertDisablingPreservesOtherConsumer(_ consumer: TorConsumer) async throws {
        let fixture = TorEnablementFixture()
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: fixture.native)
        let synchronizer = try makeSynchronizer(client: client, torEnabled: true, exchangeRateEnabled: true)
        try await consumer.update(synchronizer, enabled: false)
        XCTAssertTrue(fixture.runtimes.isAlive(fixture.runtimes.parent))
        await assertBoundedGETSucceeds(synchronizer)
        XCTAssertEqual(fixture.creationCount, 0)
        let otherConsumer: TorConsumer = consumer == .tor ? .exchangeRate : .tor
        try await otherConsumer.update(synchronizer, enabled: false)
        XCTAssertFalse(fixture.runtimes.isAlive(fixture.runtimes.parent))
        try await client.close()
    }

    private func assertBoundedGETSucceeds(_ synchronizer: SDKSynchronizer) async {
        do {
            let result = try await synchronizer.httpGetOverTor(
                for: URLRequest(url: URL(string: "https://example.com")!),
                retryLimit: 0,
                timeoutMilliseconds: 500
            )
            XCTAssertEqual(result.data, Data([3, 1, 4]))
            XCTAssertEqual(result.response.statusCode, 201)
        } catch {
            XCTFail("Successful enablement left bounded GET unusable: \(error.localizedDescription)")
        }
    }

    private func makeSynchronizer(client: TorClient, torEnabled: Bool, exchangeRateEnabled: Bool) throws -> SDKSynchronizer {
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
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
            isTorEnabled: torEnabled,
            isExchangeRateEnabled: exchangeRateEnabled
        )
        return SDKSynchronizer(initializer: initializer)
    }
}

private enum TorConsumer {
    case tor
    case exchangeRate

    func update(_ synchronizer: SDKSynchronizer, enabled: Bool) async throws {
        switch self {
        case .tor: try await synchronizer.tor(enabled: enabled)
        case .exchangeRate: try await synchronizer.exchangeRateOverTor(enabled: enabled)
        }
    }
}

private final class TorEnablementFixture: @unchecked Sendable {
    let runtimes = TorTestRuntimes()
    private let lock = NSLock()
    private var creations = 0
    private let failCreation: Bool
    private let response = TorResponseFixture()

    init(failCreation: Bool = false) {
        self.failCreation = failCreation
    }

    var creationCount: Int { lock.withLock { creations } }

    var native: TorHTTPGetNative {
        // Native HTTP is faked while the real TorClient owns preparation and cleanup.
        // The creation closure retains the fixture until the client drops its native seam.
        let runtimes = runtimes
        let response = response
        return TorHTTPGetNative(
            get: { pointer, _, _, _, _, _ in
                XCTAssertNotEqual(pointer, runtimes.parent)
                XCTAssertTrue(runtimes.isAlive(pointer))
                return response.pointer
            },
            freeResponse: { _ in },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) },
            createRuntime: { [self] _, _ in
                lock.withLock { creations += 1 }
                return failCreation ? nil : runtimes.parent
            }
        )
    }

    deinit {
        response.free()
        // Failed construction and behavioral RED leave this synthetic parent unclaimed.
        if runtimes.isAlive(runtimes.parent) { runtimes.free(runtimes.parent) }
    }
}
