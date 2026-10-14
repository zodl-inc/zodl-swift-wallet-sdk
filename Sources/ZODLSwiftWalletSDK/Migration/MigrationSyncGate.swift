//
//  MigrationSyncGate.swift
//  ZODLSwiftWalletSDK
//

import Combine
import Foundation

/// The persisted, per-account gate that decides whether ordinary wallet sync must pause for the
/// benefit of an in-flight migration.
///
/// The gate is BEHAVIOR-BASED, never time-based. A strictly time-bound lock fixes nothing,
/// because any short fixed delay between a broadcast and the next sync is itself an identifiable
/// pattern — a correlation SIGNATURE, not a defense against one: broadcast at T, sync reliably at
/// T + delay, repeated across every broadcast of a migration that runs for days. Time-based
/// spacing was the wrong abstraction, not an insufficient amount of the right one, so the
/// persisted `resumeAt` buffer that used to live here is GONE rather than lengthened or
/// randomized. The primary intent is that, while a wallet is in the process of running a
/// migration, sync is not automatically triggered on every wake.
///
/// The behavior that replaces it is not this type's to enforce: wakes serve the drive's
/// instruction and do not auto-append a sync, and a sync session starts for a REASON — the
/// engine's outlook naming sync-bound work, an organic scheduled sync, or the user. User intent
/// that requires sync (a manual balance refresh, an attempt to create a transaction) is never
/// held back by this gate.
///
/// So exactly ONE condition remains, and it is present-tense: the IN-FLIGHT BROADCAST MARKER.
/// From just before a migration submit hits the network until its outcome is recorded, sync must
/// not run — the engine's own in-flight sweep (inside `migrationAdvanceStep`) would otherwise
/// meet a transfer that is neither recorded broadcast nor yet visible on chain. That is the
/// `inFlightUntil` timestamp persisted here, and it lasts seconds in the ordinary case: the
/// submit's round trip plus the record. Its bounded ``broadcastInFlightGuardDuration`` (120 s)
/// self-expiry is CRASH-RECOVERY LIVENESS — the ceiling on how long a crash between submit and
/// record may leave sync wedged — and is emphatically not privacy spacing; nothing about the
/// gate's answer is meant to be a function of elapsed time since a broadcast.
///
/// Two conditions that used to block sync are gone. A forward-looking "ready broadcast" clause —
/// block whenever a proved, schedule-due transfer was servable — was removed first: it was
/// field-implicated in a live wedge, since it blocked the very sync whose scanned progress the
/// pending broadcast needed, freezing an awake session for 50+ minutes (FIND-5, campaign 7/8a
/// receipts). The post-broadcast privacy buffer followed it, on the rationale above.
///
/// State is durably persisted to an atomically written JSON file, but every read in this process is
/// served from an in-memory cache (see `cachedInFlightUntil`) -- the file exists for durability
/// across launches, not as the read path. The other in-memory mutable state is the
/// subscriber-gated ticker task (see `subscriberAttached()`, guarded by `subscriptionLock`) and the
/// send-generation counters (see `publish(_:generation:)`, guarded by `emissionLock`); all of it is
/// guarded by one lock or the other, so a `final class` is `@unchecked Sendable` without needing an
/// actor hop to read the reactive stream. A corrupt or missing file reads as "nothing in flight".
final class MigrationSyncGate: @unchecked Sendable {
    /// The persisted envelope: a schema version plus the epoch-seconds instant at which the
    /// in-flight broadcast marker expires. The instant is OPTIONAL (synthesized `Codable` decodes
    /// it via `decodeIfPresent`), and the version int is unchanged across the format's two
    /// evolutions so far, because both stayed decode-compatible:
    ///
    /// - files written before the in-flight marker existed carry no `inFlightUntilEpochSeconds`
    ///   and read as "nothing in flight";
    /// - files written while the post-broadcast privacy buffer existed additionally carry a
    ///   `resumeAtEpochSeconds` key, which is no longer a field here. `JSONDecoder` ignores
    ///   unknown keys, so such a file loads with its in-flight marker intact and its buffer
    ///   silently dropped — the correct reading of it now that no timed condition can block sync.
    ///   The stale key disappears from disk at this gate's next write.
    private struct GateState: Codable {
        let version: Int
        let inFlightUntilEpochSeconds: Double?
    }

