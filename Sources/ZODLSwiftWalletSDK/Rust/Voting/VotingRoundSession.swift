//
//  VotingRoundSession.swift
//  ZODLSwiftWalletSDK
//

import Foundation
import libzcashlc

// MARK: - Event bridge

/// Carries one session's events from the Rust threads that report them to the
/// closure the host passed.
///
/// The FFI calls back on a runtime worker — on the proving thread for a proof,
/// and from several threads at once during a run — and must not be kept
/// waiting: a callback that blocks holds up the bundle task that reported. So
/// the bridge does the least it can on that thread, decoding the event and
/// handing it to one serial queue per session. The host's closure therefore
/// runs one event at a time, on a queue that is neither the caller's nor
/// Rust's, in the order the callbacks arrived — which during a run is the order
/// several bundle threads reached the callback, not an order the round itself
/// defines.
final class VotingEventBridge: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onEvent: @Sendable (VotingSessionEvent) -> Void

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (VotingSessionEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    /// The context pointer the FFI hands back to the trampoline.
    ///
    /// Unretained: the bridge outlives the call because the caller holds it
    /// across the whole blocking FFI call, which is the contract the FFI
    /// states for `context`.
    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// Decodes one event and queues it for the host.
    ///
    /// The bytes are borrowed for this call only, so they are copied before
    /// they are handed on. An event that does not decode is dropped: the stream
    /// is lossy by design and the run's report is the authoritative record, so
    /// a payload from a newer crate is never a reason to fail a run.
    func report(_ json: UnsafePointer<UInt8>?, length: Int) {
        guard let json, length > 0 else { return }

        let data = Data(bytes: json, count: length)
        guard let event = try? JSONDecoder().decode(VotingSessionEvent.self, from: data) else { return }

        queue.async { [onEvent] in
            onEvent(event)
        }
    }

    /// Suspends until every event handed over so far has reached the host's
    /// closure.
    ///
    /// The queue is serial, so work enqueued behind the events already there is
    /// run after all of them. Suspends rather than blocks: a cooperative thread
    /// held here is one the rest of the wallet cannot use.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }
}

/// The C function every session call that streams events installs.
///
/// It runs on Rust's threads, so it does nothing that can fail or block: it
/// finds the bridge behind the context pointer and hands it the bytes.
private let votingEventTrampoline: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt
) -> Void = { context, json, length in
    guard let context else { return }

    Unmanaged<VotingEventBridge>.fromOpaque(context)
        .takeUnretainedValue()
        .report(json, length: Int(length))
}

// MARK: - VotingRoundSession

/// One open voting round.
///
/// A session is the round's whole working life: it plans, records the ballot,
/// lays out bundles, precomputes, proves, and drives the round to quiescence.
/// It is opened through ``VotingRustBackend/makeSession(inputs:binding:torRuntime:epoch:)``,
/// holds its own reference to the sidecar, and keeps the route — Tor or direct
/// — chosen at open for its whole life.
///
/// Blocking and cancellation: every call that reads the wallet, proves, or
/// reaches the network runs its FFI call on the voting surface's own threads
/// (``VotingBlockingCalls``) and is awaited, so neither the caller's executor
/// nor a thread of Swift's cooperative pool is held for the minutes such a call
/// can take. ``cancel()`` stops a run or a tracking run at its next boundary;
/// it does not interrupt a proof already running under
/// ``precomputeDelegationProof(bundleIndex:progress:)``, which the crate takes
/// no cancellation signal for at this revision — a proof that finishes is
/// persisted and reused, so nothing is wasted. Cancellation is permanent: a
/// cancelled session is finished, not paused.
///
/// ``run(signer:policy:overrides:events:)`` and
/// ``trackShares(policy:overrides:events:)`` are exclusive per session. A
/// second one while the first is in flight throws
/// ``VotingRustBackendError/sessionBusy``: two drivers over one round would
/// contend for its rows, and their events would be indistinguishable over one
/// callback.
///
/// Events: the stream is a best-effort narration — the report each call returns
/// is the authoritative account of what happened, and an event may be dropped
/// under load. The closure runs on one serial queue per session, one event at a
/// time, in the order the FFI's callback delivered them; a run reports from
/// several bundle threads at once, so that order is the order they arrived
/// rather than an order the round defines. Every event delivered during a call
/// reaches the closure before that call returns. The closure must not block
/// that queue: it delays every later event, and blocking it on work that waits
/// for the call itself deadlocks the call.
///
/// ``close()`` cancels, waits for every call still in flight, and frees the
/// handle; every call after it throws ``VotingRustBackendError/sessionClosed``.
public final class VotingRoundSession: @unchecked Sendable {
    /// The round this session is bound to, as canonical lowercase hex.
    public let roundId: String

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var closed = false
    private var driving = false
    /// The blocking FFI calls this session has running right now, which
    /// ``close()`` waits for before it frees the handle.
    private let calls = VotingBlockingCalls()
    private let eventQueue: DispatchQueue

