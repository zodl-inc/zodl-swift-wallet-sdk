import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthAttemptTests: XCTestCase {
    private func session() throws -> OHTTPHealthSession {
        try OHTTPHealthSession(route: OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false), generation: UUID())
    }

    private func completion(_ stream: AsyncStream<OHTTPHealthUpdate>) async -> [OHTTPHealthObservation] {
        for await update in stream {
            if case .operationCompleted(_, _, let observations) = update { return observations }
        }
        XCTFail("Missing completion")
        return []
    }

    func testAdoptionRejectsUnclosedForeignReusedAndAlreadyConsumedChildren() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let foreign = OHTTPHealthAttempt(operation: OHTTPHealthOperation())
        let reused = OHTTPHealthAttempt(operation: operation)
        let child = OHTTPHealthAttempt(operation: operation)
        let outer = OHTTPHealthAttempt(operation: operation)
        let another = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(outer) {
                outer.beginDelegation()
                outer.adoptFailure(from: outer)
                outer.adoptFailure(from: foreign)
                await OHTTPHealthContext.withAttempt(reused) {
                    OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                }
                await OHTTPHealthContext.withAttempt(reused) {}
                outer.adoptFailure(from: reused)
                await OHTTPHealthContext.withAttempt(child) {
                    OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .policyRejected, stage: .complete)
                    outer.adoptFailure(from: child)
                    XCTAssertTrue(outer.evidence(route: session.route, generation: session.generation).isEmpty)
                }
                outer.adoptFailure(from: child)
                await OHTTPHealthContext.withAttempt(another) {
                    another.beginDelegation()
                    another.adoptFailure(from: child)
                }
            }
        }
        XCTAssertEqual(outer.evidence(route: session.route, generation: session.generation).map(\.outcome), [.policyRejected])
        XCTAssertTrue(another.evidence(route: session.route, generation: session.generation).isEmpty)
    }

    func testAggregateMergeOverflowCannotDiscardAChildCause() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let outer = OHTTPHealthAttempt(operation: operation)
        let children = [OHTTPHealthAttempt(operation: operation), OHTTPHealthAttempt(operation: operation)]
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(outer) {
                outer.beginDelegation()
                for (index, child) in children.enumerated() {
                    await OHTTPHealthContext.withAttempt(child) {
                        for _ in 0..<(index == 0 ? 33 : 32) {
                            OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                        }
                    }
                }
                outer.adoptAllFailures(from: children)
            }
        }
        XCTAssertTrue(outer.evidence(route: session.route, generation: session.generation).isEmpty)
    }

    func testAggregateRequiresEveryChildInTheSameRouteAndGeneration() async throws {
        let session = try session()
        defer { session.close() }
        for sameRoute in [false, true] {
            let operation = OHTTPHealthOperation()
            let outer = OHTTPHealthAttempt(operation: operation)
            let children = [OHTTPHealthAttempt(operation: operation), OHTTPHealthAttempt(operation: operation)]
            await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(outer) {
                    outer.beginDelegation()
                    for (index, child) in children.enumerated() {
                        await OHTTPHealthContext.withAttempt(child) {
                            let route = index == 0 || sameRoute ? session.route : OHTTPHealthRoute(network: .testnet, gatewayHost: "other.test", relayURL: "https://other.test/", viaTor: false)
                            let generation = index == 0 || !sameRoute ? session.generation : UUID()
                            child.record(OHTTPHealthObservation(
                                source: .swift, route: route, scope: .lightwalletd, outcome: .transportUnavailable, stage: .connection,
                                generation: generation, version: UInt64(index + 1), requestID: UInt64(index + 1),
                                startedAtNanoseconds: 1, observedAtNanoseconds: 2, operation: operation, purpose: .userOperation
                            ))
                        }
                    }
                    outer.adoptAllFailures(from: children)
                }
            }
            XCTAssertTrue(outer.evidence(route: session.route, generation: session.generation).isEmpty)
        }
    }

    func testTerminalIndexUsesSourceVersionAndKeepsSourcesSeparate() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                for (source, version, observed, outcome) in [
                    (OHTTPHealthSource.swift, UInt64(20), UInt64(20), OHTTPHealthOutcome.policyRejected),
                    (OHTTPHealthSource.swift, UInt64(10), UInt64(30), OHTTPHealthOutcome.transportUnavailable),
                    (OHTTPHealthSource.native, UInt64(1), UInt64(5), OHTTPHealthOutcome.transportUnavailable)
                ] {
                    attempt.record(OHTTPHealthObservation(
                        source: source, route: session.route, scope: .lightwalletd, outcome: outcome,
                        stage: .complete, generation: session.generation, version: version, requestID: 1,
                        startedAtNanoseconds: 1, observedAtNanoseconds: observed, operation: operation, purpose: .userOperation
                    ))
                }
            }
        }
        let observations = attempt.evidence(route: session.route, generation: session.generation)
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.first { $0.source == .swift }?.outcome, .policyRejected)
        XCTAssertEqual(observations.first { $0.source == .swift }?.version, 20)
        XCTAssertEqual(observations.first { $0.source == .swift }?.observedAtNanoseconds, 20)
        XCTAssertEqual(observations.first { $0.source == .native }?.outcome, .transportUnavailable)
    }

    func testTerminalIndexKeepsConflictingRequestsDistinct() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                let first = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
                first.record(outcome: .policyRejected, stage: .responseHead)
                let second = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
                second.record(outcome: .policyRejected, stage: .responseHead)
                second.record(outcome: .transportUnavailable, stage: .responseBody)
            }
        }
        let observations = attempt.evidence(route: session.route, generation: session.generation)
        XCTAssertEqual(observations.filter { $0.outcome == .policyRejected }.count, 1)
        XCTAssertEqual(observations.filter { $0.outcome == .transportUnavailable }.count, 1)
        XCTAssertEqual(Set(observations.map(\.requestID)).count, 2)
    }

    func testAttemptRetains64TerminalRequestsAndFailsClosedAt65() async throws {
        for count in [64, 65] {
            let session = try session()
            defer { session.close() }
            let operation = OHTTPHealthOperation()
            let outer = OHTTPHealthAttempt(operation: operation)
            let child = OHTTPHealthAttempt(operation: operation)
            await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(outer) {
                    outer.beginDelegation()
                    await OHTTPHealthContext.withAttempt(child) {
                        for _ in 0..<count {
                            OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                        }
                    }
                    outer.adoptFailure(from: child)
                }
            }
            XCTAssertEqual(outer.evidence(route: session.route, generation: session.generation).count, count == 64 ? 64 : 0)
            XCTAssertEqual(session.snapshot().observations.count, 1, "Global retention remains category-coalesced")
        }
    }

    func testAggregateCannotReuseAnAttemptIdentity() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let outer = OHTTPHealthAttempt(operation: operation)
        let id = UUID()
        let first = OHTTPHealthAttempt(operation: operation, id: id)
        let second = OHTTPHealthAttempt(operation: operation, id: id)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(outer) {
                outer.beginDelegation()
                for child in [first, second] {
                    await OHTTPHealthContext.withAttempt(child) {
                        OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                    }
                }
                outer.adoptAllFailures(from: [first, second])
            }
        }
        XCTAssertTrue(outer.evidence(route: session.route, generation: session.generation).isEmpty)
    }

    func testLocalFailureDoesNotAttributeEarlierOptionalNetworkFailure() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(operation) {
            OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testOnlyFinalExplicitAttemptSuppliesReminderEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let earlier = OHTTPHealthAttempt(operation: operation)
        let final = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(earlier) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.withAttempt(final) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: final)
        let observations = await completion(stream)
        XCTAssertEqual(observations.map(\.outcome), [.policyRejected])
    }

    func testOverlappingAttemptsCannotReplaceSelectedAttemptsEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let first = OHTTPHealthAttempt(operation: operation)
        let second = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await OHTTPHealthContext.withAttempt(first) {
                        OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                    }
                }
                group.addTask {
                    await OHTTPHealthContext.withAttempt(second) {
                        OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
                    }
                }
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: first)
        let observations = await completion(stream)
        XCTAssertEqual(observations.map(\.outcome), [.transportUnavailable])
    }
    func testReusedAttemptCannotAttributeAnEarlierFailure() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .policyRejected, stage: .responseHead)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
    }

    func testForeignAttemptCannotSupplyCurrentOperationsEvidence() async throws {
        let session = try session()
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let foreign = OHTTPHealthAttempt(operation: OHTTPHealthOperation())
        await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(foreign) {
                OHTTPHealthCenter.shared.begin(route: session.route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
            }
        }
        let stream = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: foreign)
        let observations = await completion(stream)
        XCTAssertTrue(observations.isEmpty)
    }

}
