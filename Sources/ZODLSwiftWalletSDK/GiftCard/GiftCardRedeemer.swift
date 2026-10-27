//
//  GiftCardRedeemer.swift
//  ZODLSwiftWalletSDK
//

import Combine
import Foundation

/// What ``GiftCardRedeemer/check()`` found on chain for a gift card.
public struct GiftCardStatus: Equatable {
    /// What the card can do right now.
    public enum State: Equatable {
        /// The card has funds that can be redeemed now: ``GiftCardStatus/spendable`` is more than
        /// the fee of the transaction that sweeps it. ``GiftCardStatus/fee`` and
        /// ``GiftCardStatus/redeemable`` say what a redemption pays and sends.
        case ready
        /// The card has funds, but not enough of them are spendable yet: they are waiting for
        /// confirmations.
        ///
        /// Card funds come from another wallet, so they are untrusted in the sense of
        /// [ZIP 315](https://zips.z.cash/zip-0315) and need 10 confirmations (roughly 12 minutes at
        /// 75-second blocks, 4 minutes from NU7) before they can be spent. Call
        /// ``GiftCardRedeemer/check()`` again later.
        case pending
        /// The card's spendable funds do not exceed the fee of the transaction that would sweep
        /// them, and nothing else is on its way: redeeming it would leave nothing for the
        /// recipient. ``GiftCardRedeemer/redeem(to:memo:recordIn:)`` throws
        /// ``ZcashError/giftCardNothingToRedeem`` for it.
        case dust
        /// The card holds nothing: it was already redeemed, or it was never funded (or its funding
        /// transaction is not mined yet, or `birthdayHeight` is past it).
        case empty
    }

    /// What sweeping the card's spendable funds would pay and send, as librustzcash proposes it.
    struct Sweep: Equatable {
        /// The fee of the transaction (or transactions) that sweep the card.
        let fee: Zatoshi
        /// What the recipient receives: the value the sweep spends, minus `fee`.
        let amount: Zatoshi

        /// The fee and the amount of a send-max `proposal`.
        init(proposal: Proposal) {
            self.init(fee: proposal.totalFeeRequired(), amount: proposal.totalSpendValue() - proposal.totalFeeRequired())
        }

        init(fee: Zatoshi, amount: Zatoshi) {
            self.fee = fee
            self.amount = amount
        }
    }

    /// What the card can do right now.
    public let state: State
    /// Every shielded value the card wallet holds, spendable or not.
    public let total: Zatoshi
    /// The value that ``GiftCardRedeemer/redeem(to:)`` can sweep now, before the fee.
    public let spendable: Zatoshi
    /// The value still waiting for confirmations: `total - spendable`.
    public let pending: Zatoshi
    /// The preview fee for an Orchard-capable recipient, as librustzcash proposes it for the
    /// current spendable notes and chain height (ZIP 317: potentially more than the 10,000 zatoshi
    /// minimum). Later note or chain changes can change the actual redemption's fee and amount.
    /// Set only when ``state`` is ``State/ready``; `nil` otherwise.
    public let fee: Zatoshi?
    /// The preview amount for an Orchard-capable recipient: the value the current proposal spends
    /// minus ``fee``. Show this before redeeming, then use ``GiftCardRedeemer/Redemption/amount``
    /// for the actual proposal's result. Non-zero only when ``state`` is ``State/ready``;
    /// `.zero` otherwise.
    public let redeemable: Zatoshi

    /// - Parameters:
    ///   - balance: the card account's balance, if the account has one.
    ///   - sweep: what sweeping the spendable funds would pay and send, or `nil` when nothing is
    ///     spendable or the fee would take all of it.
    init(balance: AccountBalance?, sweep: Sweep?) {
        let total = balance?.shieldedTotal() ?? .zero
        let spendable = balance?.shieldedSpendableValue ?? .zero
        self.total = total
        self.spendable = spendable
        self.pending = total - spendable
        if spendable > .zero, let sweep, sweep.amount > .zero {
            state = .ready
            fee = sweep.fee
            redeemable = sweep.amount
        } else {
            fee = nil
            redeemable = .zero
            if pending > .zero {
                state = .pending
            } else if spendable > .zero {
                state = .dust
            } else {
                state = .empty
            }
        }
    }
}

