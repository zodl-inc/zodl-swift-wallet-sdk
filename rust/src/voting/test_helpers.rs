use zcash_voting as voting;
use zcash_voting::storage::queries;

use super::constants::SEED_FINGERPRINT_LEN;
use super::db::{VotingDatabaseHandle, zcashlc_voting_db_open, zcashlc_voting_set_wallet_id};
use super::signing::zcashlc_voting_get_stored_pczt_sighash;

pub(crate) fn open_memory_db() -> *mut VotingDatabaseHandle {
    let path = b":memory:";
    let db =
        unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), crate::NETWORK_ID_MAINNET) };
    assert!(!db.is_null());

    let wallet = b"wallet";
    let code = unsafe { zcashlc_voting_set_wallet_id(db, wallet.as_ptr(), wallet.len()) };
    assert_eq!(code, 0);

    db
}

pub(crate) fn insert_round_and_bundle(db: *mut VotingDatabaseHandle, round_id: &str) {
    let handle = unsafe { db.as_ref() }.expect("db handle");
    let params = zcash_voting::VotingRoundParams {
        vote_round_id: round_id.to_string(),
        snapshot_height: 123,
        ea_pk: vec![7u8; 32],
        nc_root: vec![8u8; 32],
        nullifier_imt_root: vec![9u8; 32],
    };
    handle
        .db
        .init_round(zcash_voting::Network::Mainnet, &params, None)
        .expect("insert round");

    let notes: Vec<zcash_voting::NoteInfo> = (0..5)
        .map(|position| zcash_voting::NoteInfo {
            commitment: vec![1u8; 32],
            nullifier: vec![2u8; 32],
            value: 13_000_000,
            position,
            diversifier: vec![0u8; 11],
            rho: vec![3u8; 32],
            rseed: vec![4u8; 32],
            scope: 0,
            ufvk_str: String::new(),
        })
        .collect();
    let layout = handle
        .db
        .ensure_bundles(round_id, &notes)
        .expect("setup bundle");
    assert_eq!(layout.bundle_count, 1);
}

/// Must match the wallet id `test_helpers::open_memory_db` registers, or the
/// planted rows are invisible to the handle under test.
pub(crate) const TEST_WALLET_ID: &str = "wallet";
pub(crate) const TEST_ROUND_ID: &str = "round";
pub(crate) const TEST_SEED: [u8; 32] = [1u8; 32];
pub(crate) const PLANTED_SIGHASH: [u8; 32] = [9u8; 32];

pub(crate) fn test_seed_fingerprint() -> [u8; SEED_FINGERPRINT_LEN] {
    zip32::fingerprint::SeedFingerprint::from_seed(&TEST_SEED)
        .expect("32-byte seed is valid for ZIP-32")
        .to_bytes()
}

/// A stored hotkey secret that `zcash_voting` accepts, produced the same way
/// a wallet would produce it rather than by guessing at the encoding.
pub(crate) fn valid_stored_secret() -> Vec<u8> {
    voting::hotkey::generate_random_voting_hotkey(voting::Network::Mainnet)
        .expect("generate hotkey")
        .stored_secret()
        .to_vec()
}

/// Plant the round, bundle, and stored PCZT signing fields (`pczt_sighash`,
/// `alpha`) that `delegate::signing_request` loads, without running the
/// proving pipeline that stores them in production. Only the two loaded
/// fields and the crate-validated `tx1_effects` need real shapes; the other
/// delegation blobs are inert 32-byte placeholders.
pub(crate) fn plant_signing_request(db: *mut VotingDatabaseHandle, alpha: &[u8; 32]) {
    insert_round_and_bundle(db, TEST_ROUND_ID);
    let handle = unsafe { db.as_ref() }.expect("db handle");
    let conn = handle.db.conn();
    let mut tx1_effects = vec![0u8; voting::tx1::TX1_EFFECTS_LEN];
    tx1_effects[0] = voting::tx1::TX1_EFFECTS_VERSION;
    queries::store_delegation_data(
        &conn,
        TEST_ROUND_ID,
        TEST_WALLET_ID,
        0,
        &[0u8; 32], // van_comm_rand
        &[],        // dummy_nullifiers
        &[0u8; 32], // rho_signed
        &[],        // padded_cmx
        &[0u8; 32], // nf_signed
        &[0u8; 32], // cmx_new
        alpha,
        &[0u8; 32], // rseed_signed
        &[0u8; 32], // rseed_output
        &[0u8; 32], // gov_comm
        65_000_000, // total_note_value
        0,          // address_index
        &[],        // padded_note_secrets
        &PLANTED_SIGHASH,
        &tx1_effects,
    )
    .expect("plant delegation signing data");
}

/// Thin wrapper around `zcashlc_voting_get_stored_pczt_sighash` for bundle 0,
/// the only bundle index these tests exercise. The readback takes no
/// delegation-key inputs, so unlike `call_sign` there is nothing here to
/// marshal beyond the round id.
pub(crate) fn call_get_sighash(
    db: *mut VotingDatabaseHandle,
    round_id: &[u8],
) -> *mut crate::ffi::BoxedSlice {
    unsafe { zcashlc_voting_get_stored_pczt_sighash(db, round_id.as_ptr(), round_id.len(), 0) }
}
