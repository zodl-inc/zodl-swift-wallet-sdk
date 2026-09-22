use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::Mutex;

use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use pasta_curves::pallas;
use zcash_voting as voting;
use zcash_voting::storage::VotingDb;
use zcash_voting::tree_sync::VoteTreeSync;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::helpers::str_from_ptr;

/// Opaque handle wrapping the voting database and its tree-sync state.
pub struct VotingDatabaseHandle {
    pub(super) db: Arc<VotingDb>,
    pub(super) tree_sync: VoteTreeSync,
    pub(super) network: voting::types::Network,
    pub(super) network_id: u32,
    /// The connected PIR client, reused across bundles and phases of a round.
    pir_client: Mutex<CachedSlot<Arc<voting::PirClientBlocking>>>,
}

/// One value negotiated for an endpoint, PIR layout, and round snapshot.
struct CachedSlot<T> {
    entry: Option<(String, voting::config::PirLayout, [u8; 32], T)>,
}

impl<T: Clone> CachedSlot<T> {
    fn new() -> Self {
        Self { entry: None }
    }

    fn get_or_insert_with(
        &mut self,
        url: &str,
        layout: voting::config::PirLayout,
        expected_root: [u8; 32],
        root_of: impl Fn(&T) -> [u8; 32],
        connect: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        if let Some((cached_url, cached_layout, cached_root, value)) = &self.entry
            && cached_url == url
            && *cached_layout == layout
            && *cached_root == expected_root
            && root_of(value) == expected_root
        {
            return Ok(value.clone());
        }
        let value = connect()?;
        if root_of(&value) != expected_root {
            return Err(anyhow!(
                "connected PIR circuit root does not match the stored round nullifier_imt_root"
            ));
        }
        self.entry = Some((url.to_string(), layout, expected_root, value.clone()));
        Ok(value)
    }
}

impl VotingDatabaseHandle {
    fn pir_root_for_round(&self, round_id: &str) -> anyhow::Result<[u8; 32]> {
        let wallet_id = self.db.wallet_id();
        let (params, network) = {
            let conn = self.db.conn();
            voting::storage::queries::load_round_params_with_network(&conn, round_id, &wallet_id)
                .map_err(|e| anyhow!("load stored voting round for PIR failed: {e}"))?
        };
        if network != self.network {
            return Err(anyhow!(
                "stored voting round network does not match the voting database handle"
            ));
        }
        let root_bytes: [u8; 32] =
            params
                .nullifier_imt_root
                .try_into()
                .map_err(|root: Vec<u8>| {
                    anyhow!(
                        "stored round nullifier_imt_root must be exactly 32 bytes, got {}",
                        root.len()
                    )
                })?;
        let root = Option::<pallas::Base>::from(pallas::Base::from_repr(root_bytes))
            .ok_or_else(|| anyhow!("stored round nullifier_imt_root is not canonical"))?;
        Ok(root.to_repr())
    }

    fn pir_client_for_with<T: Clone>(
        &self,
        cache: &Mutex<CachedSlot<T>>,
        round_id: &str,
        url: &str,
        layout: voting::config::PirLayout,
        root_of: impl Fn(&T) -> [u8; 32],
        connect: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let expected_root = self.pir_root_for_round(round_id)?;
        let mut slot = cache
            .lock()
            .map_err(|_| anyhow!("voting DB PIR client mutex poisoned"))?;
        slot.get_or_insert_with(url, layout, expected_root, root_of, connect)
    }

    /// Returns a PIR client connected to `url` for `layout` and the round's persisted snapshot.
    ///
    /// The handshake is expensive: `connect_pir_blocking` stands up a tokio runtime and a TLS
    /// client, then the client fetches both tiers' parameters and downloads the whole Tier-0
    /// dataset to recompute its root. The delegation PIR precompute and the delegation proof
    /// each need a client for every bundle of a round, so the connection is made once per handle
    /// and shared by both. The Swift side serializes every call on this handle, so no two
    /// connects race; the client is dropped with the handle.
    pub(super) fn pir_client_for(
        &self,
        round_id: &str,
        url: &str,
        layout: voting::config::PirLayout,
    ) -> anyhow::Result<Arc<voting::PirClientBlocking>> {
        self.pir_client_for_with(
            &self.pir_client,
            round_id,
            url,
            layout,
            |client| client.circuit_root().to_repr(),
            || Ok(Arc::new(connect_pir_client(url, layout)?)),
        )
    }
}