    init(handle: OpaquePointer, roundId: String) {
        self.handle = handle
        self.roundId = roundId
        self.eventQueue = DispatchQueue(label: "cash.z.wallet.voting.session.\(roundId)")
    }

    deinit {
        // A session the host dropped without closing still frees its handle.
        // Freeing during a call in flight would be memory-safe — Rust holds its
        // own reference to the round — but a session with work in flight is
        // referenced by that work and cannot be deinitialized here.
        if let handle {
            zcashlc_voting_session_free(handle)
        }
    }

    // MARK: - Planning

    /// This round's resume plan, planned against the roster the session is
    /// bound to.
    ///
    /// Reads the sidecar and nothing else. A round with no rows yet is not an
    /// error: it plans as an idle round that owes a draft.
    public func plan() throws -> VotingRoundPlan {
        try withHandle { session in
            try VotingRustBackend.decodingJSON(fallback: "`voting_session_plan` failed") {
                zcashlc_voting_session_plan(session)
            }
        }
    }

    /// Record ballot decisions and return the refreshed plan.
    ///
    /// The whole batch is resolved against the bound roster before anything is
    /// written, so a decision for a proposal outside it leaves durable intent
    /// untouched.
    ///
    /// - Important: ``setupBundles()`` must have run on this round first. An
    /// intent is recorded against the round's row, and `setupBundles()` is what
    /// creates that row — it writes it before it reads the wallet, so the row
    /// survives even the refusal an account with nothing eligible gets. Called
    /// on a round the sidecar has never seen, this fails on that foreign key
    /// and arrives as ``VotingErrorKind/storage`` carrying the sidecar's own
    /// message, which says nothing about the ordering.
    public func setBallotIntents(_ intents: [VotingBallotIntent]) throws -> VotingRoundPlan {
        let json = try VotingRustBackend.encodeJSON(intents, describing: "ballot intents")

        return try withHandle { session in
            try VotingRustBackend.decodingJSON(fallback: "`voting_session_set_ballot_intents` failed") {
                json.withUnsafeBufferPointer { buffer in
                    zcashlc_voting_session_set_ballot_intents(session, buffer.baseAddress, UInt(buffer.count))
                }
            }
        }
    }

    // MARK: - Setup

    /// Create this round's row and its delegation bundle rows.
    ///
    /// Reads the wallet to select notes, so it takes as long as that read does.
    /// An account with nothing eligible is refused as a typed
    /// ``VotingError`` — ``VotingErrorKind/noSpendableNotes`` or
    /// ``VotingErrorKind/insufficientEligibility`` — which is a state to show
    /// rather than a fault. The round row is created before the wallet is read,
    /// so it survives that refusal.
    public func setupBundles() async throws -> VotingBundleLayout {
        try await blocking(fallback: "`voting_session_setup_bundles` failed") { session in
            zcashlc_voting_session_setup_bundles(session)
        }
    }

