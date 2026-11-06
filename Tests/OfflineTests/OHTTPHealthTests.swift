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
        let firstAttempt = OHTTPHealthAttempt(operation: first)
        await OHTTPHealthContext.withOperation(first) {
            await OHTTPHealthContext.withAttempt(firstAttempt) {
                OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
        }
        await OHTTPHealthContext.withOperation(second) {
            OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        await OHTTPHealthContext.complete(first, failed: true, failedAttempt: firstAttempt)
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

    func testNativeCallbackCopiesAll126EntriesAndRejectsInvalidBounds() throws {
        let received = OSAllocatedUnfairLock(initialState: [[OHTTPHealthObservation]]())
        let generation = UUID()
        let box = OHTTPNativeHealth.CallbackBox(route: route(), generation: generation, nativeGeneration: 77) { observations in
            received.withLock { $0.append(observations) }
        }
        var entries = (0..<126).map { index in
            var entry = FfiOHTTPHealthObservationV1()
            entry.generation = 77
            entry.version = UInt64(index + 1)
            entry.request_id = UInt64(index + 1)
            entry.started_at_nanoseconds = UInt64(index + 100)
            entry.observed_at_nanoseconds = UInt64(index + 300)
            entry.scope = UInt32(index / 18)
            entry.outcome = UInt32((index / 2) % 9)
            entry.purpose = index.isMultiple(of: 2) ? 0 : 2
            entry.stage = 4
            entry.retry_not_before_nanoseconds = 900
            return entry
        }
        entries.withUnsafeBufferPointer { box.copy($0.baseAddress, count: 126, generation: 77) }
        entries[0].request_id = 0
        entries[125].version = 0
        let copied = received.withLock { $0.first ?? [] }
        XCTAssertEqual(copied.count, 126)
        XCTAssertEqual(copied.map(\.requestID), (1...126).map { UInt64($0) })
        XCTAssertEqual(copied.last?.version, 126)
        XCTAssertEqual(copied.first?.startedAtNanoseconds, 100)
        XCTAssertEqual(copied.last?.observedAtNanoseconds, 425)
        XCTAssertTrue(copied.allSatisfy { $0.generation == generation && $0.nativeGeneration == 77 })
        let outcomes: [OHTTPHealthOutcome] = [
            .usable, .transportUnavailable, .backendUnavailable, .rateLimited(retryNotBefore: 900),
            .policyRejected, .configurationFailure, .responseRejected, .cancelled, .inconclusive
        ]
        for (index, observation) in copied.enumerated() {
            XCTAssertEqual(observation.source, .native)
            XCTAssertEqual(observation.scope.rawValue, UInt32(index / 18))
            XCTAssertEqual(observation.outcome, outcomes[(index / 2) % 9])
            XCTAssertEqual(observation.stage, .complete)
            XCTAssertEqual(observation.purpose, index.isMultiple(of: 2) ? .background : .diagnostic)
            XCTAssertEqual(observation.version, UInt64(index + 1))
            XCTAssertEqual(observation.startedAtNanoseconds, UInt64(index + 100))
            XCTAssertEqual(observation.observedAtNanoseconds, UInt64(index + 300))
            XCTAssertNil(observation.operation)
            XCTAssertFalse(observation.historical)
        }
        entries.withUnsafeBufferPointer {
            box.copy($0.baseAddress, count: 127, generation: 77)
            box.copy($0.baseAddress, count: -1, generation: 77)
            box.copy($0.baseAddress, count: 126, generation: 78)
        }
        box.copy(nil, count: 126, generation: 77)
        box.copy(nil, count: 0, generation: 77)
        XCTAssertEqual(received.withLock { $0.count }, 1)
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

    func testCoalescedMailboxRetainsOrdinaryAndDiagnosticEvidenceSeparately() async throws {
        let storage = OHTTPHealthStorage(route: route(), generation: UUID())
        defer { storage.close() }
        var updates = storage.updates().makeAsyncIterator()
        let ordinarySuccess = OHTTPHealthObservation(
            source: .swift,
            route: storage.route,
            scope: .route,
            outcome: .usable,
            stage: .complete,
            generation: storage.generation,
            version: 11,
            requestID: 41,
            startedAtNanoseconds: 200,
            observedAtNanoseconds: 300
        )
        let diagnosticHead = OHTTPHealthObservation(
            source: .swift,
            route: storage.route,
            scope: .route,
            outcome: .usable,
            stage: .responseHead,
            generation: storage.generation,
            version: 12,
            requestID: 42,
            startedAtNanoseconds: 100,
            observedAtNanoseconds: 400,
            purpose: .diagnostic
        )
        let ordinaryFailure = OHTTPHealthObservation(
            source: .swift,
            route: storage.route,
            scope: .lightwalletd,
            outcome: .transportUnavailable,
            stage: .connection,
            generation: storage.generation,
            version: 13,
            requestID: 43,
            startedAtNanoseconds: 500,
            observedAtNanoseconds: 600
        )
        let diagnosticFailure = OHTTPHealthObservation(
            source: .swift,
            route: storage.route,
            scope: .lightwalletd,
            outcome: .transportUnavailable,
            stage: .responseBody,
            generation: storage.generation,
            version: 14,
            requestID: 42,
            startedAtNanoseconds: 100,
            observedAtNanoseconds: 700,
            purpose: .diagnostic
        )
        // Subscribe first and leave the real consumer paused through both same-category collisions.
        for observation in [ordinarySuccess, diagnosticHead, ordinaryFailure, diagnosticFailure] {
            storage.record([observation])
        }
        guard case let .snapshot(snapshot) = await updates.next() else { return XCTFail("Missing coalesced mailbox snapshot") }
        XCTAssertEqual(snapshot.observations.count, 4)
        // Whole-value equality checks original identity, purpose, timestamps and source version too.
        XCTAssertEqual(snapshot.observations.first { $0.requestID == ordinarySuccess.requestID }, ordinarySuccess)
        XCTAssertEqual(snapshot.observations.first { $0.requestID == ordinaryFailure.requestID }, ordinaryFailure)
        XCTAssertTrue(snapshot.observations.contains(diagnosticHead))
        XCTAssertTrue(snapshot.observations.contains(diagnosticFailure))
    }

    func testPurposePartitionKeepsCoalescingBoundedAndRejectsOlderEvidence() {
        let storage = OHTTPHealthStorage(route: route(), generation: UUID())
        defer { storage.close() }
        let purposes: [OHTTPHealthPurpose] = [.background, .userOperation, .diagnostic]
        let sources: [OHTTPHealthSource] = [.native, .swift]
        let outcomes: [OHTTPHealthOutcome] = [
            .usable, .transportUnavailable, .backendUnavailable, .rateLimited(retryNotBefore: 900),
            .policyRejected, .configurationFailure, .responseRejected, .cancelled, .inconclusive
        ]
        for source in sources {
            for scope in OHTTPHealthScope.allCases {
                for outcome in outcomes {
                    for (purposeIndex, purpose) in purposes.enumerated() {
                        for version in 1...100 {
                            let observation = OHTTPHealthObservation(
                                source: source,
                                route: storage.route,
                                scope: scope,
                                outcome: outcome,
                                stage: .complete,
                                generation: storage.generation,
                                version: UInt64(purposeIndex * 100 + version),
                                requestID: UInt64(purposeIndex * 100 + version),
                                startedAtNanoseconds: UInt64(purposeIndex * 100 + version),
                                observedAtNanoseconds: UInt64(purposeIndex * 100 + version + 1),
                                purpose: purpose
                            )
                            storage.record([observation])
                        }
                        let before = storage.snapshot()
                        // A higher version cannot rescue older observed-at evidence in either class.
                        storage.record([
                            OHTTPHealthObservation(
                                source: source,
                                route: storage.route,
                                scope: scope,
                                outcome: outcome,
                                stage: .complete,
                                generation: storage.generation,
                                version: 1_000,
                                requestID: 1_000,
                                startedAtNanoseconds: 1,
                                observedAtNanoseconds: 2,
                                purpose: purpose
                            )
                        ])
                        XCTAssertEqual(storage.snapshot(), before)
                    }
                    let bucket = storage.snapshot().observations.filter {
                        $0.source == source && $0.scope == scope && $0.outcome.category == outcome.category
                    }
                    XCTAssertLessThanOrEqual(bucket.count, 2)
                    XCTAssertTrue(bucket.allSatisfy {
                        $0.version == ($0.purpose == .diagnostic ? 300 : 200) && $0.requestID == $0.version
                    })
                    XCTAssertFalse(bucket.contains { $0.purpose == .background })
                }
            }
        }
        XCTAssertLessThanOrEqual(storage.snapshot().observations.count, 252)
    }

    func testOrdinaryRouteSuccessKeepsGreatestRequestStartAcrossCoalescedMailbox() async throws {
        for reverse in [false, true] {
            let storage = OHTTPHealthStorage(route: route(), generation: UUID())
            defer { storage.close() }
            var updates = storage.updates().makeAsyncIterator()
            func observation(start: UInt64, end: UInt64, version: UInt64, outcome: OHTTPHealthOutcome = .usable) -> OHTTPHealthObservation {
                OHTTPHealthObservation(
                    source: .swift,
                    route: storage.route,
                    scope: .route,
                    outcome: outcome,
                    stage: .complete,
                    generation: storage.generation,
                    version: version,
                    requestID: version,
                    startedAtNanoseconds: start,
                    observedAtNanoseconds: end
                )
            }
            let fresh = observation(start: 300, end: 400, version: 2)
            let old = observation(start: 100, end: 500, version: 3)
            storage.record(reverse ? [old, fresh] : [fresh, old])
            guard case let .snapshot(snapshot) = await updates.next() else { return XCTFail("Missing coalesced snapshot") }
            XCTAssertEqual(snapshot.observations, [fresh], "Ordinary recovery must survive either insertion order")
            let laterEnd = observation(start: 300, end: 600, version: 4)
            let laterVersion = observation(start: 300, end: 600, version: 5)
            storage.record([laterEnd, laterVersion, fresh, laterEnd])
            XCTAssertEqual(storage.snapshot().observations, [laterVersion], "Equal starts use end, then source version")
            let newerFailure = observation(start: 400, end: 700, version: 6, outcome: .transportUnavailable)
            let laterOlderFailure = observation(start: 100, end: 800, version: 7, outcome: .transportUnavailable)
            storage.record([newerFailure, laterOlderFailure])
            XCTAssertEqual(storage.snapshot().observations, [laterVersion, laterOlderFailure], "Failure ordering remains completion based")
        }
    }

    func testOperationContextDoesNotLeakIntoSerializedRelayHeaders() async throws {
        let operation = OHTTPHealthOperation()
        let transport = OHTTPTransport(gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://relay.test/")
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