// The layout comes from the round's resolved dynamic config and is passed through unchanged:
// `connect_pir_blocking` performs the config/server layout handshake and fails closed before any
// private query when the server disagrees.
fn connect_pir_client(
    pir_url: &str,
    pir_layout: voting::config::PirLayout,
) -> anyhow::Result<voting::PirClientBlocking> {
    voting::connect_pir_blocking(pir_layout, pir_url, Arc::new(voting::HyperTransport::new()))
        .map_err(|e| anyhow!("connect to PIR server failed: {}", e))
}

/// Open a voting database at the given path.
///
/// Returns an opaque `*mut VotingDatabaseHandle` on success, or null on error.
///
/// # Safety
///
/// - For the `(path, path_len)` byte argument: if `path_len > 0` then `path` must be
///   non-null and valid for reads for `path_len` bytes; if `path_len == 0`, `path` is
///   ignored.
/// - Call `zcashlc_voting_db_free` to free the returned handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_db_open(
    path: *const u8,
    path_len: usize,
    network_id: u32,
) -> *mut VotingDatabaseHandle {
    let res = catch_panic(|| {
        let path_str = unsafe { str_from_ptr(path, path_len) }?;
        // zcash_voting persists each round's wallet network, so the handle
        // carries it from open time (0 = testnet, 1 = mainnet, and the
        // custom/regtest network slot). The custom slot's voting identity must
        // follow the registered base network — a modified-mainnet chain votes
        // with mainnet hotkeys and HRPs — so derive it from CUSTOM_PARAMS via
        // `parse_network` (which also errors if the custom network was never
        // configured) rather than assuming Regtest.
        let network = match network_id {
            crate::NETWORK_ID_TESTNET => voting::types::Network::Testnet,
            crate::NETWORK_ID_MAINNET => voting::types::Network::Mainnet,
            crate::NETWORK_ID_REGTEST => {
                use zcash_protocol::consensus::{NetworkType, Parameters};
                match crate::parse_network(network_id)?.network_type() {
                    NetworkType::Main => voting::types::Network::Mainnet,
                    NetworkType::Test => voting::types::Network::Testnet,
                    NetworkType::Regtest => voting::types::Network::Regtest,
                }
            }
            other => return Err(anyhow!("invalid network id {other} for voting database")),
        };
        let db = VotingDb::open(&path_str)
            .map_err(|e| anyhow!("Error opening voting database: {}", e))?;
        Ok(Box::into_raw(Box::new(VotingDatabaseHandle {
            db: Arc::new(db),
            tree_sync: VoteTreeSync::new(),
            network,
            network_id,
            pir_client: Mutex::new(CachedSlot::new()),
        })))
    });
    unwrap_exc_or_null(res)
}

/// Free a `VotingDatabaseHandle`.
///
/// # Safety
///
/// - If `ptr` is non-null, it must be a pointer previously returned by
///   `zcashlc_voting_db_open` that has not already been freed.
/// - Calling this twice on the same non-null pointer, or on any pointer not obtained
///   from `zcashlc_voting_db_open`, is undefined behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_db_free(ptr: *mut VotingDatabaseHandle) {
    if !ptr.is_null() {
        let s: Box<VotingDatabaseHandle> = unsafe { Box::from_raw(ptr) };
        drop(s);
    }
}

