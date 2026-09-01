use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::constants::{KEYSTONE_SIGNATURE_LEN, PCZT_SIGHASH_LEN, RANDOMIZED_KEY_LEN};
use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};

#[derive(serde::Serialize)]
struct JsonKeystoneSignatureRecord {
    bundle_index: u32,
    sig: Vec<u8>,
    sighash: Vec<u8>,
    rk: Vec<u8>,
}

impl From<zcash_voting::storage::KeystoneSignatureRecord> for JsonKeystoneSignatureRecord {
    fn from(record: zcash_voting::storage::KeystoneSignatureRecord) -> Self {
        Self {
            bundle_index: record.bundle_index,
            sig: record.sig,
            sighash: record.sighash,
            rk: record.rk,
        }
    }
}

/// Persist the on-chain transaction hash of a submitted delegation bundle.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_delegation_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    tx_hash: *const u8,
    tx_hash_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let tx_hash_str = unsafe { str_from_ptr(tx_hash, tx_hash_len) }?;
        handle
            .db
            .store_delegation_tx_hash(&round_id_str, bundle_index, &tx_hash_str)
            .map_err(|e| anyhow!("store_delegation_tx_hash failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a previously stored delegation transaction hash.
///
/// Returns a JSON-encoded `Option<String>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_delegation_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let hash = handle
            .db
            .get_delegation_tx_hash(&round_id_str, bundle_index)
            .map_err(|e| anyhow!("get_delegation_tx_hash failed: {}", e))?;
        json_to_boxed_slice(&hash)
    });
    unwrap_exc_or_null(res)
}

/// Persist the on-chain transaction hash of a submitted vote.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_vote_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
    tx_hash: *const u8,
    tx_hash_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let tx_hash_str = unsafe { str_from_ptr(tx_hash, tx_hash_len) }?;
        voting::vote::record_submission(
            &handle.db,
            &round_id_str,
            bundle_index,
            proposal_id,
            &tx_hash_str,
        )
        .map_err(|e| anyhow!("record_submission failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a previously stored vote transaction hash.
///
/// Returns a JSON-encoded `Option<String>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_vote_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let hash = handle
            .db
            .get_vote_tx_hash(&round_id_str, bundle_index, proposal_id)
            .map_err(|e| anyhow!("get_vote_tx_hash failed: {}", e))?;
        json_to_boxed_slice(&hash)
    });
    unwrap_exc_or_null(res)
}

/// Record the on-chain vote-commitment-tree position of a confirmed vote.
///
/// This replaces the former `zcashlc_voting_store_commitment_bundle`, which also
/// took the commitment bundle JSON. `zcash_voting` now owns that JSON: it is
/// written when the vote is committed, so the caller has nothing left to supply
/// beyond the confirmed tree position, and the `bundle_json` parameter pair is
/// gone.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_record_vc_position(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
    vc_tree_position: u64,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        voting::vote::record_vc_position(
            &handle.db,
            &round_id_str,
            bundle_index,
            proposal_id,
            vc_tree_position,
        )
        .map_err(|e| anyhow!("record_vc_position failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a stored commitment bundle and vote-commitment-tree position.
///
/// Returns a JSON-encoded `Option<(String, u64)>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_commitment_bundle(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let result = handle
            .db
            .get_commitment_bundle(&round_id_str, bundle_index, proposal_id)
            .map_err(|e| anyhow!("get_commitment_bundle failed: {}", e))?;
        json_to_boxed_slice(&result)
    });
    unwrap_exc_or_null(res)
}

/// Persist a Keystone-produced PCZT signature.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
/// - `sig` must point to exactly 64 bytes.
/// - `sighash` and `rk` must each point to exactly 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_keystone_signature(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    sig: *const u8,
    sig_len: usize,
    sighash: *const u8,
    sighash_len: usize,
    rk: *const u8,
    rk_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        if sig_len != KEYSTONE_SIGNATURE_LEN {
            return Err(anyhow!(
                "sig must be {} bytes, got {}",
                KEYSTONE_SIGNATURE_LEN,
                sig_len
            ));
        }
        if sighash_len != PCZT_SIGHASH_LEN {
            return Err(anyhow!(
                "sighash must be {} bytes, got {}",
                PCZT_SIGHASH_LEN,
                sighash_len
            ));
        }
        if rk_len != RANDOMIZED_KEY_LEN {
            return Err(anyhow!(
                "rk must be {} bytes, got {}",
                RANDOMIZED_KEY_LEN,
                rk_len
            ));
        }
        let sig_bytes = unsafe { bytes_from_ptr(sig, sig_len) }?;
        let sighash_bytes = unsafe { bytes_from_ptr(sighash, sighash_len) }?;
        let rk_bytes = unsafe { bytes_from_ptr(rk, rk_len) }?;
        handle
            .db
            .store_keystone_signature(
                &round_id_str,
                bundle_index,
                sig_bytes,
                sighash_bytes,
                rk_bytes,
            )
            .map_err(|e| anyhow!("store_keystone_signature failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load all Keystone signatures stored for a round.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_keystone_signatures(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let sigs = handle
            .db
            .get_keystone_signatures(&round_id_str)
            .map_err(|e| anyhow!("get_keystone_signatures failed: {}", e))?;

        let out: Vec<JsonKeystoneSignatureRecord> = sigs.into_iter().map(Into::into).collect();

        json_to_boxed_slice(&out)
    });
    unwrap_exc_or_null(res)
}

