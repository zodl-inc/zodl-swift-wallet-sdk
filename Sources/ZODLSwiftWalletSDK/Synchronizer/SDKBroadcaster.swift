//
//  SDKBroadcaster.swift
//  ZODLSwiftWalletSDK
//

import Combine
import Foundation

final class SDKBroadcaster: Broadcaster {
    private let transactionEncoder: TransactionEncoder
    private let initializer: Initializer
    private let logger: Logger
    private let eventSubject: PassthroughSubject<SynchronizerEvent, Never>
    private let submitPlanStore: SubmitPlanStoring
    private let multiEndpointSubmitter: MultiEndpointSubmitter
    private let transactionRepository: TransactionRepository
    /// The last chain tip the synchronizer knows; `0` before it knows one.
    private let chainTip: () -> BlockHeight
    private let statusCheck: () throws -> Void

    init(
        transactionEncoder: TransactionEncoder,
        initializer: Initializer,
        logger: Logger,
        eventSubject: PassthroughSubject<SynchronizerEvent, Never>,
        submitPlanStore: SubmitPlanStoring,
        multiEndpointSubmitter: MultiEndpointSubmitter,
        transactionRepository: TransactionRepository,
        chainTip: @escaping () -> BlockHeight,
        statusCheck: @escaping () throws -> Void
    ) {
        self.transactionEncoder = transactionEncoder
        self.initializer = initializer
        self.logger = logger
        self.eventSubject = eventSubject
        self.submitPlanStore = submitPlanStore
        self.multiEndpointSubmitter = multiEndpointSubmitter
        self.transactionRepository = transactionRepository
        self.chainTip = chainTip
        self.statusCheck = statusCheck
    }

