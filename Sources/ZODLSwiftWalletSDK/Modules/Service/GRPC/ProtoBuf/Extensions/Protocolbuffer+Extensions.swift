//
//  Protocolbuffer+Extensions.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 12/09/2019.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation

extension CompactBlockRange {
    func blockRange() -> BlockRange {
        BlockRange(startHeight: lowerBound, endHeight: upperBound)
    }
}

extension BlockID {
    init(height: UInt64) {
        self = BlockID()
        self.height = height
    }

    init(height: BlockHeight) {
        self.init(height: UInt64(height))
    }

    func compactBlockHeight() -> BlockHeight? {
        BlockHeight(exactly: self.height)
    }
}

extension BlockRange {
    init(startHeight: Int, endHeight: Int? = nil) {
        self = BlockRange()
        self.start = BlockID(height: UInt64(startHeight))
        if let endHeight {
            self.end = BlockID(height: UInt64(endHeight))
        }
    }

    var compactBlockRange: CompactBlockRange {
        return Int(self.start.height) ... Int(self.end.height)
    }
}

extension Array where Element == CompactBlock {
    func asZcashCompactBlocks() throws -> [ZcashCompactBlock] {
        try self.map { try ZcashCompactBlock(compactBlock: $0) }
    }
}

extension UTXO {
    /// Creates the SDK's UTXO from the reply a server sent.
    ///
    /// - Throws: `LightWalletServiceError.generalError` when the UTXO's height is one the SDK can't use, which only a
    ///   broken or hostile server sends. The service calls this inside the `do` whose `catch` turns the error into the
    ///   `ZcashError` of the call.
    init(reply: GetAddressUtxosReply) throws {
        guard let height = BlockHeight(serverHeight: reply.height) else {
            throw LightWalletServiceError.generalError(message: "The server sent a UTXO with a height the SDK can't use.")
        }
        self.init(
            address: reply.address,
            prevoutTxId: reply.txid,
            prevoutIndex: Int(reply.index),
            script: reply.script,
            valueZat: Int(reply.valueZat),
            height: height
        )
    }
}
