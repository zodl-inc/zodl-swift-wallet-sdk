//
//  UTXOFetcher.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 6/2/21.
//

import Foundation

enum UTXOFetcherError: Error {
    case clearingFailed(_ error: Error?)
    case fetchFailed(error: Error)
}

struct UTXOFetcherConfig {
    let walletBirthdayProvider: () async -> BlockHeight
    let dataDb: URL
    let networkType: NetworkType
}

protocol UTXOFetcher {
    func fetch(
        didFetch: @escaping (Float) async -> Void
    ) async throws -> (inserted: [UnspentTransactionOutputEntity], skipped: [UnspentTransactionOutputEntity])
}

struct UTXOFetcherImpl {
    let blockDownloaderService: BlockDownloaderService
    let service: LightWalletService
    let config: UTXOFetcherConfig
    let rustBackend: ZcashRustBackendWelding
    let metrics: SDKMetrics
    let logger: Logger
    let sdkFlags: SDKFlags
}

extension UTXOFetcherImpl: UTXOFetcher {
    func fetch(
        didFetch: @escaping (Float) async -> Void
    ) async throws -> (inserted: [UnspentTransactionOutputEntity], skipped: [UnspentTransactionOutputEntity]) {
        try Task.checkCancellation()

        let accounts = try await rustBackend.listAccounts()

        if await sdkFlags.torEnabled {
            return try await fetchOverTor(accounts: accounts, didFetch: didFetch)
        }

        var tAddresses: [TransparentAddress] = []
        for account in accounts {
            tAddresses += try await rustBackend.listTransparentReceivers(accountUUID: account.id)
        }

        var utxos: [UnspentTransactionOutputEntity] = []
        let stream: AsyncThrowingStream<UnspentTransactionOutputEntity, Error> = try blockDownloaderService.fetchUnspentTransactionOutputs(
            tAddresses: tAddresses.map { $0.stringEncoded },
            startHeight: BlockHeight(0),
            mode: .direct
        )

        do {
            for try await transaction in stream {
                utxos.append(transaction)
            }
        } catch {
            throw ZcashError.unspentTransactionFetcherStream(error)
        }

        var refreshed: [UnspentTransactionOutputEntity] = []
        var skipped: [UnspentTransactionOutputEntity] = []

        let all = Float(utxos.count)
        var counter = Float(0)
        for utxo in utxos {
            do {
                try await rustBackend.putUnspentTransparentOutput(
                    txid: utxo.txid.bytes,
                    index: utxo.index,
                    script: utxo.script.bytes,
                    value: Int64(utxo.valueZat),
                    height: utxo.height
                )

                refreshed.append(utxo)

                counter += 1
                await didFetch(counter / all)
            } catch {
                logger.error("failed to put utxo - error: \(error)")
                skipped.append(utxo)
            }
        }

        let result = (inserted: refreshed, skipped: skipped)

        if Task.isCancelled {
            logger.debug("Warning: fetchUnspentTxOutputs cancelled")
        }

        return result
    }

    /// The direct path asks the server for every receiver of every account in one request, which
    /// hands it the whole wallet at once. Over Tor each receiver is queried on its own circuit, so
    /// no two of them can be tied together at the server. The FFI stores the UTXOs as they stream
    /// in, from the receiver's exposure height (or the account birthday when that is unknown), which
    /// is why this path has no entities to report back.
    private func fetchOverTor(
        accounts: [Account],
        didFetch: @escaping (Float) async -> Void
    ) async throws -> (inserted: [UnspentTransactionOutputEntity], skipped: [UnspentTransactionOutputEntity]) {
        var receivers: [(accountUUID: AccountUUID, address: TransparentAddress)] = []
        for account in accounts {
            for address in try await rustBackend.listTransparentReceivers(accountUUID: account.id) {
                receivers.append((accountUUID: account.id, address: address))
            }
        }

        let dbData = config.dataDb.osStr()
        let all = Float(receivers.count)
        var counter = Float(0)
        for receiver in receivers {
            try Task.checkCancellation()

            do {
                _ = try await service.fetchUTXOsByAddress(
                    address: receiver.address.stringEncoded,
                    dbData: dbData,
                    networkType: config.networkType,
                    accountUUID: receiver.accountUUID,
                    mode: ServiceMode.addressGroup(prefix: "utxo", address: receiver.address)
                )
            } catch {
                throw ZcashError.unspentTransactionFetcherStream(error)
            }

            counter += 1
            await didFetch(counter / all)
        }

        return (inserted: [], skipped: [])
    }
}
