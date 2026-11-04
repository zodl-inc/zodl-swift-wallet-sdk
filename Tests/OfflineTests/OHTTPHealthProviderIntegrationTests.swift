import XCTest
import os
import libzcashlc
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthProviderIntegrationTests: ZcashTestCase {
    private let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)

    private func route(viaTor: Bool) throws -> OHTTPHealthRoute {
        OHTTPHealthRoute(
            network: .testnet,
            gatewayHost: endpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: endpoint.host),
            viaTor: viaTor
        )
    }

    private func provider(slipstream: Bool, tor: TorClient) throws -> any OHTTPHealthProviding {
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: TorClient.self, isSingleton: true) { _ in tor }
        if slipstream {
            let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine(), container: container, endpoint: endpoint)
            return sync
        }
        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: endpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        return SDKSynchronizer(initializer: initializer)
    }

    func testBothProvidersValidateFactoriesAndSelectedTorBeforeDispatch() async throws {
        let relay = try XCTUnwrap(OHTTPNative.relayURL(for: OHTTPTestSupport.testnetHost))
        let signedConfigURL = try OHTTPNative.signedConfigURL(relayURL: relay)
        for slipstream in [false, true] {
            let calls = OSAllocatedUnfairLock(initialState: [String]())
            let runtimes = TorTestRuntimes()
            var native = TorHTTPGetNative()
            native.startup = TorRuntimeStartupNative.fixture { _, _ in
                calls.withLock { $0.append("create") }
                return nil
            }
            native.isolateRuntime = {
                calls.withLock { $0.append("isolate") }
                return runtimes.clone($0)
            }
            native.freeRuntime = { runtimes.free($0) }
            native.classifiedGet = { pointer, url, _, _, retries, _, timeout, outcome in
                calls.withLock { $0.append("get") }
                XCTAssertTrue(runtimes.isAlive(pointer))
                XCTAssertNotEqual(pointer, runtimes.parent)
                XCTAssertEqual(String(cString: url!), signedConfigURL)
                XCTAssertEqual(retries, 0)
                XCTAssertGreaterThan(timeout, 0)
                XCTAssertLessThanOrEqual(timeout, 20_000)
                outcome?.pointee = FfiTorHttpOutcome(kind: 1, http_status: 429, retry_not_before_ns: 1)
                return nil
            }
            native.postOnce = { _, _, _, _, _, _, _, _, _ in
                calls.withLock { $0.append("post") }
                XCTFail("Known key-fetch pause must stop before POST")
                return nil
            }
            let tor = TorClient(runtimePtr: runtimes.parent, torDir: testTempDirectory, httpGetNative: native)
            let provider = try provider(slipstream: slipstream, tor: tor)
            let direct = try route(viaTor: false)
            for mismatch in [
                OHTTPHealthRoute(network: .mainnet, gatewayHost: direct.gatewayHost, relayURL: direct.relayURL, viaTor: false),
                OHTTPHealthRoute(network: .testnet, gatewayHost: "ordinary.invalid", relayURL: direct.relayURL, viaTor: false),
                OHTTPHealthRoute(network: .testnet, gatewayHost: direct.gatewayHost, relayURL: "https://foreign.invalid/", viaTor: false),
                try route(viaTor: true)
            ] {
                do {
                    let invalid = try await provider.makeOHTTPHealthSession(route: mismatch, generation: UUID())
                    invalid.close()
                    XCTFail("Factory must reject a mismatched selected route")
                } catch { XCTAssertTrue(error is OHTTPError) }
            }
            let session = try await provider.makeOHTTPHealthSession(route: direct, generation: UUID())
            let unbound = try OHTTPHealthSession(route: direct, generation: UUID())
            let foreignProvider = try self.provider(slipstream: !slipstream, tor: tor)
            let foreign = try await foreignProvider.makeOHTTPHealthSession(route: direct, generation: UUID())
            for invalid in [unbound, foreign] {
                let result = await provider.probeOHTTPHealth(session: invalid)
                XCTAssertEqual(result.outcome, .cancelled)
                invalid.close()
            }
            if let sync = provider as? SDKSynchronizer {
                await sync.sdkFlags.torFlagUpdate(true)
            } else if let sync = provider as? SlipstreamSynchronizer {
                try await sync.tor(enabled: true)
            }
            XCTAssertEqual(session.isValid, !slipstream, "A Slipstream route transition retires the prior diagnostic binding")
            let mismatch = await provider.probeOHTTPHealth(session: session)
            XCTAssertEqual(mismatch.outcome, slipstream ? .cancelled : .configurationFailure)
            XCTAssertTrue(calls.withLock { $0.isEmpty })
            let torSession = try await provider.makeOHTTPHealthSession(route: route(viaTor: true), generation: UUID())
            let result = await provider.probeOHTTPHealth(session: torSession)
            XCTAssertEqual(result.outcome, .rateLimited(retryNotBefore: 1))
            XCTAssertEqual(result.route, torSession.route)
            XCTAssertEqual(result.generation, torSession.generation)
            XCTAssertEqual(calls.withLock { $0 }, ["isolate", "get"])
            session.close()
            torSession.close()
            let retired = await provider.probeOHTTPHealth(session: torSession)
            XCTAssertEqual(retired.outcome, .cancelled)
            XCTAssertEqual(calls.withLock { $0 }, ["isolate", "get"])
            try await tor.close()
        }
    }

    func testBothProviderTorDeadlinesIncludeBusyActorAndPreventLateDispatch() async throws {
        for slipstream in [false, true] {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let runtimes = TorTestRuntimes()
            var native = TorHTTPGetNative()
            native.isolateRuntime = {
                calls.withLock { $0 += 1 }
                return runtimes.clone($0)
            }
            native.freeRuntime = { runtimes.free($0) }
            native.startup = TorRuntimeStartupNative.fixture { _, _ in
                calls.withLock { $0 += 1 }
                XCTFail("Deadline must precede runtime creation")
                return nil
            }
            native.classifiedGet = { _, _, _, _, _, _, _, _ in
                calls.withLock { $0 += 1 }
                XCTFail("Deadline must precede GET")
                return nil
            }
            native.postOnce = { _, _, _, _, _, _, _, _, _ in
                calls.withLock { $0 += 1 }
                XCTFail("Deadline must precede POST")
                return nil
            }
            let tor = TorClient(runtimePtr: runtimes.parent, torDir: testTempDirectory, httpGetNative: native)
            let provider = try provider(slipstream: slipstream, tor: tor)
            if let sync = provider as? SDKSynchronizer {
                await sync.sdkFlags.torFlagUpdate(true)
            } else if let sync = provider as? SlipstreamSynchronizer {
                try await sync.tor(enabled: true)
            }
            let session = try await provider.makeOHTTPHealthSession(route: route(viaTor: true), generation: UUID())
            let entered = expectation(description: "selected Tor actor held")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let blocker = Task { await tor.holdForProviderTest(entered: entered, release: release) }
            await fulfillment(of: [entered], timeout: 2)
            let before = OHTTPHealthClock.nowNanoseconds
            let result = await provider.probeOHTTPHealth(session: session)
            let elapsed = OHTTPHealthClock.nowNanoseconds - before
            XCTAssertEqual(result.outcome, .transportUnavailable)
            XCTAssertGreaterThanOrEqual(elapsed, 19_000_000_000)
            XCTAssertLessThan(elapsed, 25_000_000_000)
            XCTAssertEqual(result.route, session.route)
            XCTAssertEqual(result.generation, session.generation)
            XCTAssertGreaterThanOrEqual(result.startedAtNanoseconds, before)
            XCTAssertEqual(calls.withLock { $0 }, 0)
            release.signal()
            await blocker.value
            try await tor.close()
            XCTAssertEqual(calls.withLock { $0 }, 0, "Expired admission must stay closed after releasing the actor")
            session.close()
        }
    }
}

private extension TorClient {
    func holdForProviderTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 30), .success)
    }
}
