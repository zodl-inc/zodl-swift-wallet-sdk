//! Pure key- and tree-derivation FFI for voting.
//!
//! Both entry points are total functions of their byte inputs — no sidecar
//! database, no wallet, no network — which is why they outlived the 3.0 FFI
//! surface: Swift still needs the Orchard FVK behind a UFVK and the Ironwood
//! note-commitment root behind a `TreeState` before a round can be opened.

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use prost::Message;
use zcash_client_backend::proto::service::TreeState;
use zcash_keys::keys::UnifiedFullViewingKey;

use crate::unwrap_exc_or_null;

use super::helpers::{bytes_from_ptr, str_from_ptr};

/// Extract the 96-byte Orchard FVK from a UFVK string.
///
/// Returns the raw 96-byte Orchard FVK as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `ufvk_str` must be valid for reads of `ufvk_str_len` bytes (UTF-8 encoded).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_orchard_fvk_from_ufvk(
    ufvk_str: *const u8,
    ufvk_str_len: usize,
    network_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let ufvk_string = unsafe { str_from_ptr(ufvk_str, ufvk_str_len) }?;

        let network = crate::parse_network(network_id)?;
        let ufvk = UnifiedFullViewingKey::decode(&network, &ufvk_string)
            .map_err(|e| anyhow!("failed to decode UFVK string: {}", e))?;

        let orchard_fvk = ufvk
            .orchard()
            .ok_or_else(|| anyhow!("UFVK has no Orchard component"))?;
        Ok(crate::ffi::BoxedSlice::some(
            orchard_fvk.to_bytes().to_vec(),
        ))
    });
    unwrap_exc_or_null(res)
}

/// Extract the Ironwood note commitment tree root from a protobuf-encoded TreeState.
///
/// Voting rounds anchor to the Ironwood pool — `zcash_voting` supports no other
/// shielded protocol — so a round's `nc_root` is the root of the Ironwood tree,
/// not the Orchard one. They are distinct pools with distinct trees whose
/// roots never coincide on a live chain, so reading the wrong field does not
/// degrade gracefully: it fails every round, always.
///
/// Returns the 32-byte nc_root as `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `tree_state_bytes` must be valid for reads of `tree_state_bytes_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_extract_nc_root(
    tree_state_bytes: *const u8,
    tree_state_bytes_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(tree_state_bytes, tree_state_bytes_len) }?;
        let tree_state = TreeState::decode(bytes)
            .map_err(|e| anyhow!("failed to decode TreeState protobuf: {}", e))?;
        let ironwood_ct = tree_state
            .ironwood_tree()
            .map_err(|e| anyhow!("failed to parse ironwood tree from TreeState: {}", e))?;
        let nc_root = ironwood_ct.root().to_bytes().to_vec();
        Ok(crate::ffi::BoxedSlice::some(nc_root))
    });
    unwrap_exc_or_null(res)
}

/// Recompute a vote round id the way the vote chain derives it: Poseidon (P128Pow5T3,
/// ConstantLength<8>) over `created_at_height`, the snapshot blockhash and the proposals hash
/// (each split into two little-endian 128-bit limbs), `vote_end_time`, `nullifier_imt_root` and
/// `nc_root`.
///
/// A wallet compares the result with the round id a vote server reported, so a server cannot
/// show different ballot content under a signed round id.
///
/// `snapshot_blockhash` is the hash as the vote chain reports it (display order), not the internal
/// byte order of a lightwalletd `BlockID`; the other order derives a different id.
///
/// Returns the 32-byte canonical field element as `*mut FfiBoxedSlice`, or null on error
/// (a length other than 32, or a root that is not a canonical Pallas field element).
///
/// # Safety
///
/// - Each pointer must be valid for reads of its paired length in bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_derive_round_id(
    created_at_height: u64,
    snapshot_blockhash: *const u8,
    snapshot_blockhash_len: usize,
    proposals_hash: *const u8,
    proposals_hash_len: usize,
    vote_end_time: u64,
    nullifier_imt_root: *const u8,
    nullifier_imt_root_len: usize,
    nc_root: *const u8,
    nc_root_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let fixed = |ptr: *const u8, len: usize, name: &str| -> anyhow::Result<[u8; 32]> {
            let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
            <[u8; 32]>::try_from(bytes)
                .map_err(|_| anyhow!("{name} must be exactly 32 bytes, got {}", bytes.len()))
        };
        let round_id = derive_round_id(
            created_at_height,
            fixed(
                snapshot_blockhash,
                snapshot_blockhash_len,
                "snapshot_blockhash",
            )?,
            fixed(proposals_hash, proposals_hash_len, "proposals_hash")?,
            vote_end_time,
            fixed(
                nullifier_imt_root,
                nullifier_imt_root_len,
                "nullifier_imt_root",
            )?,
            fixed(nc_root, nc_root_len, "nc_root")?,
        )?;
        Ok(crate::ffi::BoxedSlice::some(round_id.to_vec()))
    });
    unwrap_exc_or_null(res)
}

