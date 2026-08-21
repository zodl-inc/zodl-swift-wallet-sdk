//! What remains SDK-side of wiring this wallet database into the pool-migration engine.
//!
//! [`zcash_pool_migration`]'s engine works over four traits — `MigrationBackend` (notes and chain
//! tip), `MigrationCrypto` (viewing key, note plaintexts), and `PoolMigrationRead` /
//! `PoolMigrationWrite` (the store). Both halves are upstream's: the crate's own
//! [`WalletMigration`] adapter serves the first two over any `zcash_client_backend` wallet, and
//! `zcash_client_sqlite`'s account-scoped `PoolMigrations` is the store it wraps. This SDK no
//! longer forks either. What is left here is the four joints that are genuinely this wallet's:
//!
//! - [`account_store`] opens the account-scoped store. `PoolMigrations::for_account` needs the
//!   network parameters and clock the wallet handle itself was built with (its
//!   `store_proved_transaction` finalizes into the wallet's own tables, which needs branch ids and
//!   a creation timestamp), and it scopes the migration to ONE account — so a wallet database
//!   hosting a seed-derived account next to a UFVK-imported Keystone account migrates them
//!   independently. Every operation that is purely a store operation takes this directly.
//! - [`stored_ufvk`] is the one thing upstream deliberately leaves to the caller: [`WalletMigration`]
//!   takes the account's unified full viewing key as a CONSTRUCTOR PARAMETER rather than reading
//!   the account record, because a wallet may hold several keys that view one account and only the
//!   caller knows which the migration's notes belong to. This SDK's answer is always the key the
//!   account record stores, which is also what lets an imported hardware-wallet account — whose
//!   spending key never exists on this device — plan, build and prove here.
//! - [`account_migration`] is the two together: the adapter every engine call that needs
//!   `MigrationBackend` / `MigrationCrypto` (planning, estimating, committing, rebuilding) is
//!   handed.
//! - [`run_sizing`] is how one run of the account is bounded — by what a Keystone signs in one
//!   QR-scanned round, or by the in-process note cap — decided by the account row's `key_source`
//!   tag; [`planning_inputs`] reads that tag and the stored key in ONE row lookup for the planning
//!   and estimating calls. It is the one seam every planning AND estimating call takes its bound
//!   from, so a preview always describes the runs that get planned; the engine leaves the choice to
//!   the wallet because only the wallet knows who signs.
//!
//! There is no spending key in this module, and no way to give the adapter one — [`WalletMigration`]
//! holds viewing authority and offers no constructor that takes more. The engine's two signing
//! entry points take an `orchard::keys::SpendingKey` per call — deriving its full viewing key and
//! refusing eagerly if it does not match the account's, before building anything — so the FFI
//! functions that sign pass the spending key they just decoded straight through and drop it with
//! the call.
//!
//! Proving (`engine::MigrationProver`) is upstream's `wallet::WalletMigrationProver` over a
//! separate MUTABLE wallet borrow: resolving witnesses needs the note commitment tree, which the
//! shared borrow the adapter holds cannot provide. It is dispatched per transaction kind (boundary
//! anchor for transfers, preparation anchor for preparations) in [`crate::migration_finalize`],
//! and takes the account's Orchard viewing key from [`stored_orchard_fvk`].

use anyhow::anyhow;
use orchard::keys::FullViewingKey;
use rand::rngs::OsRng;
use zcash_client_backend::data_api::{Account, AccountSource, InputSource, WalletRead};
use zcash_client_sqlite::AccountUuid;
use zcash_client_sqlite::pool_migration::orchard_ironwood::{
    Error as PoolMigrationStoreError, PoolMigrations,
};
use zcash_client_sqlite::util::SystemClock;
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_pool_migration::denomination::MIGRATION_MAX_PREPARED_NOTES_PER_RUN;
use zcash_pool_migration::engine::RunSizing;
use zcash_pool_migration::signing_rounds::RunSigningCapacity;
use zcash_pool_migration::wallet::WalletMigration;

use crate::NetworkParams;

/// The concrete wallet type every migration entry point operates over.
pub(crate) type MigrationWallet =
    zcash_client_sqlite::WalletDb<rusqlite::Connection, NetworkParams, SystemClock, OsRng>;