/// Clear retryable recovery state for a round without erasing recorded
/// confirmations.
///
/// Share-delegation rows and Keystone signatures are always removed. Since
/// `zcash_voting` 3.0 the clear is conservative about confirmed state:
/// delegation tx hashes survive on bundles with a recorded VAN leaf position
/// (and on capability-imported bundles), and votes with a recorded
/// `vc_tree_position` keep their tx hash, commitment bundle, and position.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_clear_recovery_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        handle
            .db
            .clear_recovery_state(&round_id_str)
            .map_err(|e| anyhow!("clear_recovery_state failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::zcashlc_free_boxed_slice;
    use crate::voting::db::zcashlc_voting_db_free;
    use crate::voting::share_tracking::zcashlc_voting_get_share_delegations;
    use crate::voting::test_helpers::{insert_round_and_bundle, open_memory_db};
    use serde::de::DeserializeOwned;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null());
        let json = unsafe { (*ptr).as_slice() }.to_vec();
        let value = serde_json::from_slice(&json).expect("decode boxed JSON");
        unsafe { zcashlc_free_boxed_slice(ptr) };
        value
    }

    /// Creates the vote row that the recovery-state rows hang off.
    ///
    /// `zcash_voting` only writes vote rows as a side effect of `vote::commit`,
    /// which requires a full ZKP #2 proof, so tests seed the row through the
    /// public storage query layer instead.
    fn insert_vote(db: *mut VotingDatabaseHandle, round_id: &str) {
        let handle = unsafe { db.as_ref() }.expect("voting db handle");
        voting::storage::queries::store_vote(
            &handle.db.conn(),
            round_id,
            &handle.db.wallet_id(),
            0,
            0,
            0,
            &[0xaa; 32],
        )
        .expect("insert vote");
    }

    #[test]
    fn delegation_tx_hash_round_trips() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let tx_hash = b"delegation-tx";

        let code = unsafe {
            zcashlc_voting_store_delegation_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, 0);

        let result = unsafe {
            zcashlc_voting_get_delegation_tx_hash(db, round_id.as_ptr(), round_id.len(), 0)
        };
        let actual: Option<String> = decode_boxed_json(result);
        assert_eq!(actual.as_deref(), Some("delegation-tx"));

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_delegation_tx_hash_rejects_missing_bundle() {
        let db = open_memory_db();
        let round_id = b"missing";
        let tx_hash = b"delegation-tx";

        let code = unsafe {
            zcashlc_voting_store_delegation_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, -1);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn vote_tx_hash_round_trips() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");
        let tx_hash = b"vote-tx";

        let code = unsafe {
            zcashlc_voting_store_vote_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, 0);

        let result =
            unsafe { zcashlc_voting_get_vote_tx_hash(db, round_id.as_ptr(), round_id.len(), 0, 0) };
        let actual: Option<String> = decode_boxed_json(result);
        assert_eq!(actual.as_deref(), Some("vote-tx"));

        unsafe { zcashlc_voting_db_free(db) };
    }

    // The former `commitment_bundle_round_trips` test is gone: the caller can no
    // longer supply the commitment bundle JSON, so an FFI-level round trip is no
    // longer expressible. `zcash_voting` writes that JSON only from
    // `vote::commit`, which needs a real ZKP #2 proof, and
    // `zcashlc_voting_get_commitment_bundle` reports `None` until it is present.

    #[test]
    fn record_vc_position_accepts_existing_vote() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");

        let code = unsafe {
            zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
        };
        assert_eq!(code, 0);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn record_vc_position_rejects_missing_vote() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");

        let code = unsafe {
            zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
        };
        assert_eq!(code, -1);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_keystone_signature_round_trips_valid_signature() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];

        let code = unsafe {
            zcashlc_voting_store_keystone_signature(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                sig.as_ptr(),
                sig.len(),
                sighash.as_ptr(),
                sighash.len(),
                rk.as_ptr(),
                rk.len(),
            )
        };
        assert_eq!(code, 0);

        let result = unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        };
        assert!(!result.is_null());
        let json = unsafe { (*result).as_slice() }.to_vec();
        let actual: serde_json::Value =
            serde_json::from_slice(&json).expect("keystone signatures json");
        assert_eq!(
            actual,
            serde_json::json!([
                {
                    "bundle_index": 0,
                    "sig": sig.to_vec(),
                    "sighash": sighash.to_vec(),
                    "rk": rk.to_vec(),
                }
            ])
        );

        unsafe { zcashlc_free_boxed_slice(result) };
        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_keystone_signature_rejects_invalid_lengths() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];

        let cases = [
            (
                KEYSTONE_SIGNATURE_LEN - 1,
                PCZT_SIGHASH_LEN,
                RANDOMIZED_KEY_LEN,
            ),
            (
                KEYSTONE_SIGNATURE_LEN,
                PCZT_SIGHASH_LEN - 1,
                RANDOMIZED_KEY_LEN,
            ),
            (
                KEYSTONE_SIGNATURE_LEN,
                PCZT_SIGHASH_LEN,
                RANDOMIZED_KEY_LEN - 1,
            ),
        ];

        for (sig_len, sighash_len, rk_len) in cases {
            let code = unsafe {
                zcashlc_voting_store_keystone_signature(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    sig.as_ptr(),
                    sig_len,
                    sighash.as_ptr(),
                    sighash_len,
                    rk.as_ptr(),
                    rk_len,
                )
            };
            assert_eq!(code, -1);
        }

        unsafe { zcashlc_voting_db_free(db) };
    }

    /// Stores the delegation tx hash, vote tx hash, and a Keystone signature
    /// that the clear-recovery tests start from.
    fn store_recovery_fixture(db: *mut VotingDatabaseHandle, round_id: &[u8]) {
        let delegation_tx = b"delegation-tx";
        assert_eq!(
            unsafe {
                zcashlc_voting_store_delegation_tx_hash(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    delegation_tx.as_ptr(),
                    delegation_tx.len(),
                )
            },
            0
        );

        let vote_tx = b"vote-tx";
        assert_eq!(
            unsafe {
                zcashlc_voting_store_vote_tx_hash(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    0,
                    vote_tx.as_ptr(),
                    vote_tx.len(),
                )
            },
            0
        );

        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];
        assert_eq!(
            unsafe {
                zcashlc_voting_store_keystone_signature(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    sig.as_ptr(),
                    sig.len(),
                    sighash.as_ptr(),
                    sighash.len(),
                    rk.as_ptr(),
                    rk.len(),
                )
            },
            0
        );

        // Share delegations are deliberately absent from this fixture:
        // `zcashlc_voting_record_share_delegation` now derives the share
        // nullifier from the persisted vote recovery bundle, which only a real
        // `vote::commit` can write. The clear is still asserted to leave no
        // share rows behind.
    }

    #[test]
    fn clear_recovery_state_removes_unconfirmed_recovery_data() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");
        store_recovery_fixture(db, round_id);

        assert_eq!(
            unsafe { zcashlc_voting_clear_recovery_state(db, round_id.as_ptr(), round_id.len()) },
            0
        );

        let delegation_tx: Option<String> = decode_boxed_json(unsafe {
            zcashlc_voting_get_delegation_tx_hash(db, round_id.as_ptr(), round_id.len(), 0)
        });
        assert_eq!(delegation_tx, None);

        let vote_tx: Option<String> = decode_boxed_json(unsafe {
            zcashlc_voting_get_vote_tx_hash(db, round_id.as_ptr(), round_id.len(), 0, 0)
        });
        assert_eq!(vote_tx, None);

        // No position was recorded before the clear, so the vote row survives
        // with its recovery columns reset and accepts a fresh recording.
        assert_eq!(
            unsafe {
                zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 43)
            },
            0
        );

        let keystone_sigs: Vec<serde_json::Value> = decode_boxed_json(unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        });
        assert!(keystone_sigs.is_empty());

        let share_delegations: Vec<serde_json::Value> = decode_boxed_json(unsafe {
            zcashlc_voting_get_share_delegations(db, round_id.as_ptr(), round_id.len())
        });
        assert!(share_delegations.is_empty());

        unsafe { zcashlc_voting_db_free(db) };
    }

    /// Pins the conservative `zcash_voting` 3.0 clear semantics: a vote whose
    /// on-chain `vc_tree_position` is recorded is confirmed state, and the
    /// recovery clear must preserve it (rc.5 nulled it unconditionally).
    #[test]
    fn clear_recovery_state_preserves_recorded_vc_position() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");
        store_recovery_fixture(db, round_id);

        assert_eq!(
            unsafe {
                zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
            },
            0
        );

        assert_eq!(
            unsafe { zcashlc_voting_clear_recovery_state(db, round_id.as_ptr(), round_id.len()) },
            0
        );

        // The confirmed vote keeps its tx hash: the vote reset skips rows with
        // a recorded position.
        let vote_tx: Option<String> = decode_boxed_json(unsafe {
            zcashlc_voting_get_vote_tx_hash(db, round_id.as_ptr(), round_id.len(), 0, 0)
        });
        assert_eq!(vote_tx.as_deref(), Some("vote-tx"));

        // The recorded position survived: a conflicting recording is refused
        // while re-recording the same position stays idempotent.
        assert_eq!(
            unsafe {
                zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 43)
            },
            -1
        );
        assert_eq!(
            unsafe {
                zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
            },
            0
        );

        // The unconfirmed delegation (no recorded VAN leaf position) is still
        // cleared, and the unconditional lanes still empty out.
        let delegation_tx: Option<String> = decode_boxed_json(unsafe {
            zcashlc_voting_get_delegation_tx_hash(db, round_id.as_ptr(), round_id.len(), 0)
        });
        assert_eq!(delegation_tx, None);

        let keystone_sigs: Vec<serde_json::Value> = decode_boxed_json(unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        });
        assert!(keystone_sigs.is_empty());

        unsafe { zcashlc_voting_db_free(db) };
    }
}

