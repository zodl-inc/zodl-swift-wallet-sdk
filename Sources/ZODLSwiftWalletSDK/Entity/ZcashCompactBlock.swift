//
//  ZcashCompactBlock.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 12/09/2019.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation

public typealias BlockHeight = Int
public typealias CompactBlockRange = ClosedRange<BlockHeight>

extension BlockHeight {
    static func empty() -> BlockHeight {
        BlockHeight(-1)
    }

    /// Converts a block height reported by a server, or `nil` if the SDK can't use it.
    ///
    /// Heights from lightwalletd arrive as `UInt64`, and converting one with a trapping initializer
    /// crashes the app when it doesn't fit. Block heights are `u32` in Rust, and several of the SDK's
    /// FFI functions take them as `Int32`, so `Int32.max` is the largest height the SDK can pass on.
    /// That is about 1,700 years away at one block every 25 seconds, so a larger value can only come
    /// from a broken or hostile server.
    init?(serverHeight: UInt64) {
        guard serverHeight <= UInt64(Int32.max) else {
            return nil
        }
        self = BlockHeight(serverHeight)
    }

    /// The height a transaction is mined at, from the height a server reports for it, or `nil` for a transaction that
    /// is not mined in the main chain.
    ///
    /// lightwalletd reports 0 for a transaction that is still in the mempool and `UInt64.max` for one that was mined on a
    /// fork. A height that `init(serverHeight:)` rejects counts the same way, so the SDK never stores a transaction as
    /// mined at a height it can't use.
    init?(minedServerHeight: UInt64) {
        guard minedServerHeight != 0 else {
            return nil
        }
        self.init(serverHeight: minedServerHeight)
    }
}

/**
A Zcash compact block to store on cache DB
*/
public struct ZcashCompactBlock {
    struct Meta {
        let hash: Data
        let time: UInt32
        let saplingOutputs: UInt32
        let orchardOutputs: UInt32
    }

    public let height: BlockHeight
    public let data: Data

    let meta: Meta
}

extension ZcashCompactBlock: Encodable {
    enum CodingKeys: CodingKey {
        case height
        case data
        case meta
    }

    public func encode(to encoder: Encoder) throws {
        do {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data, forKey: .data)
            try container.encode(height, forKey: .height)
        } catch {
            throw ZcashError.compactBlockEncode(error)
        }
    }
}

extension ZcashCompactBlock {
    /// Creates the SDK's compact block from the one a server sent.
    ///
    /// - Throws: `LightWalletServiceError.generalError` when the block's height is one the SDK can't use, which only a
    ///   broken or hostile server sends. The services call this inside the `do` whose `catch` turns the error into the
    ///   `ZcashError` of the call.
    init(compactBlock: CompactBlock) throws {
        guard let height = BlockHeight(serverHeight: compactBlock.height) else {
            throw LightWalletServiceError.generalError(message: "The server sent a compact block with a height the SDK can't use.")
        }
        self.height = height
        self.data = (try? compactBlock.serializedData()) ?? Data()
        let outputs = compactBlock.outputCount
        self.meta = Meta(
            hash: compactBlock.hash,
            time: compactBlock.time,
            saplingOutputs: outputs.0,
            orchardOutputs: outputs.1
        )
    }
}

extension CompactBlock {
    /// O(n) sum of all CompactTx sapling outputs and Orchard Actions
    /// - Returns: a tuple (SaplingOutputs, OrchardActions)
    var outputCount: (UInt32, UInt32) {
        vtx.compactMap { compactTx -> (UInt32, UInt32) in
            (UInt32(compactTx.outputs.count), UInt32(compactTx.actions.count))
        }
        .reduce((0, 0)) { partialResult, txOutputActionPair in
            (partialResult.0 + txOutputActionPair.0, partialResult.1 + txOutputActionPair.1)
        }
    }
}
extension ZcashCompactBlock: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.height != rhs.height {
            return false
        }

        return lhs.data == rhs.data
    }
}

extension ZcashCompactBlock: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(height)
        hasher.combine(data)
    }
}
