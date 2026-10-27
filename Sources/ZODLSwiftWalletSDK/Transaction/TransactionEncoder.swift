//
//  TransactionEncoder.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 2019-11-20.
//

import Foundation

typealias TransactionEncoderResultBlock = (_ result: Result<EncodedTransaction, Error>) -> Void

public enum TransactionEncoderError: Error {
    case notFound(txId: Data)
    case notEncoded(txId: Data)
    case missingParams
    case spendingKeyWrongNetwork
    case couldNotExpand(txId: Data)
    case submitError(code: Int, message: String)
    /// The SDK did not submit the transaction because it cannot be valid in the next block: it is built for another
    /// consensus branch than the next block is under, or it has expired by then, and the refusal says which. Nothing
    /// reached the network. The next block is the one after the higher of the wallet's chain tip and the latest block
    /// height of the server the transaction was about to go to.
    case notSubmittable(TransactionSubmissionRefusal)
}

protocol TransactionEncoder {
    /// Creates a proposal for transferring funds to the given recipient.
    ///
    /// - Parameter accountUUID: the account from which to transfer funds.
    /// - Parameter recipient: string containing the recipient's address.
    /// - Parameter amount: the amount to send in Zatoshi.
    /// - Parameter memoBytes: an optional memo to include as part of the proposal's transactions. Use `nil` when sending to transparent receivers otherwise the function will throw an error.
    ///
    /// If `prepare()` hasn't already been called since creation of the synchronizer instance or since the last wipe then this method throws
    /// `SynchronizerErrors.notPrepared`.
    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: String,
        amount: Zatoshi,
        memoBytes: MemoBytes?
    ) async throws -> Proposal

    /// Creates a proposal that spends the maximum amount available in the given account to a single recipient.
    ///
    /// Unlike `proposeTransfer`, no `amount` is passed: the proposal spends as much of the account's balance as
    /// `mode` allows, with the fee already accounted for by the proposal itself.
    ///
    /// The proposal draws on shielded funds only (Sapling, Orchard, Ironwood); transparent balance is never
    /// selected and must be shielded first — see `proposeShielding`.
    ///
    /// - Parameter accountUUID: the account from which to spend funds.
    /// - Parameter recipient: string containing the recipient's address.
    /// - Parameter memoBytes: an optional memo to include as part of the proposal's transactions. Use `nil` when sending to transparent receivers otherwise the function will throw an error.
    /// - Parameter mode: how much of the account's balance the proposal should target spending. See `MaxSpendMode`.
    ///
    /// If `prepare()` hasn't already been called since creation of the synchronizer instance or since the last wipe then this method throws
    /// `SynchronizerErrors.notPrepared`.
    func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: String,
        memoBytes: MemoBytes?,
        mode: MaxSpendMode
    ) async throws -> Proposal

    /// Proposes migrating the account's entire Orchard balance into the Ironwood pool.
    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal

    /// Creates a proposal for shielding any transparent funds received by the given account.
    ///
    /// - Parameter accountUUID:the account from which to shield funds.
    /// - Parameter shieldingThreshold: the minimum transparent balance required before a proposal will be created.
    /// - Parameter memoBytes: an optional memo to include as part of the proposal's transactions.
    /// - Parameter transparentReceiver: a specific transparent receiver within the account
    ///             that should be the source of transparent funds. Default is `nil` which
    ///             will select whichever of the account's transparent receivers has funds
    ///             to shield.
    ///
    /// Returns the proposal, or `nil` if the transparent balance that would be shielded
    /// is zero or below `shieldingThreshold`.
    ///
    /// If `prepare()` hasn't already been called since creation of the synchronizer instance or since the last wipe then this method throws
    /// `SynchronizerErrors.notPrepared`.
    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memoBytes: MemoBytes?,
        transparentReceiver: String?
    ) async throws -> Proposal?

    /// Creates the transactions in the given proposal.
    ///
    /// - Parameter proposal: the proposal for which to create transactions.
    /// - Parameter spendingKey: the `UnifiedSpendingKey` associated with the account for which the proposal was created.
    /// - Parameter ovkPolicy: the outgoing viewing key the transactions' outputs are encrypted to.
    /// - Throws:
    ///     - `walletTransEncoderCreateTransactionMissingSaplingParams` if the proposal needs the sapling parameters
    ///       (see `requiresSaplingParameters(for:)`) and they aren't downloaded.
    ///     - Some `ZcashError.rust*` if the creation of transaction(s) fails.
    ///
    /// If `prepare()` hasn't already been called since creation of the synchronizer instance or since the last wipe then this method throws
    /// `SynchronizerErrors.notPrepared`.
    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        ovkPolicy: OvkPolicy
    ) async throws -> [CreatedTransaction]

    /// Whether creating the transactions of `proposal` needs the Sapling proving parameters on disk.
    ///
    /// It does only when the proposal has a Sapling input, payment, change or dummy output.
    /// - Throws: `rustProposalRequiresSaplingParams` if the proposal does not decode.
    func requiresSaplingParameters(for proposal: Proposal) throws -> Bool

    /// Returns broadcast-ready data for transactions stored by the wallet, independently of
    /// whether they are currently represented by the transaction-history view.
    ///
    /// - Parameter txIds: The transaction identifiers to read from the wallet store.
    /// - Returns: The stored transactions, in the same order as `txIds`.
    /// - Throws: `ZcashError.rustGetTransaction` when any transaction cannot be read. A throw
    ///   after transaction creation does not mean that Rust rolled back the created transactions.
    func createdTransactions(forTxIds txIds: [Data]) async throws -> [CreatedTransaction]

    /// Creates a transaction proposal to fulfill a [ZIP-321](https://zips.z.cash/zip-0321), throwing an exception whenever things are missing. When the provided wallet implementation
    /// doesn't throw an exception, we wrap the issue into a descriptive exception ourselves (rather than using
    /// double-bangs for things).
    ///
    /// - Parameters:
    /// - Parameter uri: a valid ZIP-321 payment URI.
    /// - Parameter accountUUID: the account the proposal should be made from.
    /// - Throws:
    ///     - `walletTransEncoderCreateTransactionMissingSaplingParams` if the sapling parameters aren't downloaded.
    ///     - Some `ZcashError.rust*` if the creation of transaction fails.
    func proposeFulfillingPaymentFromURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> Proposal

    /// submits a transaction to the Zcash peer-to-peer network.
    ///
    /// Nothing is submitted that cannot be valid in the next block. The next block is the one after the higher of the
    /// wallet's chain tip and the latest block height of the server the transaction goes to, which is read from the
    /// service that submits it, in the mode it submits in.
    /// - Parameter transaction: a transaction overview
    /// - Throws:
    ///     - `TransactionEncoderError.notSubmittable` if the transaction is built for another consensus branch than the
    ///       next block is under, or has expired by then. Nothing was submitted.
    ///     - `TransactionEncoderError.submitError` if the server rejects the transaction.
    ///     - `ZcashError.serviceSubmitFailed` if the server cannot be reached, which includes its height not being
    ///       readable. Nothing was submitted.
    ///     - `ZcashError.rustCheckTransactionSubmittable` if the transaction cannot be judged. Nothing was submitted.
    func submit(transaction: EncodedTransaction) async throws

    /// Asks the connected lightwalletd backend whether it has the given txid in mempool or chain.
    /// Returns `false` if the server reports `txidNotRecognized` or if the verification call itself fails.
    func isTransactionKnownToServer(txId: Data) async -> Bool

    /// Tries to fetch the transaction for the given transaction ids.
    /// - Parameter txIds: an array of transaction ids to be fetched from the DB.
    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview]

    func closeDBConnection()
}