    private static let currentVersion = 1

    /// How long the in-flight broadcast marker set by ``markBroadcastInFlight()`` lives before it
    /// self-expires: long enough to cover a submit's network round-trip plus the result record,
    /// short enough that a crash mid-broadcast does not wedge sync — the marker's whole point is
    /// to be safe to leak. A CRASH-RECOVERY bound, not a privacy interval: in the ordinary case
    /// the marker is cleared within seconds, and no gate answer is meant to correlate with time
    /// elapsed since a broadcast.
    static let broadcastInFlightGuardDuration: TimeInterval = 120

    private let fileURL: URL
    private let tickInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: Logger
    private let blockedSubject: CurrentValueSubject<Bool, Never>

    /// Guards the send-generation counters (`nextGeneration`, `lastPublishedGeneration`) and the
    /// in-memory in-flight marker cache (`cachedInFlightUntil`) -- the funnel that computes and
    /// emits values on `blockedSubject`. `publish(_:generation:)` holds this lock across the actual
    /// `blockedSubject.send(_:)` call (Combine requires sends on a subject to be serialized). Kept
    /// deliberately separate from `subscriptionLock` below -- see that property's doc for why.
    /// `NSLock` rather than `OSAllocatedUnfairLock` (the usual preference for new locking code): this
    /// package's deployment target (`Package.swift`: `.iOS(.v13)` / `.macOS(.v12)`) is below
    /// `OSAllocatedUnfairLock`'s iOS 16 / macOS 13 floor, so this matches the plain-`NSLock`
    /// convention already used elsewhere in this codebase (see `ZcashRustBackend.rustInitLock`).
    private let emissionLock = NSLock()
    /// The generation handed out to the most recently *started* `recompute()`, and the newest
    /// generation `publish(_:generation:)` has actually sent. Both guarded by `emissionLock`.
    private var nextGeneration: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0

    /// The in-memory cache of the persisted in-flight broadcast marker's expiry, guarded by
    /// `emissionLock`. Loaded once from the gate file at init; `markBroadcastInFlight()` and
    /// `clearBroadcastInFlight()` are the only writers thereafter (each persists to the file
    /// first, then updates this cache -- see `markBroadcastInFlight()` for why the file must win
    /// that race). Every read in this process (`currentInFlightUntil()`, hence `currentlyBlocked()`
    /// and `recompute()`) serves this cache rather than re-reading the file.
    ///
    /// `nil` when no marker is set; an instant in the past is an expired marker a crash left
    /// behind (equivalent to none for blocking purposes, and overwritten by the next
    /// `markBroadcastInFlight()`/`clearBroadcastInFlight()` write).
    ///
    /// A plain lock-guarded value suffices here, unlike `publish(_:generation:)`'s generation
    /// ordering: both writers run inside `OrchardMigration`'s single-flight broadcast flow -- and
    /// there is one `MigrationSyncGate` instance per account per process (the standing
    /// single-writer assumption) -- so there is never a fresher write for a slower one to clobber.
    ///
    /// One reader also writes: `currentInFlightUntil()` clamps an implausibly-far-future value
    /// (a backwards clock-step artifact — see ``clampedInFlightUntil(_:now:)``) back into the
    /// plausible window and persists the clamp HERE (cache only, not the file), so the marker
    /// then expires within ``broadcastInFlightGuardDuration`` of the observation instead of
    /// re-deriving a fresh far-future block on every read. The single-writer assumption the
    /// marking calls rely on is unaffected: the clamp only ever SHORTENS the marker, never
    /// extends or revives one.
    private var cachedInFlightUntil: Date?