/// Redeems a ``GiftCard`` into the user's own wallet through a temporary, isolated wallet.
///
/// The flow is three calls:
///
/// 1. ``check()`` creates the card wallet from the card's seed and birthday, syncs it, and reports
///    what it holds (``GiftCardStatus``): ready, pending confirmations, dust (less than the fee),
///    or empty. A ready card comes with the current proposal's preview fee and amount for an
///    Orchard-capable recipient (``GiftCardStatus/fee``, ``GiftCardStatus/redeemable``).
///    Later note or chain changes can change the actual redemption's result.
/// 2. ``redeem(to:memo:recordIn:)`` sends the card's entire spendable balance, minus the fee, to
///    the given unified address, which must have an Orchard receiver and may have other receivers.
///    The transaction discards the outgoing viewing key (``OvkPolicy/discard``): the card's key —
///    which its issuer can rederive — cannot reveal where the funds went. Sapling parameters are
///    unnecessary only when the actual proposal has no Sapling inputs or outputs. Given the user's
///    own synchronizer as the destination, the claim is recorded there at once as a trusted transaction (ZIP 315), so the main wallet shows it immediately
///    and can spend it after the default three confirmations. The issuer and anyone holding the
///    link share the card's spending key, so a competing spend during a reorg remains a risk;
///    see `docs/GIFT_CARDS.md`.
/// 3. ``cleanup()`` stops the card wallet and deletes every file it created.
///
/// ### Isolation and lifecycle
///
/// The card wallet is a `SlipstreamSynchronizer` of its own, with a custom alias derived from a hash of
/// the card's funding address (never `.default`) and all of its files in a directory of its own
/// under `storageDirectory`. It runs alongside the app's main synchronizer without touching its
/// data. Exchange-rate fetching is off for the card wallet. Tor follows `isTorEnabled`: pass the
/// main wallet's setting, so that a user who chose Tor does not reveal their IP address together
/// with identifying requests for the card's birthday, sync metadata and claim. Bulk block fetching
/// stays direct even when Tor is enabled. Protected requests never fall back to direct.
///
/// The card wallet uses the SDK's transfer confirmation policy (ZIP 315): 3 confirmations for
/// trusted notes and 10 for untrusted ones. Every note on a card comes from another wallet, so
/// it needs 10.
///
/// - The SDK does not stop two synchronizers from sharing an alias, so this type does: only one
///   redeemer or owned teardown per card may be active in the process at a time. Creating a second one throws
///   ``ZcashError/giftCardRedeemerAlreadyActive`` until safe cleanup finishes.
/// - Calls on one redeemer are serialized in the order they are made; a ``redeem(to:)`` issued
///   while ``check()`` is syncing runs after it.
/// - Swift wallet-database calls share the SDK's global executor. Both sync engines also consume
///   CPU and I/O, so checking a card can slow the main wallet's sync.
/// - ``check()`` waits for the card wallet to be up to date. The wallet keeps syncing in the
///   background afterwards, so calling ``check()`` again (for instance while funds are pending)
///   reports the latest balance without waiting for a new sync. Each caller waits at most 600
///   seconds, including queueing and preparation. Cancellation or timeout stops only that caller's
///   wait. The wallet and unfinished work remain owned until they drain and cleanup succeeds.
/// - ``cleanup()`` is always safe for the funds: the card's key is in the link, not in the
///   temporary wallet. Unredeemed funds stay on the card and a new redeemer can sweep them.
/// - Releasing a used redeemer, or one with cleanup requested, retains process ownership until
///   teardown succeeds. A crash or the
///   app being killed can leave files behind. They hold the
///   card's keys and the claim's recipient, so call ``removeLeftoverWallets(in:)`` at launch.
///   During asynchronous teardown after release, leftover cleanup leaves that wallet protected.
/// - After a redeem whose submission failed, the card wallet considers the notes spent until the
///   transaction expires, so a second ``redeem(to:)`` on the same redeemer finds nothing to
///   spend. Clean up and create a new redeemer to retry; the notes are spent at most once on
///   chain either way.
public actor GiftCardRedeemer {
    /// The outcome of ``redeem(to:memo:recordIn:)``.
    public struct Redemption: Equatable {
        /// The submission result of each created transaction (usually one). A `.success` means a
        /// server accepted it; the funds arrive once it is mined.
        public let results: [TransactionSubmitResult]
        /// Whether every accepted claim transaction was stored in the destination wallet and marked
        /// as trusted. `false` when no destination was given, when no transaction was accepted,
        /// or when the destination failed to record one (including when the claim does
        /// not involve its wallet, so it stored nothing). The redemption itself is unaffected.
        /// When the claim pays this wallet and trust was never recorded, normal sync can discover
        /// it as an ordinary untrusted receive. An unrelated destination does not receive the claim.
        public let recordedInDestination: Bool
        /// The fee the redemption paid, deducted from the card's balance.
        public let fee: Zatoshi
        /// What the redemption sends to the recipient: the value of the notes it spends, minus
        /// ``fee``, as its proposal computes it.
        public let amount: Zatoshi
    }

    /// The card being redeemed.
    public let card: GiftCard

    /// The synchronizer alias of the card wallet. It identifies the card, not its key; it is safe
    /// to log.
    public nonisolated let alias: ZcashSynchronizerAlias

    private let owner: UUID
    private let network: ZcashNetwork
    private let rootDirectory: URL
    private let initializer: Initializer
    private let checkpointSource: GiftCardCheckpointSource
    private let synchronizer: SlipstreamSynchronizer
    private var accountUUID: AccountUUID?
    private let cleanupTiming: GiftCardCleanupTiming
    nonisolated let checkTiming: GiftCardCleanupTiming
    nonisolated let checkPolicy: GiftCardCheckPolicy
    private let cleanupCoordinator: GiftCardCleanupCoordinator
    private var isCleanedUp = false
    private var hasUsedWallet = false
    private var operations: [UUID: GiftCardOperationAdmission] = [:]
    private var tail: Task<Void, Never>?

    /// Creates a redeemer for `card`. Nothing touches the disk or the network until ``check()``.
    ///
    /// - Parameters:
    ///   - card: the card to redeem.
    ///   - network: the app's network. It must be the card's network.
    ///   - endpoint: the lightwalletd server the card wallet syncs from and submits to.
    ///   - isTorEnabled: whether identifying requests (birthday/restore metadata, sync metadata
    ///     and claim submission) use Tor. Slipstream bulk blocks stay direct. Protected failures
    ///     never fall back to direct. Pass the main wallet's setting.
    ///   - storageDirectory: the directory under which the card wallet's own directory is created.
    ///     The app's caches or temporary directory is fine: everything in it is deleted by
    ///     ``cleanup()``, and losing it never loses funds.
    ///   - loggingPolicy: logging for the card wallet. Defaults to `.noLogging`, so that the
    ///     transaction linking the card to the user's address does not end up in shared logs.
    /// - Throws: ``ZcashError/giftCardNetworkMismatch`` when the card is for another network, and
    ///   ``ZcashError/giftCardRedeemerAlreadyActive`` when another redeemer for the same card is
    ///   still alive.
    public init(
        card: GiftCard,
        network: ZcashNetwork,
        endpoint: LightWalletEndpoint,
        isTorEnabled: Bool,
        storageDirectory: URL = GiftCardRedeemer.defaultStorageDirectory,
        loggingPolicy: Initializer.LoggingPolicy = .noLogging
    ) throws {
        try self.init(
            card: card,
            network: network,
            endpoint: endpoint,
            isTorEnabled: isTorEnabled,
            storageDirectory: storageDirectory,
            loggingPolicy: loggingPolicy,
            container: DIContainer(),
            makeSynchronizer: { SlipstreamSynchronizer(initializer: $0) },
            saplingParamsSourceURL: .default
        )
    }

    init(
        card: GiftCard,
        network: ZcashNetwork,
        endpoint: LightWalletEndpoint,
        isTorEnabled: Bool,
        storageDirectory: URL,
        loggingPolicy: Initializer.LoggingPolicy,
        container: DIContainer,
        makeSynchronizer: (Initializer) -> SlipstreamSynchronizer,
        cleanupTiming: GiftCardCleanupTiming = .live,
        checkTiming: GiftCardCleanupTiming = .live,
        checkPolicy: GiftCardCheckPolicy? = nil,
        saplingParamsSourceURL: SaplingParamsSourceURL
    ) throws {
        guard card.network == network.networkType else {
            throw ZcashError.giftCardNetworkMismatch
        }

        let alias = card.synchronizerAlias
        let owner = UUID()
        guard GiftCardRedeemerRegistry.claim(alias, owner: owner) else {
            throw ZcashError.giftCardRedeemerAlreadyActive
        }

        // Every file of the card wallet lives under one directory of its own. The custom alias
        // already prefixes each path's last component, but `wipe()` deletes only the data database
        // and the block cache: the SQLite -wal/-shm files, the aliased Sapling parameter copies,
        // the Tor directory and the general storage (submit plans) would all outlive it. Deleting
        // this directory in `cleanup()` removes them all at once.
        let rootDirectory = storageDirectory.appendingPathComponent(alias.description, isDirectory: true)

        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: rootDirectory.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: rootDirectory.appendingPathComponent("general_storage", isDirectory: true),
            dataDbURL: rootDirectory.appendingPathComponent("data.db"),
            torDirURL: rootDirectory.appendingPathComponent("tor", isDirectory: true),
            endpoint: endpoint,
            network: network,
            spendParamsURL: rootDirectory.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: rootDirectory.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: saplingParamsSourceURL,
            alias: alias,
            loggingPolicy: loggingPolicy,
            isTorEnabled: isTorEnabled,
            isExchangeRateEnabled: false
        )

        // The card wallet's birthday is the exact height in the link, not the nearest bundled
        // checkpoint below it (see `GiftCardCheckpointSource`); `prepareIfNeeded()` fetches it.
        let checkpointSource = GiftCardCheckpointSource(bundled: initializer.container.resolve(CheckpointSource.self))
        initializer.container.register(type: CheckpointSource.self, isSingleton: true) { _ in checkpointSource }

        self.card = card
        self.alias = alias
        self.owner = owner
        self.network = network
        self.rootDirectory = rootDirectory
        self.initializer = initializer
        self.checkpointSource = checkpointSource
        let synchronizer = makeSynchronizer(initializer)
        self.synchronizer = synchronizer
        self.cleanupTiming = cleanupTiming
        self.checkTiming = checkTiming
        self.checkPolicy = checkPolicy ?? GiftCardCheckPolicy.live(isTorEnabled: isTorEnabled)
        self.cleanupCoordinator = GiftCardCleanupCoordinator(
            timing: cleanupTiming,
            wipe: {
                try await Self.awaitCompletion(of: synchronizer.wipe())
                // The transaction encoder retains grouped service connections after the
                // Slipstream engine stops. Dispose them while the card's Tor root still exists.
                await initializer.lightWalletService.closeConnections()
                // This host runtime is separate from the engine's Tor directory. Closing an
                // existing client never creates a runtime or sends traffic.
                try await initializer.container.resolve(TorClient.self).close()
            },
            removeRoot: {
                do {
                    try FileManager.default.removeItem(at: rootDirectory)
                } catch let error as NSError {
                    // fileExists cannot distinguish an absent root from an inaccessible one.
                    // Only an actual ENOENT permits ownership release without a deletion.
                    guard error.domain == NSCocoaErrorDomain,
                          error.code == NSFileNoSuchFileError,
                          let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                          underlying.domain == NSPOSIXErrorDomain,
                          underlying.code == Int(POSIXErrorCode.ENOENT.rawValue) else {
                        throw error
                    }
                }
            },
            didFinish: { GiftCardRedeemerRegistry.release(alias, owner: owner) }
        )
    }

    deinit {
        if hasUsedWallet || isCleanedUp {
            if GiftCardRedeemerRegistry.retainCleanup(alias: alias, owner: owner, coordinator: cleanupCoordinator) {
                cleanupCoordinator.requestCleanup(after: tail)
            }
        } else {
            GiftCardRedeemerRegistry.release(alias, owner: owner)
        }
    }

    /// Creates (on first use) and syncs the card wallet, then reports what the card holds.
    ///
    /// The first call restores the card wallet from the card's birthday, which downloads and scans
    /// the blocks since then. A balance is accepted only from an up-to-date snapshot with a known
    /// positive chain tip, complete scan coverage through that tip, and the card account present.
    /// Funded balances return immediately. Zero must remain coherent for 15 seconds direct or
    /// 30 seconds with Tor; syncing, lost coverage, a missing account or a changed tip resets it.
    /// A disconnected wallet may recover for 60 seconds direct or 120 seconds with Tor. A terminal
    /// sync stall fails the check. These failures leave the balance unknown. A later explicit
    /// check restarts a pass whose stall recovery gave up, with a fresh recovery budget.
    /// Repeated checks reuse healthy syncing or up-to-date passes.
    /// The caller has a 600-second monotonic budget from method entry, including queued time and
    /// preparation. Cancellation or
    /// expiry requests cancellation of unfinished work and returns without waiting for that work
    /// to drain. Cleanup still joins it before wiping or releasing the card's alias.
    /// A timeout, disconnect or terminal stall does not mean the card is empty or cleanup has completed.
    ///
    /// When the card has spendable funds, this also proposes, without creating anything, the
    /// transaction that would sweep them, so that the fee their notes require decides: when it
    /// takes everything, the state is ``GiftCardStatus/State/dust`` rather than
    /// ``GiftCardStatus/State/ready``; otherwise the status reports that fee and the amount the
    /// sweep sends (``GiftCardStatus/fee``, ``GiftCardStatus/redeemable``). The preview uses the
    /// card's own Orchard-only address for the Orchard-capable recipient class accepted by
    /// ``redeem(to:memo:recordIn:)``. It reflects the current notes and chain height, so later
    /// note or chain changes can change the actual proposal's fee and amount.
    ///
    /// - Returns: the card's balance and whether it can be redeemed now.
    /// - Throws: the sync error if the card wallet cannot sync (for instance, the server is
    ///   unreachable), `CancellationError` if the calling task is cancelled,
    ///   ``ZcashError/giftCardCheckTimedOut`` if the caller's budget expires,
    ///   ``ZcashError/giftCardCheckDisconnected`` after continuous disconnect grace expires,
    ///   ``ZcashError/giftCardCheckSyncStalled`` when host recovery gives up, and
    ///   ``ZcashError/giftCardRedeemerCleanedUp`` after ``cleanup()``.
    public nonisolated func check() async throws -> GiftCardStatus {
        // Timestamp before the actor hop, so queueing and preparation consume the same budget.
        let operation = GiftCardCheckOperation(admittedAt: checkTiming.now(), policy: checkPolicy, timing: checkTiming)
        return try await operation.value {
            try operation.requireActive()
            return try await self.serialized { redeemer, _ in
                try operation.requireActive()
                return try await redeemer.performCheck(operation: operation)
            }
        }
    }

    /// Sends the card's entire spendable balance, minus the fee, to the Orchard-capable unified
    /// address `recipient`, without recording the claim anywhere else. See ``redeem(to:memo:recordIn:)``.
    ///
    /// - Returns: the submission result of each created transaction (usually one). A
    ///   `.success` means a server accepted it; the funds arrive once it is mined.
    public func redeem(to recipient: UnifiedAddress, memo: Memo? = nil) async throws -> [TransactionSubmitResult] {
        try await redeem(to: recipient, memo: memo, recordIn: nil).results
    }

    /// Sends the card's entire spendable balance, minus the fee, to `recipient`, and records the
    /// claim in `destination` as a trusted transaction.
    ///
    /// The transaction discards the outgoing viewing key, so the card's key cannot reveal the
    /// recipient or the amount. The recipient must have an Orchard receiver and may also have
    /// Sapling or transparent receivers. Input selection is unchanged: Sapling parameters may
    /// still be needed if the actual proposal contains Sapling inputs or outputs. Only spendable
    /// funds are swept; value still waiting for confirmations stays on the card.
    ///
    /// When `destination` is given, every accepted claim transaction is stored in it once the
    /// submission is over, and marked as trusted under [ZIP 315](https://zips.z.cash/zip-0315):
    /// the wallet shows the receive at once, and its funds become spendable after the default
    /// three confirmations. The card's externally funded notes still need ten confirmations.
    /// Its issuer and anyone holding the link share the spending key, so constructing the claim
    /// here does not establish exclusive control over its inputs. A competing spend could replace
    /// the claim during a reorg after three to nine confirmations, including after the gift was
    /// spent from. This is the accepted tradeoff for faster spendability.
    ///
    /// Recording works while `destination` is stopped. A failure to record never fails the
    /// redemption: it is logged and reported through ``Redemption/recordedInDestination``.
    /// When the claim pays this wallet, normal sync can discover it as an ordinary untrusted
    /// receive if trust was never recorded. An unrelated destination does not receive the claim.
    ///
    /// - Parameters:
    ///   - recipient: the user's own unified address, on the card's network, with an Orchard receiver.
    ///   - memo: an optional memo for the claim transaction.
    ///   - destination: the synchronizer of the wallet `recipient` belongs to, or `nil` to record
    ///     the claim nowhere. Only the SDK's own synchronizers (`SDKSynchronizer`,
    ///     `SlipstreamSynchronizer`) can record it; with any other conformer the claim is not
    ///     recorded and ``Redemption/recordedInDestination`` is `false`.
    /// - Returns: the submission results, actual proposal-derived fee and amount, and whether the
    ///   destination recorded the claim. Later note or chain changes can make these amounts differ
    ///   from the earlier ``check()`` preview.
    /// - Throws: ``ZcashError/giftCardRedeemerNotReady`` before ``check()`` has prepared the
    ///   card wallet, ``ZcashError/giftCardNothingToRedeem`` when nothing is spendable or the fee
    ///   would take everything (``GiftCardStatus/State/dust``),
    ///   ``ZcashError/giftCardNetworkMismatch`` for an address on another network,
    ///   ``ZcashError/giftCardRecipientRequiresOrchard`` for a unified address without an Orchard
    ///   receiver, and the proposal and creation errors of `Synchronizer.proposeSendMax(accountUUID:recipient:memo:mode:)`
    ///   and `Synchronizer.createProposedTransactions(proposal:spendingKey:ovkPolicy:)`. The
    ///   destination's errors are never thrown. Empty completion throws
    ///   ``ZcashError/giftCardRedemptionIncomplete``.
    ///
    /// Cancellation prevents creation until final native admission on the wallet database executor.
    /// After admission, this call owns creation, submission and accepted receipt recording through
    /// completion, even when the caller cancels. Cleanup joins that work before deleting the wallet.
    /// A later stream error is rethrown after accepted receipts are attempted in the destination.
    public func redeem(to recipient: UnifiedAddress, memo: Memo?, recordIn destination: Synchronizer?) async throws -> Redemption {
        try await serialized { redeemer, admission in
            try await redeemer.performRedeem(to: recipient, memo: memo, recordIn: destination, admission: admission)
        }
    }

    /// Closes new work admission, joins earlier work, safely wipes the wallet and deletes its
    /// root directory. Success means another redeemer can claim the card. Repeated calls join
    /// the same owned teardown and do nothing once it has succeeded.
    ///
    /// Each caller has a 30-second monotonic budget starting at admission, including queued time.
    /// Cancellation or timeout detaches only that caller; cleanup continues with the alias owned.
    /// Wipe or storage failure keeps ownership and retries teardown with capped exponential delay.
    ///
    /// - Throws: `CancellationError` when this caller is cancelled,
    ///   ``ZcashError/giftCardCleanupTimedOut`` when its budget expires, or the wipe/storage error.
    public func cleanup() async throws {
        let admittedAt = cleanupTiming.now()
        isCleanedUp = true
        accountUUID = nil
        // Close admission and transfer ownership even for an already-cancelled caller.
        for admission in operations.values { admission.requestCancellation() }
        _ = GiftCardRedeemerRegistry.retainCleanup(alias: alias, owner: owner, coordinator: cleanupCoordinator)
        do {
            try await cleanupCoordinator.cleanup(after: tail, admittedAt: admittedAt)
        } catch GiftCardCleanupWaitError.timedOut {
            throw ZcashError.giftCardCleanupTimedOut
        }
    }

    // MARK: - Private

    /// Serializes work while retaining its cancellation admission separately from teardown.
    private func serialized<T>(
        _ operation: @escaping (GiftCardRedeemer, GiftCardOperationAdmission) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !isCleanedUp else { throw ZcashError.giftCardRedeemerCleanedUp }
        let previous = tail
        let id = UUID()
        let admission = GiftCardOperationAdmission()
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation(self, admission)
        }
        admission.installCancellation { task.cancel() }
        operations[id] = admission
        tail = Task { _ = try? await task.value }
        defer { operations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            admission.requestCancellation()
        }
    }

    private func performCheck(operation: GiftCardCheckOperation) async throws -> GiftCardStatus {
        guard !isCleanedUp else {
            throw ZcashError.giftCardRedeemerCleanedUp
        }

        let accountUUID = try await prepareIfNeeded(operation: operation)
        try operation.requireActive()

        let waiter = GiftCardCheckStateWaiter(accountUUID: accountUUID, policy: checkPolicy, timing: checkTiming)
        let balance = try await waiter.wait(
            stateStream: synchronizer.stateStream,
            eventStream: synchronizer.eventStream,
            shouldStart: { await self.synchronizer.shouldStartForGiftCardCheck() },
            start: {
                try operation.requireActive()
                try await self.synchronizer.start(retry: true)
                try operation.requireActive()
            }
        )
        try operation.requireActive()
        var sweep: GiftCardStatus.Sweep?
        if balance.shieldedSpendableValue > .zero {
            sweep = try await proposedSweep(accountUUID: accountUUID)
        }
        return GiftCardStatus(balance: balance, sweep: sweep)
    }

    private func performRedeem(
        to recipient: UnifiedAddress,
        memo: Memo?,
        recordIn destination: Synchronizer?,
        admission: GiftCardOperationAdmission
    ) async throws -> Redemption {
        guard !isCleanedUp else {
            throw ZcashError.giftCardRedeemerCleanedUp
        }
        guard let accountUUID else {
            throw ZcashError.giftCardRedeemerNotReady
        }
        guard recipient.networkType == card.network else {
            throw ZcashError.giftCardNetworkMismatch
        }
        guard try recipient.availableReceiverTypecodes().contains(.orchard) else {
            throw ZcashError.giftCardRecipientRequiresOrchard
        }

        let balances = try await synchronizer.getAccountsBalances()
        guard let spendable = balances[accountUUID]?.shieldedSpendableValue, spendable > .zero else {
            throw ZcashError.giftCardNothingToRedeem
        }

        let proposal: Proposal
        do {
            proposal = try await synchronizer.proposeSendMax(
                accountUUID: accountUUID,
                recipient: .unified(recipient),
                memo: memo,
                mode: .maxSpendable
            )
        } catch ZcashError.rustProposalInsufficientFunds {
            // The fee would take everything: a dust card.
            throw ZcashError.giftCardNothingToRedeem
        }
        let tool = DerivationTool(networkType: card.network)
        let spendingKey = try card.seed.withBytes { seed in
            try tool.deriveUnifiedSpendingKey(seed: seed, accountIndex: Zip32AccountIndex(0))
        }

        // Preparatory awaits may ignore cancellation. Check before creation can store a claim.
        try Task.checkCancellation()
        let creationAdmission = GiftCardTransactionCreationAdmission()
        // Replacement forwards cancellation already requested during preparation or handoff.
        admission.installCancellation { creationAdmission.cancelBeforeCreation() }
        return try await withTaskCancellationHandler {
            let completion = Task {
                try await GiftCardTransactionCreationContext.$admission.withValue(creationAdmission) {
                    try await self.completeRedemption(proposal: proposal, spendingKey: spendingKey, recordIn: destination)
                }
            }
            // This task owns creation, submission and recording. Caller cancellation only closes
            // native admission, and the serialized queue joins completion before teardown.
            return try await completion.value
        } onCancel: {
            creationAdmission.cancelBeforeCreation()
        }
    }

    private func completeRedemption(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        recordIn destination: Synchronizer?
    ) async throws -> Redemption {
        let stream = try await synchronizer.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey,
            ovkPolicy: .discard
        )

        var results: [TransactionSubmitResult] = []
        var streamError: Error?
        do {
            for try await result in stream {
                results.append(result)
            }
        } catch {
            // Accepted receipts still belong in the destination even if a later iteration fails.
            streamError = error
        }

        var recorded = false
        if let destination {
            if let recorder = destination as? TrustedTransactionRecording {
                let cardWallet = initializer.rustBackend
                recorded = await Self.record(
                    results,
                    in: recorder,
                    rawTransaction: { txId in try await cardWallet.getTransaction(txId: txId)?.raw },
                    logger: initializer.logger
                )
            } else {
                initializer.logger.warn(
                    "Gift card: the destination cannot record incoming transactions; it will learn about the claim from the chain"
                )
            }
        }
        if let streamError { throw streamError }
        guard !results.isEmpty else { throw ZcashError.giftCardRedemptionIncomplete }
        let sweep = GiftCardStatus.Sweep(proposal: proposal)
        return Redemption(results: results, recordedInDestination: recorded, fee: sweep.fee, amount: sweep.amount)
    }

    /// Prepares the card wallet from the card's seed and birthday on first use, and returns the
    /// card account.
    private func prepareIfNeeded(operation: GiftCardCheckOperation) async throws -> AccountUUID {
        if let accountUUID {
            return accountUUID
        }

        hasUsedWallet = true

        // A wallet left behind by an earlier redeemer for this card (a crash, a killed app) is
        // never reused: it may have been created from an older checkpoint, or hold a half-done
        // claim. Rebuilding one from the card's birthday costs seconds, so start clean.
        try? FileManager.default.removeItem(at: rootDirectory)

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // The directory holds a wallet database for a key that is also in the link; it has no
        // business in a device backup. It is created before the birthday fetch, which may start
        // the card wallet's Tor client in it.
        var directory = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        await fetchExactBirthday()
        try operation.requireActive()

        let synchronizer = self.synchronizer
        let birthday = card.birthdayHeight
        _ = try await card.seed.withBytesAsync { seed in
            try await synchronizer.prepare(
                with: seed,
                walletBirthday: birthday,
                name: "Gift card",
                keySource: nil
            )
        }

        guard let account = try await synchronizer.listAccounts().first else {
            throw ZcashError.giftCardRedeemerNotReady
        }
        // Native preparation can finish after caller cancellation. Retain its account before
        // checking cancellation, so a later check cannot delete this already prepared wallet.
        accountUUID = account.id
        try Task.checkCancellation()
        return account.id
    }
}