fn derive_round_id(
    created_at_height: u64,
    snapshot_blockhash: [u8; 32],
    proposals_hash: [u8; 32],
    vote_end_time: u64,
    nullifier_imt_root: [u8; 32],
    nc_root: [u8; 32],
) -> anyhow::Result<[u8; 32]> {
    use ff::PrimeField;
    use halo2_poseidon::{ConstantLength, Hash, P128Pow5T3};
    use pasta_curves::pallas::Base;

    let limbs = |bytes: &[u8; 32]| -> (Base, Base) {
        let lo = u128::from_le_bytes(bytes[..16].try_into().expect("16 bytes"));
        let hi = u128::from_le_bytes(bytes[16..].try_into().expect("16 bytes"));
        (Base::from_u128(lo), Base::from_u128(hi))
    };
    let field = |bytes: [u8; 32], name: &str| -> anyhow::Result<Base> {
        Option::from(Base::from_repr(bytes))
            .ok_or_else(|| anyhow!("{name} is not a canonical Pallas field element"))
    };

    let (bh_lo, bh_hi) = limbs(&snapshot_blockhash);
    let (ph_lo, ph_hi) = limbs(&proposals_hash);
    let inputs = [
        Base::from(created_at_height),
        bh_lo,
        bh_hi,
        ph_lo,
        ph_hi,
        Base::from(vote_end_time),
        field(nullifier_imt_root, "nullifier_imt_root")?,
        field(nc_root, "nc_root")?,
    ];

    let hash = Hash::<_, P128Pow5T3, ConstantLength<8>, 3, 2>::init().hash(inputs);
    Ok(hash.to_repr())
}

#[cfg(test)]
mod derive_round_id_tests {
    use super::derive_round_id;

    fn hex32(s: &str) -> [u8; 32] {
        let mut out = [0u8; 32];
        for (i, byte) in out.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap();
        }
        out
    }

    // A real round from the prod vote chain ("NU7 Scope"); the expected id is its `vote_round_id`.
    const BLOCKHASH: &str = "000000000079f151b017b515d0084713d19bd596a76ecfd75f82fd32bf43d968";
    const PROPOSALS_HASH: &str = "7699c729a197ead27b327c569a5fa7a4b98132a67081b3cb6b9baea3a5ef2d02";
    const NF_ROOT: &str = "362eaf14c595d4df74932bbcc184b5cd5d1896592668c2dba7dcd7bac685da09";
    const NC_ROOT: &str = "060a13d76e798c460b1a51497e621f61a9e482bae1def3ca06eecb0d85a5d41d";
    const ROUND_ID: &str = "16eef7ebc77e0e04fb1c7329abfcc390f4a0c002964671ebb360914a3e5a3f11";

    fn derive(height: u64, proposals_hash: &str) -> anyhow::Result<[u8; 32]> {
        derive_round_id(
            height,
            hex32(BLOCKHASH),
            hex32(proposals_hash),
            1_789_412_400,
            hex32(NF_ROOT),
            hex32(NC_ROOT),
        )
    }

    #[test]
    fn matches_the_on_chain_round_id() {
        assert_eq!(derive(5_717_157, PROPOSALS_HASH).unwrap(), hex32(ROUND_ID));
    }

    #[test]
    fn changing_any_input_changes_the_id() {
        let other_hash = "7699c729a197ead27b327c569a5fa7a4b98132a67081b3cb6b9baea3a5ef2d03";
        assert_ne!(derive(5_717_157, other_hash).unwrap(), hex32(ROUND_ID));
        assert_ne!(derive(5_717_158, PROPOSALS_HASH).unwrap(), hex32(ROUND_ID));
    }

    #[test]
    fn rejects_a_non_canonical_field_element() {
        let result = derive_round_id(
            5_717_157,
            hex32(BLOCKHASH),
            hex32(PROPOSALS_HASH),
            1_789_412_400,
            [0xff; 32],
            hex32(NC_ROOT),
        );
        assert!(result.is_err());
    }

    #[test]
    fn ffi_returns_the_round_id_and_null_on_a_wrong_length() {
        let (bh, ph, nf, nc) = (
            hex32(BLOCKHASH),
            hex32(PROPOSALS_HASH),
            hex32(NF_ROOT),
            hex32(NC_ROOT),
        );
        let ok = unsafe {
            super::zcashlc_voting_derive_round_id(
                5_717_157,
                bh.as_ptr(),
                32,
                ph.as_ptr(),
                32,
                1_789_412_400,
                nf.as_ptr(),
                32,
                nc.as_ptr(),
                32,
            )
        };
        assert!(!ok.is_null());
        let bytes = unsafe { (*ok).as_slice() }.to_vec();
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ok) };
        assert_eq!(bytes, hex32(ROUND_ID).to_vec());

        let short = unsafe {
            super::zcashlc_voting_derive_round_id(
                5_717_157,
                bh.as_ptr(),
                31,
                ph.as_ptr(),
                32,
                1_789_412_400,
                nf.as_ptr(),
                32,
                nc.as_ptr(),
                32,
            )
        };
        assert!(short.is_null());
    }
}

