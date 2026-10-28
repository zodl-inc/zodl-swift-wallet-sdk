//! Durable persistence of ZIP 318 anchor-retention marks into the wallet's sqlite store.
//!
//! Slipstream retains anchor checkpoints on its IN-MEMORY substitution trees (its `[B6]`
//! `ensure_retained` calls protect the batch build), and its flush persists those marks to the
//! wallet database alongside the checkpoints it writes, in the same transaction and in all
//! three pools, so the sqlite `*_tree_retained_checkpoints` tables carry them. An older
//! engine's flush wrote checkpoints WITHOUT the marks, and a database it wrote keeps them that
//! way: its retained tables stay empty. The engine's open-time deep-history heal reads the
//! retained set from the SQLITE store and dooms every checkpoint deeper than its margin
//! (10,000 blocks below each pool's max) that the missing marks fail to spare — which, on any
//! migration whose privacy schedule outlives the margin, is exactly the drawn boundary
//! anchors: `prove_transfer` would defer on `AnchorNotFound` forever. Field evidence
//! (2026-08-02, testnet device, written by an older engine): retention policy configured, 216
//! grid checkpoints present, retained tables EMPTY in every pool.
//!
//! [`reconcile_retained_anchor_marks`] backfills such a database from the SDK side: at wallet
//! open — before any engine session, and therefore before any heal, exists — it marks every height
//! the network's retention policy retains, from the NU6.3 activation floor to the wallet's
//! chain tip, as a durable anchor in ALL THREE pools' stores. It goes through the public
//! `WalletCommitmentTrees` + `ShardTree::ensure_retained` seam, whose sqlite store persists
//! each mark as `INSERT OR IGNORE` — idempotent by construction. Marking a height whose
//! checkpoint does not (or does not yet) exist is explicitly allowed by the `ShardStore`
//! contract and harmless to the heal ("bloat, not breakage" — its own words): the retained
//! set only ever SPARES ids.
//!
//! The root fix is in the engine: Slipstream's flush persists its in-memory retained set
//! alongside the checkpoints it writes, as above. This reconcile is the BACKFILL for databases
//! an older engine wrote, whose checkpoints were flushed without marks. Where the flush has
//! written the marks, it only re-asserts them.

use anyhow::anyhow;
use zcash_client_backend::data_api::{WalletCommitmentTrees, WalletRead};
use zcash_client_sqlite::WalletDb;
use zcash_client_sqlite::util::SystemClock;

use crate::{NetworkParams, anchor_retention_policy};