    // MARK: - Broadcaster conformance

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [CreatedTransaction] {
        try await createProposedTransactions(proposal: proposal, spendingKey: spendingKey, ovkPolicy: .sender, recordingPlans: true)
    }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        ovkPolicy: OvkPolicy
    ) async throws -> [CreatedTransaction] {
        try await createProposedTransactions(proposal: proposal, spendingKey: spendingKey, ovkPolicy: ovkPolicy, recordingPlans: true)
    }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> [CreatedTransaction] {
        try await createTransactionFromPCZT(pcztWithProofs: pcztWithProofs, pcztWithSigs: pcztWithSigs, recordingPlans: true)
    }

    func submit(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> TransactionSubmissionOutcome {
        do {
            return try await initializer.container.resolve(SDKFlags.self).routeAdmission.withLease {
                await self.submitAdmitted(transaction: transaction, to: endpoints, timing: timing)
            }
        } catch {
            // Admission refusal is still a pending submission result. Preserve the caller's
            // intended endpoints only for transactions belonging to the live wallet lifecycle.
            await releaseForResubmission(transactions: [transaction], to: endpoints)
            return .unreachable
        }
    }

    private func submitAdmitted(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> TransactionSubmissionOutcome {
        OHTTPHealthContext.attempt?.beginDelegation()
        let txId = transaction.txId.toHexStringTxId()

        guard !endpoints.isEmpty else {
            logger.debug("Transaction \(txId) submit requested with no endpoints; nothing sent, transaction stays awaiting.")
            return .unreachable
        }

        let endpointList = endpoints.map { "\($0.host):\($0.port)" }.joined(separator: ", ")
        logger.debug("Transaction \(txId) submitting to \(endpoints.count) endpoint(s): \(endpointList).")

        // Record before any network attempt so a cancelled or timed-out race
        // still leaves the intended retry plan behind. The returned token is
        // carried through the network race so a `wipe()` that lands while it
        // is in flight leaves the eventual `markAccepted` call provably stale.
        let lifecycle = await submitPlanStore.recordPlan(txId: transaction.txId, endpoints: endpoints)

        let outcome = await multiEndpointSubmitter.submit(transaction: transaction, to: endpoints, timing: timing)
        logger.debug("Transaction \(txId) submission \(outcome.logDescription).")

        // Remember which server took it, so the app can tell "handed to a
        // server" apart from "still trying" while the transaction waits to be
        // mined. Retrying continues either way — a mempool is not a commitment.
        if case .accepted(by: let endpoint) = outcome {
            await submitPlanStore.markAccepted(txId: transaction.txId, host: "\(endpoint.host):\(endpoint.port)", lifecycle: lifecycle)
        }

        return outcome
    }

    func releaseForResubmission(
        transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint]
    ) async {
        guard !endpoints.isEmpty else {
            logger.debug("Release for resubmission requested with no endpoints; transactions stay awaiting.")
            return
        }
        // `recordPlanForAwaitingTransaction`, not `recordPlan`: a release only succeeds for a
        // transaction that already has an awaiting row from this wallet lifecycle, so a release
        // landing after `wipe()` can never recreate the plan store's database file.
        var releasedCount = 0
        for transaction in transactions {
            guard await submitPlanStore.recordPlanForAwaitingTransaction(txId: transaction.txId, endpoints: endpoints) != nil else {
                logger.debug(
                    """
                    Release for resubmission dropped for \(transaction.txId.toHexStringTxId()); the transaction has \
                    no awaiting row in the current wallet lifecycle.
                    """
                )
                continue
            }
            releasedCount += 1
        }
        logger.debug("Released \(releasedCount) created transaction(s) to background resubmission.")
    }

    func submit(
        transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> [TransactionSubmissionReport] {
        OHTTPHealthContext.attempt?.beginDelegation()
        logger.debug("Batch submitting \(transactions.count) transaction(s).")
        var reports: [TransactionSubmissionReport] = []
        var stopped = false

        for transaction in transactions {
            let txId = transaction.txId.toHexStringTxId()
            if stopped {
                logger.debug("Transaction \(txId) not attempted; an earlier transaction in the batch was not accepted.")
                reports.append(TransactionSubmissionReport(txId: transaction.txId, outcome: .notAttempted))
                continue
            }

            let outcome = await submit(transaction: transaction, to: endpoints, timing: timing)
            reports.append(TransactionSubmissionReport(txId: transaction.txId, outcome: outcome))

            if case .accepted = outcome {
                continue
            }
            logger.debug("Batch stopping after \(txId) was \(outcome.logDescription); remaining marked not attempted.")
            stopped = true
        }

        return reports
    }

    // MARK: - Internal create paths (legacy callers pass recordingPlans: false)

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        ovkPolicy: OvkPolicy = .sender,
        recordingPlans: Bool
    ) async throws -> [CreatedTransaction] {
        OHTTPHealthContext.attempt?.beginDelegation()
        try statusCheck()

        // Captured before the (potentially slow) sapling-parameter download and proving work so a
        // `wipe()` that lands mid-flight leaves the eventual `markAwaitingSubmission` call provably
        // stale instead of reopening — and thereby recreating — the database `wipe()` just deleted.
        let lifecycle = await submitPlanStore.currentLifecycle()

        // A proposal without a Sapling bundle is proven without the Sapling parameters, so a wallet
        // that only spends Orchard or Ironwood funds never downloads them.
        if try transactionEncoder.requiresSaplingParameters(for: proposal) {
            try await downloadSaplingParamsIfNeeded()
        }

        let createdTransactions = try await transactionEncoder.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey,
            ovkPolicy: ovkPolicy
        )
        let overviews = await overviewsForEvent(txIds: createdTransactions.map(\.txId))

        return await finishCreation(
            createdTransactions: createdTransactions,
            overviews: overviews,
            recordingPlans: recordingPlans,
            lifecycle: lifecycle
        )
    }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt,
        recordingPlans: Bool
    ) async throws -> [CreatedTransaction] {
        OHTTPHealthContext.attempt?.beginDelegation()
        try statusCheck()

        // Captured before the (potentially slow) sapling-parameter download and PCZT extraction so
        // a `wipe()` that lands mid-flight leaves the eventual `markAwaitingSubmission` call
        // provably stale instead of reopening — and thereby recreating — the database `wipe()` just
        // deleted.
        let lifecycle = await submitPlanStore.currentLifecycle()

        try await downloadSaplingParamsIfNeeded()

        let txId = try await initializer.rustBackend.extractAndStoreTxFromPCZT(
            pcztWithProofs: pcztWithProofs,
            pcztWithSigs: pcztWithSigs
        )
        guard let createdTransaction = try await transactionEncoder.createdTransactions(forTxIds: [txId]).first else {
            throw ZcashError.rustGetTransaction(
                "Transaction \(txId.toHexStringTxId()) is unavailable in the wallet store"
            )
        }

        let overviews = await overviewsForEvent(txIds: [createdTransaction.txId])

        return await finishCreation(
            createdTransactions: [createdTransaction],
            overviews: overviews,
            recordingPlans: recordingPlans,
            lifecycle: lifecycle
        )
    }

    // MARK: - Private

    private func downloadSaplingParamsIfNeeded() async throws {
        return try await initializer.container.resolve(SDKFlags.self).routeAdmission.withLease {
            let sdkFlags = initializer.container.resolve(SDKFlags.self)
            let container = initializer.container
            try await SaplingParameterDownloader.downloadParamsIfnotPresent(
                spendURL: initializer.spendParamsURL,
                spendSourceURL: initializer.saplingParamsSourceURL.spendParamFileURL,
                outputURL: initializer.outputParamsURL,
                outputSourceURL: initializer.saplingParamsSourceURL.outputParamFileURL,
                logger: logger,
                torClientProvider: {
                    let isTorEnabled = await sdkFlags.torEnabled
                    return isTorEnabled ? container.resolve(TorClient.self) : nil
                }
            )
        }
    }

    private func overviewsForEvent(txIds: [Data]) async -> [ZcashTransaction.Overview] {
        var overviews: [ZcashTransaction.Overview] = []

        for txId in txIds {
            do {
                overviews.append(contentsOf: try await transactionEncoder.fetchTransactionsForTxIds([txId]))
            } catch {
                logger.warn(
                    """
                    Created transaction \(txId.toHexStringTxId()) could not be enriched from v_transactions; \
                    continuing with wallet-store bytes. \(error.localizedDescription)
                    """
                )
            }
        }

        return overviews
    }

    private func finishCreation(
        createdTransactions: [CreatedTransaction],
        overviews: [ZcashTransaction.Overview],
        recordingPlans: Bool,
        lifecycle: SubmitPlanLifecycle
    ) async -> [CreatedTransaction] {
        let txIdList = createdTransactions.map { $0.txId.toHexStringTxId() }.joined(separator: ", ")
        if recordingPlans {
            logger.debug("Created \(createdTransactions.count) transaction(s) awaiting submission by the app: \(txIdList).")
            await submitPlanStore.markAwaitingSubmission(txIds: createdTransactions.map(\.txId), lifecycle: lifecycle)
        } else {
            logger.debug("Created \(createdTransactions.count) transaction(s) for immediate submission: \(txIdList).")
        }

        if !overviews.isEmpty {
            eventSubject.send(.foundTransactions(overviews, nil))
        }

        return createdTransactions
    }
}