    /// Whether this account can vote in this round, without persisting
    /// anything.
    public func eligibility() async throws -> VotingEligibilityReport {
        try await blocking(fallback: "`voting_session_eligibility` failed") { session in
            zcashlc_voting_session_eligibility(session)
        }
    }

    /// Sync this round's vote-commitment tree from `nodeUrl`, returning the
    /// height synced to.
    ///
    /// The sync rides the session's route like the rest of its traffic, so on
    /// a ``VotingTransportRoute/tor`` session it fails closed instead of
    /// reaching the node directly.
    ///
    /// The tree client belongs to the session's route rather than to the
    /// round, which costs a host two things worth planning for. A session's
    /// first sync of a round starts the tree from scratch instead of
    /// continuing the last session's, so reopening a round that was already
    /// synced pays for the whole tree again — and because a route change is
    /// always a new session, toggling Tor mid-round means resyncing over Tor.
    /// This is not a cost only a caller of this method pays:
    /// ``run(signer:policy:overrides:events:)`` syncs the same tree, on the
    /// same route, whenever it casts a vote.
    /// The session that synced also leaves its tree in memory after
    /// ``close()``: that client outlives the session for as long as it holds
    /// any round's state, and it owns the session's transport — on a
    /// ``VotingTransportRoute/tor`` session, that session's isolated Tor
    /// client, which therefore stays alive after the voter turns Tor off.
    /// ``VotingRustBackend/resetVoteTree(roundId:)``
    /// releases it, and so does closing the sidecar once no session and no
    /// ``VotingRustBackend`` still hold it open.
    ///
    /// Reset when the voter leaves the round, not on every ``close()``: the
    /// reset forgets that round on every tree client the wallet has, including
    /// one a concurrent session is still syncing on. It is scoped to the
    /// wallet id the backend is bound to when it is called, so an account
    /// switch resets before ``VotingRustBackend/setWalletId(_:)``, never after.
    public func syncVoteTree(nodeUrl: String) async throws -> UInt32 {
        let url = [UInt8](nodeUrl.utf8)

        let height = try await runBlocking { session -> Int64 in
            let synced = url.withUnsafeBufferPointer { urlBytes in
                zcashlc_voting_session_sync_vote_tree(session, urlBytes.baseAddress, UInt(urlBytes.count))
            }

            // Read here rather than after the await: the FFI's last-error slot
            // is per-thread, and this is the thread that made the call.
            guard synced >= 0 else {
                throw VotingRustBackend.votingError(fallback: "`voting_session_sync_vote_tree` failed")
            }
            return synced
        }

        guard let synced = UInt32(exactly: height) else {
            throw VotingError(
                kind: .internal,
                message: "vote tree synced to height \(height), which is not a block height"
            )
        }
        return synced
    }

    /// Persist one bundle's witnesses and padded secrets and warm its PIR rows.
    ///
    /// Reaches the PIR fleet over the session's route like the rest of its
    /// traffic, so it blocks for as long as those queries take — and on a
    /// ``VotingTransportRoute/tor`` session it fails closed rather than
    /// querying the fleet directly.
    public func precomputePir(bundleIndex: UInt32) async throws -> VotingPirPrecomputeReport {
        try await blocking(fallback: "`voting_session_precompute_pir` failed") { session in
            zcashlc_voting_session_precompute_pir(session, bundleIndex)
        }
    }