private extension GiftCardRedeemer {
    /// Fetches the server's tree state for the block before the card's birthday, so the card
    /// wallet scans from the birthday itself. A fetch failure, or a state for another height,
    /// leaves the bundled checkpoint in place: slower, never wrong. The fetch goes over Tor when
    /// the card wallet uses it.
    func fetchExactBirthday() async {
        // The rust parser guarantees a birthday at or above NU5 activation, so `- 1` is a block.
        let height = card.birthdayHeight - 1
        do {
            let sdkFlags = initializer.container.resolve(SDKFlags.self)
            let treeState = try await initializer.lightWalletService.getTreeState(
                BlockID(height: UInt64(height)),
                mode: await sdkFlags.ifTor(.uniqueTor)
            )
            if !checkpointSource.use(treeState, forBirthday: card.birthdayHeight) {
                initializer.logger.warn("Gift card: the server sent a tree state for another height; using the bundled checkpoint")
            }
        } catch {
            initializer.logger.warn("Gift card: tree state for the birthday unavailable, using the bundled checkpoint")
        }
    }
}

// MARK: - Leftover card wallets

public extension GiftCardRedeemer {
    /// The directory card wallets are created under unless the app chooses another one.
    static let defaultStorageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZcashGiftCards", isDirectory: true)