    /// Guards the subscriber count and the ticker task's start/stop state -- the bookkeeping for
    /// `blockedStream`'s subscription lifecycle. Deliberately a SEPARATE lock from `emissionLock`:
    /// Combine can invoke `receiveCancel` (-> `subscriberDetached()`) *synchronously, on the calling
    /// thread*, when a subscriber cancels from inside its own value-handling closure -- including a
    /// value just delivered by `publish(_:generation:)`, i.e. while that thread is still inside
    /// `publish`'s `emissionLock` critical section around `blockedSubject.send(_:)`. If subscription
    /// bookkeeping shared `emissionLock`, that re-entrant `lock()` would deadlock against itself
    /// (`NSLock` is non-recursive) and wedge the gate permanently -- every later
    /// `currentInFlightUntil()` / `currentlyBlocked()` / `markBroadcastInFlight()` / subscribe would
    /// then hang too, since the thread that deadlocked never releases the lock it holds.
    ///
    /// The ordering rule this buys is one-way, not "never both": `subscriberAttached()`,
    /// `subscriberDetached()`, `startTicking()`, and `stopTicking()` touch only `subscriptionLock`
    /// and must never acquire `emissionLock` -- that is the invariant that actually prevents the
    /// deadlock described above. The reverse nesting is deliberate and safe: `publish(_:generation:)`
    /// legitimately holds `emissionLock` across `blockedSubject.send(_:)`, and that send can
    /// synchronously re-enter this instance via a subscriber's synchronous cancel
    /// (-> `subscriberDetached()`, which acquires `subscriptionLock`) -- so `emissionLock` ->
    /// `subscriptionLock` is a real, one-way nesting this type relies on. What must never happen is
    /// the reverse acquisition order; keep it that way rather than letting subscription-side code
    /// reach back into `emissionLock`. See `publish(_:generation:)`'s doc for the different,
    /// currently-unreachable re-entrancy hazard this same nesting creates for `emissionLock` itself.
    private let subscriptionLock = NSLock()
    /// Live subscriber count of `blockedStream`, guarded by `subscriptionLock`. The ticker task runs
    /// only while this is > 0: `subscriberAttached()` starts it on the 0 -> 1 transition,
    /// `subscriberDetached()` cancels it on the 1 -> 0 transition. With zero subscribers the gate
    /// does zero periodic FFI/sqlite work (finding 14).
    private var subscriberCount = 0
    /// The ticker task itself, guarded by `subscriptionLock` alongside `subscriberCount` -- see
    /// `startTicking()` / `stopTicking()`.
    private var tickerTask: Task<Void, Never>?

    /// Creates a gate rooted at `directory`, scoped to `accountUUID` by file name.
    ///
    /// - Parameters:
    ///   - directory: the general-storage directory the gate file lives in; provisioned via
    ///     ``BackupExcludedStorage`` (created if missing, and excluded from backup either way --
    ///     migration state must never leave the device via an iCloud/iTunes backup).
    ///   - accountUUID: the account this gate governs; encoded into the file name.
    ///   - tickInterval: how often the reactive stream re-evaluates (the marker's self-expiry
    ///     alone can flip the answer even with no data change). Injectable for tests.
    ///   - now: the clock. Injectable for tests.
    ///   - logger: sink for the single warning emitted on a corrupt read or a failed write.
    init(
        directory: URL,
        accountUUID: AccountUUID,
        tickInterval: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        let url = directory.appendingPathComponent(Self.fileName(accountUUID: accountUUID))
        self.fileURL = url
        self.tickInterval = tickInterval
        self.now = now
        self.logger = logger

        do {
            try BackupExcludedStorage.provision(directory: directory)
        } catch {
            logger.warn("MigrationSyncGate: failed to provision the storage directory (backup exclusion may be missing): \(error)")
        }

        // Load the in-memory `inFlightUntil` cache from the file exactly once, here -- every
        // subsequent read in this process serves this cache (see `cachedInFlightUntil`), never the
        // file again, until a marking call updates it. The marker is clamped into its plausible
        // window at this load (the A13 backwards-clock-step guard — see
        // `clampedInFlightUntil(_:now:)`), so a marker persisted before a clock step back expires
        // within `broadcastInFlightGuardDuration` of THIS launch rather than wedging sync for the
        // whole displacement. Also seeds the synchronous subscribe-time value, which is EXACT —
        // the gate's input is entirely this one persisted instant — so subscribers get an
        // immediate, correct value.
        let loadedAt = now()
        let loadedInFlightUntil = Self.readInFlightUntil(fileURL: url, logger: logger)
        let clampedInFlightUntil = Self.clampedInFlightUntil(loadedInFlightUntil, now: loadedAt)
        self.cachedInFlightUntil = clampedInFlightUntil
        self.blockedSubject = CurrentValueSubject(
            Self.isBlocked(now: loadedAt, inFlightUntil: clampedInFlightUntil)
        )
        self.tickerTask = nil

        // No `startTicking()` here: the ticker is subscription-gated (finding 14) -- it starts on the
        // first `blockedStream` subscriber (`subscriberAttached()`), not at construction.
    }

