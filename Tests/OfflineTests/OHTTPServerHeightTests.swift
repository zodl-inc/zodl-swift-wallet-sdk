import Foundation
import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPServerHeightTests: XCTestCase {
    private let invalidHeight = UInt64(Int32.max) + 1

    private func makeService() -> LightWalletOHTTPService {
        let service = LightWalletOHTTPService(
            endpoint: LightWalletEndpoint(address: "ohttp-gateway-testnet.example", port: 443, secure: true),
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: TorClient(torDir: FileManager.default.temporaryDirectory),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        service.walletNetwork = .testnet
        return service
    }

    func testLatestBlockHeightRejectsAHeightAboveInt32Max() async throws {
        let service = makeService()
        let height = invalidHeight
        service.latestBlockRPC = { _, _ in
            var block = BlockID()
            block.height = height
            return block
        }
        do {
            _ = try await service.latestBlockHeight(mode: ServiceMode.direct)
            XCTFail("An unusable latest block height must be rejected")
        } catch ZcashError.serviceLatestBlockHeightFailed {
        }
        await service.closeConnections()
    }

    func testUTXOStreamRejectsAHeightAboveInt32Max() async throws {
        let service = makeService()
        let height = invalidHeight
        service.utxosRPC = { _, _ in
            var reply = GetAddressUtxosReply()
            reply.height = height
            return [reply]
        }
        do {
            for try await _ in try service.fetchUTXOs(for: ["address"], height: 1, mode: ServiceMode.direct) {
                XCTFail("An unusable-height UTXO must not be yielded")
            }
            XCTFail("An unusable UTXO height must terminate the stream with an error")
        } catch ZcashError.serviceFetchUTXOsFailed {
        }
        await service.closeConnections()
    }

    func testTransactionSentinelsAndHeightsAboveInt32MaxAreTreatedAsUnmined() async throws {
        let service = makeService()
        for height in [UInt64(0), invalidHeight, UInt64(UInt32.max), UInt64.max] {
            service.transactionRPC = { _, _ in
                var transaction = RawTransaction()
                transaction.height = height
                transaction.data = Data([0x01])
                return transaction
            }
            let result = try await service.fetchTransaction(txId: Data(repeating: 0x01, count: 32), mode: ServiceMode.direct)
            XCTAssertNil(result.tx?.minedHeight, "server height \(height)")
            XCTAssertEqual(result.status, TransactionStatus.notInMainChain, "server height \(height)")
        }
        await service.closeConnections()
    }
}