extension LightWalletService {
    /// Why `rawTransaction` cannot be submitted through this service, or `nil` when it can be valid in the next block.
    ///
    /// The next block is judged at the higher of the wallet's chain tip and this service's own latest block height, so
    /// the height is read here, from this very service and in the very `mode` the transaction is about to be submitted
    /// in. A server other than the one that will receive the transaction, or another Tor circuit, may stand on another
    /// block. When the check cannot be made this throws, and the transaction stays unsubmitted: the check fails closed.
    /// There are two ways it cannot, and they are told apart.
    ///
    /// The height is the first request of a submission, so a read that fails is a submission that could not reach the
    /// server, and it fails the way the submit after it would have: as ``ZcashError/serviceSubmitFailed(_:)``, carrying the
    /// failure of the read. Over Tor the read throws the error of the Tor connection, where the submit wraps all of
    /// them in a generic service error, and so does this. A cancellation during the read is reported as a failed submit
    /// too, as the services' own submit reports one, not as a `CancellationError`. A caller that reports a failed submit as
    /// a failure to reach the server reports this as one too.
    ///
    /// A transaction the check cannot judge (it does not parse, or the wallet database is missing) is another thing: no
    /// retry fixes it. It fails with ``ZcashError/rustCheckTransactionSubmittable(_:)``.
    /// - Throws: `serviceSubmitFailed` for a height that cannot be read, or `rustCheckTransactionSubmittable`.
    func submissionRefusal(
        for rawTransaction: Data,
        mode: ServiceMode,
        using rustBackend: ZcashRustBackendWelding
    ) async throws -> TransactionSubmissionRefusal? {
        let serverHeight: BlockHeight
        do {
            serverHeight = try await latestBlockHeight(mode: mode)
        } catch ZcashError.serviceLatestBlockHeightFailed(let error) {
            throw ZcashError.serviceSubmitFailed(error)
        } catch {
            throw ZcashError.serviceSubmitFailed(LightWalletServiceError.genericError(error: error))
        }

        return try await rustBackend.checkTransactionSubmittable(rawTransaction, submissionServerHeight: serverHeight)
    }
}

extension TransactionEncoder {
    /// Creates the transactions in the given proposal with the default `OvkPolicy.sender`.
    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [CreatedTransaction] {
        try await createProposedTransactions(proposal: proposal, spendingKey: spendingKey, ovkPolicy: .sender)
    }

    /// Conservative default for encoders that cannot inspect a proposal: assume the Sapling
    /// parameters are needed, which is what every encoder assumed before the check existed.
    func requiresSaplingParameters(for proposal: Proposal) throws -> Bool {
        true
    }
}