/// The account-scoped pool-migration store, over the second connection into the wallet database
/// file that every migration call opens ([`crate::migration`]'s `CallCtx::store_conn`).
pub(crate) type MigrationStore<'a> =
    PoolMigrations<&'a mut rusqlite::Connection, NetworkParams, SystemClock>;

/// The upstream migration adapter over this SDK's wallet handle and store.
pub(crate) type AccountMigration<'a> = WalletMigration<'a, MigrationWallet, MigrationStore<'a>>;

/// The adapter's error type: upstream's three-way split over the wallet's read and note-source
/// errors and the store's own. Every engine call made through an [`AccountMigration`] reports
/// through it (as `CommitError<AdapterError>`, `RebuildError<AdapterError>`, and so on).
pub(crate) type AdapterError = zcash_pool_migration::wallet::Error<
    <MigrationWallet as WalletRead>::Error,
    <MigrationWallet as InputSource>::Error,
    PoolMigrationStoreError,
>;

/// Open the account-scoped migration store over `store_conn`.
///
/// This is the whole seam for every operation that only ever touches the store: the
/// history-inclusive `latest_migration` (upstream's `PoolMigrationRead::get_migration` is
/// PENDING-ONLY, so the reads that must keep serving a completed, failed or cancelled run read
/// through the store's own accessor), the atomic broadcast seam, cancellation, and the drive's
/// `advance_migration` — none of which needs a viewing key, and so none of which asks for one.
pub(crate) fn account_store<'a>(
    wallet: &MigrationWallet,
    account: AccountUuid,
    store_conn: &'a mut rusqlite::Connection,
) -> anyhow::Result<MigrationStore<'a>> {
    PoolMigrations::for_account(wallet.params().clone(), SystemClock, store_conn, account)
        .map_err(|e| anyhow!("opening the account-scoped migration store failed: {e}"))
}

/// The account row `account` names, or a hard error when the wallet does not know it — the one
/// lookup every account-derived input in this module (the stored viewing key, the run sizing)
/// starts from, so the two can never disagree about what an unknown account looks like.
fn stored_account(
    wallet: &MigrationWallet,
    account: AccountUuid,
) -> anyhow::Result<<MigrationWallet as WalletRead>::Account> {
    wallet
        .get_account(account)
        .map_err(|e| anyhow!("account lookup failed: {e}"))?
        .ok_or_else(|| anyhow!("unknown account"))
}

/// The unified full viewing key a stored account row holds, or the hard error every key-needing
/// path reports when it holds none: nothing downstream can proceed without one, and deferring to
/// whichever engine call first needs the Orchard component would report the same condition later
/// and less clearly.
fn row_ufvk(
    row: &<MigrationWallet as WalletRead>::Account,
) -> anyhow::Result<UnifiedFullViewingKey> {
    row.ufvk()
        .cloned()
        .ok_or_else(|| anyhow!("the account has no unified full viewing key"))
}

/// The account's STORED unified full viewing key — the key this SDK builds every migration
/// against.
///
/// The one thing upstream's adapter asks its caller for. A hard error when the account record
/// holds no key (see [`row_ufvk`]).
pub(crate) fn stored_ufvk(
    wallet: &MigrationWallet,
    account: AccountUuid,
) -> anyhow::Result<UnifiedFullViewingKey> {
    row_ufvk(&stored_account(wallet, account)?)
}

/// The Orchard component of [`stored_ufvk`], for the one consumer that needs it outside the
/// adapter: `wallet::WalletMigrationProver`, which recomputes each spend's nullifier under it to
/// locate the note in the wallet's commitment tree.
pub(crate) fn stored_orchard_fvk(
    wallet: &MigrationWallet,
    account: AccountUuid,
) -> anyhow::Result<FullViewingKey> {
    stored_ufvk(wallet, account)?
        .orchard()
        .cloned()
        .ok_or_else(|| anyhow!("the account's viewing key has no Orchard component"))
}

/// The `key_source` tag that marks an account whose transactions a Keystone hardware wallet signs,
/// compared case-insensitively. It is the tag the platform layers stamp on a Keystone import
/// (zodl-ios stamps it in `AddHWWalletStore` and reads it back as `WalletAccount.vendor`;
/// `AccountDataSource.importKeystoneAccount` on Android), and the only account-level signal this
/// SDK has that a run's signing carries a per-round QR cost.
pub(crate) const KEYSTONE_KEY_SOURCE: &str = "keystone";

