import XCTest
import libzcashlc
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthTests: XCTestCase {
    private func route() -> OHTTPHealthRoute {
        OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString.lowercased()).test", relayURL: "https://relay.test/", viaTor: false)
    }

    func testSnapshotRetainsSuccessAndFailureWithOriginalRequestOrdering() throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let old = OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd)
        let failed = OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd)
        failed.record(outcome: .transportUnavailable, stage: .connection)
        old.record(outcome: .usable, stage: .complete)
        let observations = session.snapshot().observations
        XCTAssertEqual(observations.count, 2)
        let failure = try XCTUnwrap(observations.first { $0.outcome == .transportUnavailable })
        let success = try XCTUnwrap(observations.first { $0.outcome == .usable })
        XCTAssertLessThan(success.startedAtNanoseconds, failure.observedAtNanoseconds)
        XCTAssertGreaterThan(success.observedAtNanoseconds, failure.observedAtNanoseconds)
        XCTAssertEqual(success.generation, session.generation)
    }

    func testRetiredRequestCannotEnterNewGeneration() throws {
        let route = route()
        let old = try OHTTPHealthSession(route: route, generation: UUID())
        let request = OHTTPHealthCenter.shared.begin(route: route, scope: .route)
        old.close()
        let current = try OHTTPHealthSession(route: route, generation: UUID())
        defer { current.close() }
        request.record(outcome: .transportUnavailable, stage: .connection)
        XCTAssertTrue(current.snapshot().observations.isEmpty)
        XCTAssertTrue(old.snapshot().observations.isEmpty)
    }

    func testReplayIsHistoricalAndDoesNotRewriteGeneration() throws {
        let route = route()
        let old = try OHTTPHealthSession(route: route, generation: UUID())
        OHTTPHealthCenter.shared.begin(route: route, scope: .route).record(outcome: .transportUnavailable, stage: .connection)
        old.close()
        let current = try OHTTPHealthSession(route: route, generation: UUID())
        defer { current.close() }
        let observation = try XCTUnwrap(current.snapshot().observations.first)
        XCTAssertTrue(observation.historical)
        XCTAssertEqual(observation.generation, old.generation)
        XCTAssertNotEqual(observation.generation, current.generation)
    }

    func testStalledConsumerKeepsFirstOperationsEvidenceWhileSecondRemainsActive() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        var updates = session.updates().makeAsyncIterator()
        let first = OHTTPHealthOperation()
        let second = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(first) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        await OHTTPHealthContext.withOperation(second) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        await OHTTPHealthContext.complete(first, failed: true)
        for _ in 0..<4 {
            guard let update = await updates.next() else { return XCTFail("Session ended before completion") }
            if case let .operationCompleted(operation, failed, observations) = update {
                XCTAssertEqual(operation, first)
                XCTAssertTrue(failed)
                XCTAssertEqual(observations.count, 1)
                XCTAssertEqual(observations.first?.operation, first)
                XCTAssertEqual(observations.first?.generation, session.generation)
                return
            }
        }
        XCTFail("First completion was delayed behind the unfinished operation")
    }

    func testNativeCapabilityMismatchFailsExplicitly() {
        XCTAssertThrowsError(try OHTTPNativeHealth.checkVersion(2)) { error in
            XCTAssertEqual(error as? OHTTPHealthError, .unsupportedNativeVersion(2))
        }
    }

    func testOperationsCaptureHealthMonotonicClock() {
        let before = OHTTPHealthClock.nowNanoseconds
        let operation = OHTTPHealthOperation()
        let after = OHTTPHealthClock.nowNanoseconds
        XCTAssertGreaterThanOrEqual(operation.startedAtNanoseconds, before)
        XCTAssertLessThanOrEqual(operation.startedAtNanoseconds, after)
    }

    func testCompletionQueueBackpressuresAndCloseReleasesPublisher() async throws {
        let mailbox = OHTTPHealthMailbox()
        let operation = OHTTPHealthOperation()
        for _ in 0..<64 {
            await mailbox.complete(.operationCompleted(operation, failed: true, observations: []))
        }
        let entered = expectation(description: "Publisher started")
        let finished = expectation(description: "Publisher released")
        let premature = expectation(description: "Publisher must wait for capacity")
        premature.isInverted = true
        let publisher = Task {
            entered.fulfill()
            await mailbox.complete(.operationCompleted(operation, failed: true, observations: []))
            finished.fulfill()
            premature.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        publisher.cancel()
        await fulfillment(of: [premature], timeout: 0.05)
        mailbox.close()
        await fulfillment(of: [finished], timeout: 2)
        await publisher.value
        let next = await mailbox.next()
        XCTAssertNil(next)
    }

    func testConsumingCompletionAdmitsNextPublisherWithoutLosingEvidence() async throws {
        let mailbox = OHTTPHealthMailbox()
        let operations = (0..<65).map { _ in OHTTPHealthOperation() }
        for operation in operations.prefix(64) {
            await mailbox.complete(.operationCompleted(operation, failed: true, observations: []))
        }
        let publisher = Task { await mailbox.complete(.operationCompleted(operations[64], failed: false, observations: [])) }
        for operation in operations {
            guard case let .operationCompleted(actual, _, _) = await mailbox.next() else { return XCTFail("Missing completion") }
            XCTAssertEqual(actual, operation)
        }
        await publisher.value
        mailbox.close()
    }

    func testNativeEnumsAndHistoryAreCopiedWithoutFreshnessRewrite() throws {
        let route = route()
        let generation = UUID()
        let outcomes: [OHTTPHealthOutcome] = [.usable, .transportUnavailable, .backendUnavailable,
                                             .rateLimited(retryNotBefore: 900), .policyRejected,
                                             .configurationFailure, .responseRejected, .cancelled, .inconclusive]
        for (tag, expected) in outcomes.enumerated() {
            var raw = FfiOHTTPHealthObservationV1()
            raw.generation = 77
            raw.version = 19
            raw.request_id = 21
            raw.started_at_nanoseconds = 100
            raw.observed_at_nanoseconds = 300
            raw.retry_not_before_nanoseconds = 900
            raw.scope = 2
            raw.outcome = UInt32(tag)
            raw.stage = 3
            raw.purpose = 2
            raw.historical = true
            let value = try XCTUnwrap(OHTTPNativeHealth.observation(raw, route: route, generation: generation, nativeGeneration: 88))
            XCTAssertEqual(value.outcome, expected)
            XCTAssertEqual(value.scope, .exchangeRates)
            XCTAssertEqual(value.stage, .responseBody)
            XCTAssertEqual(value.purpose, .diagnostic)
            XCTAssertEqual(value.source, .native)
            XCTAssertEqual(value.version, 19)
            XCTAssertEqual(value.requestID, 21)
            XCTAssertEqual(value.startedAtNanoseconds, 100)
            XCTAssertEqual(value.observedAtNanoseconds, 300)
            XCTAssertNil(value.generation)
            XCTAssertEqual(value.nativeGeneration, 77)
            XCTAssertTrue(value.historical)
        }
    }

    func testSharedSnapshotKeepsNativeAndSwiftEvidenceAndIgnoresLateReplay() throws {
        let route = route()
        let generation = UUID()
        let storage = OHTTPHealthStorage(route: route, generation: generation)
        defer { storage.close() }
        let native = OHTTPHealthObservation(
            source: .native, route: route, scope: .route, outcome: .transportUnavailable, stage: .connection,
            generation: generation, nativeGeneration: 7, version: 2, requestID: 31,
            startedAtNanoseconds: 100, observedAtNanoseconds: 200
        )
        let swift = OHTTPHealthObservation(
            source: .swift, route: route, scope: .route, outcome: .usable, stage: .complete,
            generation: generation, version: 1, requestID: 1, startedAtNanoseconds: 201, observedAtNanoseconds: 250,
            purpose: .diagnostic
        )
        storage.record([native, swift])
        let version = storage.snapshot().version
        storage.record([native])
        XCTAssertEqual(storage.snapshot().version, version)
        XCTAssertEqual(storage.snapshot().observations, [native, swift])
    }

    func testCoalescedSnapshotKeepsLatestEvidenceAfterMoreThan64Events() async throws {
        let storage = OHTTPHealthStorage(route: route(), generation: UUID())
        defer { storage.close() }
        var updates = storage.updates().makeAsyncIterator()
        for index in 1...100 {
            storage.record([OHTTPHealthObservation(
                source: .native, route: storage.route, scope: .route, outcome: .transportUnavailable, stage: .connection,
                generation: storage.generation, nativeGeneration: 8, version: UInt64(index), requestID: UInt64(index),
                startedAtNanoseconds: UInt64(index), observedAtNanoseconds: UInt64(index + 1)
            )])
        }
        guard case let .snapshot(snapshot) = await updates.next() else { return XCTFail("Missing snapshot") }
        XCTAssertEqual(snapshot.observations.count, 1)
        XCTAssertEqual(snapshot.observations.first?.version, 100)
    }

    func testOperationContextDoesNotLeakIntoSerializedRelayHeaders() async throws {
        let operation = OHTTPHealthOperation()
        let transport = OHTTPTransport(gatewayHost: "ohttp-gateway-testnet.example", relayURL: "https://relay.test/")
        let request = try await OHTTPHealthContext.withOperation(operation) {
            XCTAssertEqual(OHTTPHealthContext.operation, operation)
            return try await transport.relayPost(url: "https://relay.test/", body: Data([1, 2, 3]), timeoutMS: 2000)
        }
        XCTAssertNil(OHTTPHealthContext.operation)
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertFalse(headers.values.contains { $0.contains(operation.id.uuidString) })
        XCTAssertFalse(headers.keys.contains { $0.lowercased().contains("operation") })
        XCTAssertEqual(request.httpBody, Data([1, 2, 3]))
    }

    func testExplicitBackgroundChildDoesNotInheritUserOperation() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        await OHTTPHealthContext.withOperation(OHTTPHealthOperation()) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd, purpose: .background)
                .record(outcome: .transportUnavailable, stage: .connection)
        }
        let observation = try XCTUnwrap(session.snapshot().observations.first)
        XCTAssertNil(observation.operation)
        XCTAssertEqual(observation.purpose, .background)
    }

    func testNewRequestRetainsFreshHealthButDropsObsoleteOperationAttribution() async throws {
        let route = route()
        let obsolete = OHTTPHealthOperation(startedAtNanoseconds: 0)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        var updates = session.updates().makeAsyncIterator()
        await OHTTPHealthContext.withOperation(obsolete) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        await OHTTPHealthContext.complete(obsolete, failed: true)
        let observation = try XCTUnwrap(session.snapshot().observations.first)
        XCTAssertEqual(observation.outcome, .transportUnavailable)
        XCTAssertEqual(observation.generation, session.generation)
        XCTAssertNil(observation.operation)
        XCTAssertEqual(observation.purpose, .background)
        XCTAssertFalse(observation.historical)
        // A stale completion must not be queued ahead of the fresh health snapshot.
        guard case .snapshot = await updates.next() else { return XCTFail("Obsolete operation became an eligible completion") }
    }

    func testBackendFailureAndRouteSuccessRemainSeparate() throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let request = OHTTPHealthCenter.shared.begin(route: route, scope: .swaps)
        request.recordRouteUsable(stage: .responseHead)
        request.record(outcome: .backendUnavailable, stage: .complete)
        let observations = session.snapshot().observations
        XCTAssertEqual(observations.map(\.scope), [.route, .swaps])
        XCTAssertEqual(observations.map(\.outcome), [.usable, .backendUnavailable])
        XCTAssertEqual(observations[0].requestID, observations[1].requestID)
    }

    func testInvalidRouteFailsSubscriptionExplicitly() {
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "bad\0host", relayURL: "https://relay.test/", viaTor: false)
        XCTAssertThrowsError(try OHTTPHealthSession(route: route, generation: UUID())) { error in
            XCTAssertEqual(error as? OHTTPHealthError, .subscriptionFailed)
        }
    }

    func testHealthDeliveryDoesNotWaitForBlockedWalletSummaryTask() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let summaryStarted = expectation(description: "Wallet summary is blocked")
        let healthDelivered = expectation(description: "Health arrives independently")
        let releaseSummary = DispatchSemaphore(value: 0)
        let summary = DispatchWorkItem {
            summaryStarted.fulfill()
            releaseSummary.wait()
        }
        DispatchQueue(label: "test.blocked-wallet-summary").async(execute: summary)
        defer { releaseSummary.signal() }
        await fulfillment(of: [summaryStarted], timeout: 2)
        let updates = session.updates()
        let consumer = Task {
            for await update in updates {
                if case let .snapshot(snapshot) = update, !snapshot.observations.isEmpty {
                    healthDelivered.fulfill()
                    return
                }
            }
        }
        OHTTPHealthCenter.shared.begin(route: route, scope: .route).record(outcome: .transportUnavailable, stage: .connection)
        await fulfillment(of: [healthDelivered], timeout: 2)
        consumer.cancel()
        summary.cancel()
    }

    func testSessionCloseReleasesCompletionWaitingBehindFullSubscriber() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        let updates = session.updates()
        for _ in 0..<64 {
            let operation = OHTTPHealthOperation()
            await OHTTPHealthContext.withOperation(operation) {
                OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.complete(operation, failed: true)
        }
        let operation = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(operation) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        let released = expectation(description: "Retirement releases the completion publisher")
        let publisher = Task {
            await OHTTPHealthContext.complete(operation, failed: true)
            released.fulfill()
        }
        session.close()
        await fulfillment(of: [released], timeout: 2)
        await publisher.value
        var iterator = updates.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testDroppingStalledStreamReleasesCancelledCompletionPublisher() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let stream = OSAllocatedUnfairLock<AsyncStream<OHTTPHealthUpdate>?>(initialState: session.updates())
        for _ in 0..<64 {
            let operation = OHTTPHealthOperation()
            await OHTTPHealthContext.withOperation(operation) {
                OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.complete(operation, failed: true)
        }
        let operation = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(operation) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        let entered = expectation(description: "Publisher entered")
        let released = expectation(description: "Stream retirement releases cancelled publisher")
        let publisher = Task {
            entered.fulfill()
            await OHTTPHealthContext.complete(operation, failed: true)
            released.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        publisher.cancel()
        stream.withLock { $0 = nil }
        await fulfillment(of: [released], timeout: 2)
        // Always release the failed-test publisher so RED is a failure, not a leaked task.
        session.close()
        await publisher.value
    }
}
