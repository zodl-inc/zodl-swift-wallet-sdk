//
//  TransparentAddressWalletStore.swift
//  ZODLSwiftWalletSDK
//
//  The wallet half of the transparent-address checks `LightWalletOHTTPService` runs over the OHTTP
//  transport: which address is due, where its range starts, and the storing of what the server returned.
//  The Tor gRPC path does the same inside `zcashlc_tor_lwd_conn_*`.
//

import Foundation
import libzcashlc

enum TransparentAddressWalletStore {
    /// A single-use address due for a check, and the block range to ask the server for.
    struct DueCheck: Equatable {
        let address: String
        let startHeight: BlockHeight
        let endHeight: BlockHeight
    }

    /// The single-use transparent address of `accountUUID` most overdue for a check, or nil when none is.
    @DBActor
    static func singleUseAddressToCheck(
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID
    ) throws -> DueCheck? {
        guard let check = zcashlc_single_use_taddr_to_check(dbData.0, dbData.1, networkType.networkId, accountUUID.id) else {
            throw ZcashError.rustCheckSingleUseTransparentAddresses(
                lastErrorMessage(fallback: "`singleUseAddressToCheck` failed with unknown error")
            )
        }
        defer { zcashlc_free_transparent_address_check(check) }

        guard check.pointee.tag != 0 else {
            return nil
        }
        return DueCheck(
            address: String(cString: check.pointee.due.address),
            startHeight: BlockHeight(check.pointee.due.start_height),
            endHeight: BlockHeight(check.pointee.due.end_height)
        )
    }

    /// Reschedules the check of a single-use address whose check found nothing.
    @DBActor
    static func scheduleNextSingleUseAddressCheck(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID
    ) throws {
        guard zcashlc_schedule_single_use_taddr_check(dbData.0, dbData.1, networkType.networkId, accountUUID.id, address) else {
            throw ZcashError.rustCheckSingleUseTransparentAddresses(
                lastErrorMessage(fallback: "`scheduleNextSingleUseAddressCheck` failed with unknown error")
            )
        }
    }

    /// The height from which the UTXOs of `address` are looked for, or nil when the address is not one of
    /// `accountUUID`'s.
    @DBActor
    static func utxoStartHeight(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID
    ) throws -> BlockHeight? {
        let height = zcashlc_transparent_address_utxo_start_height(dbData.0, dbData.1, networkType.networkId, accountUUID.id, address)
        switch height {
        case -1:
            return nil
        case ..<(-1):
            throw ZcashError.rustFetchUTXOsByAddress(lastErrorMessage(fallback: "`utxoStartHeight` failed with unknown error"))
        default:
            return BlockHeight(height)
        }
    }

    /// Decrypts and stores `transaction` as the server returned it (height 0 or above `UInt32.max`: not
    /// mined in the main chain).
    @DBActor
    static func store(_ transaction: RawTransaction, dbData: (String, UInt), networkType: NetworkType) throws {
        let minedHeight: Int64 = transaction.height == 0 || transaction.height > UInt64(UInt32.max) ? 0 : Int64(transaction.height)
        let txBytes = [UInt8](transaction.data)
        var txid = [UInt8](repeating: 0, count: 32)
        let result = zcashlc_decrypt_and_store_transaction(
            dbData.0,
            dbData.1,
            txBytes,
            UInt(txBytes.count),
            minedHeight,
            networkType.networkId,
            &txid
        )
        guard result == 1 else {
            throw ZcashError.rustDecryptAndStoreTransaction(
                lastErrorMessage(fallback: "`decryptAndStoreTransaction` failed with unknown error")
            )
        }
    }

    /// Stores the UTXO `reply` describes.
    @DBActor
    static func store(_ reply: GetAddressUtxosReply, dbData: (String, UInt), networkType: NetworkType) throws {
        let txid = [UInt8](reply.txid)
        let script = [UInt8](reply.script)
        guard let height = Int32(exactly: reply.height) else {
            throw ZcashError.rustPutUnspentTransparentOutput("UTXO height \(reply.height) out of range")
        }
        let stored = zcashlc_put_utxo(
            dbData.0,
            dbData.1,
            txid,
            UInt(txid.count),
            reply.index,
            script,
            UInt(script.count),
            reply.valueZat,
            height,
            networkType.networkId
        )
        guard stored else {
            throw ZcashError.rustPutUnspentTransparentOutput(
                lastErrorMessage(fallback: "`putUnspentTransparentOutput` failed with unknown error")
            )
        }
    }
}