/// Ensure every anchor-retention mark the network's policy calls for, from the NU6.3
/// activation floor to the wallet's current chain tip, in all three pools' stores.
///
/// Returns the number of (height × pool) marks ensured. `Ok(0)` when the wallet has no chain
/// tip yet (nothing scanned — nothing to retain) or the network has no NU6.3 activation
/// (no migration boundaries exist to retain).
pub(crate) fn reconcile_retained_anchor_marks(
    wallet: &mut WalletDb<rusqlite::Connection, NetworkParams, SystemClock, crate::SystemRng>,
    network: &NetworkParams,
) -> anyhow::Result<u64> {
    let Some(tip) = wallet
        .chain_height()
        .map_err(|e| anyhow!("chain height lookup failed: {e}"))?
    else {
        return Ok(0);
    };
    let Some(retention) = anchor_retention_policy(*network) else {
        return Ok(0);
    };
    let floor = retention.from_height();
    if tip < floor {
        return Ok(0);
    }
    let heights = retention.retained_in_range(floor..=tip);
    if heights.is_empty() {
        return Ok(0);
    }

    // All three pools: a ZIP 318 boundary must be checkpointed (and so retained) in every
    // tree, because a transfer's proof resolves the Orchard source AND Ironwood destination
    // anchors at one height, and cross-pool alignment keeps sapling on the same grid.
    wallet
        .with_sapling_tree_mut::<_, _, shardtree::error::ShardTreeError<_>>(|tree| {
            for h in &heights {
                tree.ensure_retained(*h)?;
            }
            Ok(())
        })
        .map_err(|e| anyhow!("sapling retained-mark write failed: {e:?}"))?;
    wallet
        .with_orchard_tree_mut::<_, _, shardtree::error::ShardTreeError<_>>(|tree| {
            for h in &heights {
                tree.ensure_retained(*h)?;
            }
            Ok(())
        })
        .map_err(|e| anyhow!("orchard retained-mark write failed: {e:?}"))?;
    wallet
        .with_ironwood_tree_mut::<_, _, shardtree::error::ShardTreeError<_>>(|tree| {
            for h in &heights {
                tree.ensure_retained(*h)?;
            }
            Ok(())
        })
        .map_err(|e| anyhow!("ironwood retained-mark write failed: {e:?}"))?;

    Ok((heights.len() as u64) * 3)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_client_backend::data_api::WalletWrite;
    use zcash_client_sqlite::WalletDb;
    use zcash_client_sqlite::util::SystemClock;
    use zcash_client_sqlite::wallet::init::init_wallet_db;
    use zcash_protocol::consensus::{BlockHeight, Network};

    /// NU6.3 testnet activation (the retention floor) — must match
    /// `Network::TestNetwork.activation_height(NetworkUpgrade::Nu6_3)`.
    const FLOOR: u32 = 4_134_000;

    /// NU7 testnet activation — must match
    /// `Network::TestNetwork.activation_height(NetworkUpgrade::Nu7)`.
    const NU7: u32 = 4_465_026;

    fn fresh_wallet(
        dir: &std::path::Path,
    ) -> WalletDb<rusqlite::Connection, NetworkParams, SystemClock, crate::SystemRng> {
        let path = dir.join("wallet.sqlite");
        let network = NetworkParams::Standard(Network::TestNetwork);
        let mut db = WalletDb::for_path(&path, network, SystemClock, crate::system_rng())
            .expect("opens a fresh wallet db");
        init_wallet_db(&mut db, None).expect("initializes the wallet schema");
        db
    }

    fn retained_rows(dir: &std::path::Path, table: &str) -> Vec<u32> {
        let conn = rusqlite::Connection::open(dir.join("wallet.sqlite")).expect("opens");
        let mut stmt = conn
            .prepare(&format!(
                "SELECT checkpoint_id FROM {table} ORDER BY checkpoint_id"
            ))
            .expect("prepares");
        stmt.query_map([], |r| r.get::<_, u32>(0))
            .expect("queries")
            .collect::<Result<Vec<_>, _>>()
            .expect("collects")
    }

    /// The reconcile marks every policy-retained grid height in [floor ..= tip], in all
    /// three pools, and reports the total. Grid: below NU7, testnet retains every 12th block
    /// from the NU6.3 activation floor (itself on the grid), so tip = floor + 120 yields 11
    /// heights.
    #[test]
    fn marks_every_grid_height_up_to_the_chain_tip_in_all_pools() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut wallet = fresh_wallet(dir.path());
        let network = NetworkParams::Standard(Network::TestNetwork);
        wallet
            .update_chain_tip(BlockHeight::from_u32(FLOOR + 120))
            .expect("sets the chain tip");

        let ensured = reconcile_retained_anchor_marks(&mut wallet, &network).expect("reconciles");
        drop(wallet);

        let expected: Vec<u32> = (0..=10).map(|k| FLOOR + 12 * k).collect();
        assert_eq!(ensured, 33, "11 grid heights × 3 pools");
        for table in [
            "sapling_tree_retained_checkpoints",
            "orchard_tree_retained_checkpoints",
            "ironwood_tree_retained_checkpoints",
        ] {
            assert_eq!(
                retained_rows(dir.path(), table),
                expected,
                "{table} holds exactly the policy-retained grid heights"
            );
        }
    }

    /// From NU7 activation each reference block spans three blocks, and the grid's boundaries
    /// follow: testnet retains every 12th block below the activation and every 36th from it.
    /// Marking the plain multiples of 12 past the activation would mark heights no transfer
    /// anchors to, and differ from the grid the engine and the wallet's own scan retain.
    #[test]
    fn marks_the_spaced_grid_from_the_nu7_activation() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut wallet = fresh_wallet(dir.path());
        let network = NetworkParams::Standard(Network::TestNetwork);
        wallet
            .update_chain_tip(BlockHeight::from_u32(NU7 + 100))
            .expect("sets the chain tip");

        let ensured = reconcile_retained_anchor_marks(&mut wallet, &network).expect("reconciles");
        drop(wallet);

        let expected: Vec<u32> = (FLOOR..NU7)
            .step_by(12)
            .chain((NU7..=NU7 + 100).filter(|height| height % 36 == 0))
            .collect();
        assert_eq!(
            expected.iter().rev().take(4).copied().collect::<Vec<_>>(),
            [4_465_116, 4_465_080, 4_465_044, 4_465_020],
            "the last multiple of 12 below the activation, then the multiples of 36"
        );
        assert_eq!(ensured, 3 * expected.len() as u64);
        for table in [
            "sapling_tree_retained_checkpoints",
            "orchard_tree_retained_checkpoints",
            "ironwood_tree_retained_checkpoints",
        ] {
            assert_eq!(
                retained_rows(dir.path(), table),
                expected,
                "{table} holds exactly the policy-retained grid heights"
            );
        }
    }

    /// Re-running the reconcile changes nothing: the store's mark write is INSERT OR IGNORE,
    /// and the reported count is the same "ensured" total, not a growth.
    #[test]
    fn reconcile_is_idempotent() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut wallet = fresh_wallet(dir.path());
        let network = NetworkParams::Standard(Network::TestNetwork);
        wallet
            .update_chain_tip(BlockHeight::from_u32(FLOOR + 24))
            .expect("sets the chain tip");

        let first = reconcile_retained_anchor_marks(&mut wallet, &network).expect("first run");
        let second = reconcile_retained_anchor_marks(&mut wallet, &network).expect("second run");
        drop(wallet);

        assert_eq!(first, 9, "3 grid heights × 3 pools");
        assert_eq!(second, first, "the second pass re-ensures the same marks");
        assert_eq!(
            retained_rows(dir.path(), "orchard_tree_retained_checkpoints").len(),
            3,
            "no duplicate rows accumulate"
        );
    }

    /// A wallet that has scanned nothing has no chain tip and nothing to retain: the
    /// reconcile is a quiet no-op, never an error.
    #[test]
    fn no_chain_tip_is_a_quiet_no_op() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut wallet = fresh_wallet(dir.path());
        let network = NetworkParams::Standard(Network::TestNetwork);

        let ensured = reconcile_retained_anchor_marks(&mut wallet, &network)
            .expect("a fresh wallet reconciles to nothing");
        drop(wallet);

        assert_eq!(ensured, 0);
        assert!(retained_rows(dir.path(), "orchard_tree_retained_checkpoints").is_empty());
    }
}