    /// Deletes card wallets left in `storageDirectory` by a crash or the app being killed.
    ///
    /// A leftover card wallet holds the card's keys, its notes and the claim transaction with its
    /// recipient, so call this when the app starts. It skips every wallet with an active redeemer
    /// or retained teardown in this process, and anything that is not a card wallet.
    /// Losing a card wallet never loses funds: the card's key is in its link.
    ///
    /// - Parameter storageDirectory: the directory passed to ``init(card:network:endpoint:isTorEnabled:storageDirectory:loggingPolicy:)``.
    /// - Returns: the number of card wallets deleted.
    /// - Throws: the first error from deleting a card wallet; the others are still attempted.
    @discardableResult
    static func removeLeftoverWallets(in storageDirectory: URL = GiftCardRedeemer.defaultStorageDirectory) throws -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: storageDirectory.path) else {
            return 0
        }
        let prefix = ZcashSynchronizerAlias.custom(GiftCard.aliasPrefix).description

        // The registry stays locked while deleting, so that no redeemer for one of these cards
        // can be created, and start writing its wallet, between the check and the deletion.
        return try GiftCardRedeemerRegistry.withActiveAliases { active in
            let activeNames = Set(active.map(\.description))
            var removed = 0
            var firstError: Error?
            for name in names where name.hasPrefix(prefix) && !activeNames.contains(name) {
                do {
                    try fileManager.removeItem(at: storageDirectory.appendingPathComponent(name, isDirectory: true))
                    removed += 1
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
            return removed
        }
    }
}

