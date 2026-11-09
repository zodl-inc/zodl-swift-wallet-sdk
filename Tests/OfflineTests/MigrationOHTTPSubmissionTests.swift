import Foundation
import os
import XCTest
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class MigrationOHTTPSubmissionTests: ZcashTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    func testMigrationRejectsBeforePreparationWhenRouteIsRetired() async throws {
        let admission = TorNetworkAdmission(enabled: false)
        let state = State()
        let client = Client(state: state)
        let broadcaster = MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory, logger: logger,
            torClientFactory: { _ in throw Failure.bootstrap }, networkType: .testnet,
            ohttpClientFactory: { _ in client }, admission: admission
        )
        admission.require(false)
        do {
            _ = try await broadcaster.broadcast(
                to: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443),
                useTor: false, onWillSubmit: { state.event("willSubmit") },
                prepareTransaction: { _ in
                    state.event("prepare")
                    return Data([1])
                }
            )
            XCTFail("Retired route must reject migration work")
        } catch {}
        XCTAssertEqual(state.values.withLock { $0.events }, [])
    }

    private let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.mainnetHost, port: 443)

    private final class State: Sendable {
        struct Values: Sendable {
            var events: [String] = []
            var submitted: Data?
            var factories = 0
            var clientIDs: [UUID] = []
        }
        let values = OSAllocatedUnfairLock(initialState: Values())
        func event(_ value: String) { values.withLock { $0.events.append(value) } }
    }

    private enum Failure: Error { case height, preparation, bootstrap }

    private final class Client: MigrationOHTTPClient {
        let state: State
        let height: UInt64
        let failsHeight: Bool
        let id = UUID()
        init(state: State, height: UInt64 = 4_465_026, failsHeight: Bool = false) {
            self.state = state
            self.height = height
            self.failsHeight = failsHeight
        }
        func latestBlock() async throws -> BlockID {
            state.values.withLock { $0.clientIDs.append(id) }
            state.event("height")
            if failsHeight { throw Failure.height }
            var block = BlockID()
            block.height = height
            return block
        }
        func submit(_ transaction: RawTransaction) async throws -> SendResponse {
            state.values.withLock {
                $0.clientIDs.append(id)
                $0.submitted = transaction.data
            }
            state.event("submit")
            return SendResponse()
        }
    }

    private func broadcaster(state: State, client: Client) -> MigrationBroadcaster {
        MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory,
            logger: logger,
            torClientFactory: { _ in throw Failure.bootstrap },
            networkType: .testnet,
            ohttpClientFactory: { _ in
                state.values.withLock { $0.factories += 1 }
                return client
            }
        )
    }

    private struct AttributedClient: MigrationOHTTPClient {
        let route: OHTTPHealthRoute
        let failure: String
        func latestBlock() async throws -> BlockID {
            OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: failure == "height" ? .transportUnavailable : .usable, stage: .complete)
            if failure == "height" { throw Failure.height }
            var block = BlockID()
            block.height = 4_465_026
            return block
        }
        func submit(_ transaction: RawTransaction) async throws -> SendResponse {
            OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: .policyRejected, stage: .responseHead)
            throw Failure.height
        }
    }

    private func realBroadcaster() -> MigrationBroadcaster {
        MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory, logger: logger,
            torClientFactory: { _ in throw Failure.bootstrap }, networkType: .testnet
        )
    }

    func testRealMigrationKeyPreparationUsesIsolatedConfiguration() async throws {
        let calls = State()
        _ = try await realBroadcaster().preparedOHTTPClient(
            for: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443),
            viaTor: false, keyCache: OHTTPKeyCache(), testKeyVerifier: OHTTPTestSupport.makeKeyVerifier()
        ) { request, _ in
            calls.event(request.httpMethod ?? "")
            return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }
        XCTAssertEqual(calls.values.withLock { $0.events }, ["GET"])
    }

    private let preparationEndpoint = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443)

    private func preparationRoute(viaTor: Bool) throws -> OHTTPHealthRoute {
        OHTTPHealthRoute(
            network: .testnet, gatewayHost: preparationEndpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: preparationEndpoint.host), viaTor: viaTor
        )
    }

    private func prepare(
        viaTor: Bool, cache: OHTTPKeyCache, operation: OHTTPHealthOperation, attempt: OHTTPHealthAttempt,
        testRelayURL: String? = nil,
        verifier: OHTTPTransport.KeyVerifier? = nil, sender: @escaping OHTTPTransport.HTTPSender
    ) async -> Error? {
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                do {
                    _ = try await OHTTPHealthFailureOwner().request {
                        try await self.realBroadcaster().preparedOHTTPClient(
                            for: self.preparationEndpoint, viaTor: viaTor,
                            keyCache: cache, testKeyVerifier: verifier, testRelayURL: testRelayURL, httpSender: sender
                        )
                    }
                    return nil
                } catch { return error }
            }
        }
    }

    private func selectedEvidence(
        session: OHTTPHealthSession, operation: OHTTPHealthOperation, attempt: OHTTPHealthAttempt
    ) async -> [OHTTPHealthObservation] {
        guard !attempt.evidence(route: session.route, generation: session.generation).isEmpty else { return [] }
        let updates = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        for await update in updates {
            if case .operationCompleted(let completed, _, let observations) = update, completed == operation {
                return observations
            }
        }
        return []
    }

    func testRealMigrationKeyPreparationFailureIsAttributedForDirectAndTor() async throws {
        for viaTor in [false, true] {
            for expired in [false, true] {
                let route = try preparationRoute(viaTor: viaTor)
                let session = try OHTTPHealthSession(route: route, generation: UUID())
                defer { session.close() }
                let cache = OHTTPKeyCache()
                if expired {
                    await cache.store(
                        OHTTPVerifiedKey(bytes: Data(repeating: 1, count: 33), notAfter: 1, isTestnet: true),
                        for: OHTTPTransport.keyCacheKey(relayURL: route.relayURL, gatewayHost: route.gatewayHost, viaTor: viaTor)
                    )
                }
                let operation = OHTTPHealthOperation()
                let attempt = OHTTPHealthAttempt(operation: operation)
                let calls = State()
                let originalError = URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "key preparation connection failure"])
                let error = await prepare(viaTor: viaTor, cache: cache, operation: operation, attempt: attempt) { request, _ in
                    calls.event(request.url?.host ?? "")
                    throw originalError
                }
                XCTAssertEqual(error as NSError?, originalError as NSError)
                XCTAssertEqual(calls.values.withLock { $0.events }, [URL(string: route.relayURL)!.host!, "cloudflare-dns.com", "dns.google"])
                let observations = session.snapshot().observations.filter { !$0.historical && $0.operation == operation }
                XCTAssertEqual(observations.count, 1)
                if let observation = observations.first {
                    XCTAssertEqual(observation.scope, .route)
                    XCTAssertEqual(observation.stage, .keyConfiguration)
                    XCTAssertEqual(observation.operation, operation)
                    XCTAssertEqual(observation.outcome, .transportUnavailable)
                    XCTAssertEqual(observation.route.viaTor, viaTor)
                    XCTAssertEqual(observation.route.network, .testnet)
                }
                let selected = await selectedEvidence(session: session, operation: operation, attempt: attempt)
                XCTAssertEqual(selected.map(\.outcome), [.transportUnavailable])
            }
        }
    }

    func testRealMigrationKeyPreparationCacheAndRecoveredFallbackDoNotPublishFailureOrRecovery() async throws {
        for viaTor in [false, true] {
            let route = try preparationRoute(viaTor: viaTor)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let cache = OHTTPKeyCache()
            let calls = State()
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            let envelope = OHTTPTestSupport.stubEnvelope.base64EncodedString()
            let dns = Data("{\"Status\":0,\"Answer\":[{\"name\":\"\(OHTTPTestSupport.testnetDNSName)\",\"type\":16,\"TTL\":300,\"data\":\"\\\"\(envelope)\\\"\"}]}".utf8)
            let error = await prepare(
                viaTor: viaTor, cache: cache, operation: operation, attempt: attempt,
                verifier: OHTTPTestSupport.makeKeyVerifier()
            ) { request, _ in
                calls.event(request.url?.host ?? "")
                if request.url?.host != "cloudflare-dns.com" { throw URLError(.cannotConnectToHost) }
                return (dns, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            XCTAssertNil(error)
            XCTAssertEqual(calls.values.withLock { $0.events }, [URL(string: route.relayURL)!.host!, "cloudflare-dns.com"])
            XCTAssertTrue(session.snapshot().observations.filter { !$0.historical && $0.operation == operation }.isEmpty)
            let selected = await selectedEvidence(session: session, operation: operation, attempt: attempt)
            XCTAssertTrue(selected.isEmpty)
            let cachedOperation = OHTTPHealthOperation()
            let cachedAttempt = OHTTPHealthAttempt(operation: cachedOperation)
            let cachedError = await prepare(viaTor: viaTor, cache: cache, operation: cachedOperation, attempt: cachedAttempt) { request, _ in
                calls.event("unexpected cached request")
                throw Failure.preparation
            }
            XCTAssertNil(cachedError)
            XCTAssertEqual(calls.values.withLock { $0.events.count }, 2, "Cache hit sends no request")
            XCTAssertTrue(session.snapshot().observations.filter { !$0.historical && $0.operation == cachedOperation }.isEmpty)
        }
    }

    func testRealMigrationKeyPreparationSharedWaitersKeepOwnAttribution() async throws {
        for viaTor in [false, true] {
            let route = try preparationRoute(viaTor: viaTor)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let enrolled = expectation(description: "both cache waiters enrolled")
            enrolled.expectedFulfillmentCount = 2
            let cache = OHTTPKeyCache(testWaiterEnrolled: { enrolled.fulfill() })
            let calls = State()
            let gate = MigrationKeyGate()
            let started = expectation(description: "shared relay fetch started")
            let operations = [OHTTPHealthOperation(), OHTTPHealthOperation()]
            let attempts = operations.map { OHTTPHealthAttempt(operation: $0) }
            let sender: OHTTPTransport.HTTPSender = { request, _ in
                calls.event(request.url?.host ?? "")
                if request.url?.host == URL(string: route.relayURL)?.host {
                    started.fulfill()
                    await gate.wait()
                }
                throw URLError(.cannotConnectToHost)
            }
            let tasks = operations.indices.map { index in
                Task { await self.prepare(viaTor: viaTor, cache: cache, operation: operations[index], attempt: attempts[index], sender: sender) }
            }
            await fulfillment(of: [started, enrolled], timeout: 2)
            await gate.release()
            for task in tasks {
                let error = await task.value
                XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            }
            XCTAssertEqual(calls.values.withLock { $0.events }, [URL(string: route.relayURL)!.host!, "cloudflare-dns.com", "dns.google"])
            var requestIDs = Set<UInt64>()
            for index in operations.indices {
                let selected = await selectedEvidence(session: session, operation: operations[index], attempt: attempts[index])
                XCTAssertEqual(selected.map(\.outcome), [.transportUnavailable])
                XCTAssertEqual(selected.first?.operation, operations[index])
                selected.forEach { requestIDs.insert($0.requestID) }
            }
            XCTAssertEqual(requestIDs.count, 2, "Each waiter owns a distinct request identity")
        }
    }

    func testRealMigrationKeyPreparationCancellationAndRejectionStayTyped() async throws {
        for viaTor in [false, true] {
            let route = OHTTPHealthRoute(
                network: .testnet, gatewayHost: preparationEndpoint.host,
                relayURL: "https://migration-rejection-\(UUID().uuidString.lowercased()).test/relay", viaTor: viaTor
            )
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            for status in [429, 403, 200] {
                let cache = OHTTPKeyCache()
                let calls = State()
                let operation = OHTTPHealthOperation()
                let attempt = OHTTPHealthAttempt(operation: operation)
                let error = await prepare(
                    viaTor: viaTor, cache: cache, operation: operation, attempt: attempt,
                    testRelayURL: route.relayURL, verifier: { _, _ in throw OHTTPError.keyConfigError("invalid signed configuration") }
                ) { request, _ in
                    calls.event(request.url?.host ?? "")
                    if calls.values.withLock({ $0.events.count }) > 1 { throw URLError(.cannotConnectToHost) }
                    return (Data(), OHTTPTestSupport.response(for: request.url, status: status, headers: ["Retry-After": "120"]))
                }
                if status == 200 {
                    guard case .keyConfigError = error as? OHTTPError else { return XCTFail("Original configuration error must survive") }
                } else {
                    guard case .httpStatusError(let actual, _) = error as? OHTTPError else { return XCTFail("Original HTTP error must survive") }
                    XCTAssertEqual(actual, status)
                }
                let evidence = await selectedEvidence(session: session, operation: operation, attempt: attempt)
                XCTAssertEqual(evidence.count, 1)
                if status == 429 {
                    guard case .rateLimited(let pause) = evidence.first?.outcome else { return XCTFail("Known pause must survive") }
                    XCTAssertGreaterThan(pause, OHTTPHealthClock.nowNanoseconds + 100_000_000_000)
                    let retained = try OHTTPHealthSession(route: route, generation: UUID())
                    defer { retained.close() }
                    XCTAssertTrue(retained.snapshot().observations.contains {
                        $0.historical && $0.operation == operation && $0.route == route && $0.outcome == .rateLimited(retryNotBefore: pause)
                    }, "The active pause must remain retained on the fixture route")
                    let canonical = try OHTTPHealthSession(route: try preparationRoute(viaTor: viaTor), generation: UUID())
                    defer { canonical.close() }
                    XCTAssertFalse(canonical.snapshot().observations.contains {
                        $0.operation == operation && $0.outcome == .rateLimited(retryNotBefore: pause)
                    }, "The fixture pause must not contaminate the canonical route")
                    let deadline = await cache.backoffDeadline(for: "\(route.relayURL)|\(viaTor ? "tor" : "direct")")
                    XCTAssertGreaterThan(try XCTUnwrap(deadline).timeIntervalSinceNow, 100)
                    XCTAssertEqual(calls.values.withLock { $0.events.count }, 1, "429 prohibits DNS fallback")
                } else {
                    XCTAssertEqual(evidence.first?.outcome, status == 403 ? .policyRejected : .configurationFailure)
                    XCTAssertEqual(calls.values.withLock { $0.events.count }, 3)
                }
            }
            let enrolled = expectation(description: "both cache waiters enrolled")
            enrolled.expectedFulfillmentCount = 2
            let cache = OHTTPKeyCache(testWaiterEnrolled: { enrolled.fulfill() })
            let calls = State()
            let gate = MigrationKeyGate()
            let started = expectation(description: "cancellable shared fetch started")
            let cancelledOperation = OHTTPHealthOperation()
            let remainingOperation = OHTTPHealthOperation()
            let cancelledAttempt = OHTTPHealthAttempt(operation: cancelledOperation)
            let remainingAttempt = OHTTPHealthAttempt(operation: remainingOperation)
            let sender: OHTTPTransport.HTTPSender = { request, _ in
                calls.event(request.url?.host ?? "")
                if request.url?.host == URL(string: route.relayURL)?.host {
                    started.fulfill()
                    await gate.wait()
                    XCTAssertFalse(Task.isCancelled, "Cancelling a waiter must leave the shared fetch alive")
                }
                throw URLError(.cannotConnectToHost)
            }
            let cancelled = Task {
                await self.prepare(
                    viaTor: viaTor, cache: cache, operation: cancelledOperation, attempt: cancelledAttempt,
                    testRelayURL: route.relayURL, sender: sender
                )
            }
            await fulfillment(of: [started], timeout: 2)
            let remaining = Task {
                await self.prepare(
                    viaTor: viaTor, cache: cache, operation: remainingOperation, attempt: remainingAttempt,
                    testRelayURL: route.relayURL, sender: sender
                )
            }
            await fulfillment(of: [enrolled], timeout: 2)
            cancelled.cancel()
            let cancelledError = await cancelled.value
            XCTAssertTrue(cancelledError is CancellationError)
            let cancelledEvidence = await selectedEvidence(session: session, operation: cancelledOperation, attempt: cancelledAttempt)
            XCTAssertEqual(cancelledEvidence.map(\.outcome), [.cancelled])
            await gate.release()
            let remainingError = await remaining.value
            XCTAssertEqual((remainingError as? URLError)?.code, .cannotConnectToHost)
            let remainingEvidence = await selectedEvidence(session: session, operation: remainingOperation, attempt: remainingAttempt)
            XCTAssertEqual(remainingEvidence.map(\.outcome), [.transportUnavailable])
            XCTAssertEqual(calls.values.withLock { $0.events.count }, 3)
            XCTAssertEqual(cancelledAttempt.evidence(route: route, generation: session.generation).map(\.outcome), [.cancelled], "No late shared-fetch evidence reaches the cancelled waiter")
        }
    }

    func testMigrationSelectsActualFailedStageAndExcludesPreparationFailures() async throws {
        for failure in ["key", "height", "preparation", "submit"] {
            let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let calls = State()
            let broadcaster = MigrationBroadcaster(
                torDirURL: testGeneralStorageDirectory, logger: logger,
                torClientFactory: { _ in throw Failure.bootstrap }, networkType: .testnet,
                ohttpClientFactory: { _ in
                    calls.event("client")
                    if failure == "key" {
                        OHTTPHealthCenter.shared.begin(route: route, scope: .route).record(outcome: .transportUnavailable, stage: .keyConfiguration)
                        throw Failure.bootstrap
                    }
                    return AttributedClient(route: route, failure: failure)
                }
            )
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(attempt) {
                    OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                    do {
                        let result = try await broadcaster.broadcast(to: self.endpoint, useTor: false, onWillSubmit: { calls.event("willSubmit") }) { _ in
                            calls.event("prepare")
                            if failure == "preparation" { throw Failure.preparation }
                            return Data([1])
                        }
                        XCTAssertEqual(result, .transportError)
                        XCTAssertNotEqual(failure, "preparation")
                    } catch Failure.preparation {
                        XCTAssertEqual(failure, "preparation")
                    } catch { XCTFail("Unexpected error: \(error)") }
                }
            }
            let updates = session.updates()
            await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
            for await update in updates {
                if case .operationCompleted(_, _, let observations) = update {
                    let expected: [OHTTPHealthOutcome] = failure == "preparation" ? [] : [failure == "submit" ? .policyRejected : .transportUnavailable]
                    XCTAssertEqual(observations.map(\.outcome), expected, failure)
                    XCTAssertFalse(observations.contains { $0.scope == .swaps }, failure)
                    break
                }
            }
            let expectedEvents = failure == "submit" ? ["client", "prepare", "willSubmit"] : failure == "preparation" ? ["client", "prepare"] : ["client"]
            XCTAssertEqual(calls.values.withLock { $0.events }, expectedEvents)
        }
    }

    func testGatewayReadsHeightBeforePreparationAndSubmit() async throws {
        let state = State()
        let client = Client(state: state)
        let bytes = Data([0x01, 0x02])
        let result = try await broadcaster(state: state, client: client).broadcast(
            to: endpoint, useTor: false,
            onWillSubmit: { state.event("willSubmit") },
            prepareTransaction: { height in
                state.event("prepare:\(height)")
                return bytes
            }
        )
        XCTAssertEqual(result, MigrationBroadcastOutcome.submitted)
        state.values.withLock {
            XCTAssertEqual($0.events, ["height", "prepare:4465026", "willSubmit", "submit"])
            XCTAssertEqual($0.submitted, bytes)
            XCTAssertEqual($0.factories, 1)
            XCTAssertEqual($0.clientIDs, [client.id, client.id])
        }
    }

    func testGatewayHeightFailureDoesNotPrepareOrSubmit() async throws {
        let state = State()
        let result = try await broadcaster(state: state, client: Client(state: state, failsHeight: true)).broadcast(
            to: endpoint, useTor: false,
            onWillSubmit: { state.event("willSubmit") },
            prepareTransaction: { _ in state.event("prepare")
                return Data([0x01])
            }
        )
        XCTAssertEqual(result, MigrationBroadcastOutcome.transportError)
        XCTAssertEqual(state.values.withLock { $0.events }, ["height"])
    }

    func testGatewayInvalidHeightDoesNotPrepareOrSubmit() async throws {
        let state = State()
        let result = try await broadcaster(state: state, client: Client(state: state, height: UInt64.max)).broadcast(
            to: endpoint, useTor: false,
            onWillSubmit: { state.event("willSubmit") },
            prepareTransaction: { _ in state.event("prepare")
                return Data([0x01])
            }
        )
        XCTAssertEqual(result, MigrationBroadcastOutcome.transportError)
        XCTAssertEqual(state.values.withLock { $0.events }, ["height"])
    }

    func testGatewayPreparationFailureDoesNotSubmit() async throws {
        let state = State()
        do {
            _ = try await broadcaster(state: state, client: Client(state: state)).broadcast(
                to: endpoint, useTor: false,
                onWillSubmit: { state.event("willSubmit") },
                prepareTransaction: { _ in state.event("prepare")
                    throw Failure.preparation
                }
            )
            XCTFail("Preparation failure must propagate")
        } catch Failure.preparation {
            XCTAssertEqual(state.values.withLock { $0.events }, ["height", "prepare"])
        }
    }
}

private actor MigrationKeyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
