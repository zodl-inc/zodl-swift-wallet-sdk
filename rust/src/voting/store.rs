//! Sidecar voting-database handle owned by the SDK, and the store-level
//! operations Swift drives outside a round session.
//!
//! One [`VotingDatabaseHandle`] is opened per sidecar file and held for the
//! app's lifetime. It keeps the *unscoped* root connection plus the wallet id
//! Swift sets after opening, and hands out a scoped `VotingDb` per call: the
//! crate scopes rows per wallet, so nothing below this module may run against
//! a handle whose wallet id is unset. Scoping is cheap — a scoped handle
//! clones the root's connection handle rather than opening one — so there is
//! nothing to cache and no lifetime to manage beyond this one.
//!
//! That is the contract a host is expected to keep, but this module does not
//! rely on it holding perfectly: every handle opened on one canonical sidecar
//! path shares one root — a handful of SQLite database names excepted, which
//! are never shared (see [`is_private_database_name`]) — so two callers that
//! each open their own handle on the same file serialize on that root
//! instead of contending for the file lock. A round session opened from a
//! handle keeps that handle's root alive for as long as the session runs,
//! even past the handle itself closing, so the same guarantee holds for a
//! handle re-opened while an older session on its path is still live — unless
//! the file itself is gone, in which case the re-opened handle gets a fresh
//! database rather than the old connection. See [`shared_root`].
//!
//! Everything here is synchronous and short: these are the reads and the
//! destructive edits a screen performs directly. Nothing here reaches the
//! network. Anything that does — proving, submission, helper delivery,
//! vote-tree sync — belongs to the session, which has a route to take it on.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

use zcash_voting::storage::VotingDb;

use super::errors::{VotingResultExt, internal, invalid_input};
use super::helpers::voting_network;
use super::wire::{KeystoneSignatureRecordDto, RoundPlanDto, RoundSummaryDto, plan_view};

/// Opaque handle over one open voting sidecar database.
///
/// `root` is deliberately never used for a wallet-scoped read or write: it
/// carries no wallet id, and `zcash_voting` panics rather than guesses when a
/// scoped operation runs without one. Callers go through [`Self::scoped`],
/// which fails with typed JSON while the wallet id is still unset.
pub struct VotingDatabaseHandle {
    /// The unscoped connection to the sidecar. Every scoped handle derived
    /// from it shares this one connection, so writers reached through this
    /// handle serialize on it instead of contending for the file. A second
    /// `zcashlc_voting_db_open` on the same canonical path shares this same
    /// root through the process-wide registry (see [`shared_root`]) instead
    /// of opening a second connection.
    root: Arc<VotingDb>,
    /// The wallet whose rows this handle reads and writes. `None` until Swift
    /// calls `zcashlc_voting_set_wallet_id`; a `Mutex` because the handle is
    /// shared across threads and the id can be set again on wallet switch.
    wallet_id: Mutex<Option<String>>,
    /// The voting identity of `network_id`, fixed once at open time because
    /// `zcash_voting` persists each round's network.
    pub(super) network: zcash_voting::Network,
    /// The SDK's numeric network id, kept so wallet-database and key
    /// derivation calls resolve the same (possibly custom) chain the handle
    /// was opened for.
    pub(super) network_id: u32,
}

/// Open sidecar roots, keyed by canonical path.
///
/// `VotingDb::open` gives every call its own SQLite connection, so two
/// backends opened on one sidecar would contend for the file lock instead of
/// serializing on one connection. The crate's `open_wallet_sidecar` prevents
/// that, but it derives the sidecar's path from the wallet database's, and
/// this SDK's sidecar lives where the host put it. The sharing is done here
/// instead: every handle opened on one path holds the same root, and each
/// scopes it to its own wallet through `VotingDb::scoped`.
///
/// The registry lock is held across the open, migrations included, so opens
/// serialize process-wide. A host opens one sidecar, so that costs nothing in
/// practice and keeps two racing opens of one path from both migrating it.
static ROOTS: OnceLock<Mutex<HashMap<PathBuf, RegisteredRoot>>> = OnceLock::new();

/// One registry entry: a root, and the file it was connected to.
struct RegisteredRoot {
    /// Weak, so a path nothing holds open any more releases its connection.
    root: Weak<VotingDb>,
    /// The file `root` was opened on, read once the open had returned.
    ///
    /// `None` where the platform exposes no identity for a file; see
    /// [`FileIdentity`].
    identity: Option<FileIdentity>,
}

impl RegisteredRoot {
    /// Whether this entry's root is still a connection to whatever `path`
    /// names now.
    ///
    /// A missing file answers no whatever the platform can tell: the root is
    /// then connected to an inode nothing can reach by name, and handing it to
    /// a caller that just asked for `path` would put that caller's rows in a
    /// database which disappears when the last handle on it closes.
    fn still_describes(&self, path: &str) -> bool {
        let Ok(metadata) = std::fs::metadata(path) else {
            return false;
        };
        match self.identity {
            Some(registered) => file_identity(&metadata) == Some(registered),
            // Nothing was recorded, so existence is the whole of what this
            // platform can check. It cannot tell a replacement apart from the
            // original; see [`FileIdentity`].
            None => true,
        }
    }
}

/// Which file on which device — what survives a rename and changes on a
/// delete-and-recreate, so it is what says whether a path still names the file
/// a root was opened on.
///
/// Unix only. This crate is built for Apple platforms and for the host running
/// its own unit tests, all of which are unix; elsewhere the identity is simply
/// unknown ([`file_identity`] answers `None`) and a reopened path that still
/// exists is reused as before. Losing the distinction there costs the
/// delete-and-recreate case, not the delete case, which
/// [`RegisteredRoot::still_describes`] answers without an identity at all.
#[derive(Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

