import Foundation
import os
import XCTest
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class MigrationOHTTPSubmissionTests: ZcashTestCase {
    private let endpoint = LightWalletEndpoint(address: "ohttp-gateway.example", port: 443)

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
