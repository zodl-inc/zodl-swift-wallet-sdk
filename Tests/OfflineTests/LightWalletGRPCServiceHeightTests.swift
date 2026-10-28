//
//  LightWalletGRPCServiceHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// The gRPC service turns what a lightwalletd server sends into SDK types. A height the SDK can't use
/// (above `Int32.max`) can only come from a broken or hostile server, and has to fail the call with the
/// call's own `ZcashError` instead of reaching a trapping conversion. These tests run the real service
/// against a lightwalletd stand-in on the loopback interface.
final class LightWalletGRPCServiceHeightTests: ZcashTestCase {
    private let fetchedTxId = Data(repeating: 0xAB, count: 32)

    private func makeServer() throws -> HeightReportingLightwalletd {
        let server = try HeightReportingLightwalletd()
        addTeardownBlock { try? server.stop() }
        return server
    }

    private func makeService(for server: HeightReportingLightwalletd) -> LightWalletGRPCService {
        let service = LightWalletGRPCService(endpoint: server.endpoint)
        addTeardownBlock { service.stop() }
        return service
    }

    // MARK: - latestBlockHeight

    func testLatestBlockHeightAtInt32MaxIsReturned() async throws {
        let server = try makeServer()
        server.latestBlockHeight = UInt64(Int32.max)

        let height = try await makeService(for: server).latestBlockHeight(mode: .direct)

        XCTAssertEqual(height, BlockHeight(Int32.max))
    }

    func testLatestBlockHeightAboveInt32MaxFailsWithServiceLatestBlockHeightFailed() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max), UInt64.max] {
            let server = try makeServer()
            server.latestBlockHeight = reported

            do {
                let height = try await makeService(for: server).latestBlockHeight(mode: .direct)
                XCTFail("Expected the latest block height \(reported) to fail but got \(height).")
            } catch ZcashError.serviceLatestBlockHeightFailed(let underlying) {
                XCTAssertFalse("\(underlying)".contains(String(reported)), "The error must not carry the height: \(underlying)")
            } catch {
                XCTFail("Expected ZcashError.serviceLatestBlockHeightFailed for \(reported) but got \(error).")
            }
        }
    }

    // MARK: - blockRange and blockStream

    func testBlockRangeFailsWithServiceBlockRangeFailedOnABlockAboveInt32Max() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64.max] {
            let server = try makeServer()
            server.compactBlockHeights = [1, reported]

            let stream = try makeService(for: server).blockRange(1...2, mode: .direct)

            var received: [BlockHeight] = []
            do {
                for try await block in stream {
                    received.append(block.height)
                }
                XCTFail("Expected the stream to fail on the block at \(reported).")
            } catch ZcashError.serviceBlockRangeFailed {
            } catch {
                XCTFail("Expected ZcashError.serviceBlockRangeFailed for \(reported) but got \(error).")
            }
            XCTAssertEqual(received, [1], "The block before the unusable one is delivered.")
        }
    }

    func testBlockStreamFailsWithServiceBlockStreamFailedOnABlockAboveInt32Max() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64.max] {
            let server = try makeServer()
            server.compactBlockHeights = [1, reported]

            let stream = try makeService(for: server).blockStream(startHeight: 1, endHeight: 2, mode: .direct)

            var received: [BlockHeight] = []
            do {
                for try await block in stream {
                    received.append(block.height)
                }
                XCTFail("Expected the stream to fail on the block at \(reported).")
            } catch ZcashError.serviceBlockStreamFailed {
            } catch {
                XCTFail("Expected ZcashError.serviceBlockStreamFailed for \(reported) but got \(error).")
            }
            XCTAssertEqual(received, [1], "The block before the unusable one is delivered.")
        }
    }

    func testBlockStreamDeliversABlockAtInt32Max() async throws {
        let server = try makeServer()
        server.compactBlockHeights = [UInt64(Int32.max)]

        let stream = try makeService(for: server).blockStream(startHeight: 1, endHeight: 2, mode: .direct)

        var received: [BlockHeight] = []
        for try await block in stream {
            received.append(block.height)
        }
        XCTAssertEqual(received, [BlockHeight(Int32.max)])
    }

    // MARK: - fetchTransaction

    // A transaction a server returns at a height the SDK can't use is not mined as far as the SDK is concerned,
    // exactly like one in the mempool (height 0) or one mined on a fork (`UInt64.max`).

    func testFetchTransactionAtInt32MaxIsMined() async throws {
        let server = try makeServer()
        server.transactionHeight = UInt64(Int32.max)

        let fetched = try await makeService(for: server).fetchTransaction(txId: fetchedTxId, mode: .direct)

        XCTAssertEqual(fetched.status, .mined(BlockHeight(Int32.max)))
        XCTAssertEqual(fetched.tx?.minedHeight, UInt32(Int32.max))
    }

    func testFetchTransactionInTheMempoolIsNotInMainChain() async throws {
        let server = try makeServer()
        server.transactionHeight = 0

        let fetched = try await makeService(for: server).fetchTransaction(txId: fetchedTxId, mode: .direct)

        XCTAssertEqual(fetched.status, .notInMainChain)
        XCTAssertNotNil(fetched.tx)
        XCTAssertNil(fetched.tx?.minedHeight)
    }

    func testFetchTransactionAboveInt32MaxIsNotInMainChain() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64(Int64.max) + 1, UInt64.max] {
            let server = try makeServer()
            server.transactionHeight = reported

            let fetched = try await makeService(for: server).fetchTransaction(txId: fetchedTxId, mode: .direct)

            XCTAssertEqual(fetched.status, .notInMainChain, "\(reported)")
            XCTAssertNotNil(fetched.tx, "The transaction itself is still returned for \(reported).")
            XCTAssertNil(fetched.tx?.minedHeight, "\(reported)")
        }
    }

    // MARK: - fetchUTXOs

    func testFetchUTXOsFailsWithServiceFetchUTXOsFailedOnAHeightAboveInt32Max() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64.max] {
            let server = try makeServer()
            server.utxoHeights = [10, reported]

            let stream = try makeService(for: server).fetchUTXOs(for: "tmExampleTransparentAddress", height: 0, mode: .direct)

            var received: [BlockHeight] = []
            do {
                for try await utxo in stream {
                    received.append(utxo.height)
                }
                XCTFail("Expected the stream to fail on the UTXO at \(reported).")
            } catch ZcashError.serviceFetchUTXOsFailed {
            } catch {
                XCTFail("Expected ZcashError.serviceFetchUTXOsFailed for \(reported) but got \(error).")
            }
            XCTAssertEqual(received, [10], "The UTXO before the unusable one is delivered.")
        }
    }

    func testFetchUTXOsDeliversAUTXOAtInt32Max() async throws {
        let server = try makeServer()
        server.utxoHeights = [UInt64(Int32.max)]

        let stream = try makeService(for: server).fetchUTXOs(for: "tmExampleTransparentAddress", height: 0, mode: .direct)

        var received: [BlockHeight] = []
        for try await utxo in stream {
            received.append(utxo.height)
        }
        XCTAssertEqual(received, [BlockHeight(Int32.max)])
    }
}
