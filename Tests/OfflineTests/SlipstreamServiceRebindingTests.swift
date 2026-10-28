import XCTest
import os
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SlipstreamServiceRebindingTests: ZcashTestCase {
    private let publicEndpoint = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
    private let gatewayEndpoint = LightWalletEndpoint(address: "ohttp-gateway-testnet.example", port: 443, secure: true)

    // A successful engine switch must move Swift RPCs too. The old service answers with its route,
    // so this fails on an actual stale RPC rather than on missing factory or wrapper symbols.
    func testSwitchMovesTreeStateOffTheOldService() async throws {
        let fixture = try makeFixture()
        try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
        do {
            _ = try await fixture.synchronizer.getTreeState(height: 10)
            XCTFail("expected the recording transport's route")
        } catch let route as Route {
            XCTAssertEqual(route.host, gatewayEndpoint.host)
        }
    }

    func testRetainedConsumersUseGatewayThenPublicAfterSuccessfulSwitches() async throws {
        let fixture = try makeFixture()
        let service = fixture.initializer.container.resolve(LightWalletService.self)
        let downloader = fixture.initializer.blockDownloaderService
        let encoder = fixture.initializer.container.resolve(TransactionEncoder.self)
        let broadcaster = fixture.synchronizer.broadcaster
        let txId = Data(repeating: 1, count: 32)
        let initiallyKnown = await encoder.isTransactionKnownToServer(txId: txId)
        XCTAssertFalse(initiallyKnown)

        try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
        let gatewayTransaction = try await downloader.fetchTransaction(txId: txId, mode: .direct)
        XCTAssertEqual(gatewayTransaction.status, .notInMainChain)
        let knownAtGateway = await encoder.isTransactionKnownToServer(txId: txId)
        XCTAssertTrue(knownAtGateway)
        try await assertTreeRoute(service, host: gatewayEndpoint.host)
        XCTAssertTrue((broadcaster as AnyObject) === (fixture.synchronizer.broadcaster as AnyObject))
        XCTAssertEqual(fixture.initializer.endpoint, gatewayEndpoint)

        try await fixture.synchronizer.switchTo(endpoint: publicEndpoint)
        let publicTransaction = try await downloader.fetchTransaction(txId: txId, mode: .direct)
        XCTAssertEqual(publicTransaction.status, .txidNotRecognized)
        let knownAtPublic = await encoder.isTransactionKnownToServer(txId: txId)
        XCTAssertFalse(knownAtPublic)
        try await assertTreeRoute(service, host: publicEndpoint.host)
        XCTAssertEqual(fixture.initializer.endpoint, publicEndpoint)
    }

    func testTransactionEnhancementMovesRoutesAndPreservesTorMode() async throws {
        let fixture = try makeFixture(torEnabled: true)
        let txId = try TxId([UInt8](repeating: 7, count: 32))
        try await fixture.synchronizer.enhanceTransactionBy(txId: txId)
        try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
        try await fixture.synchronizer.enhanceTransactionBy(txId: txId)
        try await fixture.synchronizer.switchTo(endpoint: publicEndpoint)
        try await fixture.synchronizer.enhanceTransactionBy(txId: txId)
        let routes = fixture.fetches.withLockUnchecked { $0 }
        XCTAssertEqual(routes.map(\.host), [publicEndpoint.host, gatewayEndpoint.host, publicEndpoint.host])
        XCTAssertTrue(routes.allSatisfy { $0.mode == .txIdGroup(prefix: "fetch", txId: txId.id.data) })
    }

    func testExplicitRestartRebindsBeforeStartingTheNewPass() async throws {
        let fixture = try makeFixture()
        await fixture.synchronizer.setInternalSyncStatusForTesting(.stopped)
        try await fixture.synchronizer.restartSync(at: gatewayEndpoint)
        try await assertTreeRoute(fixture.initializer.lightWalletService, host: gatewayEndpoint.host)
        XCTAssertEqual(fixture.initializer.endpoint, gatewayEndpoint)
        await fixture.synchronizer.stopAndWait()
    }

    func testRefusedStopDoesNotBuildOrPublishAReplacement() async throws {
        let fixture = try makeFixture()
        fixture.engine.stopQuiescent = false
        do {
            try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
            XCTFail("expected a refused stop")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code, .slipstreamEngineNotQuiescent)
        }
        try await assertTreeRoute(fixture.initializer.lightWalletService, host: publicEndpoint.host)
        XCTAssertEqual(fixture.factoryCalls.withLockUnchecked { $0.count }, 0)
        XCTAssertEqual(fixture.initializer.endpoint, publicEndpoint)
    }

    func testFailedReopenDoesNotBuildOrPublishAReplacement() async throws {
        let fixture = try makeFixture()
        await fixture.engine.setReopenError(Route(host: "reopen failed"))
        do {
            try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
            XCTFail("expected a failed reopen")
        } catch let route as Route {
            XCTAssertEqual(route.host, "reopen failed")
        }
        try await assertTreeRoute(fixture.initializer.lightWalletService, host: publicEndpoint.host)
        XCTAssertEqual(fixture.factoryCalls.withLockUnchecked { $0.count }, 0)
        XCTAssertEqual(fixture.initializer.endpoint, publicEndpoint)
    }

    func testSameEndpointDoesNotReplaceTheService() async throws {
        let fixture = try makeFixture()
        try await fixture.synchronizer.switchTo(endpoint: publicEndpoint)
        try await assertTreeRoute(fixture.initializer.lightWalletService, host: publicEndpoint.host)
        XCTAssertEqual(fixture.factoryCalls.withLockUnchecked { $0.count }, 0)
        let engineCalls = await fixture.engine.calls
        XCTAssertTrue(engineCalls.isEmpty)
    }

    func testReplacementReceivesTheExistingTorFlagsAndNetwork() async throws {
        let fixture = try makeFixture(torEnabled: true)
        try await fixture.synchronizer.switchTo(endpoint: gatewayEndpoint)
        let context = try XCTUnwrap(fixture.factoryCalls.withLockUnchecked { $0.first })
        XCTAssertTrue(context.tor === fixture.initializer.container.resolve(TorClient.self))
        XCTAssertTrue(context.flags === fixture.initializer.container.resolve(SDKFlags.self))
        XCTAssertEqual(context.network, .testnet)
        do {
            _ = try await fixture.synchronizer.getTreeState(height: 10)
            XCTFail("expected the recording route")
        } catch let route as Route {
            XCTAssertEqual(route.host, gatewayEndpoint.host)
            XCTAssertEqual(route.mode, .uniqueTor)
        }
    }

    func testConcreteFactoryPreservesTransportAndTorContext() async throws {
        let tor = TorClient(torDir: testTempDirectory)
        let flags = SDKFlags(torEnabled: true, exchangeRateEnabled: false)
        let gateway = try XCTUnwrap(Dependencies.makeLightWalletService(
            endpoint: gatewayEndpoint, torClient: tor, sdkFlags: flags, networkType: .testnet
        ) as? LightWalletOHTTPService)
        XCTAssertTrue(gateway.tor === tor)
        XCTAssertTrue(gateway.sdkFlags === flags)
        XCTAssertEqual(gateway.walletNetwork, .testnet)
        let direct = try XCTUnwrap(Dependencies.makeLightWalletService(
            endpoint: publicEndpoint, torClient: tor, sdkFlags: flags, networkType: .testnet
        ) as? LightWalletGRPCServiceOverTor)
        XCTAssertFalse(direct is LightWalletOHTTPService)
        XCTAssertTrue(direct.tor === tor)
        XCTAssertTrue(direct.sdkFlags === flags)
        let torMode = await direct.resolvedMode(.direct)
        XCTAssertEqual(torMode, .defaultTor)
        await gateway.closeConnections()
        await direct.closeConnections()
    }

    func testRetiredTeardownCannotCloseTheReplacement() async throws {
        let old = LightWalletServiceMock()
        let replacement = LightWalletServiceMock()
        replacement.closeConnectionsClosure = {}
        let last = LightWalletServiceMock()
        let entered = expectation(description: "retired close entered")
        let finished = expectation(description: "retired close finished")
        let gate = Gate()
        defer { gate.open() }
        let closes = OSAllocatedUnfairLock(initialState: 0)
        old.closeConnectionsClosure = {
            entered.fulfill()
            await gate.wait()
            finished.fulfill()
        }
        last.closeConnectionsClosure = { closes.withLock { $0 += 1 } }
        last.latestBlockHeightModeReturnValue = 321
        let binding = RebindingLightWalletService(service: old)
        binding.replace(with: replacement)
        await fulfillment(of: [entered], timeout: 5)
        binding.replace(with: last)
        gate.open()
        await fulfillment(of: [finished], timeout: 5)
        let height = try await binding.latestBlockHeight(mode: .direct)
        XCTAssertEqual(height, 321)
        XCTAssertEqual(closes.withLock { $0 }, 0)
    }

    func testInFlightRPCUsesItsSnapshotWhileNewRPCUsesReplacement() async throws {
        let entered = expectation(description: "old RPC is in flight")
        let gate = Gate()
        defer { gate.open() }
        let old = LightWalletServiceMock()
        old.closeConnectionsClosure = {}
        old.latestBlockHeightModeClosure = { _ in
            entered.fulfill()
            await gate.wait()
            return 111
        }
        let next = LightWalletServiceMock()
        next.latestBlockHeightModeReturnValue = 222
        let binding = RebindingLightWalletService(service: old)
        let oldRequest = Task { try await binding.latestBlockHeight(mode: .direct) }
        await fulfillment(of: [entered], timeout: 5)
        binding.replace(with: next)
        let nextHeight = try await binding.latestBlockHeight(mode: .direct)
        XCTAssertEqual(nextHeight, 222)
        gate.open()
        let oldHeight = try await oldRequest.value
        XCTAssertEqual(oldHeight, 111)
    }

    private func assertTreeRoute(_ service: LightWalletService, host: String) async throws {
        do {
            _ = try await service.getTreeState(BlockID(height: 10), mode: .direct)
            XCTFail("expected the recording transport's route")
        } catch let route as Route {
            XCTAssertEqual(route.host, host)
        }
    }

    private struct Route: Error {
        let host: String
        var mode: ServiceMode = .direct
    }

    private struct FactoryContext {
        let tor: TorClient
        let flags: SDKFlags
        let network: NetworkType
    }

    private struct Fixture {
        let synchronizer: SlipstreamSynchronizer
        let initializer: Initializer
        let engine: GatedFakeSlipstreamEngine
        let factoryCalls: OSAllocatedUnfairLock<[FactoryContext]>
        let fetches: OSAllocatedUnfairLock<[Route]>
    }

    private func makeFixture(torEnabled: Bool = false) throws -> Fixture {
        let backend = ZcashRustBackendWeldingMock()
        backend.listAccountsReturnValue = []
        backend.setTransactionStatusTxIdStatusClosure = { _, _ in }
        backend.migrationBlockRateSamplesWindowReturnValue = []
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: publicEndpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: torEnabled,
            isExchangeRateEnabled: false
        )
        let binding = try XCTUnwrap(initializer.lightWalletService as? RebindingLightWalletService)
        let fetches = OSAllocatedUnfairLock(uncheckedState: [Route]())
        binding.replace(with: Self.recordingService(for: publicEndpoint, fetches: fetches))
        // Force the singleton encoder to retain the production binding before Slipstream is built.
        _ = initializer.container.resolve(TransactionEncoder.self)
        let engine = GatedFakeSlipstreamEngine()
        let factoryCalls = OSAllocatedUnfairLock(uncheckedState: [FactoryContext]())
        let synchronizer = SlipstreamSynchronizer(
            initializer: initializer, alternateEndpoints: [], engine: engine,
            makeEndpointService: { endpoint, tor, flags, network in
                factoryCalls.withLockUnchecked { $0.append(FactoryContext(tor: tor, flags: flags, network: network)) }
                return Self.recordingService(for: endpoint, fetches: fetches)
            }
        )
        return Fixture(synchronizer: synchronizer, initializer: initializer, engine: engine, factoryCalls: factoryCalls, fetches: fetches)
    }

    private static func recordingService(for endpoint: LightWalletEndpoint, fetches: OSAllocatedUnfairLock<[Route]>) -> LightWalletService {
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.getTreeStateModeClosure = { _, mode in throw Route(host: endpoint.host, mode: mode) }
        service.fetchTransactionTxIdModeClosure = { _, mode in
            fetches.withLockUnchecked { $0.append(Route(host: endpoint.host, mode: mode)) }
            return (nil, endpoint.host == "public.example.com" ? .txidNotRecognized : .notInMainChain)
        }
        return service
    }
}
