//
//  TxId.swift
//  ZcashLightClientKit
//
//  Created by Lukáš Korba on 2026-27-11.
//

import Foundation

/// A transaction id: the 32 bytes of a transaction's hash, in the byte order the protocol uses
/// internally (the reverse of the hex string block explorers display).
public struct TxId: Equatable, Hashable, Identifiable {
    static let byteLength = 32

    /// The id's 32 bytes, in internal byte order.
    public let id: [UInt8]

    private static func txIdStringToBytes(_ txId: String) throws -> [UInt8] {
        guard txId.count == byteLength * 2 else {
            throw ZcashError.txIdNot32Bytes
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(txId.count / 2)

        var index = txId.startIndex

        while index < txId.endIndex {
            let nextIndex = txId.index(index, offsetBy: 2)
            let byteString = txId[index..<nextIndex]

            if let byte = UInt8(byteString, radix: 16) {
                bytes.append(byte)
            } else {
                throw ZcashError.txIdInvalidHexEncoding
            }

            index = nextIndex
        }

        return bytes.reversed()
    }

    /// Creates an id from its 32 bytes, in internal byte order.
    /// - Throws: `ZcashError.txIdNot32Bytes` when `id` is not 32 bytes long.
    public init(_ id: [UInt8]) throws {
        guard id.count == Self.byteLength else {
            throw ZcashError.txIdNot32Bytes
        }
        self.id = id
    }

    /// Creates an id from the hex string block explorers display (the reverse of the internal
    /// byte order).
    /// - Throws: `ZcashError.txIdNot32Bytes` when `id` is not 64 hex digits long, and
    ///   `ZcashError.txIdInvalidHexEncoding` when it is not hex.
    public init(_ id: String) throws {
        self.id = try TxId.txIdStringToBytes(id)
    }
}