    deinit {
        tickerTask?.cancel()
    }

    /// The account-scoped gate file name, e.g. `migration_sync_gate_<account-uuid-hex>.json`.
    static func fileName(accountUUID: AccountUUID) -> String {
        "migration_sync_gate_\(Data(accountUUID.id).hexEncodedString()).json"
    }

    /// The persisted in-flight broadcast marker's expiry for `accountUUID`, read directly from its
    /// gate file under `directory`, without constructing a gate instance. A corrupt or missing
    /// file reads as `nil` ("nothing in flight"), exactly like an instance's init-time load.
    ///
    /// The wallet-scope path a host uses to answer "is any account mid-submit?" after a fresh
    /// launch, when the per-account gate for a dormant account has not been (and must not need to
    /// be) constructed. Reuses the same envelope-read path (`readInFlightUntil`) as the instance's
    /// own init so the on-disk format has a single reader. The raw file value is returned
    /// UNCLAMPED — this static read has nowhere to persist a clamp, so an implausibly-far-future
    /// marker (a backwards clock-step artifact) is instead neutralized at evaluation time by
    /// ``isBlocked(now:inFlightUntil:)``'s plausible-window rule.
    static func persistedInFlightUntil(
        directory: URL,
        accountUUID: AccountUUID,
        logger: Logger
    ) -> Date? {
        let fileURL = directory.appendingPathComponent(fileName(accountUUID: accountUUID))
        return readInFlightUntil(fileURL: fileURL, logger: logger)
    }

    /// The in-flight marker expiry clamped into its plausible window: a marker is armed at
    /// exactly `now + broadcastInFlightGuardDuration`, so under a monotone clock its remaining
    /// life can never EXCEED the guard duration — an expiry further out than that proves the
    /// clock has stepped backwards since it was armed (the A13 hazard: without the clamp, the
    /// marker would block sync for the whole displacement). Clamping to `now + guard` preserves
    /// the protective window (the marker still blocks, briefly) while bounding it. `nil` passes
    /// through; a plausible value is returned unchanged.
    static func clampedInFlightUntil(_ inFlightUntil: Date?, now: Date) -> Date? {
        inFlightUntil.map { min($0, now.addingTimeInterval(broadcastInFlightGuardDuration)) }
    }

    /// The gate's core predicate: sync is blocked exactly while an unexpired in-flight broadcast
    /// marker exists — a present-tense behavior condition, and the only one left (see the type
    /// doc for the removed forward-looking and timed clauses). Pure, so it is exhaustively
    /// table-testable.
    ///
    /// The marker is honored only within its PLAUSIBLE window (`inFlightUntil` at most
    /// ``broadcastInFlightGuardDuration`` in the future — see ``clampedInFlightUntil(_:now:)``): a
    /// marker further out than a freshly armed one proves a backwards clock step, and on the read
    /// paths with no cache to persist a clamp into (the host's dormant-account file reads) it must
    /// fail OPEN here, or each re-read would re-derive a fresh block forever. The marker is
    /// designed to be safe to leak, so failing open on clock weirdness matches its contract; the
    /// in-process cache paths additionally clamp (load + `currentInFlightUntil()`), which keeps the
    /// protective window instead.
    static func isBlocked(now: Date, inFlightUntil: Date?) -> Bool {
        guard let inFlightUntil else {
            return false
        }
        return now < inFlightUntil && inFlightUntil.timeIntervalSince(now) <= Self.broadcastInFlightGuardDuration
    }

