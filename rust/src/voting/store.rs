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
//! handle re-opened while an older session on its path is still live. See
//! [`shared_root`].
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
use super::wire::{KeystoneSignatureRecordDto, RoundSummaryDto, plan_view};

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
static ROOTS: OnceLock<Mutex<HashMap<PathBuf, Weak<VotingDb>>>> = OnceLock::new();

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

/// A root `VotingDb` shared with every other handle already open on `path`.
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
    if let Some(root) = roots.get(&key).and_then(Weak::upgrade) {
        return Ok(root);
    }
    let root = Arc::new(VotingDb::open(path).ffi()?);
    roots.retain(|_, weak| weak.strong_count() > 0);
    roots.insert(key, Arc::downgrade(&root));
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
) -> anyhow::Result<zcash_voting::wire::RoundPlanView> {
    let db = h.scoped()?;
    let plan = zcash_voting::session::resume_plan(&db, round_id, proposal_ids).ffi()?;
    plan_view(plan)
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

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2]).unwrap();
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

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2]).unwrap();
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

        let plan = round_plan(&handle, &hex_round_id(0xfe), &[1]).unwrap();
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
    /// The registry is process-wide, so poisoning it here is safe to run only
    /// in isolation: run this one test alone
    /// (`cargo test --lib voting::store::tests::a_poisoned_registry_lock_still_lets_a_later_path_open`),
    /// never as part of the full suite, since a run before the fix leaves the
    /// lock poisoned for every other test still to come in the same process.
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
