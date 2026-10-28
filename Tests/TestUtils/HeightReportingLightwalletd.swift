//
//  HeightReportingLightwalletd.swift
//  TestUtils
//

import Foundation
import GRPC
import NIO
import os
@testable import ZODLSwiftWalletSDK

/// A lightwalletd stand-in on the loopback interface that answers the calls a test cares about with the
/// heights the test chose, including heights no real server reports. Set the properties before the first
/// request.
class HeightReportingLightwalletd: RecordingCompactTxStreamerService {
    private struct Answers {
        var latestBlockHeight: UInt64 = 0
        var compactBlockHeights: [UInt64] = []
        var utxoHeights: [UInt64] = []
        var info: LightdInfo?
        var transactionHeight: UInt64?
    }

    /// The test thread writes the answers while the event loop reads them to serve a call.
    private let answers = OSAllocatedUnfairLock(initialState: Answers())

    /// The height `getLatestBlock` answers with.
    var latestBlockHeight: UInt64 {
        get { answers.withLock { $0.latestBlockHeight } }
        set { answers.withLock { $0.latestBlockHeight = newValue } }
    }

    /// The heights of the compact blocks `getBlockRange` streams, in order, whatever the requested range is.
    var compactBlockHeights: [UInt64] {
        get { answers.withLock { $0.compactBlockHeights } }
        set { answers.withLock { $0.compactBlockHeights = newValue } }
    }

    /// The heights of the UTXOs `getAddressUtxosStream` streams, in order.
    var utxoHeights: [UInt64] {
        get { answers.withLock { $0.utxoHeights } }
        set { answers.withLock { $0.utxoHeights = newValue } }
    }

    /// What `getLightdInfo` answers with. Unimplemented while `nil`.
    var info: LightdInfo? {
        get { answers.withLock { $0.info } }
        set { answers.withLock { $0.info = newValue } }
    }

    /// The height `getTransaction` reports its transaction at. Unimplemented while `nil`.
    var transactionHeight: UInt64? {
        get { answers.withLock { $0.transactionHeight } }
        set { answers.withLock { $0.transactionHeight = newValue } }
    }

    /// The calls get 30 s instead of the 5 s of the submission tests: a stall of a few seconds on a loaded machine must
    /// not fail these tests, and a call that hangs still does.
    convenience init() throws {
        try self.init(sendResponse: SendResponse(), callTimeoutInMillis: 30_000)
    }

    /// The `getLightdInfo` answer of a healthy testnet server whose tip is at `blockHeight`, except for what the
    /// test overrides afterwards. Its consensus branch id is the one `ZcashRustBackendWeldingMock` tests use.
    static func testnetInfo(blockHeight: UInt64) -> LightdInfo {
        var info = LightdInfo()
        info.chainName = "test"
        info.saplingActivationHeight = 280_000
        info.consensusBranchID = "c2d6d0b4"
        info.blockHeight = blockHeight
        info.estimatedHeight = blockHeight
        return info
    }

    override func getLightdInfo(request: ZODLSwiftWalletSDK.Empty, context: StatusOnlyCallContext) -> EventLoopFuture<LightdInfo> {
        guard let info else {
            return super.getLightdInfo(request: request, context: context)
        }
        return context.eventLoop.makeSucceededFuture(info)
    }

    override func getTransaction(request: TxFilter, context: StatusOnlyCallContext) -> EventLoopFuture<RawTransaction> {
        guard let transactionHeight else {
            return super.getTransaction(request: request, context: context)
        }
        var transaction = RawTransaction()
        transaction.data = Data([0x04, 0x00, 0x00, 0x80])
        transaction.height = transactionHeight
        return context.eventLoop.makeSucceededFuture(transaction)
    }

    override func getLatestBlock(request: ChainSpec, context: StatusOnlyCallContext) -> EventLoopFuture<BlockID> {
        context.eventLoop.makeSucceededFuture(BlockID(height: latestBlockHeight))
    }

    override func getBlockRange(request: BlockRange, context: StreamingResponseCallContext<CompactBlock>) -> EventLoopFuture<GRPCStatus> {
        let sent = compactBlockHeights.map { height -> EventLoopFuture<Void> in
            var block = CompactBlock()
            block.height = height
            block.hash = Data(repeating: 0x11, count: 32)
            block.time = 1_700_000_000
            return context.sendResponse(block)
        }
        return EventLoopFuture.andAllSucceed(sent, on: context.eventLoop).map { GRPCStatus.ok }
    }

    override func getAddressUtxosStream(
        request: GetAddressUtxosArg,
        context: StreamingResponseCallContext<GetAddressUtxosReply>
    ) -> EventLoopFuture<GRPCStatus> {
        let sent = utxoHeights.map { height -> EventLoopFuture<Void> in
            var reply = GetAddressUtxosReply()
            reply.address = "tmExampleTransparentAddress"
            reply.txid = Data(repeating: 0x22, count: 32)
            reply.script = Data([0x76, 0xa9])
            reply.valueZat = 4_200
            reply.height = height
            return context.sendResponse(reply)
        }
        return EventLoopFuture.andAllSucceed(sent, on: context.eventLoop).map { GRPCStatus.ok }
    }
}
