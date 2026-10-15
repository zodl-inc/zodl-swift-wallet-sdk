import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class TorSynchronizerRoutingTests: ZcashTestCase {
    func testSDKSynchronizerUsesPreparedRootAndBoundedGET() async throws {
        try await assertRouting(slipstream: false)
    }

    func testSlipstreamUsesPreparedRootAndBoundedGET() async throws {
        try await assertRouting(slipstream: true)
    }

    func testSlipstreamDisablingAlreadyDisabledTorPreservesExchangeRateRoot() async throws {
        try await assertSlipstreamDisableOrder(first: .tor, enableFirstConsumer: false)
    }

    func testSlipstreamDisablingTorPreservesExchangeRateRoot() async throws {
        try await assertSlipstreamDisableOrder(first: .tor)
    }

    func testSlipstreamDisablingExchangeRatePreservesTorRoot() async throws {
        try await assertSlipstreamDisableOrder(first: .exchangeRate)
    }

    private func assertSlipstreamDisableOrder(first: SlipstreamTorConsumer, enableFirstConsumer: Bool = true) async throws {
        let fixture = SlipstreamTorLifecycleFixture()
        let client = TorClient(torDir: testTempDirectory.appendingPathComponent("tor-lifecycle"), httpGetNative: fixture.native)
        let initializer = try makeInitializer(client: client, torEnabled: false, exchangeRateEnabled: false)
        let synchronizer = SlipstreamSynchronizer(initializer: initializer)
        let remaining: SlipstreamTorConsumer = first == .tor ? .exchangeRate : .tor
        try await remaining.update(synchronizer, enabled: true)
        if enableFirstConsumer {
            try await first.update(synchronizer, enabled: true)
        }
        XCTAssertEqual(fixture.creationCount, 1)

        for _ in 0..<2 {
            // Repeating false must preserve the runtime owned by the remaining consumer.
            try await first.update(synchronizer, enabled: false)
            XCTAssertEqual(fixture.rootFreeCount, 0)
            XCTAssertTrue(fixture.runtimes.isAlive(fixture.runtimes.parent))
            do {
                let result = try await synchronizer.httpGetOverTor(
                    for: URLRequest(url: URL(string: "https://example.com")!),
                    retryLimit: 0,
                    timeoutMilliseconds: 500
                )
                XCTAssertEqual(result.data, Data([3, 1, 4]))
                XCTAssertEqual(result.response.statusCode, 201)
            } catch {
                XCTFail("Disabling one consumer broke the remaining consumer's bounded GET: \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(fixture.creationCount, 1, "Bounded GET must reuse the prepared root")
        XCTAssertEqual(fixture.requestCount, 2)

        try await remaining.update(synchronizer, enabled: false)
        XCTAssertEqual(fixture.rootFreeCount, 1)
        XCTAssertFalse(fixture.runtimes.isAlive(fixture.runtimes.parent))
        try await remaining.update(synchronizer, enabled: false)
        try await first.update(synchronizer, enabled: false)
        try await client.close()
        XCTAssertEqual(fixture.rootFreeCount, 1, "Repeated disable and close must not free the root again")
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
        let capture = TorDeadlineCapture()
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
                capture.once { captured.fulfill() }
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

    private func makeInitializer(client: TorClient, torEnabled: Bool = true, exchangeRateEnabled: Bool = false) throws -> Initializer {
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
            isTorEnabled: torEnabled,
            isExchangeRateEnabled: exchangeRateEnabled
        )
    }
}

private enum SlipstreamTorConsumer {
    case tor
    case exchangeRate

    func update(_ synchronizer: SlipstreamSynchronizer, enabled: Bool) async throws {
        switch self {
        case .tor: try await synchronizer.tor(enabled: enabled)
        case .exchangeRate: try await synchronizer.exchangeRateOverTor(enabled: enabled)
        }
    }
}

private final class SlipstreamTorLifecycleFixture: @unchecked Sendable {
    let runtimes = TorTestRuntimes()
    private let response = TorResponseFixture()
    private let lock = NSLock()
    private var creations = 0
    private var rootFrees = 0
    private var requests = 0

    var creationCount: Int { lock.withLock { creations } }
    var rootFreeCount: Int { lock.withLock { rootFrees } }
    var requestCount: Int { lock.withLock { requests } }

    var native: TorHTTPGetNative {
        TorHTTPGetNative(
            get: { [self] pointer, _, _, _, _, _ in
                XCTAssertNotEqual(pointer, runtimes.parent)
                XCTAssertTrue(runtimes.isAlive(pointer))
                lock.withLock { requests += 1 }
                return response.pointer
            },
            // The fixture retains one immutable response across these sequential requests.
            freeResponse: { _ in },
            isolateRuntime: { [self] in runtimes.clone($0) },
            freeRuntime: { [self] pointer in
                if pointer == runtimes.parent {
                    lock.withLock { rootFrees += 1 }
                }
                runtimes.free(pointer)
            },
            createRuntime: { [self] _, _ in
                lock.withLock { creations += 1 }
                return runtimes.parent
            }
        )
    }

    deinit {
        response.free()
        if runtimes.isAlive(runtimes.parent) { runtimes.free(runtimes.parent) }
    }
}

private extension SlipstreamSynchronizer {
    func holdActorForTorDeadlineTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}

private final class TorDeadlineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = false

    func once(_ action: () -> Void) {
        let first = lock.withLock {
            if captured { return false }
            captured = true
            return true
        }
        if first { action() }
    }
}