// MARK: - Helpers

extension GiftCardRedeemer {
    func cardWalletSynchronizer() -> Synchronizer { synchronizer }

    /// The confirmation policy the card wallet spends with: the backend's transfer policy, 3
    /// confirmations for trusted notes and 10 for untrusted ones (ZIP 315). Card notes are
    /// untrusted, so they need 10. Internal, so that a test pins it.
    func cardWalletConfirmationsPolicy() -> ConfirmationsPolicy? {
        (initializer.rustBackend as? ZcashRustBackend)?.confirmationsPolicy
    }

    /// What sweeping the card's spendable funds would pay and send, or `nil` when the fee would
    /// take everything.
    ///
    /// librustzcash computes both: a send-max proposal (never turned into a transaction) to the
    /// card's own Orchard-only address, for the Orchard-capable recipient class redemption accepts.
    /// This is a snapshot of the current notes and chain height, not a reservation of the later
    /// redemption's inputs or fee. It fails with insufficient funds when the fee takes everything.
    private func proposedSweep(accountUUID: AccountUUID) async throws -> GiftCardStatus.Sweep? {
        do {
            let proposal = try await synchronizer.proposeSendMax(
                accountUUID: accountUUID,
                recipient: .unified(card.fundingAddress),
                memo: nil,
                mode: .maxSpendable
            )
            return GiftCardStatus.Sweep(proposal: proposal)
        } catch ZcashError.rustProposalInsufficientFunds {
            return nil
        }
    }