    /// Persists the in-flight broadcast marker (`inFlightUntil = now +`
    /// ``broadcastInFlightGuardDuration``), file first, then cache, then a reactive recompute.
    /// Call just before a migration submit hits the network; pair with ``clearBroadcastInFlight()``
    /// once the outcome is recorded. A crash (or a record failure) between the two leaves the
    /// marker behind, and it self-expires on its own — that leak-safety, not any privacy pacing,
    /// is the point of the deadline.
    ///
    /// The file write must land before the cache update, not after. `OrchardMigrationHost`'s
    /// wallet-scope predicate reads the FILE (`persistedInFlightUntil`) — alongside, for accounts
    /// with a live actor, this gate's in-memory view (blocked wins; the A8 defense against a
    /// failed write) — while the gate's own recomputes (and therefore `blockedStream`) read the
    /// in-memory cache. If the cache updated first, a recompute could observe the fresh cache and
    /// publish `true` before the file write lands; that emission can trigger a wallet-scope
    /// recompute whose FILE half reads the still-stale file, computes `false`, and publishes it
    /// with a later generation -- the later, correct `true` (once the file does land) then
    /// collapses into that stale `false` as a consecutive duplicate under `removeDuplicates()`,
    /// leaving the wallet-scope stream stuck at `false` until the next periodic tick. Persisting
    /// first closes that window: the file is never observably behind the cache. The same
    /// write-file-before-cache discipline applies to ``clearBroadcastInFlight()``.
    ///
    /// A failed write (`write(inFlightUntil:)` only logs, never throws) still updates the cache
    /// afterward, so in-process gating never depends on the write having actually landed on
    /// disk — and the host's live-view consultation (above) keeps even the wallet-scope answer
    /// correct in that case.
    func markBroadcastInFlight() {
        let inFlightUntil = now().addingTimeInterval(Self.broadcastInFlightGuardDuration)

        write(inFlightUntil: inFlightUntil)

        emissionLock.lock()
        cachedInFlightUntil = inFlightUntil
        emissionLock.unlock()

        recomputeAsync()
    }

    /// Clears the in-flight broadcast marker (file first, then cache, then a reactive recompute)
    /// — the release half of ``markBroadcastInFlight()``, called once the broadcast's outcome is
    /// recorded, or when the submit never happened at all (a fail-closed pre-submit throw).
    /// Nothing takes its place: with the marker cleared the gate is open, no matter how recently
    /// the broadcast happened.
    func clearBroadcastInFlight() {
        write(inFlightUntil: nil)

        emissionLock.lock()
        cachedInFlightUntil = nil
        emissionLock.unlock()

        recomputeAsync()
    }

    /// The in-memory cached in-flight broadcast marker's expiry (see `cachedInFlightUntil`), or
    /// `nil` when none is set. Reflects the gate file's contents as of the last init or
    /// mark/clear in THIS process, not a fresh file read.
    ///
    /// Every read is the A13 evaluation-side clamp: a value more than
    /// ``broadcastInFlightGuardDuration`` in the future (the clock stepped backwards after the
    /// marker was armed) is clamped to `now + guard` and the clamp is written back to the cache,
    /// so the marker keeps its protective window once and then expires — instead of re-deriving a
    /// fresh far-future block on every evaluation. The file is deliberately NOT rewritten: its
    /// stale value is re-clamped at the next launch's load, and the wallet-scope reader's raw
    /// file read is bounded by `isBlocked`'s plausible-window rule instead.
    func currentInFlightUntil() -> Date? {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        guard let inFlightUntil = cachedInFlightUntil else {
            return nil
        }
        let clamped = Self.clampedInFlightUntil(inFlightUntil, now: now())
        cachedInFlightUntil = clamped
        return clamped
    }