/// How one migration run of an account with `source` is bounded — the sizing every planning and
/// estimating call passes to the engine, so a preview describes exactly the runs that get planned.
///
/// A Keystone-tagged account (see [`KEYSTONE_KEY_SOURCE`]) is sized to what its signer signs in
/// ONE interaction, [`RunSigningCapacity::KEYSTONE`] (96 actions per QR-scanned round): a run's
/// actions are `16 * preparations + 3 * transfers` and the preparation count follows the wallet's
/// fragmentation, so a fixed note cap alone cannot promise a single round. Every other account is
/// signed in process, where a round has no per-interaction cost to bound, so it keeps the crate's
/// default note-cap sizing, [`MIGRATION_MAX_PREPARED_NOTES_PER_RUN`] — exactly the bound
/// `plan_migration` itself applies, so these accounts plan the same runs as before per-account
/// sizing existed. An account without a `key_source`, or with any other tag, is an in-process
/// signer.
///
/// Pure: the account row is read by [`planning_inputs`], which resolves this together with the
/// stored viewing key from one lookup.
pub(crate) fn run_sizing(source: &AccountSource) -> RunSizing {
    let is_keystone = source
        .key_source()
        .is_some_and(|tag| tag.eq_ignore_ascii_case(KEYSTONE_KEY_SOURCE));
    if is_keystone {
        RunSizing::Signer(RunSigningCapacity::KEYSTONE)
    } else {
        RunSizing::Notes(MIGRATION_MAX_PREPARED_NOTES_PER_RUN)
    }
}

/// Everything a planning or estimating call derives from the account row, read in ONE lookup:
/// the run sizing ([`run_sizing`]) and the stored unified full viewing key ([`stored_ufvk`]).
/// `compute_plan` and `estimate_runs` in [`crate::migration`] build their adapter from `ufvk`
/// through [`account_migration_with`], so one call reads the row once instead of once for the
/// sizing and again for the key.
pub(crate) struct PlanningInputs {
    pub sizing: RunSizing,
    pub ufvk: UnifiedFullViewingKey,
}

/// The [`PlanningInputs`] of `account`: a hard error when the wallet does not know the account
/// ("unknown account") or its row holds no unified full viewing key — the same two errors
/// [`stored_ufvk`] reports, from the same lookup.
pub(crate) fn planning_inputs(
    wallet: &MigrationWallet,
    account: AccountUuid,
) -> anyhow::Result<PlanningInputs> {
    let row = stored_account(wallet, account)?;
    let ufvk = row_ufvk(&row)?;
    Ok(PlanningInputs {
        sizing: run_sizing(row.source()),
        ufvk,
    })
}

/// The migration adapter for one account: upstream's [`WalletMigration`] over this wallet handle,
/// the account's stored viewing key, and its scoped store.
///
/// Construct one per FFI call and drop it with the call — the adapter snapshots the account's
/// spendable notes on first read (the engine addresses a note by its index into that sequence, so
/// every read through one adapter must see the same set), and wallet changes are observed by
/// constructing a fresh one.
pub(crate) fn account_migration<'a>(
    wallet: &'a MigrationWallet,
    account: AccountUuid,
    store_conn: &'a mut rusqlite::Connection,
) -> anyhow::Result<AccountMigration<'a>> {
    let ufvk = stored_ufvk(wallet, account)?;
    account_migration_with(wallet, account, ufvk, store_conn)
}

/// [`account_migration`] for a caller that already holds the account's stored viewing key — the
/// planning and estimating entry points, which read it through [`planning_inputs`] alongside the
/// run sizing and must not pay for the account row a second time.
pub(crate) fn account_migration_with<'a>(
    wallet: &'a MigrationWallet,
    account: AccountUuid,
    ufvk: UnifiedFullViewingKey,
    store_conn: &'a mut rusqlite::Connection,
) -> anyhow::Result<AccountMigration<'a>> {
    let store = account_store(wallet, account, store_conn)?;
    Ok(WalletMigration::new(wallet, account, ufvk, store))
}
