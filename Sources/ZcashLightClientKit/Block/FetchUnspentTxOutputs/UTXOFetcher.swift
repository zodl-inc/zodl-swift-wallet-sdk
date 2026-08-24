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
    /// Receivers looked up over Tor at the same time. Bounded so a wallet with many receivers does
    /// not open that many circuits at once, without serializing every round trip either.
    static let torConcurrency = 4

    func fetch(
        didFetch: @escaping (Float) async -> Void
    ) async throws -> (inserted: [UnspentTransactionOutputEntity], skipped: [UnspentTransactionOutputEntity]) {
        try Task.checkCancellation()

        let accounts = try await rustBackend.listAccounts()

        guard await sdkFlags.ifTor(.uniqueTor) == .direct else {
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
    ///
    /// A receiver whose lookup fails does not stop the others: it is counted, logged without naming
    /// it, and retried on the next cycle, which sweeps every receiver again. Only a sweep in which
    /// every receiver failed is reported as a failure, so a single unreachable address cannot
    /// starve the rest of the wallet of UTXO discovery.
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
        var completed = Float(0)
        var succeeded = 0
        var failed = 0
        var firstFailure: Error?

        try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            var next = 0
            while next < receivers.count && next < Self.torConcurrency {
                let receiver = receivers[next]
                group.addTask { await lookUpOverTor(receiver, dbData: dbData) }
                next += 1
            }

            for try await outcome in group {
                try Task.checkCancellation()

                switch outcome {
                case .success:
                    succeeded += 1
                case .failure(let error):
                    failed += 1
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }

                completed += 1
                await didFetch(completed / all)

                if next < receivers.count {
                    let receiver = receivers[next]
                    group.addTask { await lookUpOverTor(receiver, dbData: dbData) }
                    next += 1
                }
            }
        }

        if let firstFailure, succeeded == 0 {
            throw ZcashError.unspentTransactionFetcherStream(firstFailure)
        }

        if failed > 0 {
            logger.error("UTXO discovery over Tor skipped \(failed) of \(receivers.count) receivers; they are retried on the next sync cycle.")
        }

        return (inserted: [], skipped: [])
    }

    /// One receiver's lookup, on the circuit dedicated to its address. The mode is resolved per
    /// receiver so a Tor toggle during the sweep is honoured: a receiver whose mode resolves to
    /// direct is not fetched in the clear, it fails like any other lookup. The service's
    /// `.torRequired` answer means it has no Tor connection to offer, which is a failure here and
    /// never a silent no-op.
    private func lookUpOverTor(
        _ receiver: (accountUUID: AccountUUID, address: TransparentAddress),
        dbData: (String, UInt)
    ) async -> Result<Void, Error> {
        do {
            let mode = await sdkFlags.ifTor(ServiceMode.addressGroup(prefix: "utxo", address: receiver.address))

            guard mode != .direct else {
                throw ZcashError.torNotEnabled
            }

            let result = try await service.fetchUTXOsByAddress(
                address: receiver.address.stringEncoded,
                dbData: dbData,
                networkType: config.networkType,
                accountUUID: receiver.accountUUID,
                mode: mode
            )

            guard result != .torRequired else {
                throw ZcashError.serviceTorRequired
            }

            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