/// One carved bundle, as the wallet client recovered it from a wiped database.
///
/// Deserialised rather than passed as a C array because the count varies and a
/// repeated-struct ABI would have to be kept in step by hand on both sides;
/// the rest of this FFI already moves structured data as JSON.
///
/// `van_comm_rand` and `gov_comm` are lowercase hex, matching how round and
/// transaction identifiers already cross this boundary.
#[derive(serde::Deserialize)]
struct JsonCarvedBundle {
    bundle_index: u32,
    van_comm_rand: String,
    gov_comm: String,
    total_note_value: u64,
    #[serde(default)]
    delegation_tx_hash: Option<String>,
}

fn decode_field(hex_str: &str, field: &str) -> anyhow::Result<[u8; 32]> {
    // Decoded by hand: `hex` is a dev-dependency of this crate, and a new
    // runtime dependency for sixteen lines is not a trade worth making.
    if hex_str.len() != 64 {
        return Err(anyhow!(
            "{field} must be 64 hex characters, got {}",
            hex_str.len()
        ));
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        let pair = &hex_str[i * 2..i * 2 + 2];
        *byte = u8::from_str_radix(pair, 16)
            .map_err(|e| anyhow!("{field} is not valid hex: {e}"))?;
    }
    Ok(out)
}

/// Restores delegation state the wallet carved out of a wiped database.
///
/// The wipe destroyed `van_comm_rand`, which is sampled from `OsRng` and was
/// writable through no exported call -- which is exactly why it was terminal.
/// The client can now recover it from freed pages and the write-ahead log, and
/// this is the door back in.
///
/// `bundles_json` is an array of objects:
///
/// ```json
/// [{"bundle_index": 0,
///   "van_comm_rand": "<64 hex chars>",
///   "gov_comm": "<64 hex chars>",
///   "total_note_value": 130000000,
///   "delegation_tx_hash": "<hex or null>"}]
/// ```
///
/// A null `delegation_tx_hash` is legitimate: it is stored only after
/// submission returns, so its absence usually means nothing was broadcast.
///
/// Returns the number of bundles whose secrets were written, which is 0 when
/// they were already present -- the call is idempotent, and recovery runs on
/// every cold launch. Returns -1 on error.
///
/// # Safety
///
/// `db` must be a valid `VotingDatabaseHandle`; the pointers must reference
/// initialised buffers of the given lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_restore_carved_delegation(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundles_json: *const u8,
    bundles_json_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let json = unsafe { str_from_ptr(bundles_json, bundles_json_len) }?;

        let parsed: Vec<JsonCarvedBundle> = serde_json::from_str(&json)
            .map_err(|e| anyhow!("carved bundles are not valid JSON: {}", e))?;

        let bundles = parsed
            .into_iter()
            .map(|b| {
                Ok(voting::carved_delegation::CarvedBundle {
                    bundle_index: b.bundle_index,
                    van_comm_rand: decode_field(&b.van_comm_rand, "van_comm_rand")?,
                    gov_comm: decode_field(&b.gov_comm, "gov_comm")?,
                    total_note_value: b.total_note_value,
                    delegation_tx_hash: b.delegation_tx_hash,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let outcome = handle
            .db
            .restore_carved_delegation(&round_id_str, &bundles)
            .map_err(|e| anyhow!("restore_carved_delegation failed: {}", e))?;

        Ok(i32::try_from(outcome.restored).unwrap_or(i32::MAX))
    });
    unwrap_exc_or(res, -1)
}
