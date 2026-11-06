import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class OHTTPSubmissionAttributionTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    private struct Submitter: EndpointSubmitter {
        let work: @Sendable (LightWalletEndpoint) async throws -> Void
        func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws {
            try await work(endpoint)
        }
    }

    private actor Gate {
        private var started: Set<String> = []
        private var finished: Set<String> = []
        private var releases: [String: CheckedContinuation<Void, Never>] = [:]
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var finishWaiters: [String: CheckedContinuation<Void, Never>] = [:]

        func pause(_ host: String) async {
            await withCheckedContinuation { continuation in
                releases[host] = continuation
                started.insert(host)
                let ready = startWaiters.filter { $0.0 <= started.count }
                startWaiters.removeAll { $0.0 <= started.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func waitForStarts(_ count: Int) async {
            if started.count >= count { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }
        func release(_ host: String) { releases.removeValue(forKey: host)?.resume() }
        func didFinish(_ host: String) {
            finished.insert(host)
            finishWaiters.removeValue(forKey: host)?.resume()
        }
        func waitForFinish(_ host: String) async {
            if finished.contains(host) { return }
            await withCheckedContinuation { finishWaiters[host] = $0 }
        }
    }

    private func session() throws -> OHTTPHealthSession {
        try OHTTPHealthSession(
            route: OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false),
            generation: UUID()
        )
    }

    private func transaction() -> CreatedTransaction {
        CreatedTransaction(txId: Data(repeating: 1, count: 32), raw: Data([1]), expiryHeight: nil)
    }

    private func endpoint(_ index: Int) -> LightWalletEndpoint {
        LightWalletEndpoint(address: "server\(index).test", port: 443)
    }

    private func evidence(_ session: OHTTPHealthSession, operation: OHTTPHealthOperation, attempt: OHTTPHealthAttempt) async -> [OHTTPHealthObservation] {
        await OHTTPHealthContext.withOperation(operation) {
            _ = OHTTPHealthCenter.shared.begin(route: session.route, scope: .other)
        }
        let updates = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        for await update in updates {
            if case .operationCompleted(_, _, let observations) = update { return observations }
        }
        XCTFail("Missing completion")
        return []
    }

    func testAllFailedRaceSelectsItsCompleteEndpointSetAndDropsIncidentalTraffic() async throws {
        let session = try session()
        defer { session.close() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let submitter = Submitter { endpoint in
            calls.withLock { $0.append(endpoint.host) }
            OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
            throw Failure.unavailable
        }
        let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        let outcome = await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                return await race.submit(transaction: self.transaction(), to: [self.endpoint(1), self.endpoint(2)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
            }
        }
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(calls.withLock { $0.sorted() }, ["server1.test", "server2.test"])
        let observations = await evidence(session, operation: operation, attempt: attempt)
        XCTAssertEqual(observations.map(\.outcome), [.transportUnavailable, .transportUnavailable])
        XCTAssertEqual(observations.map(\.scope), [.lightwalletd, .lightwalletd])
    }

    func testAggregateRejectsEarlierConflictingTerminalRequestEvenAfterSameCategoryReplacement() async throws {
        let session = try session()
        defer { session.close() }
        let submitter = Submitter { endpoint in
            if endpoint.host == "server1.test" {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .policyRejected, stage: .responseHead)
            }
            let final = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
            final.record(outcome: .policyRejected, stage: .responseHead)
            final.record(outcome: .transportUnavailable, stage: .responseBody)
            throw Failure.unavailable
        }
        let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        let result = await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                await race.submit(transaction: self.transaction(), to: [self.endpoint(1), self.endpoint(2)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
            }
        }
        XCTAssertEqual(result, .unreachable)
        let observations = await evidence(session, operation: operation, attempt: attempt)
        XCTAssertTrue(observations.isEmpty)
    }

    func testAllFailedRacePreservesEveryRequestInEitherCompletionOrder() async throws {
        for order in [[1, 2], [2, 1]] {
            let session = try session()
            defer { session.close() }
            let gate = Gate()
            let starts = OSAllocatedUnfairLock(initialState: [UInt64: UInt64]())
            let submitter = Submitter { endpoint in
                let request = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
                starts.withLock { $0[request.requestID] = request.startedAtNanoseconds }
                await gate.pause(endpoint.host)
                request.record(outcome: .transportUnavailable, stage: .connection)
                await gate.didFinish(endpoint.host)
                throw Failure.unavailable
            }
            let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            let task = Task {
                await OHTTPHealthContext.withOperation(operation) {
                    await OHTTPHealthContext.withAttempt(attempt) {
                        await race.submit(transaction: self.transaction(), to: [self.endpoint(1), self.endpoint(2)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
                    }
                }
            }
            await gate.waitForStarts(2)
            for index in order {
                let host = self.endpoint(index).host
                await gate.release(host)
                await gate.waitForFinish(host)
            }
            let result = await task.value
            XCTAssertEqual(result, .unreachable)
            let observations = await evidence(session, operation: operation, attempt: attempt)
            XCTAssertEqual(observations.count, 2)
            for observation in observations {
                XCTAssertEqual(observation.outcome, .transportUnavailable)
                XCTAssertEqual(observation.startedAtNanoseconds, starts.withLock { $0[observation.requestID] })
                XCTAssertEqual(observation.generation, session.generation)
            }
        }
    }

    func testTimeoutAndCancellationNeverAdoptLateEndpointFailures() async throws {
        for cancel in [false, true] {
            let session = try session()
            defer { session.close() }
            let gate = Gate()
            let submitter = Submitter { endpoint in
                let request = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
                await gate.pause(endpoint.host)
                request.record(outcome: .transportUnavailable, stage: .connection)
                await gate.didFinish(endpoint.host)
                throw Failure.unavailable
            }
            let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            let task = Task {
                await OHTTPHealthContext.withOperation(operation) {
                    await OHTTPHealthContext.withAttempt(attempt) {
                        await race.submit(transaction: self.transaction(), to: [self.endpoint(1)], timing: SubmissionTiming(responseTimeout: cancel ? 2 : 0.02, postAcceptanceGraceDelay: 0))
                    }
                }
            }
            await gate.waitForStarts(1)
            if cancel { task.cancel() }
            let result = await task.value
            XCTAssertEqual(result, cancel ? .cancelled : .timedOut)
            await gate.release(endpoint(1).host)
            await gate.waitForFinish(endpoint(1).host)
            let observations = await evidence(session, operation: operation, attempt: attempt)
            XCTAssertTrue(observations.isEmpty)
            XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
        }
    }

    func testMixedAndAcceptedRaceResultsDoNotAdoptOtherEndpointsFailures() async throws {
        for result in ["policy", "untyped", "local", "cancel", "accepted"] {
            let session = try session()
            defer { session.close() }
            let submitter = Submitter { endpoint in
                if endpoint.host == "server1.test" {
                    OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                    throw Failure.unavailable
                }
                switch result {
                case "accepted": return
                case "cancel": throw CancellationError()
                case "local": throw TransactionEncoderError.notSubmittable(.expired)
                case "policy":
                    OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .policyRejected, stage: .responseHead)
                    throw Failure.unavailable
                default: throw Failure.unavailable
                }
            }
            let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            _ = await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(attempt) {
                    await race.submit(transaction: self.transaction(), to: [self.endpoint(1), self.endpoint(2)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
                }
            }
            let observations = await evidence(session, operation: operation, attempt: attempt)
            XCTAssertTrue(observations.isEmpty, result)
        }
    }

    func testConcurrentRacesWithinOneOperationKeepTheirSelectedEvidenceSeparate() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let transport = OHTTPHealthAttempt(operation: operation)
        let policy = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await withTaskGroup(of: Void.self) { group in
                for (attempt, outcome) in [(transport, OHTTPHealthOutcome.transportUnavailable), (policy, OHTTPHealthOutcome.policyRejected)] {
                    group.addTask {
                        let endpointSubmitter = Submitter { _ in
                            OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: outcome, stage: .connection)
                            throw Failure.unavailable
                        }
                        let race = MultiEndpointSubmitter(endpointSubmitter: endpointSubmitter, logger: submissionLifecycleLogger())
                        let result = await OHTTPHealthContext.withAttempt(attempt) {
                            await race.submit(transaction: self.transaction(), to: [self.endpoint(1)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
                        }
                        XCTAssertEqual(result, .unreachable)
                    }
                }
            }
        }
        let observations = await evidence(session, operation: operation, attempt: transport)
        XCTAssertEqual(observations.map(\.outcome), [.transportUnavailable])
        XCTAssertTrue(policy.evidence(route: session.route, generation: session.generation).isEmpty)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .policyRejected })
    }

    func testReturnedRejectionNeverAdoptsEndpointTransportEvidence() async throws {
        for localRefusal in [false, true] {
            let session = try session()
            defer { session.close() }
            let calls = OSAllocatedUnfairLock(initialState: [String]())
            let submitter = Submitter { endpoint in
                calls.withLock { $0.append(endpoint.host) }
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                if endpoint.host == "server1.test" { throw Failure.unavailable }
                if localRefusal { throw TransactionEncoderError.notSubmittable(.expired) }
                throw TransactionEncoderError.submitError(code: -25, message: "rejected")
            }
            let race = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            let result = await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(attempt) {
                    await race.submit(transaction: self.transaction(), to: [self.endpoint(1), self.endpoint(2)], timing: SubmissionTiming(responseTimeout: 2, postAcceptanceGraceDelay: 0))
                }
            }
            XCTAssertEqual(result, localRefusal
                ? .rejected(code: -9102, message: TransactionSubmissionRefusal.expired.description)
                : .rejected(code: -25, message: "rejected"))
            XCTAssertEqual(calls.withLock { $0.sorted() }, ["server1.test", "server2.test"])
            let observations = await evidence(session, operation: operation, attempt: attempt)
            XCTAssertTrue(observations.isEmpty, "A returned rejection is the final business cause")
            XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
        }
    }

    func testBackgroundPlanExecutorClearsInheritedUserContextAndKeepsRetries() async throws {
        let session = try session()
        defer { session.close() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let submitter = Submitter { endpoint in
            calls.withLock { $0.append(endpoint.host) }
            OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
            throw Failure.unavailable
        }
        let executor = SubmitPlanExecutor(endpointSubmitter: submitter, logger: submissionLifecycleLogger())
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                do {
                    try await executor.submit(transaction: self.transaction(), endpoints: [self.endpoint(1), self.endpoint(2)])
                    XCTFail("Expected original final error")
                } catch Failure.unavailable {
                } catch { XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, ["server1.test", "server2.test"])
        let observations = await evidence(session, operation: operation, attempt: attempt)
        XCTAssertTrue(observations.isEmpty)
        XCTAssertTrue(session.snapshot().observations.allSatisfy { $0.operation == nil && $0.purpose == .background })
    }
}