#[cfg(test)]
mod tests {
    use ff::PrimeField;
    use incrementalmerkletree::frontier::{CommitmentTree, Frontier};
    use orchard::tree::{Anchor, MerkleHashOrchard};
    use pasta_curves::pallas;
    use zcash_keys::keys::UnifiedSpendingKey;
    use zcash_primitives::merkle_tree::write_commitment_tree;
    use zcash_protocol::consensus::Network;
    use zip32::AccountId;

    use super::super::constants::ORCHARD_FVK_LEN;
    use super::*;
    use crate::{NETWORK_ID_MAINNET, NETWORK_ID_TESTNET};

    fn free(ptr: *mut crate::ffi::BoxedSlice) {
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
    }

    fn boxed_slice_to_vec(ptr: *mut crate::ffi::BoxedSlice) -> Vec<u8> {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let bytes = unsafe { (*ptr).as_slice() }.to_vec();
        free(ptr);
        bytes
    }

    fn derive_test_ufvk(network: Network) -> (String, [u8; ORCHARD_FVK_LEN]) {
        let seed = [0u8; 32];
        let account = AccountId::try_from(0).expect("account 0");
        let usk = UnifiedSpendingKey::from_seed(&network, &seed, account).expect("from_seed");
        let ufvk = usk.to_unified_full_viewing_key();
        let ufvk_str = ufvk.encode(&network).unwrap();
        let orchard_bytes = ufvk.orchard().expect("orchard present").to_bytes();
        (ufvk_str, orchard_bytes)
    }

    #[test]
    fn extract_orchard_fvk_returns_orchard_bytes_for_valid_mainnet_ufvk() {
        let (ufvk_str, expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_MAINNET,
            )
        };

        assert!(!result.is_null(), "expected non-null BoxedSlice");
        let actual = unsafe { (*result).as_slice() }.to_vec();
        free(result);