// MARK: - Unaccepted transactions after a server change

extension SDKBroadcaster {
    func resubmitUnacceptedTransactions(
        through endpoint: LightWalletEndpoint,
        timing: SubmissionTiming
    ) async -> [TransactionSubmissionReport] {
        let server = "\(endpoint.host):\(endpoint.port)"
        let candidates: [ZcashTransaction.Overview]
        do {
            // Like `submit`, no prepared synchronizer is required: a wallet database that cannot be read yet only
            // means there is nothing to list. The same selection background resubmission makes: sent, not mined,
            // not expired as of the last tip.
            // Before any tip is known that is every unmined send; the submitter refuses an expired one itself.
            candidates = try await transactionRepository.findForResubmission(upTo: chainTip())
        } catch {
            logger.warn("Unaccepted transactions could not be listed for \(server); nothing sent: \(error.localizedDescription)")
            return []
        }

        var reports: [TransactionSubmissionReport] = []
        for overview in candidates {
            // The store decides whether the transaction is stuck (submitted, not accepted) and extends its plan in
            // the same step. Its token makes an acceptance that arrives after a `wipe()` provably stale.
            guard let lifecycle = await submitPlanStore.addEndpointToUnacceptedPlan(txId: overview.rawID, endpoint: endpoint) else {
                continue
            }
            let txId = overview.rawID.toHexStringTxId()
            guard let transaction = try? CreatedTransaction(overview: overview) else {
                logger.warn("Transaction \(txId) has no raw bytes to send through \(server).")
                continue
            }
            // Each transaction on its own: one that the server does not take must not keep the next one waiting,
            // unlike a batch, whose later transactions may depend on the earlier ones.
            let outcome: TransactionSubmissionOutcome
            do {
                outcome = try await initializer.container.resolve(SDKFlags.self).routeAdmission.withLease {
                    await self.multiEndpointSubmitter.submit(transaction: transaction, to: [endpoint], timing: timing)
                }
            } catch {
                outcome = .unreachable
            }
            if case .accepted(by: let acceptingEndpoint) = outcome {
                await submitPlanStore.markAccepted(
                    txId: overview.rawID,
                    host: "\(acceptingEndpoint.host):\(acceptingEndpoint.port)",
                    lifecycle: lifecycle
                )
            }
            logger.debug("Transaction \(txId) resubmission through \(server) \(outcome.logDescription).")
            reports.append(TransactionSubmissionReport(txId: overview.rawID, outcome: outcome))
        }
        return reports
    }
}
