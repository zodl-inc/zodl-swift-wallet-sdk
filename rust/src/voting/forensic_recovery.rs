//! Thin FFI boundary for the narrowly scoped historical delegation recovery.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;
use zeroize::Zeroizing;

use crate::unwrap_exc_or_null;

use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};
use super::json::{
    JsonForensicDelegationRecovery, JsonForensicDelegationRecoveryRequest,
    JsonVerifiedVoteTreeSnapshot,
};

// The core additionally caps the number of bundles. This boundary cap prevents
// an accidental oversized JSON allocation before that semantic validation.
const MAX_FORENSIC_RECOVERY_REQUEST_BYTES: usize = 2 * 1024 * 1024;

/// Download all public leaves for a round and return them only after
/// `zcash_voting` has recomputed the vote chain's advertised Merkle root.
///
/// Returns JSON-encoded `JsonVerifiedVoteTreeSnapshot`, or null on error.
///
/// # Safety
///
/// Each byte pointer must be non-null and valid for its stated length when the
/// length is non-zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_verified_vote_tree_snapshot(
    round_id: *const u8,
    round_id_len: usize,
    node_url: *const u8,
    node_url_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let node_url = unsafe { str_from_ptr(node_url, node_url_len) }?;
        let snapshot = voting::verified_vote_tree_snapshot(&round_id, &node_url)
            .map_err(|e| anyhow!("verified_vote_tree_snapshot failed: {e}"))?;

        json_to_boxed_slice(&JsonVerifiedVoteTreeSnapshot::from(snapshot))
    });
    unwrap_exc_or_null(res)
}

/// Validate a complete recovered delegation batch against the stored round,
/// voting hotkey, and a freshly root-validated public tree, then atomically
/// install only the minimal state required to resume voting.
///
/// This is a historical recovery seam, not an alternative delegation path.
/// The request must contain the authenticated round context and every bundle
/// from the original delegation batch.
///
/// Returns JSON-encoded `JsonForensicDelegationRecovery`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `request_json` must be non-null and valid for `request_json_len` bytes
///   when the length is non-zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_recover_delegation_from_forensic_evidence(
    db: *mut VotingDatabaseHandle,
    request_json: *const u8,
    request_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        if request_json_len > MAX_FORENSIC_RECOVERY_REQUEST_BYTES {
            return Err(anyhow!(
                "forensic recovery request exceeds {MAX_FORENSIC_RECOVERY_REQUEST_BYTES} bytes"
            ));
        }
        let request_bytes = unsafe { bytes_from_ptr(request_json, request_json_len) }?;
        let request: JsonForensicDelegationRecoveryRequest = serde_json::from_slice(request_bytes)
            .map_err(|e| anyhow!("invalid forensic recovery request JSON: {e}"))?;

        let JsonForensicDelegationRecoveryRequest {
            expected_chain_id,
            expected_round_params,
            node_url,
            hotkey_stored_secret,
            bundles,
        } = request;
        let hotkey_stored_secret = Zeroizing::new(hotkey_stored_secret);
        let hotkey = voting::VotingHotkey::from_stored_secret(
            hotkey_stored_secret.as_slice(),
            handle.network,
        )
        .map_err(|e| anyhow!("failed to reconstruct voting hotkey: {e}"))?;
        let bundles = bundles
            .into_iter()
            .map(|bundle| bundle.into_validated_core())
            .collect::<Result<Vec<_>, _>>()?;

        let recovery = voting::recover_delegation_from_forensic_evidence(
            handle.db.as_ref(),
            voting::RecoverDelegationFromForensicEvidenceParams {
                voting_hotkey: &hotkey,
                expected_chain_id: &expected_chain_id,
                expected_network: handle.network,
                expected_round_params: &expected_round_params,
                node_url: &node_url,
                bundles: &bundles,
            },
        )
        .map_err(|e| anyhow!("forensic delegation recovery failed: {e}"))?;

        json_to_boxed_slice(&JsonForensicDelegationRecovery::from(recovery))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_json_preserves_root_validated_public_data() {
        let json = JsonVerifiedVoteTreeSnapshot::from(voting::VerifiedVoteTreeSnapshot {
            anchor_height: 42,
            root: [7; 32],
            leaves: vec![voting::VerifiedVoteTreeLeaf {
                position: 3,
                commitment: [9; 32],
            }],
        });

        assert_eq!(json.anchor_height, 42);
        assert_eq!(json.root, vec![7; 32]);
        assert_eq!(json.leaves[0].position, 3);
        assert_eq!(json.leaves[0].commitment, vec![9; 32]);
    }

    #[test]
    fn forensic_bundle_conversion_requires_exact_field_encodings() {
        let bundle = super::super::json::JsonForensicDelegationBundle {
            bundle_index: 0,
            total_note_value: 100_000_000,
            address_index: 0,
            van_comm_rand: vec![1; 31],
            van_commitment: vec![2; 32],
            van_leaf_position: 4,
            delegation_tx_hash: None,
        };

        assert!(bundle.into_validated_core().is_err());
    }

    #[test]
    fn recovery_ffi_rejects_a_null_database_before_network_access() {
        let request = b"{}";
        let result = unsafe {
            zcashlc_voting_recover_delegation_from_forensic_evidence(
                std::ptr::null_mut(),
                request.as_ptr(),
                request.len(),
            )
        };
        assert!(result.is_null());
    }

    #[test]
    fn snapshot_ffi_rejects_an_invalid_round_before_network_access() {
        let round_id = b"invalid";
        let node_url = b"http://127.0.0.1:1";
        let result = unsafe {
            zcashlc_voting_verified_vote_tree_snapshot(
                round_id.as_ptr(),
                round_id.len(),
                node_url.as_ptr(),
                node_url.len(),
            )
        };
        assert!(result.is_null());
    }
}