        assert_eq!(
            actual.len(),
            ORCHARD_FVK_LEN,
            "Orchard FVK must be {ORCHARD_FVK_LEN} bytes"
        );
        assert_eq!(actual, expected.to_vec(), "FVK bytes must match");
    }

    #[test]
    fn extract_orchard_fvk_returns_orchard_bytes_for_valid_testnet_ufvk() {
        let (ufvk_str, expected) = derive_test_ufvk(Network::TestNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_TESTNET,
            )
        };

        assert!(!result.is_null(), "expected non-null BoxedSlice");
        let actual = unsafe { (*result).as_slice() }.to_vec();
        free(result);

        assert_eq!(
            actual.len(),
            ORCHARD_FVK_LEN,
            "Orchard FVK must be {ORCHARD_FVK_LEN} bytes"
        );
        assert_eq!(actual, expected.to_vec(), "FVK bytes must match");
    }

    #[test]
    fn extract_orchard_fvk_rejects_mainnet_ufvk_with_testnet_network_id() {
        let (ufvk_str, _expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                ufvk_str.as_ptr(),
                ufvk_str.len(),
                NETWORK_ID_TESTNET,
            )
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_null_pointer_with_nonzero_len() {
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(std::ptr::null(), 5, NETWORK_ID_MAINNET)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_invalid_network_id() {
        let (ufvk_str, _expected) = derive_test_ufvk(Network::MainNetwork);
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(ufvk_str.as_ptr(), ufvk_str.len(), 99)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_non_ufvk_string() {
        let bogus = b"not a ufvk";
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(
                bogus.as_ptr(),
                bogus.len(),
                NETWORK_ID_MAINNET,
            )
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_orchard_fvk_rejects_empty_input() {
        let result = unsafe {
            zcashlc_voting_extract_orchard_fvk_from_ufvk(std::ptr::null(), 0, NETWORK_ID_MAINNET)
        };

        assert!(result.is_null());
    }

    #[test]
    fn extract_nc_root_returns_empty_ironwood_root_for_empty_tree_state() {
        let tree_state = TreeState {
            network: "main".to_string(),
            height: 1,
            hash: "00".repeat(32),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: String::new(),
            ironwood_tree: String::new(),
        };
        let tree_state_bytes = tree_state.encode_to_vec();

        let result = unsafe {
            zcashlc_voting_extract_nc_root(tree_state_bytes.as_ptr(), tree_state_bytes.len())
        };

        let root = boxed_slice_to_vec(result);
        assert_eq!(root.len(), 32);
        assert_eq!(root, Anchor::empty_tree().to_bytes().to_vec());
    }

    const TREE_DEPTH: u8 = orchard::NOTE_COMMITMENT_TREE_DEPTH as u8;

    /// A distinguishable Orchard-tree leaf built from a small field element.
    fn merkle_hash(tag: u64) -> MerkleHashOrchard {
        let repr = pallas::Base::from(tag).to_repr();
        MerkleHashOrchard::from_bytes(&repr).expect("small field element is canonical")
    }

    /// A commitment-tree frontier holding one leaf per tag.
    fn frontier_with(tags: &[u64]) -> Frontier<MerkleHashOrchard, TREE_DEPTH> {
        let mut frontier = Frontier::empty();
        for tag in tags {
            assert!(frontier.append(merkle_hash(*tag)));
        }
        frontier
    }

    /// The hex tree-state encoding `TreeState` carries for a frontier.
    fn tree_hex(frontier: &Frontier<MerkleHashOrchard, TREE_DEPTH>) -> String {
        let commitment_tree = CommitmentTree::from_frontier(frontier);
        let mut tree_bytes = Vec::new();
        write_commitment_tree(&commitment_tree, &mut tree_bytes)
            .expect("serialize note commitment tree state");
        hex::encode(tree_bytes)
    }

    /// Voting rounds are anchored to the **Ironwood** note commitment tree, so
    /// when the cached `TreeState` carries both pools the extracted `nc_root`
    /// must be the Ironwood root, not the Orchard one. This is the second half
    /// of the `8a40d1f9` fix that the `eea6cde8` merge lost; without it, nothing
    /// in the suite notices which field this FFI reads.
    #[test]
    fn extract_nc_root_returns_ironwood_root_when_both_trees_present() {
        let orchard_frontier = frontier_with(&[1, 2, 3]);
        let ironwood_frontier = frontier_with(&[7, 8]);
        assert_ne!(
            orchard_frontier.root().to_bytes(),
            ironwood_frontier.root().to_bytes(),
            "test needs distinguishable roots"
        );
        let tree_state = TreeState {
            network: "test".to_string(),
            height: 100,
            hash: String::new(),
            time: 0,
            sapling_tree: String::new(),
            orchard_tree: tree_hex(&orchard_frontier),
            ironwood_tree: tree_hex(&ironwood_frontier),
        };
        let tree_state_bytes = tree_state.encode_to_vec();

        let result = unsafe {
            zcashlc_voting_extract_nc_root(tree_state_bytes.as_ptr(), tree_state_bytes.len())
        };

        let root = boxed_slice_to_vec(result);
        assert_eq!(
            root,
            ironwood_frontier.root().to_bytes().to_vec(),
            "nc_root must come from the Ironwood tree"
        );
    }
}
