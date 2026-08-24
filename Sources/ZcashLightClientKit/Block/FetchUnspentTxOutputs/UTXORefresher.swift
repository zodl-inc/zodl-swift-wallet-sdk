//
//  UTXORefresher.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)
//  Licensed under the GNU Affero General Public License, version 3 only (AGPL-3.0-only).
//  See LICENSE, LICENSE-EXCEPTIONS.md and COMMERCIAL-LICENSE.md in this repository.
//

import Foundation

/// Refreshes the UTXOs of one transparent address: the implementation behind
/// `Synchronizer.refreshUTXOs(address:from:)`, shared by both synchronizers so the transport
/// decision and its consequences live in one place.
struct UTXORefresher {
    let blockDownloaderService: BlockDownloaderService
    let service: LightWalletService
    let rustBackend: ZcashRustBackendWelding
    let dataDb: URL
    let networkType: NetworkType
    let logger: Logger

    func refresh(address: TransparentAddress, startHeight: BlockHeight, mode: ServiceMode) async throws -> RefreshedUTXOs {
        guard mode == .direct else {
            return try await refreshOverTor(address: address, mode: mode)
        }

        let stream: AsyncThrowingStream<UnspentTransactionOutputEntity, Error> = try blockDownloaderService.fetchUnspentTransactionOutputs(
            tAddress: address.stringEncoded,
            startHeight: startHeight,
            mode: mode
        )

        var utxos: [UnspentTransactionOutputEntity] = []
        for try await utxo in stream {
            utxos.append(utxo)
        }

        return await store(utxos)
    }

    /// The Tor lookup is account-scoped on the FFI side: it starts at the address's exposure height
    /// (or the account birthday when that is unknown) rather than at a caller-supplied height, and it
    /// stores the UTXOs itself, so there are no entities to hand back. An address no account exposed
    /// has nothing to fetch. A service answering `.torRequired` has no Tor connection to offer,
    /// which is an error rather than a silent no-op.
    private func refreshOverTor(address: TransparentAddress, mode: ServiceMode) async throws -> RefreshedUTXOs {
        guard let accountUUID = try await rustBackend.getAccount(forTransparentAddress: address)?.id else {
            logger.info("refreshUTXOs: the address is not a receiver of any account, nothing to fetch.")
            return (inserted: [], skipped: [])
        }

        let result = try await service.fetchUTXOsByAddress(
            address: address.stringEncoded,
            dbData: dataDb.osStr(),
            networkType: networkType,
            accountUUID: accountUUID,
            mode: mode
        )

        guard result != .torRequired else {
            throw ZcashError.serviceTorRequired
        }

        return (inserted: [], skipped: [])
    }

    private func store(_ utxos: [UnspentTransactionOutputEntity]) async -> RefreshedUTXOs {
        var inserted: [UnspentTransactionOutputEntity] = []
        var skipped: [UnspentTransactionOutputEntity] = []

        for utxo in utxos {
            do {
                try await rustBackend.putUnspentTransparentOutput(
                    txid: utxo.txid.bytes,
                    index: utxo.index,
                    script: utxo.script.bytes,
                    value: Int64(utxo.valueZat),
                    height: utxo.height
                )

                inserted.append(utxo)
            } catch {
                logger.error("refreshUTXOs: failed to store a UTXO - error: \(error.localizedDescription)")
                skipped.append(utxo)
            }
        }

        return (inserted: inserted, skipped: skipped)
    }
}
