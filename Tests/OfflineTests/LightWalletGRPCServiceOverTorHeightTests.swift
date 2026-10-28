//
//  LightWalletGRPCServiceOverTorHeightTests.swift
//  OfflineTests
//

import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// Over Tor the latest block comes from a `TorLwdConn` and the tree state is requested through one, both
/// as 32-bit heights on the rust side. The service has to refuse a height the SDK can't use before it
/// gets there, with the same errors it reports for its other failures.
final class LightWalletGRPCServiceOverTorHeightTests: ZcashTestCase {
    /// Answers `latestBlock(mode:)` itself, so no Tor connection is needed.
    private final class LatestBlockStub: LightWalletGRPCServiceOverTor {
        var latestBlockID = BlockID()

        override func latestBlock(mode: ServiceMode) async throws -> BlockID {
            latestBlockID
        }
    }

    private func makeService() -> LatestBlockStub {
        LatestBlockStub(
            endpoint: LightWalletEndpointBuilder.default,
            tor: TorClient(torDir: testTempDirectory.appendingPathComponent("tor", isDirectory: true))
        )
    }

    // MARK: - latestBlockHeight

    func testLatestBlockHeightAtInt32MaxIsReturned() async throws {
        let service = makeService()
        service.latestBlockID = BlockID(height: UInt64(Int32.max))

        let height = try await service.latestBlockHeight(mode: .defaultTor)

        XCTAssertEqual(height, BlockHeight(Int32.max))
    }

    func testLatestBlockHeightJustAboveInt32MaxFails() async throws {
        try await assertLatestBlockHeightFails(forHeight: UInt64(Int32.max) + 1)
    }

    /// The rust side hands over a `u32`, so this is the largest height a Tor connection can report.
    func testLatestBlockHeightAtUInt32MaxFails() async throws {
        try await assertLatestBlockHeightFails(forHeight: UInt64(UInt32.max))
    }

    private func assertLatestBlockHeightFails(forHeight height: UInt64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let service = makeService()
        service.latestBlockID = BlockID(height: height)

        do {
            let returned = try await service.latestBlockHeight(mode: .defaultTor)
            XCTFail("Expected the latest block height to fail but got \(returned).", file: file, line: line)
        } catch ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.generalError(let message)) {
            XCTAssertFalse(message.contains(String(height)), "The message must not carry the height: \(message)", file: file, line: line)
        } catch {
            XCTFail("Expected ZcashError.serviceLatestBlockHeightFailed but got \(error).", file: file, line: line)
        }
    }

    // MARK: - getTreeState

    /// The check comes before a connection is asked for, so a request that can't be made says nothing
    /// about the connection, and the test needs no Tor.
    func testGetTreeStateAboveInt32MaxFailsBeforeConnecting() async throws {
        for height in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max) + 1, UInt64.max] {
            guard let outcome = await treeStateOutcome(at: height) else {
                XCTFail("The tree state request at \(height) did not fail within \(Self.bound) s: it must not wait for a Tor connection.")
                return
            }

            switch outcome {
            case .success:
                XCTFail("Expected the tree state request at \(height) to fail.")
            case .failure(ZcashError.rustTorLwdGetTreeState):
                break
            case .failure(let error):
                XCTFail("Expected ZcashError.rustTorLwdGetTreeState for \(height) but got \(error).")
            }
        }
    }

    private static let bound: TimeInterval = 5

    /// The outcome of a `getTreeState` request, or `nil` when it has not finished within `bound` seconds.
    ///
    /// A request that wrongly reaches for a Tor connection blocks in a call that cancellation can't interrupt, so the
    /// request runs in a task of its own that is left behind when the bound passes, instead of being raced against a
    /// timer inside a task group, which would wait for it.
    private func treeStateOutcome(at height: UInt64) async -> Result<TreeState, Error>? {
        let service = makeService()
        let finished = expectation(description: "getTreeState at \(height) finished")
        let outcome = OSAllocatedUnfairLock<Result<TreeState, Error>?>(initialState: nil)

        let task = Task {
            let result: Result<TreeState, Error>
            do {
                result = .success(try await service.getTreeState(BlockID(height: height), mode: .defaultTor))
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: Self.bound)
        task.cancel()
        return outcome.withLock { $0 }
    }
}