/// Set the wallet identifier for all subsequent voting operations.
/// Must be called after `zcashlc_voting_db_open` and before any round operations.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For the `(wallet_id, wallet_id_len)` byte argument: if `wallet_id_len > 0` then
///   `wallet_id` must be non-null and valid for reads for `wallet_id_len` bytes; if
///   `wallet_id_len == 0`, `wallet_id` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_set_wallet_id(
    db: *mut VotingDatabaseHandle,
    wallet_id: *const u8,
    wallet_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let wallet_id_str = unsafe { str_from_ptr(wallet_id, wallet_id_len) }?;
        handle.db.set_wallet_id(&wallet_id_str);
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ff::PrimeField;
    use pasta_curves::pallas;

    #[test]
    fn db_open_rejects_invalid_utf8_path() {
        let invalid_path = [0xff];
        let handle =
            unsafe { zcashlc_voting_db_open(invalid_path.as_ptr(), invalid_path.len(), 1) };
        assert!(handle.is_null());
    }

    #[test]
    fn db_open_rejects_invalid_network_id() {
        // The network is validated once, here, so no database-bound call has to
        // re-check it: the handle cannot exist for a network that does not.
        let path = b":memory:";
        let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), 99) };
        assert!(db.is_null(), "unknown network id must not open a handle");
    }

    #[test]
    fn db_free_accepts_null() {
        unsafe { zcashlc_voting_db_free(std::ptr::null_mut()) };
    }

    #[test]
    fn set_wallet_id_rejects_null_db() {
        let code = unsafe { zcashlc_voting_set_wallet_id(std::ptr::null_mut(), b"x".as_ptr(), 1) };
        assert_eq!(code, -1);
    }

    /// The custom slot's voting identity must follow the registered base
    /// network: a modified-mainnet chain keeps mainnet hotkeys and HRPs. This
    /// is the only test that touches the process-global custom-network slot —
    /// keep it that way (parallel tests share the global).
    #[test]
    fn db_open_custom_network_derives_voting_network_from_base() {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "zcashlc_voting_db_custom_network_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_string_lossy().as_bytes().to_vec();

        // Before zcashlc_set_custom_network runs, the custom slot has no base
        // to derive the voting network from — opening must fail, not silently
        // fall back to Regtest.
        let unconfigured = unsafe {
            zcashlc_voting_db_open(
                path_bytes.as_ptr(),
                path_bytes.len(),
                crate::NETWORK_ID_REGTEST,
            )
        };
        assert!(
            unconfigured.is_null(),
            "custom slot must not open before the custom network is configured"
        );

        // Modified-mainnet: base identity mainnet, custom activation heights.
        assert!(crate::zcashlc_set_custom_network(
            1, 347_500, 419_200, 653_600, 903_000, 1_046_400, 1_687_104, 2_726_400, 3_146_400,
            3_364_600, 3_428_143,
        ));

        let db = unsafe {
            zcashlc_voting_db_open(
                path_bytes.as_ptr(),
                path_bytes.len(),
                crate::NETWORK_ID_REGTEST,
            )
        };
        assert!(!db.is_null(), "open voting db at {:?}", path);
        let network = unsafe { (*db).network };
        assert_eq!(
            network,
            voting::types::Network::Mainnet,
            "base-mainnet custom network must map to the mainnet voting identity"
        );
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&path);
    }

    fn layout(depth: u32) -> voting::config::PirLayout {
        voting::config::PirLayout {
            pir_depth: depth,
            tier0_layers: 2,
            tier1_layers: 3,
            poly_len: 4096,
        }
    }

    #[derive(Clone, Debug)]
    struct TestPirClient {
        root: [u8; 32],
        generation: u32,
    }

    fn test_client(root: [u8; 32], generation: u32) -> Arc<TestPirClient> {
        Arc::new(TestPirClient { root, generation })
    }

    #[test]
    fn cached_slot_connects_once_for_the_same_endpoint_and_layout() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let mut connects = 0;
        let root = [1u8; 32];

        let first = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root,
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root, connects))
                },
            )
            .unwrap();
        let second = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root,
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root, connects))
                },
            )
            .unwrap();

        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(connects, 1);
    }

    #[test]
    fn cached_slot_reconnects_for_a_new_snapshot() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let mut connects = 0;
        let root_a = [1u8; 32];
        let root_b = [2u8; 32];

        let first = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_a,
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root_a, connects))
                },
            )
            .unwrap();
        let second = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_b,
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root_b, connects))
                },
            )
            .unwrap();

        assert_eq!(first.generation, 1);
        assert_eq!(second.generation, 2);
        assert_eq!(connects, 2);
    }

    #[test]
    fn cached_slot_revalidates_the_cached_clients_actual_root() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let expected = [1u8; 32];
        let first = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                expected,
                |client| client.root,
                || Ok(test_client(expected, 1)),
            )
            .unwrap();
        drop(first);
        let cached = &mut slot.entry.as_mut().expect("cached client").3;
        Arc::get_mut(cached)
            .expect("cache owns the only client")
            .root = [2u8; 32];

        let corrected = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                expected,
                |client| client.root,
                || Ok(test_client(expected, 2)),
            )
            .unwrap();

        assert_eq!(corrected.generation, 2);
        assert_eq!(corrected.root, expected);
    }

    #[test]
    fn cached_slot_reconnects_when_the_endpoint_or_the_layout_changes() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let mut connects = 0;
        let root = [1u8; 32];
        let mut connect = || {
            connects += 1;
            Ok(test_client(root, connects))
        };

        assert_eq!(
            slot.get_or_insert_with(
                "https://pir.example",
                layout(20),
                root,
                |client| client.root,
                &mut connect
            )
            .unwrap()
            .generation,
            1
        );
        assert_eq!(
            slot.get_or_insert_with(
                "https://other.example",
                layout(20),
                root,
                |client| client.root,
                &mut connect
            )
            .unwrap()
            .generation,
            2
        );
        assert_eq!(
            slot.get_or_insert_with(
                "https://other.example",
                layout(21),
                root,
                |client| client.root,
                &mut connect
            )
            .unwrap()
            .generation,
            3
        );
        assert_eq!(
            slot.get_or_insert_with(
                "https://other.example",
                layout(21),
                root,
                |client| client.root,
                &mut connect
            )
            .unwrap()
            .generation,
            3
        );
        assert_eq!(connects, 3);
    }

    #[test]
    fn a_mismatched_candidate_is_not_cached() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let expected = [2u8; 32];

        let error = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                expected,
                |client| client.root,
                || Ok(test_client([1u8; 32], 1)),
            )
            .unwrap_err();
        assert!(error.to_string().contains("circuit root"));

        let corrected = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                expected,
                |client| client.root,
                || Ok(test_client(expected, 2)),
            )
            .unwrap();
        assert_eq!(corrected.generation, 2);
    }

    #[test]
    fn cached_slot_keeps_the_old_client_when_a_reconnect_fails() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let root_a = [1u8; 32];
        let root_b = [2u8; 32];
        let original = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_a,
                |client| client.root,
                || Ok(test_client(root_a, 7)),
            )
            .unwrap();

        let failed = slot.get_or_insert_with(
            "https://pir.example",
            layout(20),
            root_b,
            |client| client.root,
            || Err(anyhow!("down")),
        );
        assert!(failed.is_err());

        let reused = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_a,
                |client| client.root,
                || panic!("the valid prior client should remain cached"),
            )
            .unwrap();
        assert!(Arc::ptr_eq(&original, &reused));
    }

    #[test]
    fn cached_slot_keeps_the_old_client_when_a_candidate_root_mismatches() {
        let mut slot: CachedSlot<Arc<TestPirClient>> = CachedSlot::new();
        let root_a = [1u8; 32];
        let root_b = [2u8; 32];
        let original = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_a,
                |client| client.root,
                || Ok(test_client(root_a, 1)),
            )
            .unwrap();

        let failed = slot.get_or_insert_with(
            "https://pir.example",
            layout(20),
            root_b,
            |client| client.root,
            || Ok(test_client([3u8; 32], 2)),
        );
        assert!(failed.is_err());

        let reused = slot
            .get_or_insert_with(
                "https://pir.example",
                layout(20),
                root_a,
                |client| client.root,
                || panic!("a root-mismatched candidate must not evict the valid prior client"),
            )
            .unwrap();
        assert!(Arc::ptr_eq(&original, &reused));
    }

    fn stored_round(round_id: String, root: [u8; 32]) -> voting::VotingRoundParams {
        voting::VotingRoundParams {
            vote_round_id: round_id,
            snapshot_height: 100,
            ea_pk: vec![0; 32],
            nc_root: pallas::Base::from(9).to_repr().to_vec(),
            nullifier_imt_root: root.to_vec(),
        }
    }

    fn memory_handle() -> VotingDatabaseHandle {
        let db = Arc::new(VotingDb::open(":memory:").expect("open voting database"));
        db.set_wallet_id("cache-test-wallet");
        VotingDatabaseHandle {
            db,
            tree_sync: VoteTreeSync::new(),
            network: voting::Network::Mainnet,
            network_id: crate::NETWORK_ID_MAINNET,
            pir_client: Mutex::new(CachedSlot::new()),
        }
    }

    #[test]
    fn persisted_round_roots_drive_cache_selection() {
        let handle = memory_handle();
        let cache: Mutex<CachedSlot<Arc<TestPirClient>>> = Mutex::new(CachedSlot::new());
        let mut connects = 0;
        let root_a = pallas::Base::from(1).to_repr();
        let root_b = pallas::Base::from(2).to_repr();
        let round_a = hex::encode(pallas::Base::from(3).to_repr());
        let round_b = hex::encode(pallas::Base::from(4).to_repr());
        handle
            .db
            .init_round(
                voting::Network::Mainnet,
                &stored_round(round_a.clone(), root_a),
                None,
            )
            .expect("insert first round");
        handle
            .db
            .init_round(
                voting::Network::Mainnet,
                &stored_round(round_b.clone(), root_b),
                None,
            )
            .expect("insert second round");

        let first = handle
            .pir_client_for_with(
                &cache,
                &round_a,
                "https://pir.example",
                layout(20),
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root_a, connects))
                },
            )
            .unwrap();
        let repeated = handle
            .pir_client_for_with(
                &cache,
                &round_a,
                "https://pir.example",
                layout(20),
                |client| client.root,
                || panic!("the same persisted round should reuse its client"),
            )
            .unwrap();
        let second = handle
            .pir_client_for_with(
                &cache,
                &round_b,
                "https://pir.example",
                layout(20),
                |client| client.root,
                || {
                    connects += 1;
                    Ok(test_client(root_b, connects))
                },
            )
            .unwrap();

        assert!(Arc::ptr_eq(&first, &repeated));
        assert_eq!(first.generation, 1);
        assert_eq!(second.generation, 2);
        assert_eq!(connects, 2);
    }

    #[test]
    fn persisted_round_root_rejects_missing_and_malformed_rows() {
        let handle = memory_handle();
        let round_id = hex::encode(pallas::Base::from(5).to_repr());
        assert!(handle.pir_root_for_round(&round_id).is_err());

        let root = pallas::Base::from(6).to_repr();
        handle
            .db
            .init_round(
                voting::Network::Mainnet,
                &stored_round(round_id.clone(), root),
                None,
            )
            .expect("insert round");
        let wallet_id = handle.db.wallet_id();
        let conn = handle.db.conn();
        conn.execute(
            "UPDATE rounds SET nullifier_imt_root = X'FF' WHERE round_id = ?1 AND wallet_id = ?2",
            rusqlite::params![round_id, wallet_id],
        )
        .expect("malform persisted root");
        drop(conn);

        assert!(handle.pir_root_for_round(&round_id).is_err());

        let conn = handle.db.conn();
        conn.execute(
            "UPDATE rounds SET nullifier_imt_root = ?3 WHERE round_id = ?1 AND wallet_id = ?2",
            rusqlite::params![round_id, wallet_id, vec![0xffu8; 32]],
        )
        .expect("persist noncanonical root");
        drop(conn);

        assert!(handle.pir_root_for_round(&round_id).is_err());
    }

    #[test]
    fn persisted_round_root_rejects_a_different_network() {
        let handle = memory_handle();
        let root = pallas::Base::from(7).to_repr();
        let round_id = hex::encode(pallas::Base::from(8).to_repr());
        handle
            .db
            .init_round(
                voting::Network::Testnet,
                &stored_round(round_id.clone(), root),
                None,
            )
            .expect("insert round");

        assert!(handle.pir_root_for_round(&round_id).is_err());
    }
}