    /// Whether the in-flight broadcast marker is currently live: armed
    /// (``markBroadcastInFlight()``) and neither cleared nor self-expired. The submit-to-record
    /// window signal callers use to defer work that must not observe a just-broadcast transfer.
    func isBroadcastInFlight() -> Bool {
        guard let inFlightUntil = currentInFlightUntil() else {
            return false
        }
        return now() < inFlightUntil
    }

    /// Whether sync is currently blocked by the in-flight broadcast marker — the gate's only
    /// remaining condition, live for the seconds a submit is mid-flight. Never throws, never
    /// suspends: the gate's input is entirely local.
    func currentlyBlocked() -> Bool {
        Self.isBlocked(now: now(), inFlightUntil: currentInFlightUntil())
    }

    /// A stream of the blocked flag: emits the current value on subscribe, re-evaluates every
    /// `tickInterval` — waking EARLY at the marker's known expiry (see `nextRecomputeDelay`) —
    /// and after every ``markBroadcastInFlight()``/``clearBroadcastInFlight()``, and collapses
    /// consecutive duplicates.
    /// Internally synchronized: the ticker loop and every marking-triggered recompute can
    /// be in flight concurrently, and every send is serialized and generation-ordered -- latest-wins, so a recompute that started earlier
    /// but finishes later after a fresher one already published is dropped rather than emitted as a
    /// stale overwrite. See `publish(_:generation:)`.
    ///
    /// - Important: Subscription-gated (finding 14): the periodic ticker only runs while at least one
    ///   subscriber is attached (`subscriberAttached()`/`subscriberDetached()`, via `handleEvents`
    ///   below), so a `blockedStream` with no subscribers costs nothing beyond the seed already
    ///   computed at init. Marking-triggered recomputes are unaffected by subscriber count.
    var blockedStream: AnyPublisher<Bool, Never> {
        blockedSubject
            .handleEvents(
                receiveSubscription: { [weak self] _ in self?.subscriberAttached() },
                receiveCancel: { [weak self] in self?.subscriberDetached() }
            )
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Private

    /// Called (via `handleEvents`) whenever a new `blockedStream` subscription is established. On the
    /// 0 -> 1 transition, starts the ticker task -- see `subscriberCount`.
    private func subscriberAttached() {
        subscriptionLock.lock()
        subscriberCount += 1
        if subscriberCount == 1 {
            startTicking()
        }
        subscriptionLock.unlock()
    }

    /// Called (via `handleEvents`) whenever a `blockedStream` subscription is cancelled. On the
    /// 1 -> 0 transition, cancels the ticker task -- see `subscriberCount`.
    private func subscriberDetached() {
        subscriptionLock.lock()
        subscriberCount -= 1
        if subscriberCount == 0 {
            stopTicking()
        }
        subscriptionLock.unlock()
    }

    /// Starts the ticker task. Only called with `subscriptionLock` held, on the 0 -> 1 subscriber
    /// transition (`subscriberAttached()`) -- creating the `Task` here is a cheap, non-suspending
    /// call, so doing it under the lock is safe. No risk of deadlock either way: the task's own body
    /// (`recompute()`) only ever acquires `emissionLock`, never `subscriptionLock`.
    ///
    /// BOUNDARY-AWARE (field-caught 2026-08-02): the gate KNOWS when its persisted input flips --
    /// `inFlightUntil` is a wall-clock deadline -- yet the flat `tickInterval` sleep could leave a
    /// cleared gate unnoticed for a whole interval. On a foregrounded device that read as a dead
    /// half-minute between "gate expired" and "sync resumed", with the app doing nothing wrong.
    /// Each iteration now sleeps only until that boundary (plus a small epsilon so the recompute
    /// lands strictly after the flip), capped at `tickInterval`.
    private func startTicking() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.recompute()
                let delay = Self.nextRecomputeDelay(
                    now: self.now(),
                    inFlightUntil: self.currentInFlightUntil(),
                    tickInterval: self.tickInterval
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// The ticker's next sleep: the marker's FUTURE expiry (`inFlightUntil`, plus a 0.25 s epsilon
    /// so the wake lands strictly after the input flips), capped at `tickInterval`. A past or
    /// absent boundary falls back to the plain interval. Pure and static for offline testing.
    static func nextRecomputeDelay(
        now: Date,
        inFlightUntil: Date?,
        tickInterval: TimeInterval
    ) -> TimeInterval {
        guard let boundary = inFlightUntil?.timeIntervalSince(now), boundary > 0 else {
            return tickInterval
        }
        return min(tickInterval, boundary + 0.25)
    }

    /// Stops the ticker task. Only called with `subscriptionLock` held, on the 1 -> 0 subscriber
    /// transition (`subscriberDetached()`).
    private func stopTicking() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func recomputeAsync() {
        Task { [weak self] in
            await self?.recompute()
        }
    }

    private func recompute() async {
        let generation = drawNextGeneration()

        let blocked = Self.isBlocked(now: now(), inFlightUntil: currentInFlightUntil())
        publish(blocked, generation: generation)
    }

    /// Snapshots this recompute's generation, under `emissionLock`, at the moment it *starts*, so
    /// `publish(_:generation:)` can later tell whether a later-started recompute has already
    /// published.
    private func drawNextGeneration() -> UInt64 {
        emissionLock.lock()
        defer { emissionLock.unlock() }

        nextGeneration += 1
        return nextGeneration
    }

    /// The single funnel every `blockedSubject.send` goes through. Atomically (under `emissionLock`)
    /// checks freshness and sends: `generation` was snapshotted when the calling `recompute()`
    /// started, so if a *later*-started recompute has already published (`lastPublishedGeneration` is
    /// newer), this send is stale and is silently dropped instead of overwriting the fresher value.
    /// Serializing the actual `.send()` call here also satisfies Combine's requirement that sends on
    /// a subject not race.
    ///
    /// Holding `emissionLock` across `send(_:)` is safe with respect to `subscriptionLock` even
    /// though `send(_:)` can synchronously re-enter this instance (a subscriber cancelling from
    /// inside its own value handler, see `subscriptionLock`'s doc): the only re-entrant call that path
    /// reaches is `subscriberDetached()`, which acquires `subscriptionLock`, never this lock.
    ///
    /// - Warning: That safety is specific to the cancel path. A subscriber's synchronous
    ///   value-handling callback must never call back into `currentInFlightUntil()`,
    ///   `currentlyBlocked()`, or the marking calls from inside its handler for this
    ///   emission: all of them acquire `emissionLock`, which -- unlike `subscriptionLock` -- this
    ///   thread is already holding right here, and `NSLock` is non-recursive, so a same-thread
    ///   re-acquisition would deadlock. No shipped subscriber does this today (only cancellation
    ///   reaches back in, and only into `subscriptionLock`), so the hazard is currently unreachable,
    ///   not exercised.
    private func publish(_ blocked: Bool, generation: UInt64) {
        emissionLock.lock()
        defer { emissionLock.unlock() }

        guard generation > lastPublishedGeneration else {
            return
        }
        lastPublishedGeneration = generation
        blockedSubject.send(blocked)
    }

    /// Persists the gate envelope atomically. The envelope carries one field now, so a write is a
    /// whole-state write by construction; an older file's dropped `resumeAtEpochSeconds` key does
    /// not survive it (see ``GateState``).
    private func write(inFlightUntil: Date?) {
        do {
            let state = GateState(
                version: Self.currentVersion,
                inFlightUntilEpochSeconds: inFlightUntil?.timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warn("MigrationSyncGate: failed to persist sync-gate state: \(error)")
        }
    }

    private static func readInFlightUntil(fileURL: URL, logger: Logger) -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(GateState.self, from: data)
            guard state.version == Self.currentVersion else {
                logger.warn("MigrationSyncGate: ignoring sync-gate file with unknown version \(state.version)")
                return nil
            }
            return state.inFlightUntilEpochSeconds.map { Date(timeIntervalSince1970: $0) }
        } catch {
            logger.warn("MigrationSyncGate: ignoring corrupt sync-gate file: \(error)")
            return nil
        }
    }
}