    /// Generate one bundle's delegation proof ahead of a run, or report the
    /// persisted one it reused.
    ///
    /// Blocks for the whole proof — minutes when there is one to generate — on
    /// a thread Rust creates and sizes for Orchard proving, under the
    /// interactive proving boost. ``cancel()`` does not interrupt a proof
    /// already in flight here.
    public func precomputeDelegationProof(
        bundleIndex: UInt32,
        progress: @escaping @Sendable (VotingDelegationProgress) -> Void
    ) async throws -> VotingDelegationProofStatus {
        let bridge = VotingEventBridge(queue: eventQueue) { event in
            guard case .delegationProgress(let step) = event else { return }
            progress(step)
        }

        return try await reporting(through: bridge) {
            try await VotingRustBackend.withInteractiveProvingBoost {
                try await blocking(fallback: "`voting_session_precompute_delegation_proof` failed") { session in
                    withExtendedLifetime(bridge) {
                        zcashlc_voting_session_precompute_delegation_proof(
                            session,
                            bundleIndex,
                            votingEventTrampoline,
                            bridge.context
                        )
                    }
                }
            }
        }
    }

    // MARK: - Keystone

    /// The redacted PCZTs a Keystone device signs, one per named bundle, in the
    /// order named.
    ///
    /// A batch that names no bundle, or names one twice, is refused as
    /// ``VotingErrorKind/invalidInput``: the host asked for the set of QRs that
    /// covers a round, and neither a set that covers nothing nor one that shows
    /// a bundle twice is that.
    public func keystoneSigningRequests(bundleIndices: [UInt32]) async throws -> [VotingKeystoneSigningRequest] {
        let json = try VotingRustBackend.encodeJSON(bundleIndices, describing: "bundle indices")

        return try await blocking(fallback: "`voting_session_keystone_signing_requests` failed") { session in
            json.withUnsafeBufferPointer { buffer in
                zcashlc_voting_session_keystone_signing_requests(session, buffer.baseAddress, UInt(buffer.count))
            }
        }
    }

    /// Lift the signatures off the PCZTs a Keystone device returned, check each
    /// one against the request it answers, and store them for this round.
    ///
    /// A response this wallet cannot use is refused as
    /// ``VotingErrorKind/invalidInput``, and nothing of the batch is stored,
    /// not even the entries that did verify. Two ways it can be unusable, one
    /// refusal for both: bytes that are not a signed PCZT carrying a
    /// spend-authorization signature, and a signature that does not sign that
    /// bundle's current signing request — the wrong bundle's QR, or a stale one
    /// from a round whose bundles were rebuilt. ``VotingError/bundleIndex``
    /// names the bundle whose response was refused, so the host can ask for
    /// that one again; scanning the right response for it afterwards stores it.
    /// When the round's bundles were rebuilt, call
    /// ``keystoneSigningRequests(bundleIndices:)`` again first: a request is
    /// built from the bundle's stored PCZT, sighash and randomized key, so a
    /// response to the request that preceded the rebuild cannot verify however
    /// often it is rescanned.
    ///
    /// Storing is the only moment the refusal can happen: the sidecar keeps the
    /// first signature stored for a bundle, so a wrong one that got in could not
    /// be replaced.
    ///
    /// One atomic idempotent batch, so a retry after an interrupted QR session
    /// reports what was already there rather than failing on it: a response that
    /// already verified and was stored is reported through `alreadyPresent`
    /// rather than stored twice. An empty batch and a repeated bundle index are
    /// refused as ``VotingErrorKind/invalidInput``.
    public func storeKeystoneSignatures(
        _ signed: [VotingKeystoneSignedBundle]
    ) async throws -> VotingKeystoneSignatureBatchResult {
        let json = try VotingRustBackend.encodeJSON(signed, describing: "signed keystone bundles")

        return try await blocking(fallback: "`voting_session_store_keystone_signatures` failed") { session in
            json.withUnsafeBufferPointer { buffer in
                zcashlc_voting_session_store_keystone_signatures(session, buffer.baseAddress, UInt(buffer.count))
            }
        }
    }

    // MARK: - Driving

