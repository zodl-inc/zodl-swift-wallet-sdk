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
    use crate::ffi::zcashlc_free_boxed_slice;
    use crate::voting::db::{
        zcashlc_voting_db_free, zcashlc_voting_db_open, zcashlc_voting_set_wallet_id,
    };
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    const ROUND_ID: &str = "0101010101010101010101010101010101010101010101010101010101010101";
    const WALLET_ID: &str = "forensic-recovery-wallet";

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
    fn recovery_ffi_restores_a_post_cleanup_round_and_returns_decodable_json() {
        let path = b":memory:";
        let db =
            unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), crate::NETWORK_ID_TESTNET) };
        assert!(!db.is_null());
        let wallet_id = WALLET_ID.as_bytes();
        assert_eq!(
            unsafe { zcashlc_voting_set_wallet_id(db, wallet_id.as_ptr(), wallet_id.len()) },
            0
        );
        let handle = unsafe { db.as_ref() }.expect("voting database handle");
        let params = voting::VotingRoundParams {
            vote_round_id: ROUND_ID.to_string(),
            snapshot_height: 100,
            ea_pk: vec![2; 32],
            nc_root: vec![3; 32],
            nullifier_imt_root: vec![4; 32],
        };
        handle
            .db
            .create_round(voting::Network::Testnet, &params, None)
            .expect("create recovery round");
        voting::storage::queries::insert_bundle(&handle.db.conn(), ROUND_ID, WALLET_ID, 0, &[50])
            .expect("insert local bundle");
        handle
            .db
            .conn()
            .execute(
                "UPDATE bundles
                 SET van_comm_rand = ?1, gov_comm = ?2,
                     total_note_value = ?3, address_index = 0
                 WHERE round_id = ?4 AND wallet_id = ?5 AND bundle_index = 0",
                rusqlite::params![
                    [100u8; 32],
                    [200u8; 32],
                    voting::BALLOT_DIVISOR,
                    ROUND_ID,
                    WALLET_ID,
                ],
            )
            .expect("stage unsigned delegation fields");
        handle
            .db
            .conn()
            .execute(
                "INSERT INTO proofs
                 (round_id, wallet_id, bundle_index, proof, success, created_at)
                 VALUES (?1, ?2, 0, X'01', 1, 1)",
                rusqlite::params![ROUND_ID, WALLET_ID],
            )
            .expect("insert stale delegation proof");
        handle
            .db
            .set_ballot_intent(ROUND_ID, 2, voting::session::Decision::Choice(1), 3)
            .expect("store ballot intent");

        // Reproduce the cleanup that preserved the local bundle selection but
        // discarded the VAN randomness needed to get through delegation.
        handle
            .db
            .clear_unsigned_delegation_setup_fields(ROUND_ID)
            .expect("clear unsigned delegation fields");
        let (node_url, server) = start_known_vote_tree_server();
        let mut van_comm_rand = vec![0; 32];
        van_comm_rand[0] = 10;
        let van_commitment = vec![
            232, 61, 123, 29, 249, 247, 83, 140, 64, 62, 212, 129, 182, 235, 51, 128, 205, 150, 67,
            213, 102, 13, 174, 224, 229, 86, 55, 8, 42, 0, 116, 54,
        ];
        let request = serde_json::to_vec(&serde_json::json!({
            "expected_round_params": params,
            "node_url": node_url,
            "hotkey_stored_secret": vec![0xAB; 64],
            "bundles": [{
                "bundle_index": 0,
                "total_note_value": voting::BALLOT_DIVISOR,
                "address_index": 0,
                "van_comm_rand": van_comm_rand,
                "van_commitment": van_commitment,
                "van_leaf_position": 1,
                "delegation_tx_hash": null
            }]
        }))
        .expect("serialize forensic request");

        let result = unsafe {
            zcashlc_voting_recover_delegation_from_forensic_evidence(
                db,
                request.as_ptr(),
                request.len(),
            )
        };
        assert!(!result.is_null());
        server.join().expect("serve both vote tree requests");
        let recovery: JsonForensicDelegationRecovery =
            serde_json::from_slice(unsafe { (*result).as_slice() })
                .expect("decode forensic recovery result");
        unsafe { zcashlc_free_boxed_slice(result) };

        assert_eq!(recovery.anchor_height, 5);
        assert_eq!(recovery.bundle_count, 1);
        assert!(!recovery.already_recovered);
        assert_eq!(
            recovery.tree_root,
            vec![
                251, 113, 3, 32, 68, 62, 155, 112, 149, 216, 10, 161, 132, 61, 83, 238, 231, 1, 64,
                254, 198, 141, 206, 13, 83, 61, 2, 219, 213, 249, 220, 25,
            ]
        );
        let plan = voting::session::resume_plan(handle.db.as_ref(), ROUND_ID, &[2])
            .expect("resume recovered round");
        assert_eq!(
            plan.next_steps
                .iter()
                .filter(|step| matches!(step, voting::session::NextStep::CastVote { .. }))
                .count(),
            1
        );
        assert_eq!(
            handle.db.ballot_intents(ROUND_ID).expect("ballot intents"),
            vec![(2, voting::session::Decision::Choice(1))]
        );
        let proof_count: i64 = handle
            .db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM proofs WHERE round_id = ?1 AND wallet_id = ?2",
                rusqlite::params![ROUND_ID, WALLET_ID],
                |row| row.get(0),
            )
            .expect("count stale proofs");
        assert_eq!(proof_count, 0);

        unsafe { zcashlc_voting_db_free(db) };
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

    fn start_known_vote_tree_server() -> (String, thread::JoinHandle<()>) {
        const LATEST: &str = r#"{"tree":{"height":5,"next_index":5,"root":"+3EDIEQ+m3CV2AqhhD1T7ucBQP7Gjc4NUz0C29X53Bk="}}"#;
        const LEAVES: &str = r#"{"blocks":[{"height":1,"leaves":["9AEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="],"root":"d56PEKjXhaZzOkTeaf2bIZVe9Jsr0c/mZcxJ+wK7cyw=","start_index":0},{"height":2,"leaves":["6D17Hfn3U4xAPtSBtuszgM2WQ9VmDa7g5VY3CCoAdDY="],"root":"UFk7f+7OhvutefQUXbo25dFktWNQ+utWAW96e/Ul3Tk=","start_index":1},{"height":3,"leaves":["9wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="],"root":"HAoWr7jvdR7vwKPqYc0JmzHiA9y9cLQoRca9MJqxDD0=","start_index":2},{"height":4,"leaves":["z4tfIgCq7R2EIbvXzJ2z7v7RIkrbuWdtuZGgGiHmMyk="],"root":"scjCk3YVJAeHrDoXUp5ih6Z2kDcFbExQToTMxU3T9DI=","start_index":3},{"height":5,"leaves":["+QEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="],"root":"+3EDIEQ+m3CV2AqhhD1T7ucBQP7Gjc4NUz0C29X53Bk=","start_index":4}],"next_from_height":0}"#;
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind vote tree fixture");
        let url = format!("http://{}", listener.local_addr().expect("server address"));
        let server = thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept vote tree request");
                let mut request = [0u8; 2048];
                let length = stream.read(&mut request).expect("read vote tree request");
                let request = String::from_utf8_lossy(&request[..length]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");
                let body = if path.ends_with("/latest") {
                    LATEST
                } else if path.contains("/leaves?") {
                    LEAVES
                } else {
                    panic!("unexpected vote tree request: {path}");
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                stream
                    .write_all(response.as_bytes())
                    .expect("write vote tree response");
            }
        });
        (url, server)
    }
}