/// The identity `metadata` describes, or `None` on a platform that exposes
/// none. See [`FileIdentity`].
#[cfg(unix)]
fn file_identity(metadata: &std::fs::Metadata) -> Option<FileIdentity> {
    use std::os::unix::fs::MetadataExt;
    Some(FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

#[cfg(not(unix))]
fn file_identity(_metadata: &std::fs::Metadata) -> Option<FileIdentity> {
    None
}

/// Whether `path` names a SQLite database that must never be shared through
/// the registry: the empty string, `:memory:`, or a `file:` URI.
///
/// An empty path is reachable through the FFI (`str_from_ptr` accepts a
/// zero-length string, see `helpers::str_from_ptr_zero_len_accepts_null`) and
/// names SQLite's own private on-disk temporary database — a fresh, unshared
/// file-backed database on every open, by SQLite's own documented contract
/// for it, exactly like `:memory:`. A `file:` URI is excepted wholesale
/// rather than parsed: it can itself name an in-memory or a temporary
/// database, or opt into SQLite's own `cache=shared` connection pooling, and
/// none of that is this registry's to interpret or to interfere with by
/// keying it into the map alongside ordinary paths.
fn is_private_database_name(path: &str) -> bool {
    path.is_empty() || path == ":memory:" || path.starts_with("file:")
}

/// A root `VotingDb` shared with every other handle already open on `path`,
/// unless the file it was opened on is no longer the file `path` names.
///
/// [`is_private_database_name`] paths are excepted and never shared: each
/// names a database SQLite itself never reuses across opens (or, for a
/// `file:` URI, whose sharing is the URI's own business). For every other
/// path, the registry lock is held for the whole call, including
/// `VotingDb::open`'s migration on a first open, so this must never be
/// called while that lock is already held on this thread. `VotingDb::open`
/// runs no code that calls back into this module — it only opens a
/// `rusqlite::Connection` and runs the crate's own migrations — so it cannot
/// re-enter `shared_root` and deadlock on the lock it is called under.
///
/// Sharing is conditional on the file still being there, and still being the
/// same one ([`RegisteredRoot::still_describes`]). The registry outlives a
/// handle — a live round session keeps its entry upgradable — while
/// [`registry_key`] yields the same key for a path whose file has been
/// deleted, so without that check a host that deleted the sidecar between two
/// opens would be handed a connection to the unlinked inode and write the new
/// wallet's rounds into a file that vanishes with the process. A root that
/// fails the check is left alone rather than dropped: whoever still holds it
/// asked for the old file and has it, and only the registry's answer for this
/// path changes.
fn shared_root(path: &str) -> anyhow::Result<Arc<VotingDb>> {
    if is_private_database_name(path) {
        return Ok(Arc::new(VotingDb::open(path).ffi()?));
    }
    let key = registry_key(path);
    // A poisoned lock is recovered rather than treated as fatal. This map is
    // mutated only by the `retain`/`insert` pair below, which runs after
    // `VotingDb::open` has already returned successfully — a panic while this
    // lock was held can only have come from a *previous* holder's own open,
    // or from a `VotingDb::open` this call itself is about to retry, never
    // from a half-finished mutation of the map. The crate's own two
    // process-wide registries recover from poison the same way and for the
    // same reason (`OPEN_SIDECARS` in `zcash_voting::storage`,
    // `sidecar_registry()` in `zcash_voting::round`). Treating it as fatal
    // instead would mean one panic anywhere inside a `VotingDb::open` call —
    // caught at the FFI boundary, but only after poisoning this mutex on the
    // way out — permanently disables `zcashlc_voting_db_open` for every path
    // for the rest of the process.
    let mut roots = ROOTS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(entry) = roots.get(&key)
        && let Some(root) = entry.root.upgrade()
        && entry.still_describes(path)
    {
        return Ok(root);
    }
    let root = Arc::new(VotingDb::open(path).ffi()?);
    // Read after the open, so the file is there to be identified even on a
    // first open that created it.
    let identity = std::fs::metadata(path)
        .ok()
        .as_ref()
        .and_then(file_identity);
    roots.retain(|_, entry| entry.root.strong_count() > 0);
    // Replaces a stale entry rather than merging with it: this root is the
    // answer for this path from now on, whatever the old one is still
    // connected to.
    roots.insert(
        key,
        RegisteredRoot {
            root: Arc::downgrade(&root),
            identity,
        },
    );
    Ok(root)
}

/// Test-only: take the registry lock and panic while still holding it.
///
/// Lets a test poison [`ROOTS`]'s lock deliberately, from another thread, so
/// it can then confirm the registry recovers a later open rather than
/// bricking it. Touches nothing in the map — the point is to prove that
/// merely holding the lock across a panic is harmless on its own, without
/// also having to reason about a mutation the panic interrupted partway.
#[cfg(test)]
fn poison_roots_lock_for_test() {
    let _guard = ROOTS.get_or_init(Default::default).lock().expect("lock");
    panic!("deliberately poisoning the sidecar registry lock (test)");
}

/// The registry key for `path`. Mirrors the crate's own
/// `zcash_voting::storage::sidecar_registry_key`.
///
/// Canonicalizing `path` whole succeeds once the sidecar exists, and that is
/// tried first: it also resolves a sidecar path that is itself a symlink to
/// its real target, so the symlink and the file it points at share one key.
/// Before the file exists, canonicalizing the PARENT directory and rejoining
/// the file name is the fallback — `.` stands in for an empty parent
/// component, so `voting.sqlite3` and `./voting.sqlite3` share a key too —
/// and a parent that cannot be canonicalized either (not created yet) keeps
/// the path exactly as given.
fn registry_key(path: &str) -> PathBuf {
    let path = Path::new(path);
    if let Ok(existing) = path.canonicalize() {
        return existing;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => {
            let parent = if parent.as_os_str().is_empty() {
                Path::new(".")
            } else {
                parent
            };
            parent
                .canonicalize()
                .map(|dir| dir.join(name))
                .unwrap_or_else(|_| path.to_path_buf())
        }
        _ => path.to_path_buf(),
    }
}

impl VotingDatabaseHandle {
    /// Open (or create) the sidecar at `path` for `network_id`.
    ///
    /// The network is resolved once, here, so no later call has to re-check
    /// it: a handle cannot exist for a network that does not. The root
    /// connection is shared with every other handle already open on the same
    /// canonical path — see [`shared_root`] — so only the first open on a
    /// path runs `VotingDb::open`'s migration of an existing schema-13
    /// sidecar; a later open reuses that migrated connection.
    /// [`is_private_database_name`] paths (an empty path, `:memory:`, a
    /// `file:` URI) are excepted and never shared.
    ///
    /// A path whose file was deleted or replaced since it was opened is not
    /// shared either: this call then opens a fresh database there. A session
    /// or handle still holding the old root keeps it — its connection is to
    /// the old file, which is what it asked for — so a host that deletes the
    /// sidecar while a round session is live leaves that session writing into
    /// a database nothing can reach by name any more. Close the sessions and
    /// the handles before deleting the file.
    pub(super) fn open(path: &str, network_id: u32) -> anyhow::Result<Self> {
        let network = voting_network(network_id)?;
        let root = shared_root(path)?;
        Ok(VotingDatabaseHandle {
            root,
            wallet_id: Mutex::new(None),
            network,
            network_id,
        })
    }

    /// A clone of this handle's shared root.
    ///
    /// The clone is a second strong reference to the very same `Arc<VotingDb>`
    /// allocation as [`Self::root`] — unlike [`Self::scoped`], which wraps a
    /// distinct `VotingDb` value (and so a distinct allocation) over the same
    /// underlying connection. Anything that must keep this handle's root
    /// findable through the registry after this handle itself is dropped
    /// holds this clone instead: a round session outliving the handle it was
    /// opened from is why this exists.
    pub(super) fn shared_root_handle(&self) -> Arc<VotingDb> {
        Arc::clone(&self.root)
    }

    /// Bind every subsequent operation to `wallet_id`.
    ///
    /// An empty id is refused here rather than at the first scoped call, so a
    /// host that forgot to supply one learns at the point of the mistake.
    pub(super) fn set_wallet_id(&self, wallet_id: &str) -> anyhow::Result<()> {
        if wallet_id.is_empty() {
            return Err(invalid_input("wallet id must not be empty"));
        }
        *self.wallet_id_slot()? = Some(wallet_id.to_string());
        Ok(())
    }

    /// The wallet id bound to this handle.
    pub(super) fn wallet_id(&self) -> anyhow::Result<String> {
        self.wallet_id_slot()?.clone().ok_or_else(|| {
            invalid_input("wallet id is not set; call zcashlc_voting_set_wallet_id first")
        })
    }

    /// A handle on the same connection, scoped to this handle's wallet.
    pub(super) fn scoped(&self) -> anyhow::Result<Arc<VotingDb>> {
        Ok(self.scoped_with_id()?.0)
    }

    /// [`Self::scoped`] plus the wallet id it scoped to.
    ///
    /// For the one caller that needs both. Reading the id a second time from
    /// the handle would be reading it after a wallet switch could have
    /// replaced it, which would ask one wallet's question of another wallet's
    /// rows; taking both from one read cannot disagree.
    pub(super) fn scoped_with_id(&self) -> anyhow::Result<(Arc<VotingDb>, String)> {
        let wallet_id = self.wallet_id()?;
        let db = Arc::new(self.root.scoped(&wallet_id).ffi()?);
        Ok((db, wallet_id))
    }

    fn wallet_id_slot(&self) -> anyhow::Result<MutexGuard<'_, Option<String>>> {
        self.wallet_id
            .lock()
            .map_err(|_| internal("voting wallet id lock is poisoned"))
    }
}

/// Every round this wallet has in the sidecar, newest first.
pub(super) fn list_rounds(h: &VotingDatabaseHandle) -> anyhow::Result<Vec<RoundSummaryDto>> {
    Ok(h.scoped()?
        .list_rounds()
        .ffi()?
        .into_iter()
        .map(RoundSummaryDto::from)
        .collect())
}

/// The plan for `round_id` against the authenticated `proposal_ids`.
///
/// The roster is the caller's: `zcash_voting` classifies stored ballot intents
/// against exactly the proposals passed here, so an intent outside the
/// authenticated roster is reported as withheld rather than acted on.
pub(super) fn round_plan(
    h: &VotingDatabaseHandle,
    round_id: &str,
    proposal_ids: &[u32],
) -> anyhow::Result<RoundPlanDto> {
    let db = h.scoped()?;
    let plan = zcash_voting::session::resume_plan(&db, round_id, proposal_ids).ffi()?;
    let has_legacy_in_flight_submission = legacy_in_flight(&db, round_id, &plan)?;
    Ok(RoundPlanDto {
        plan: plan_view(plan)?,
        has_legacy_in_flight_submission,
    })
}

/// Whether `round_id` holds a submission *this wallet built* and an older SDK
/// dispatched without ever seeing it confirmed.
///
/// A sidecar first gains the lifecycle table at schema 18, and the migration
/// that adds it imports none of the evidence beside it: a delegation or a vote
/// that carried only a transaction hash keeps carrying only that. The crate's
/// typed phases project such a row as `Submitted`, which the 5.x lifecycle
/// never produces for work it reserved itself — anything it owns projects as
/// `SubmissionManaged`, `SubmittedWithoutHash`, `SubmissionRejected` or
/// `Confirmed` — so `Submitted` is the evidence an older build left behind.
///
/// It is not, on its own, evidence of a *resumable* dispatch. A delegation
/// imported from a capability package reaches the same phase from a hash
/// somebody else broadcast, and carries none of the material a dispatch is
/// made of: no note selection, no PCZT, no proof. The lifecycle adopts that
/// hash on its first pass and never asks the voter for a signer or sends the
/// transaction again, so there is nothing to re-dispatch and the round is
/// driven normally. Those bundles are excluded, using the distinction the
/// planner already made: it is the crate's own classifier that decides whether
/// a bundle's delegation work is `AdvanceImportedDelegation`, and this reads
/// that decision off the typed plan rather than re-deriving it from columns.
///
/// The vote half has no such exception: a vote reaching `Submitted` was built
/// and cast by this wallet either way.
///
/// This is computed here rather than read off the plan because the plan's JSON
/// view carries no per-vote phase at all, so a host could not tell a legacy
/// vote from a lifecycle-owned one.
pub(super) fn legacy_in_flight(
    db: &VotingDb,
    round_id: &str,
    plan: &zcash_voting::session::RoundPlan,
) -> anyhow::Result<bool> {
    use zcash_voting::phases::{DelegationPhase, VotePhase};
    use zcash_voting::session::NextStep;

    // `NextStep` is `#[non_exhaustive]`, so this matches the one variant it
    // needs and ignores the rest by design: a step kind added upstream is not
    // an imported delegation until something says it is.
    let imported: std::collections::BTreeSet<u32> = plan
        .next_steps
        .iter()
        .filter_map(|step| match step {
            NextStep::AdvanceImportedDelegation { bundle_index } => Some(*bundle_index),
            _ => None,
        })
        .collect();

    let delegations = db.delegation_phases(round_id).ffi()?;
    let votes = db.vote_phases(round_id).ffi()?;
    Ok(delegations.iter().any(|(bundle_index, phase)| {
        matches!(phase, DelegationPhase::Submitted) && !imported.contains(bundle_index)
    }) || votes
        .iter()
        .any(|(_, _, phase)| matches!(phase, VotePhase::Submitted)))
}

/// Rounds of this wallet with helper-share work still outstanding.
///
/// This is what tells the host whether it still owes share tracking, so it
/// is the query the app polls on entering the voting flow and on foreground
/// while anything is pending.
pub(super) fn pending_share_rounds(
    h: &VotingDatabaseHandle,
) -> anyhow::Result<Vec<zcash_voting::wire::PendingShareRoundView>> {
    // The crate's multi-account entry point re-scopes per wallet id and
    // ignores the handle's own, so the id is passed explicitly. The SDK holds
    // one handle per wallet, so that list is always this wallet alone — and
    // the id comes back from the same read that scoped the handle, so a wallet
    // switch between the two cannot ask one wallet's question of another's
    // rows.
    let (db, wallet_id) = h.scoped_with_id()?;
    Ok(
        zcash_voting::share::pending_rounds_for_accounts(&db, &[wallet_id.as_str()])
            .ffi()?
            .into_iter()
            .map(zcash_voting::wire::PendingShareRoundView::from)
            .collect(),
    )
}

/// Drop the cached vote-tree state for one round.
///
/// An empty `round_id` is the crate's wallet-wide reset, not a no-op: it
/// forgets every round's cached tree state for this wallet. Callers that mean
/// one round must pass its id.
pub(super) fn reset_vote_tree(h: &VotingDatabaseHandle, round_id: &str) -> anyhow::Result<()> {
    let db = h.scoped()?;
    zcash_voting::precompute::reset_vote_tree(&db, round_id).ffi()
}

/// Return a round to a re-runnable state after an interrupted setup.
///
/// Drops the cached tree state and clears the locally prepared *unsigned*
/// delegation setup fields, so an abandoned Keystone request can be rebuilt.
/// Proved or submitted bundles, imported capabilities and stored signatures
/// survive: this is a retry, not a deletion.
///
/// An empty `round_id` resets only the cached tree state, wallet-wide, and
/// clears no persisted column — the crate's guard, which is why this calls the
/// crate's combined entry point rather than its two halves.
pub(super) fn reset_session_state(h: &VotingDatabaseHandle, round_id: &str) -> anyhow::Result<()> {
    let db = h.scoped()?;
    zcash_voting::precompute::reset_voting_session_state(&db, round_id).ffi()
}

/// Delete one round.
///
/// The default refuses once part of the round has reached the network, because
/// its stored setup is then the only thing that can reproduce its voting
/// weight. `discard_recovery` is the deliberate abandonment path past that
/// refusal, and the weight does not come back.
pub(super) fn delete_round(
    h: &VotingDatabaseHandle,
    round_id: &str,
    discard_recovery: bool,
) -> anyhow::Result<()> {
    let db = h.scoped()?;
    if discard_recovery {
        db.delete_round_discarding_recovery(round_id).ffi()
    } else {
        db.delete_round(round_id).ffi()
    }
}

/// Drop bundle rows at index `>= keep_count`, returning how many were deleted.
pub(super) fn delete_skipped_bundles(
    h: &VotingDatabaseHandle,
    round_id: &str,
    keep_count: u32,
) -> anyhow::Result<u64> {
    h.scoped()?
        .delete_skipped_bundles(round_id, keep_count)
        .ffi()
}

/// Forget a bundle's combined-cast rejection streak, returning whether one was
/// recorded.
///
/// The block is advisory — the wallet stops re-proving a delegation the chain
/// keeps refusing — so this is the voter's explicit "the cause is fixed".
pub(super) fn retry_blocked_combined_cast(
    h: &VotingDatabaseHandle,
    round_id: &str,
    bundle_index: u32,
) -> anyhow::Result<bool> {
    h.scoped()?
        .retry_blocked_combined_cast(round_id, bundle_index)
        .ffi()
}

/// Clear the stored ballot intent for each of `proposal_ids`.
///
/// Applied one proposal at a time, as the crate exposes it: a proposal whose
/// vote the chain lifecycle already owns fails, and the call stops there
/// rather than clearing the rest behind a partial success.
pub(super) fn clear_ballot_intents(
    h: &VotingDatabaseHandle,
    round_id: &str,
    proposal_ids: &[u32],
) -> anyhow::Result<()> {
    let db = h.scoped()?;
    for &proposal_id in proposal_ids {
        db.clear_ballot_intent(round_id, proposal_id).ffi()?;
    }
    Ok(())
}

/// The Keystone signatures stored for a round, for `KeystoneSignatureSource::Stored` reuse.
pub(super) fn keystone_signatures(
    h: &VotingDatabaseHandle,
    round_id: &str,
) -> anyhow::Result<Vec<KeystoneSignatureRecordDto>> {
    Ok(h.scoped()?
        .get_keystone_signatures(round_id)
        .ffi()?
        .into_iter()
        .map(KeystoneSignatureRecordDto::from)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::test_support::{hex_round_id, open_memory_store, synthetic_round_params};
    // The two crate enums the characterization assertions below name, aliased
    // because they read as the plan's own vocabulary at the assertion site.
    use zcash_voting::wire::{NextStepKind as Step, WorkflowPhaseView as Phase};

    #[test]
    fn open_rejects_unknown_network_and_requires_wallet_id() {
        assert!(VotingDatabaseHandle::open(":memory:", 99).is_err());
        let handle = VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_MAINNET).unwrap();
        assert!(
            handle.scoped().is_err(),
            "scoped without wallet id must fail"
        );
        handle.set_wallet_id("w").unwrap();
        assert!(handle.scoped().is_ok());
    }

    #[test]
    fn list_rounds_reflects_created_rounds() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        assert!(list_rounds(&handle).unwrap().is_empty());
        let params = synthetic_round_params(0x11, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        let rounds = list_rounds(&handle).unwrap();
        assert_eq!(rounds.len(), 1);
        assert_eq!(rounds[0].round_id, hex_round_id(0x11));
        assert_eq!(rounds[0].snapshot_height, 123);
    }

    /// `needs_bundle_setup` is narrower than "this round has no bundles": the
    /// crate raises it only for a round that *holds a ballot choice* and has
    /// no bundle rows to cast it into, which is the one ordering a host can
    /// resolve. A round nobody has decided on yet owes a draft instead, so
    /// both sides of that distinction are asserted here.
    #[test]
    fn round_plan_reports_bundle_setup_once_a_ballot_choice_exists() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x12, 123);
        let db = handle.scoped().unwrap();
        db.ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2])
            .unwrap()
            .plan;
        assert_eq!(plan.round_id, hex_round_id(0x12));
        assert!(!plan.needs_bundle_setup);
        assert!(plan.needs_draft_setup);

        db.set_ballot_intent(
            &hex_round_id(0x12),
            1,
            zcash_voting::session::Decision::Choice(0),
            2,
        )
        .unwrap();

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2])
            .unwrap()
            .plan;
        assert_eq!(plan.round_id, hex_round_id(0x12));
        assert!(plan.needs_bundle_setup);
    }

    /// An id the sidecar has never seen is not an error: planning reads a
    /// round's rows, and a round with none plans as an empty round that owes a
    /// draft. What must hold is that the *error* path is decodable JSON rather
    /// than a panic or a bare message, so a roster the crate refuses is
    /// checked alongside it.
    #[test]
    fn round_plan_for_unknown_round_is_an_idle_plan_and_a_bad_roster_is_a_json_error() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");

        let plan = round_plan(&handle, &hex_round_id(0xfe), &[1]).unwrap().plan;
        assert_eq!(plan.round_id, hex_round_id(0xfe));
        assert!(plan.next_steps.is_empty());
        assert!(plan.needs_draft_setup);

        let err = round_plan(&handle, &hex_round_id(0xfe), &[0]).unwrap_err();
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        assert!(!view.message.is_empty());
    }

    /// `share::pending_rounds_for_accounts` silently drops empty wallet ids,
    /// so a handle that failed to plumb one through would answer `[]` and look
    /// healthy. Asserting that an unbound handle *fails* is what distinguishes
    /// "no pending rounds" from "asked about no wallet".
    #[test]
    fn pending_share_rounds_requires_a_bound_wallet() {
        let handle = VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_MAINNET).unwrap();
        let err = pending_share_rounds(&handle).unwrap_err();
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    /// The wallet id the pending-share query runs under is the one the handle
    /// is scoped to at the moment of the call, taken from a single read.
    ///
    /// The crate's multi-account entry point takes the id as an argument and
    /// ignores the scoped handle's own, so an id read separately from the
    /// scope could ask one wallet's question of another's rows. Switching the
    /// handle between two wallets is what makes a mismatch visible.
    #[test]
    fn pending_share_rounds_follows_the_handle_to_the_current_wallet() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "wallet-a");
        let params = synthetic_round_params(0x15, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        assert_eq!(list_rounds(&handle).unwrap().len(), 1);

        handle.set_wallet_id("wallet-b").unwrap();
        assert!(list_rounds(&handle).unwrap().is_empty());
        assert!(pending_share_rounds(&handle).unwrap().is_empty());

        let (db, wallet_id) = handle.scoped_with_id().unwrap();
        assert_eq!(wallet_id, "wallet-b");
        assert!(db.list_rounds().unwrap().is_empty());
    }

    #[test]
    fn delete_round_removes_it_and_pending_share_rounds_is_empty() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x13, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        assert!(pending_share_rounds(&handle).unwrap().is_empty());
        delete_round(&handle, &hex_round_id(0x13), false).unwrap();
        assert!(list_rounds(&handle).unwrap().is_empty());
    }

    /// A schema-13 sidecar left by an older core opens, migrates in place to
    /// the schema this crate speaks, and keeps the rows it carried.
    ///
    /// The upgrade is one-way — a migrated file cannot be reopened by the core
    /// that wrote it — so what has to hold is that nothing is lost on the way
    /// through. The fixture is the schema-13 DDL verbatim; the rows and the
    /// `user_version` stamp are set here, because that is what a sidecar in the
    /// field carries and a bare DDL file does not.
    ///
    /// A characterization test: it pins the migration the crate performs, not
    /// behaviour this SDK implements, so a change upstream that drops rows or
    /// lands on a different schema version fails here rather than on a device.
    #[test]
    fn opening_a_version_13_sidecar_migrates_to_24_and_keeps_rows() {
        const FIXTURE_WALLET: &str = "schema13-wallet";

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("voting.sqlite3");
        {
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.execute_batch(include_str!("fixtures/schema13.sql"))
                .unwrap();
            conn.pragma_update(None, "user_version", 13).unwrap();
            // Two rounds of one wallet, one of them carrying a bundle: enough
            // for a migration that dropped rows, renamed the wallet scope or
            // broke the bundle foreign key to show up as a count. The bundle
            // carries a value so the contents can be read back too — a
            // migration that rebuilt the table with the right row count but
            // the wrong columns would otherwise pass.
            for tag in [0x51u8, 0x52] {
                conn.execute(
                    "INSERT INTO rounds(round_id, wallet_id, network, snapshot_height, \
                     ea_pk, nc_root, nullifier_imt_root, created_at) \
                     VALUES (?1, ?2, 'mainnet', 4200000, ?3, ?3, ?3, 1)",
                    (hex_round_id(tag), FIXTURE_WALLET, vec![tag; 32]),
                )
                .unwrap();
            }
            conn.execute(
                "INSERT INTO bundles(round_id, wallet_id, bundle_index, total_note_value) \
                 VALUES (?1, ?2, 0, 12500000)",
                (hex_round_id(0x51), FIXTURE_WALLET),
            )
            .unwrap();

            let version: u32 = conn
                .query_row("PRAGMA user_version", [], |r| r.get(0))
                .unwrap();
            assert_eq!(version, 13, "the fixture is a version-13 sidecar");
        }

        let counts_before = sidecar_counts(&path);
        assert!(counts_before.0 >= 1, "the fixture carries rounds to keep");

        let handle = VotingDatabaseHandle::open(path.to_str().unwrap(), crate::NETWORK_ID_MAINNET)
            .expect("opening a version-13 sidecar migrates it");
        handle.set_wallet_id(FIXTURE_WALLET).unwrap();

        let version: u32 = rusqlite::Connection::open(&path)
            .unwrap()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 24, "the sidecar is migrated in place");

        let counts_after = sidecar_counts(&path);
        assert_eq!(
            counts_after, counts_before,
            "the migration kept every round and bundle row"
        );

        let total_note_value: i64 = rusqlite::Connection::open(&path)
            .unwrap()
            .query_row(
                "SELECT total_note_value FROM bundles WHERE round_id = ?1 AND bundle_index = 0",
                (hex_round_id(0x51),),
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            total_note_value, 12_500_000,
            "the migration kept the bundle's stored value, not just its row"
        );

        // The rows are not merely present but readable as this wallet's: the
        // migration preserved the wallet scope the fixture rows were written
        // under.
        let listed = list_rounds(&handle).unwrap();
        assert_eq!(listed.len() as i64, counts_after.0);
        let mut ids = listed
            .iter()
            .map(|r| r.round_id.as_str())
            .collect::<Vec<_>>();
        ids.sort_unstable();
        assert_eq!(ids, vec![hex_round_id(0x51), hex_round_id(0x52)]);
    }

    /// `(rounds, bundles)` row counts read from a fresh connection.
    fn sidecar_counts(path: &std::path::Path) -> (i64, i64) {
        let conn = rusqlite::Connection::open(path).unwrap();
        let count = |table: &str| {
            conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap()
        };
        (count("rounds"), count("bundles"))
    }

    // MARK: the boundary at the upgrade

    /// The state an older SDK left one round in, as a schema-13 sidecar holds
    /// it.
    ///
    /// Every variant is written with a raw connection against the schema-13
    /// DDL, because that is the point: these rows predate the lifecycle table,
    /// which the sidecar first gains at schema 18, and the migration adds that
    /// table empty rather than importing the evidence beside it. A transaction
    /// hash on a bundle or a vote is therefore all that is left of a dispatch
    /// the older build made.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum LegacyFixture {
        /// The ballot was decided and the bundle laid out; nothing was built,
        /// signed or dispatched.
        SetUpOnly,
        /// The delegation was dispatched and never seen confirmed: a
        /// transaction hash on the bundle and no VAN position.
        DelegationSubmitted,
        /// A delegation imported from a capability package and not yet seen
        /// confirmed: a transaction hash somebody else broadcast, with none of
        /// the local material a wallet's own delegation carries.
        ///
        /// The same columns `zcash_voting`'s `import_delegation_capability`
        /// writes, which the previously released SDK exposed as
        /// `zcashlc_voting_restore_recovered_delegation`, so a schema-13
        /// sidecar can hold exactly this.
        CapabilityImported,
        /// The delegation confirmed, and the vote was dispatched and never
        /// seen confirmed: a transaction hash on the vote, no tree position,
        /// and the recovery material the older build persisted before it
        /// dispatched.
        VoteSubmitted,
        /// [`Self::VoteSubmitted`] with the recovery material missing. The
        /// older build's call order wrote that column before it recorded a
        /// hash, so this is not a shape it produced, and 5.1.0 refuses to plan
        /// it at all.
        VoteSubmittedWithoutRecovery,
        /// Everything the older build dispatched was confirmed, shares
        /// included.
        AllConfirmed,
    }

    const LEGACY_WALLET: &str = "legacy-wallet";
    /// The one proposal the fixture's voter chose; 1 and 3 are skipped, so the
    /// roster is fully decided before anything is dispatched.
    const LEGACY_PROPOSAL: u32 = 2;
    const LEGACY_CHOICE: u32 = 1;
    const LEGACY_ROSTER: &[u32] = &[1, 2, 3];

    /// A schema-13 sidecar in `fixture`'s state, migrated by opening it.
    ///
    /// The returned directory must outlive the handle: the sidecar is a real
    /// file, both because the migration is what this exercises and because
    /// every handle on one path shares a root, so each fixture needs a path of
    /// its own.
    fn migrated_schema13_sidecar(
        fixture: LegacyFixture,
    ) -> (VotingDatabaseHandle, String, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let round_id = hex_round_id(0x61);
        let imported_capability = matches!(fixture, LegacyFixture::CapabilityImported);
        let dispatched_delegation =
            !matches!(fixture, LegacyFixture::SetUpOnly) && !imported_capability;
        let confirmed_delegation = matches!(
            fixture,
            LegacyFixture::VoteSubmitted
                | LegacyFixture::VoteSubmittedWithoutRecovery
                | LegacyFixture::AllConfirmed
        );
        let dispatched_vote = confirmed_delegation;
        let confirmed_vote = matches!(fixture, LegacyFixture::AllConfirmed);

        {
            let conn = rusqlite::Connection::open(&path).expect("open fixture");
            conn.execute_batch(include_str!("fixtures/schema13.sql"))
                .expect("schema 13 ddl");
            conn.execute(
                "INSERT INTO rounds(round_id, wallet_id, network, snapshot_height, \
                 ea_pk, nc_root, nullifier_imt_root, created_at) \
                 VALUES (?1, ?2, 'mainnet', 4200000, ?3, ?3, ?3, 1)",
                (&round_id, LEGACY_WALLET, vec![0x61u8; 32]),
            )
            .expect("round row");

            // The ballot the voter completed before anything reached the
            // chain: one choice and two deliberate skips, so the roster the
            // plan is read against is fully decided.
            for (proposal_id, skipped, choice) in [
                (1u32, 1i64, None),
                (LEGACY_PROPOSAL, 0, Some(i64::from(LEGACY_CHOICE))),
                (3, 1, None),
            ] {
                conn.execute(
                    "INSERT INTO ballot_intent(round_id, wallet_id, proposal_id, skipped, \
                     choice, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 1, 1)",
                    (&round_id, LEGACY_WALLET, proposal_id, skipped, choice),
                )
                .expect("ballot intent row");
            }

            if imported_capability {
                // Exactly the columns the crate's `import_delegation_capability`
                // writes: the package's commitments, its weight, and the
                // transaction hash of a delegation somebody else broadcast.
                // Every field a locally built bundle carries stays NULL,
                // `note_positions_blob` included, which is how the planner
                // recognizes the import.
                conn.execute(
                    "INSERT INTO bundles(round_id, wallet_id, bundle_index, van_comm_rand, \
                     gov_comm, total_note_value, address_index, delegation_tx_hash) \
                     VALUES (?1, ?2, 0, ?3, ?4, 12500000, 0, 'dtx')",
                    (&round_id, LEGACY_WALLET, vec![0x63u8; 32], vec![0x64u8; 32]),
                )
                .expect("imported bundle row");
            } else {
                // The note selection a locally laid-out bundle always persists
                // — two note positions as little-endian `u64`s, with an opaque
                // 32-byte identity digest each. It has to be here: the planner
                // reads a bundle whose `note_positions_blob` is NULL as an
                // imported delegation capability, which is somebody else's
                // delegation already on the chain, not a dispatch of this
                // wallet's own.
                //
                // Deliberately out of scope: `van_comm_rand`, `gov_comm` and
                // the rest of the proving and signing material a bundle that
                // really built a governance transaction carries. Nothing any
                // projection under test reads touches them, so the row is the
                // phase evidence rather than a complete picture of a
                // dispatched bundle.
                let note_positions = [17u64, 23]
                    .iter()
                    .flat_map(|position| position.to_le_bytes())
                    .collect::<Vec<u8>>();
                let note_identity_hashes = [0x81u8, 0x82]
                    .iter()
                    .flat_map(|tag| [*tag; 32])
                    .collect::<Vec<u8>>();
                conn.execute(
                    "INSERT INTO bundles(round_id, wallet_id, bundle_index, note_positions_blob, \
                     note_identity_hashes_blob, total_note_value, address_index, pczt_sighash, \
                     delegation_tx_hash, van_leaf_position) \
                     VALUES (?1, ?2, 0, ?3, ?4, 12500000, 0, ?5, ?6, ?7)",
                    (
                        &round_id,
                        LEGACY_WALLET,
                        note_positions,
                        note_identity_hashes,
                        dispatched_delegation.then(|| vec![0x62u8; 32]),
                        dispatched_delegation.then_some("dtx"),
                        confirmed_delegation.then_some(7i64),
                    ),
                )
                .expect("bundle row");
            }

            // A dispatched delegation was proved first, and the proof row is
            // what says so.
            if dispatched_delegation {
                conn.execute(
                    "INSERT INTO proofs(round_id, wallet_id, bundle_index, success, created_at) \
                     VALUES (?1, ?2, 0, 1, 1)",
                    (&round_id, LEGACY_WALLET),
                )
                .expect("proof row");
            }

            if dispatched_vote {
                let recovery = (fixture != LegacyFixture::VoteSubmittedWithoutRecovery)
                    .then(|| legacy_vote_recovery_json(&round_id, confirmed_vote));
                conn.execute(
                    "INSERT INTO votes(round_id, wallet_id, bundle_index, proposal_id, choice, \
                     commitment, created_at, tx_hash, vc_tree_position, commitment_bundle_json) \
                     VALUES (?1, ?2, 0, ?3, ?4, ?5, 1, 'vtx', ?6, ?7)",
                    (
                        &round_id,
                        LEGACY_WALLET,
                        LEGACY_PROPOSAL,
                        LEGACY_CHOICE,
                        vec![0xCCu8; 16],
                        confirmed_vote.then_some(LEGACY_VC_TREE_POSITION as i64),
                        recovery,
                    ),
                )
                .expect("vote row");
            }

            // A confirmed vote owes its helper shares, so "everything
            // confirmed" has to include them or the round is not finished.
            if confirmed_vote {
                for share_index in 0..2u32 {
                    conn.execute(
                        "INSERT INTO share_delegations(round_id, wallet_id, bundle_index, \
                         proposal_id, share_index, sent_to_urls, nullifier, confirmed, \
                         submit_at, created_at) \
                         VALUES (?1, ?2, 0, ?3, ?4, '[\"https://helper.example/\"]', ?5, 1, 0, 1)",
                        (
                            &round_id,
                            LEGACY_WALLET,
                            LEGACY_PROPOSAL,
                            share_index,
                            vec![0x70u8 + share_index as u8; 32],
                        ),
                    )
                    .expect("share row");
                }
            }

            conn.pragma_update(None, "user_version", 13)
                .expect("stamp version 13");
        }

        let handle =
            VotingDatabaseHandle::open(path.to_str().expect("utf-8"), crate::NETWORK_ID_MAINNET)
                .expect("a schema-13 sidecar opens and migrates");
        handle.set_wallet_id(LEGACY_WALLET).expect("wallet id");
        (handle, round_id, dir)
    }

    /// The tree position a confirmed fixture vote carries.
    const LEGACY_VC_TREE_POSITION: u64 = 42;

    /// The recovery material the older build persisted when it committed a
    /// vote, in the crate's own `zcash_voting_vote_recovery_v1` JSON.
    ///
    /// Written through the crate's serializer rather than by hand, so the
    /// bytes in the fixture are the bytes the format actually produces and the
    /// planner can parse them back.
    fn legacy_vote_recovery_json(round_id: &str, confirmed: bool) -> String {
        let share =
            |tag: u8, share_index: u32, plaintext_value: u64| zcash_voting::types::EncryptedShare {
                c1: vec![tag; 32],
                c2: vec![tag + 1; 32],
                share_index,
                plaintext_value,
                randomness: vec![tag + 2; 32],
            };
        zcash_voting::vote::serialize_recovery(&zcash_voting::vote::VoteRecoveryBundle {
            vote_round_id: round_id.to_string(),
            bundle_index: 0,
            proposal_id: LEGACY_PROPOSAL,
            vote_decision: LEGACY_CHOICE,
            anchor_height: 123,
            vc_tree_position: if confirmed {
                LEGACY_VC_TREE_POSITION
            } else {
                0
            },
            single_share: false,
            num_options: 3,
            van_nullifier: [0x10; 32],
            vote_authority_note_new: [0x11; 32],
            vote_commitment: [0x12; 32],
            proof: vec![0x13; 96],
            shares_hash: [0x14; 32],
            r_vpk: [0x15; 32],
            alpha_v: [0x16; 32],
            vote_auth_sig: [0x17; 64],
            encrypted_shares: vec![share(0x21, 0, 5), share(0x31, 1, 6)],
            share_blinds: vec![[0x41; 32], [0x42; 32]],
            share_comms: vec![[0x51; 32], [0x52; 32]],
            batch: None,
        })
        .expect("recovery json")
    }

    /// The `kind` of every step a plan owes, in order.
    fn step_kinds(plan: &RoundPlanDto) -> Vec<zcash_voting::wire::NextStepKind> {
        plan.plan.next_steps.iter().map(|step| step.kind).collect()
    }

    /// The phase of every bundle's delegation, in bundle order.
    fn delegation_phases(plan: &RoundPlanDto) -> Vec<zcash_voting::wire::WorkflowPhaseView> {
        plan.plan
            .delegation_statuses
            .iter()
            .map(|status| status.phase)
            .collect()
    }

    /// A delegation the older build dispatched and never saw confirmed: the
    /// bundle carries a transaction hash and no VAN position.
    ///
    /// Everything asserted past the flag is characterization — upstream
    /// specifies no outcome for resuming this, so what is pinned is what
    /// 5.1.0 in fact says. It says the round is ordinary work: an
    /// `advance_delegation` step that would re-dispatch the same transaction
    /// bytes, with the cast queued behind it.
    #[test]
    fn a_migrated_round_with_an_unconfirmed_legacy_delegation_reports_legacy_in_flight() {
        let (handle, round_id, _dir) =
            migrated_schema13_sidecar(LegacyFixture::DelegationSubmitted);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");

        assert!(plan.has_legacy_in_flight_submission);
        assert_eq!(delegation_phases(&plan), [Phase::SubmittedDelegation]);
        assert_eq!(step_kinds(&plan), [Step::AdvanceDelegation, Step::CastVote]);
        let json = serde_json::to_value(&plan).expect("json");
        assert_eq!(json["primary_action"], "delegate");
        assert_eq!(
            json["delegation_statuses"][0]["phase"],
            "submitted_delegation"
        );
        assert!(plan.plan.has_in_flight_delegation);
        assert!(plan.plan.pending_recovery);
        assert!(plan.plan.blocking_recovery);
    }

    /// A vote the older build dispatched and never saw confirmed, behind a
    /// delegation that did confirm.
    ///
    /// The plan carries no vote phase at all, which is why the flag cannot be
    /// derived from it: the only thing distinguishing this from a vote the
    /// 5.x lifecycle is tracking is the `advance_vote` step, and a lifecycle
    /// vote under recovery plans the same step.
    #[test]
    fn a_migrated_round_with_an_unconfirmed_legacy_vote_reports_legacy_in_flight() {
        let (handle, round_id, _dir) = migrated_schema13_sidecar(LegacyFixture::VoteSubmitted);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");

        assert!(plan.has_legacy_in_flight_submission);
        assert_eq!(delegation_phases(&plan), [Phase::Confirmed]);
        assert_eq!(step_kinds(&plan), [Step::AdvanceVote]);
        let json = serde_json::to_value(&plan).expect("json");
        assert_eq!(json["primary_action"], "vote");
        assert_eq!(json["recovered_vote_work"][0]["tx_hash"], "vtx");
        assert!(plan.plan.needs_vote_polling);
        assert!(plan.plan.pending_recovery);
        assert!(plan.plan.blocking_recovery);
    }

    #[test]
    fn a_migrated_round_whose_legacy_submissions_all_confirmed_does_not() {
        let (handle, round_id, _dir) = migrated_schema13_sidecar(LegacyFixture::AllConfirmed);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");

        assert!(!plan.has_legacy_in_flight_submission);
        assert_eq!(delegation_phases(&plan), [Phase::Confirmed]);
        assert!(step_kinds(&plan).is_empty());
        assert_eq!(
            serde_json::to_value(&plan).expect("json")["primary_action"],
            "done"
        );
        assert!(plan.plan.completed_for_display);
        assert!(!plan.plan.pending_recovery);
        assert!(!plan.plan.blocking_recovery);
    }

    /// A delegation imported from a capability is NOT a legacy in-flight
    /// submission, although its phase is the same `Submitted`.
    ///
    /// The row carries a transaction hash somebody else broadcast and none of
    /// the material a dispatch is made of — no note selection, no PCZT, no
    /// proof — so there is nothing here to re-dispatch. The lifecycle adopts
    /// the package hash on its first pass and never asks the voter for a
    /// signer, which is what `advance_imported_delegation` is for, so the harm
    /// the flag exists to prevent cannot happen. Firing it would do harm
    /// instead: the host would make the round display-only and the voter could
    /// never cast, over work that finishes normally.
    #[test]
    fn a_migrated_round_whose_delegation_was_imported_from_a_capability_does_not() {
        let (handle, round_id, _dir) = migrated_schema13_sidecar(LegacyFixture::CapabilityImported);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");

        assert!(!plan.has_legacy_in_flight_submission);
        // The phase is the same one a legacy dispatch reaches, which is why
        // the phase alone cannot decide this.
        assert_eq!(delegation_phases(&plan), [Phase::SubmittedDelegation]);
        assert_eq!(step_kinds(&plan), [Step::AdvanceImportedDelegation]);
        let json = serde_json::to_value(&plan).expect("json");
        assert_eq!(json["primary_action"], "delegate");
        assert_eq!(
            json["recovered_delegation_work"][0]["kind"],
            "advance_imported_delegation"
        );
        // The voter is never asked for signing material, because the
        // transaction is already broadcast and this wallet holds no key that
        // could re-sign it — the reason there is nothing here to re-dispatch.
        assert!(!plan.plan.needs_delegation_signing);
        assert!(plan.plan.delegation_bundles_needing_signing.is_empty());
        assert!(plan.plan.has_in_flight_delegation);
        // The cast waits for the imported delegation to confirm, so this round
        // is real work the host must be able to drive to the end.
        assert!(plan.plan.pending_recovery);
        assert_eq!(plan.plan.delegation_bundles_needing_work, vec![0]);
    }

    /// A round the older build only set up reports `false` and is ordinary
    /// work: nothing of it ever reached the chain, so there is nothing for the
    /// 5.x lifecycle to have failed to adopt.
    #[test]
    fn a_migrated_round_the_older_build_only_set_up_does_not() {
        let (handle, round_id, _dir) = migrated_schema13_sidecar(LegacyFixture::SetUpOnly);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");

        assert!(!plan.has_legacy_in_flight_submission);
        assert_eq!(delegation_phases(&plan), [Phase::Prepared]);
        assert_eq!(step_kinds(&plan), [Step::Delegate, Step::CastVote]);
        assert_eq!(
            serde_json::to_value(&plan).expect("json")["primary_action"],
            "delegate"
        );
        assert!(!plan.plan.has_in_flight_delegation);
    }

    /// A vote row with a transaction hash and no recovery material cannot be
    /// planned at all, so the flag is never reached for one.
    ///
    /// `commitment_bundle_json` is nullable in the schema-13 DDL, and the
    /// older build's own submission call did not guard the ordering, so the
    /// combination was prevented by that build's call order — committing the
    /// vote, which wrote the column, before recording a hash — rather than by
    /// anything enforced in storage. What is pinned here is 5.1.0's answer to
    /// it either way: the round is refused rather than planned, so no host can
    /// read a flag off it.
    #[test]
    fn a_migrated_vote_with_a_hash_and_no_recovery_material_cannot_be_planned() {
        let (handle, round_id, _dir) =
            migrated_schema13_sidecar(LegacyFixture::VoteSubmittedWithoutRecovery);
        let err = round_plan(&handle, &round_id, LEGACY_ROSTER).unwrap_err();
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(
            serde_json::to_value(view.kind).unwrap(),
            "invalid_input",
            "{}",
            view.message
        );
        assert!(
            view.message
                .contains("submitted vote without recovery material"),
            "{}",
            view.message
        );
    }

    #[test]
    fn a_round_this_sdk_created_itself_reports_no_legacy_in_flight_submission() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x62, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        let plan = round_plan(&handle, &hex_round_id(0x62), LEGACY_ROSTER).expect("plan");
        assert!(!plan.has_legacy_in_flight_submission);
    }

    #[test]
    fn the_flag_rides_on_the_crate_plan_keys_rather_than_nesting_them() {
        let (handle, round_id, _dir) = migrated_schema13_sidecar(LegacyFixture::VoteSubmitted);
        let plan = round_plan(&handle, &round_id, LEGACY_ROSTER).expect("plan");
        let json = serde_json::to_value(&plan).expect("json");
        assert_eq!(json["round_id"], round_id);
        assert!(json["primary_action"].is_string());
        assert_eq!(json["has_legacy_in_flight_submission"], true);
    }

    #[test]
    fn keystone_signatures_and_clear_intents_on_fresh_round() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x14, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        assert!(
            keystone_signatures(&handle, &hex_round_id(0x14))
                .unwrap()
                .is_empty()
        );
        clear_ballot_intents(&handle, &hex_round_id(0x14), &[1]).unwrap();
        reset_session_state(&handle, &hex_round_id(0x14)).unwrap();
    }

    #[test]
    fn two_handles_on_one_path_share_one_root() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path");
        let first =
            VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET).expect("first open");
        let second =
            VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET).expect("second open");
        assert!(Arc::ptr_eq(&first.root, &second.root));
    }

    #[test]
    fn two_spellings_of_one_path_share_one_root() {
        let dir = tempfile::tempdir().expect("tempdir");
        let plain = dir.path().join("voting.sqlite3");
        let dotted = dir.path().join(".").join("voting.sqlite3");
        let first =
            VotingDatabaseHandle::open(plain.to_str().expect("utf-8"), crate::NETWORK_ID_TESTNET)
                .expect("open");
        let second =
            VotingDatabaseHandle::open(dotted.to_str().expect("utf-8"), crate::NETWORK_ID_TESTNET)
                .expect("open");
        assert!(Arc::ptr_eq(&first.root, &second.root));
    }

    #[test]
    fn handles_on_different_paths_do_not_share() {
        let dir = tempfile::tempdir().expect("tempdir");
        let first = VotingDatabaseHandle::open(
            dir.path().join("a.sqlite3").to_str().expect("utf-8"),
            crate::NETWORK_ID_TESTNET,
        )
        .expect("open");
        let second = VotingDatabaseHandle::open(
            dir.path().join("b.sqlite3").to_str().expect("utf-8"),
            crate::NETWORK_ID_TESTNET,
        )
        .expect("open");
        assert!(!Arc::ptr_eq(&first.root, &second.root));
    }

    #[test]
    fn the_root_is_released_with_its_last_handle() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path");
        let first = VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET).expect("open");
        let weak = Arc::downgrade(&first.root);
        drop(first);
        assert!(
            weak.upgrade().is_none(),
            "the registry must not keep a closed sidecar alive"
        );
        let reopened = VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET).expect("reopen");
        reopened
            .set_wallet_id("registry-wallet")
            .expect("wallet id");
        assert!(list_rounds(&reopened).expect("list rounds").is_empty());
    }

    #[test]
    fn in_memory_stores_never_share() {
        let first =
            VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_TESTNET).expect("open");
        let second =
            VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_TESTNET).expect("open");
        assert!(!Arc::ptr_eq(&first.root, &second.root));
    }

    /// An empty path is reachable through the FFI (`str_from_ptr` accepts a
    /// zero-length string) and names SQLite's own private on-disk temporary
    /// database: a fresh, unshared database on every open, by SQLite's own
    /// documented contract for it, same as `:memory:`.
    #[test]
    fn two_opens_of_the_empty_path_do_not_share_a_root() {
        let first = VotingDatabaseHandle::open("", crate::NETWORK_ID_TESTNET).expect("open");
        let second = VotingDatabaseHandle::open("", crate::NETWORK_ID_TESTNET).expect("open");
        assert!(!Arc::ptr_eq(&first.root, &second.root));
    }

    #[test]
    fn is_private_database_name_matches_sqlite_special_names_only() {
        assert!(is_private_database_name(""));
        assert!(is_private_database_name(":memory:"));
        assert!(is_private_database_name("file::memory:?cache=shared"));
        assert!(!is_private_database_name("voting.sqlite3"));
    }

    /// A panic anywhere inside a `VotingDb::open` call — while the registry
    /// lock is held across it, by design (see [`shared_root`]) — must not
    /// permanently disable every later sidecar open in the process.
    ///
    /// The registry is process-wide, so this test poisons the lock for every
    /// test that runs after it in the same process. That is harmless, and is
    /// the point: recovery is what [`shared_root`] does, so a poisoned lock
    /// costs a later open nothing. Were the recovery removed, this test would
    /// not be the only casualty — every other test that opens a sidecar on a
    /// real path would start failing too, which is a louder signal than one
    /// isolated failure, not a reason to keep this one out of the suite.
    #[test]
    fn a_poisoned_registry_lock_still_lets_a_later_path_open() {
        let poisoner = std::thread::spawn(poison_roots_lock_for_test);
        assert!(
            poisoner.join().is_err(),
            "the poisoning thread must itself have panicked"
        );

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path");
        VotingDatabaseHandle::open(path, crate::NETWORK_ID_TESTNET)
            .expect("a poisoned registry lock must not brick a later open");
    }

    /// Removes the sidecar at `path` along with the `-wal` and `-shm`
    /// siblings SQLite may have left beside it, the way a host wiping a
    /// wallet's voting data does.
    fn remove_sidecar_files(path: &str) {
        std::fs::remove_file(path).expect("remove the sidecar");
        for suffix in ["-wal", "-shm"] {
            let sibling = format!("{path}{suffix}");
            if std::fs::metadata(&sibling).is_ok() {
                std::fs::remove_file(&sibling).expect("remove a sidecar sibling");
            }
        }
    }

    /// Stores one round through `handle`, so a later open of the same path can
    /// say whether it is reading the same file.
    fn store_a_round(handle: &VotingDatabaseHandle, tag: u8) {
        handle
            .scoped()
            .expect("scoped")
            .ensure_round(
                zcash_voting::Network::Testnet,
                &crate::voting::test_support::synthetic_round_params(tag, 123),
                None,
            )
            .expect("store a round");
    }

    /// A host that deletes the sidecar file while a session still holds its
    /// root must not have the next open of that path handed the old,
    /// now-unlinked database.
    ///
    /// The registry key is the same either way — [`registry_key`] falls back
    /// to the canonical parent plus the file name once the file is gone — so
    /// nothing but the recorded file identity distinguishes the two cases. A
    /// live session keeps the entry upgradable (see
    /// `a_live_session_keeps_its_handles_root_alive_so_a_reopened_handle_shares_it`
    /// in `session.rs`), which is what makes this reachable: the strong clone
    /// held here stands in for that session.
    ///
    /// The reopened handle's writes must reach the file at the path, which the
    /// third open below reads back — a root still connected to the unlinked
    /// inode would answer with rows that vanish when the process exits.
    #[test]
    fn a_reopened_path_whose_file_was_deleted_opens_a_fresh_database() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path").to_string();

        let first = VotingDatabaseHandle::open(&path, crate::NETWORK_ID_TESTNET).expect("open");
        let session_root = first.shared_root_handle();
        drop(first);
        remove_sidecar_files(&path);

        let second = VotingDatabaseHandle::open(&path, crate::NETWORK_ID_TESTNET).expect("reopen");
        assert!(
            !Arc::ptr_eq(&second.shared_root_handle(), &session_root),
            "a path whose file was deleted must not be served from the old root"
        );

        second.set_wallet_id("reopened-wallet").expect("wallet id");
        store_a_round(&second, 0x51);
        drop(second);

        let third =
            VotingDatabaseHandle::open(&path, crate::NETWORK_ID_TESTNET).expect("third open");
        third.set_wallet_id("reopened-wallet").expect("wallet id");
        assert_eq!(
            list_rounds(&third)
                .expect("rounds")
                .iter()
                .map(|round| round.round_id.clone())
                .collect::<Vec<_>>(),
            vec![hex_round_id(0x51)],
            "the reopened handle's rows must be in the file at the path"
        );
        // Held to here on purpose: the old root must still be alive while the
        // reopen above happens, or the registry would drop its entry for
        // reasons that have nothing to do with the deleted file.
        drop(session_root);
    }

    /// The same path standing for a *different* file: deleted and recreated
    /// while the old root is still held. The path exists again by the time of
    /// the reopen, so an existence check alone would hand back the old root;
    /// only the file's identity tells the two apart.
    #[cfg(unix)]
    #[test]
    fn a_sidecar_replaced_by_another_file_is_not_served_from_the_old_root() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("voting.sqlite3");
        let path = path.to_str().expect("utf-8 path").to_string();

        let first = VotingDatabaseHandle::open(&path, crate::NETWORK_ID_TESTNET).expect("open");
        let session_root = first.shared_root_handle();
        drop(first);
        remove_sidecar_files(&path);
        // A second sidecar now stands where the first one did. The first one's
        // inode cannot be recycled for it, because `session_root` still holds
        // that file open.
        drop(VotingDb::open(&path).expect("recreate the sidecar at the same path"));
        assert!(
            std::fs::metadata(&path).is_ok(),
            "the replacement file must exist for this test to mean anything"
        );

        let second = VotingDatabaseHandle::open(&path, crate::NETWORK_ID_TESTNET).expect("reopen");
        assert!(
            !Arc::ptr_eq(&second.shared_root_handle(), &session_root),
            "a replaced file at a known path must not be served from the old root"
        );
        drop(session_root);
    }

    /// A sidecar path that is itself a symlink shares its target's root: the
    /// registry key is the canonical path, and canonicalizing resolves
    /// symlinks along the way, exactly like the crate's own
    /// `sidecar_registry_key`.
    #[cfg(unix)]
    #[test]
    fn a_symlink_to_a_sidecar_shares_its_targets_root() {
        let dir = tempfile::tempdir().expect("tempdir");
        let real = dir.path().join("voting.sqlite3");
        let first = VotingDatabaseHandle::open(
            real.to_str().expect("utf-8 path"),
            crate::NETWORK_ID_TESTNET,
        )
        .expect("open the real path");

        let link = dir.path().join("voting-link.sqlite3");
        std::os::unix::fs::symlink(&real, &link).expect("symlink");
        let second = VotingDatabaseHandle::open(
            link.to_str().expect("utf-8 path"),
            crate::NETWORK_ID_TESTNET,
        )
        .expect("open through the symlink");

        assert!(Arc::ptr_eq(&first.root, &second.root));
    }
}