    /// Drive this round to quiescence.
    ///
    /// The driver itself does not fail: a run that could do nothing says why
    /// through the report's quiescence. A throw here is the call around it —
    /// a signer this host cannot build, or a session that is closed or already
    /// driving.
    ///
    /// A software seed lives in Rust's signer for this call only and is
    /// zeroized there; it never reaches Swift again, and neither do the
    /// sighashes or PCZTs the run signs.
    ///
    /// `overrides` is merged into the session's service configuration as this
    /// run starts, with the semantics of
    /// ``updateHostConfiguration(_:)``: a field it names replaces the
    /// session's current value, a field it leaves absent keeps whatever is
    /// there — including a configuration pushed earlier. The driver reads that
    /// configuration on every dispatch, so it can be replaced while this run
    /// is in flight, and what this call merged outlives the run: a later run
    /// that names nothing is still driven against it.
    ///
    /// The merge happens once this call has been admitted — a
    /// ``VotingRustBackendError/sessionBusy`` or
    /// ``VotingRustBackendError/sessionClosed`` refusal merges nothing — and
    /// before the signer is built, so a call that then throws on a seed Rust
    /// cannot derive from has still moved the session's configuration. Nothing
    /// rolls it back: a host that wants a later call driven against the values
    /// the session was opened with names those values on that call.
    public func run(
        signer: VotingDelegationSigner,
        policy: VotingRoundDrivePolicy = .default,
        overrides: VotingHostOverrides = VotingHostOverrides(),
        events: @escaping @Sendable (VotingRoundDriveEvent) -> Void
    ) async throws -> VotingRoundRunReport {
        try beginDriving()
        defer { endDriving() }

        let hostJSON = try VotingRustBackend.encodeJSON(overrides, describing: "host overrides")
        let signerJSON = try VotingRustBackend.encodeJSON(signer, describing: "signer")
        let policyJSON = try VotingRustBackend.encodeJSON(policy, describing: "drive policy")
        let bridge = VotingEventBridge(queue: eventQueue) { event in
            guard case .roundDrive(let driveEvent) = event else { return }
            events(driveEvent)
        }

        return try await reporting(through: bridge) {
            try await VotingRustBackend.withInteractiveProvingBoost {
                try await blocking(fallback: "`voting_session_run` failed") { session in
                    withExtendedLifetime(bridge) {
                        hostJSON.withUnsafeBufferPointer { hostBytes in
                            signerJSON.withUnsafeBufferPointer { signerBytes in
                                policyJSON.withUnsafeBufferPointer { policyBytes in
                                    zcashlc_voting_session_run(
                                        session,
                                        hostBytes.baseAddress,
                                        UInt(hostBytes.count),
                                        signerBytes.baseAddress,
                                        UInt(signerBytes.count),
                                        policyBytes.baseAddress,
                                        UInt(policyBytes.count),
                                        votingEventTrampoline,
                                        bridge.context
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Drive this round's unconfirmed helper shares to confirmation.
    ///
    /// Like a run, the driver does not fail: a round that owed nothing, ran out
    /// of passes or found the vote closed says so through the report's
    /// quiescence, and tracking a round another pass already holds returns
    /// ``VotingShareTrackingQuiescenceKind/alreadyDriving`` at once. No signer:
    /// tracking delivers and confirms shares that already exist.
    ///
    /// `overrides` is merged into the session's service configuration exactly
    /// as ``run(signer:policy:overrides:events:)`` merges its own — the same
    /// configuration, the same per-field merge — and this driver reads it on
    /// every pass.
    public func trackShares(
        policy: VotingShareTrackingPolicy = VotingShareTrackingPolicy(),
        overrides: VotingHostOverrides = VotingHostOverrides(),
        events: @escaping @Sendable (VotingShareTrackingEvent) -> Void
    ) async throws -> VotingShareTrackingRunReport {
        try beginDriving()
        defer { endDriving() }

        let hostJSON = try VotingRustBackend.encodeJSON(overrides, describing: "host overrides")
        let policyJSON = try VotingRustBackend.encodeJSON(policy, describing: "share tracking policy")
        let bridge = VotingEventBridge(queue: eventQueue) { event in
            guard case .shareTracking(let trackingEvent) = event else { return }
            events(trackingEvent)
        }

        return try await reporting(through: bridge) {
            try await blocking(fallback: "`voting_session_track_shares` failed") { session in
                withExtendedLifetime(bridge) {
                    hostJSON.withUnsafeBufferPointer { hostBytes in
                        policyJSON.withUnsafeBufferPointer { policyBytes in
                            zcashlc_voting_session_track_shares(
                                session,
                                hostBytes.baseAddress,
                                UInt(hostBytes.count),
                                policyBytes.baseAddress,
                                UInt(policyBytes.count),
                                votingEventTrampoline,
                                bridge.context
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Host configuration

    /// Replace the service configuration this session's drivers read.
    ///
    /// A field the overrides name replaces the session's current value; one
    /// they leave absent keeps it. Both drivers read the merged value on every
    /// dispatch, so a call made while ``run(signer:policy:overrides:events:)``
    /// or ``trackShares(policy:overrides:events:)`` is in flight takes effect
    /// at the next dispatch, and it still holds for later runs. Push the
    /// helper fleet and vote-tree nodes here whenever the host refreshes its
    /// service configuration.
    ///
    /// Returns as soon as the merge is recorded, whatever else the session is
    /// doing: it takes the configuration's own lock and nothing a driver
    /// holds. Throws ``VotingRustBackendError/sessionClosed`` on a closed
    /// session — unlike ``cancel()`` and ``setOperationEpoch(_:)``, which are
    /// no-ops there, because a configuration nothing will ever read is worth
    /// saying out loud.
    public func updateHostConfiguration(_ overrides: VotingHostOverrides) throws {
        let hostJSON = try VotingRustBackend.encodeJSON(overrides, describing: "host overrides")

        try withHandle { session in
            let status = hostJSON.withUnsafeBufferPointer { hostBytes in
                zcashlc_voting_session_update_host_configuration(session, hostBytes.baseAddress, UInt(hostBytes.count))
            }

            guard status == 0 else {
                throw VotingRustBackend.votingError(fallback: "`voting_session_update_host_configuration` failed")
            }
        }
    }

    // MARK: - Lifecycle

    /// Cancel every bounded pass this session governs.
    ///
    /// A run and a tracking run stop at their next boundary and report
    /// cancelled; a proof already running under
    /// ``precomputeDelegationProof(bundleIndex:progress:)`` runs to completion.
    /// Permanent, and work already made durable stays durable. A no-op on a
    /// closed session.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard let session = handle else { return }

        zcashlc_voting_session_cancel(session)
    }

    /// Move the host operation epoch, invalidating passes that captured an
    /// older one.
    ///
    /// Bump it when the voter switches wallets or leaves the flow: every
    /// bounded pass started under an older epoch stops at its next boundary. A
    /// no-op on a closed session.
    public func setOperationEpoch(_ epoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let session = handle else { return }

        zcashlc_voting_session_set_epoch(session, epoch)
    }

    /// Cancel, wait for every call still in flight, and free the handle.
    ///
    /// Freeing during a call would be memory-safe on its own — Rust holds its
    /// own reference to the round — but a run left to itself keeps driving a
    /// round nothing is listening to, so this joins first. Idempotent, and
    /// every call afterwards throws ``VotingRustBackendError/sessionClosed``.
    ///
    /// The event queue is not drained here: an event already handed to it can
    /// still reach the host's closure after this returns. Nothing unsafe
    /// follows from that — what the closure receives is a decoded Swift value,
    /// not memory the freed handle owned — but a host that tears down the state
    /// its closure writes to should expect one more call into it.
    public func close() async {
        cancel()
        markClosed()
        await calls.join()
        releaseHandle()
    }
}

// MARK: - Private helpers

private extension VotingRoundSession {
    /// Runs a short session call while holding the handle lock, which keeps
    /// ``VotingRoundSession/close()`` from freeing the handle underneath it.
    ///
    /// Only for the calls that read the sidecar and return: anything that
    /// proves or reaches the network goes through ``blocking(fallback:_:)``
    /// instead, because holding this lock for a run would block cancellation.
    func withHandle<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let session = handle, !closed else {
            throw VotingRustBackendError.sessionClosed
        }
        return try operation(session)
    }

    /// Runs one blocking FFI call off the caller's executor and awaits it,
    /// decoding the JSON it answers with.
    func blocking<T: Decodable & Sendable>(
        fallback: String,
        _ call: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<FfiBoxedSlice>?
    ) async throws -> T {
        try await runBlocking { session in
            try VotingRustBackend.decodingJSON(fallback: fallback) {
                call(session)
            }
        }
    }

    /// Runs `body` on the voting surface's own threads, registered as in
    /// flight, so ``close()`` waits for it before freeing the handle.
    ///
    /// The handle is read and the call registered under one lock hold, so a
    /// call either joins what ``close()`` waits for or is refused as closed:
    /// there is no window where a call starts against a handle that is about to
    /// be freed.
    func runBlocking<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        let (session, ticket) = try startCall()
        return try await calls.run(ticket: ticket) { try body(session) }
    }

    /// Reads the handle and registers the call under one lock hold.
    /// Synchronous because that is what taking a lock around a few field reads
    /// should be: an `async` function may not hold an `NSLock` across a
    /// suspension.
    func startCall() throws -> (OpaquePointer, UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let session = handle, !closed else {
            throw VotingRustBackendError.sessionClosed
        }
        return (session, calls.register())
    }

    /// Closes the session to new work. Every call registered after this throws
    /// ``VotingRustBackendError/sessionClosed`` instead, which is what makes the
    /// join that follows complete rather than chase new arrivals.
    func markClosed() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    /// Frees the handle once nothing is in flight.
    func releaseHandle() {
        lock.lock()
        defer { lock.unlock() }

        if let session = handle {
            zcashlc_voting_session_free(session)
            handle = nil
        }
    }

    /// Claims this session's single drive slot for a run or a tracking run.
    func beginDriving() throws {
        lock.lock()
        defer { lock.unlock() }

        guard handle != nil, !closed else {
            throw VotingRustBackendError.sessionClosed
        }
        guard !driving else {
            throw VotingRustBackendError.sessionBusy
        }
        driving = true
    }

    func endDriving() {
        lock.lock()
        defer { lock.unlock() }
        driving = false
    }

    /// Runs `body` and lets the events it produced finish reaching the host
    /// before its answer does, on the throwing path as well.
    func reporting<T>(through bridge: VotingEventBridge, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await bridge.drain()
            return value
        } catch {
            await bridge.drain()
            throw error
        }
    }
}

// MARK: - Account identity

extension AccountUUID {
    /// The account id in the hyphenated text form the voting FFI parses.
    ///
    /// ``AccountUUID/id`` is the raw 16 bytes; `zcash_voting` names accounts by
    /// their UUID text, so the two have to be converted rather than passed
    /// through as bytes.
    ///
    /// The length is checked rather than assumed: the initializer that traps on
    /// a wrong one is not the only way an `AccountUUID` is made — a decoded one
    /// carries whatever its payload said — and a voting session is not the
    /// place to find that out by reading off the end of an array.
    func votingUUIDString() throws -> String {
        guard id.count == 16 else {
            throw VotingError(
                kind: .invalidInput,
                message: "account UUID is \(id.count) bytes, not the 16 a UUID is"
            )
        }

        return UUID(
            uuid: (
                id[0], id[1], id[2], id[3],
                id[4], id[5], id[6], id[7],
                id[8], id[9], id[10], id[11],
                id[12], id[13], id[14], id[15]
            )
        ).uuidString
    }
}