    /// Hands every accepted transaction in `results` to `destination` as a trusted receive.
    ///
    /// Nothing here can fail the redemption: the transactions are already with the servers. A
    /// missing raw transaction or a destination error is logged — without the error's associated
    /// values, which may echo caller input — and reported through the return value.
    ///
    /// - Parameters:
    ///   - results: the submission results of the claim.
    ///   - destination: the synchronizer to record the claim in.
    ///   - rawTransaction: looks up the raw bytes of a transaction of the card wallet by its id.
    /// - Returns: `true` when at least one transaction was accepted and every accepted one was
    ///   recorded.
    static func record(
        _ results: [TransactionSubmitResult],
        in destination: TrustedTransactionRecording,
        rawTransaction: (Data) async throws -> Data?,
        logger: Logger
    ) async -> Bool {
        var recordedAny = false
        var recordedAll = true
        for result in results {
            guard case .success(let txId) = result else { continue }
            do {
                guard let raw = try await rawTransaction(txId) else {
                    logger.warn("Gift card: the claim transaction is not in the card wallet; the destination will learn about it from the chain")
                    recordedAll = false
                    continue
                }
                try await destination.recordTrustedTransaction(raw, txId: try TxId([UInt8](txId)))
                recordedAny = true
            } catch {
                logger.warn("Gift card: recording the claim in the destination wallet failed: \(error.localizedDescription)")
                recordedAll = false
            }
        }
        return recordedAny && recordedAll
    }

    /// Waits for terminal completion, even when the caller is cancelled. A pending wipe must
    /// keep its wallet and alias owned; elapsed time is not evidence that deletion is safe.
    static func awaitCompletion(of publisher: AnyPublisher<Void, Error>) async throws {
        let waiter = PublisherCompletionWaiter()
        // The waiter owns the subscription; keep it alive until the continuation resumes.
        defer { withExtendedLifetime(waiter) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.begin(continuation: continuation, publisher: publisher)
        }
    }
}

/// Resumes a continuation once, only when a `Void` publisher completes.
private final class PublisherCompletionWaiter {
    private let lock = NSLock()
    private var cancellable: AnyCancellable?

    func begin(continuation: CheckedContinuation<Void, Error>, publisher: AnyPublisher<Void, Error>) {
        let resumed = OneShot()
        let cancellable = publisher.sink(
            receiveCompletion: { completion in
                guard resumed.fire() else { return }
                switch completion {
                case .finished:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            },
            receiveValue: { _ in }
        )
        lock.lock()
        self.cancellable = cancellable
        lock.unlock()
    }
}

private final class OneShot {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
