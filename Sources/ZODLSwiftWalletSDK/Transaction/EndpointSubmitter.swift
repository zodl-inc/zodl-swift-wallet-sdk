//
//  EndpointSubmitter.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Submits one transaction to one endpoint. The mock seam for offline tests.
protocol EndpointSubmitter {
    /// - Throws: `TransactionEncoderError.submitError` when the server rejects
    ///   the transaction, `TransactionEncoderError.notSubmittable` when the SDK
    ///   refuses to submit it because it cannot be valid in the block after the
    ///   endpoint's height; any other error indicates a failure to reach the
    ///   endpoint, including one to read its height.
    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws
}

/// Submits over an ephemeral gRPC connection, respecting the Tor configuration.
final class GRPCEndpointSubmitter: EndpointSubmitter {
    private let torClient: TorClient
    private let sdkFlags: SDKFlags
    private let rustBackend: ZcashRustBackendWelding
    private let logger: Logger

    init(torClient: TorClient, sdkFlags: SDKFlags, rustBackend: ZcashRustBackendWelding, logger: Logger) {
        self.torClient = torClient
        self.sdkFlags = sdkFlags
        self.rustBackend = rustBackend
        self.logger = logger
    }

    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws {
        let mode: ServiceMode
        let serviceTorClient: TorClient
        let transport: String
        if await sdkFlags.torEnabled {
            // One isolated Tor client per submission attempt: connecting
            // through the shared TorClient serializes every endpoint behind
            // one blocking FFI call on its actor, so a single stalled endpoint
            // would starve the whole multi-endpoint race.
            serviceTorClient = try await torClient.isolatedClient()
            mode = ServiceMode.txIdGroup(prefix: "submit", txId: transaction.txId)
            transport = "an isolated Tor circuit"
        } else {
            serviceTorClient = torClient
            mode = ServiceMode.direct
            transport = "a direct connection"
        }

        logger.debug(
            "Transaction \(transaction.txId.toHexStringTxId()) submitting to \(endpoint.host):\(endpoint.port) over \(transport)."
        )

        let service = LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: serviceTorClient)

        let response: LightWalletServiceResponse
        do {
            // Nothing is submitted that cannot be valid in the next block, which is the one after the higher of the wallet's chain
            // tip and the height of this endpoint. Each endpoint is judged at its own height, which is read from the service, and in
            // the mode, that is about to submit to it. A height that cannot be read fails the attempt at this endpoint, like a
            // connection that cannot be made, and so does a transaction that cannot be judged.
            if let refusal = try await service.submissionRefusal(for: transaction.raw, mode: mode, using: rustBackend) {
                logger.warn(
                    """
                    Transaction \(transaction.txId.toHexStringTxId()) is not submitted to \(endpoint.host):\(endpoint.port): \
                    \(refusal.description)
                    """
                )
                throw TransactionEncoderError.notSubmittable(refusal)
            }

            response = try await service.submit(spendTransaction: transaction.raw, mode: mode)
        } catch {
            await service.closeConnections()
            throw error
        }

        guard response.errorCode >= 0 else {
            let isKnown = await service.isTransactionKnownToServer(txId: transaction.txId, mode: mode)
            await service.closeConnections()

            if isKnown {
                logger.debug(
                    """
                    Transaction \(transaction.txId.toHexStringTxId()) submission was rejected, but the same \
                    server confirmed it is known.
                    """
                )
                return
            }

            throw TransactionEncoderError.submitError(
                code: Int(response.errorCode),
                message: response.errorMessage
            )
        }

        await service.closeConnections()
    }
}
