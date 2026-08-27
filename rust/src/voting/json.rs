use serde::{Deserialize, Serialize};
use zcash_voting as voting;

use anyhow::{anyhow, Result};

// =============================================================================
// Serde-compatible types for JSON serialization across the FFI boundary
// =============================================================================

/// Public, root-validated vote-tree leaf returned to Swift for forensic
/// candidate discovery.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JsonVerifiedVoteTreeLeaf {
    pub position: u32,
    pub commitment: Vec<u8>,
}

impl From<voting::VerifiedVoteTreeLeaf> for JsonVerifiedVoteTreeLeaf {
    fn from(leaf: voting::VerifiedVoteTreeLeaf) -> Self {
        Self {
            position: leaf.position,
            commitment: leaf.commitment.to_vec(),
        }
    }
}

/// Complete vote-tree snapshot after `zcash_voting` has recomputed the
/// advertised root.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JsonVerifiedVoteTreeSnapshot {
    pub anchor_height: u32,
    pub root: Vec<u8>,
    pub leaves: Vec<JsonVerifiedVoteTreeLeaf>,
}

impl From<voting::VerifiedVoteTreeSnapshot> for JsonVerifiedVoteTreeSnapshot {
    fn from(snapshot: voting::VerifiedVoteTreeSnapshot) -> Self {
        Self {
            anchor_height: snapshot.anchor_height,
            root: snapshot.root.to_vec(),
            leaves: snapshot.leaves.into_iter().map(Into::into).collect(),
        }
    }
}

/// One secret-bearing forensic bundle supplied by the application.
///
/// This type intentionally omits `Debug`: `van_comm_rand` is the historical
/// secret this recovery path exists to restore.
#[derive(Deserialize)]
pub struct JsonForensicDelegationBundle {
    pub bundle_index: u32,
    pub total_note_value: u64,
    pub address_index: u32,
    pub van_comm_rand: Vec<u8>,
    pub van_commitment: Vec<u8>,
    pub van_leaf_position: u32,
    pub delegation_tx_hash: Option<String>,
}

impl JsonForensicDelegationBundle {
    /// Convert the wire shape explicitly because this is a partial,
    /// security-sensitive boundary rather than a lossless domain conversion.
    pub fn into_validated_core(self) -> Result<voting::ForensicDelegationBundle> {
        Ok(voting::ForensicDelegationBundle {
            bundle_index: self.bundle_index,
            total_note_value: self.total_note_value,
            address_index: self.address_index,
            van_comm_rand: exact_32(self.van_comm_rand, "van_comm_rand")?,
            van_commitment: exact_32(self.van_commitment, "van_commitment")?,
            van_leaf_position: self.van_leaf_position,
            delegation_tx_hash: self.delegation_tx_hash,
        })
    }
}

/// Secret-bearing request accepted by the narrow forensic recovery FFI.
///
/// This type intentionally omits `Debug` so callers cannot accidentally log
/// the voting hotkey or recovered commitment randomness.
#[derive(Deserialize)]
pub struct JsonForensicDelegationRecoveryRequest {
    pub expected_round_params: voting::VotingRoundParams,
    pub node_url: String,
    pub hotkey_stored_secret: Vec<u8>,
    pub bundles: Vec<JsonForensicDelegationBundle>,
}

/// Public result of an atomic forensic delegation repair.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JsonForensicDelegationRecovery {
    pub anchor_height: u32,
    pub tree_root: Vec<u8>,
    pub bundle_count: u32,
    pub already_recovered: bool,
}

impl From<voting::ForensicDelegationRecovery> for JsonForensicDelegationRecovery {
    fn from(recovery: voting::ForensicDelegationRecovery) -> Self {
        Self {
            anchor_height: recovery.anchor_height,
            tree_root: recovery.tree_root.to_vec(),
            bundle_count: recovery.bundle_count,
            already_recovered: recovery.already_recovered,
        }
    }
}

fn exact_32(bytes: Vec<u8>, field: &str) -> Result<[u8; 32]> {
    let len = bytes.len();
    bytes
        .try_into()
        .map_err(|_| anyhow!("{field} must be exactly 32 bytes, got {len}"))
}

/// JSON-serializable NoteInfo.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonNoteInfo {
    pub commitment: Vec<u8>,
    pub nullifier: Vec<u8>,
    pub value: u64,
    pub position: u64,
    pub diversifier: Vec<u8>,
    pub rho: Vec<u8>,
    pub rseed: Vec<u8>,
    pub scope: u32,
    pub ufvk_str: String,
}

impl From<JsonNoteInfo> for voting::NoteInfo {
    fn from(n: JsonNoteInfo) -> Self {
        Self {
            commitment: n.commitment,
            nullifier: n.nullifier,
            value: n.value,
            position: n.position,
            diversifier: n.diversifier,
            rho: n.rho,
            rseed: n.rseed,
            scope: n.scope,
            ufvk_str: n.ufvk_str,
        }
    }
}

impl From<voting::NoteInfo> for JsonNoteInfo {
    fn from(n: voting::NoteInfo) -> Self {
        Self {
            commitment: n.commitment,
            nullifier: n.nullifier,
            value: n.value,
            position: n.position,
            diversifier: n.diversifier,
            rho: n.rho,
            rseed: n.rseed,
            scope: n.scope,
            ufvk_str: n.ufvk_str,
        }
    }
}

/// JSON-serializable VotingPczt.
#[allow(dead_code)]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonVotingPczt {
    pub pczt_bytes: Vec<u8>,
    pub rk: Vec<u8>,
    pub alpha: Vec<u8>,
    pub nf_signed: Vec<u8>,
    pub cmx_new: Vec<u8>,
    pub gov_nullifiers: Vec<Vec<u8>>,
    pub van: Vec<u8>,
    pub van_comm_rand: Vec<u8>,
    pub dummy_nullifiers: Vec<Vec<u8>>,
    pub rho_signed: Vec<u8>,
    pub padded_cmx: Vec<Vec<u8>>,
    pub rseed_signed: Vec<u8>,
    pub rseed_output: Vec<u8>,
    pub action_bytes: Vec<u8>,
    pub action_index: u32,
    /// padded_note_secrets: list of [rho, rseed] pairs
    pub padded_note_secrets: Vec<Vec<Vec<u8>>>,
    pub pczt_sighash: Vec<u8>,
}

impl From<voting::GovernancePczt> for JsonVotingPczt {
    fn from(g: voting::GovernancePczt) -> Self {
        Self {
            pczt_bytes: g.pczt_bytes,
            rk: g.rk,
            alpha: g.alpha,
            nf_signed: g.nf_signed,
            cmx_new: g.cmx_new,
            gov_nullifiers: g.gov_nullifiers,
            van: g.van,
            van_comm_rand: g.van_comm_rand,
            dummy_nullifiers: g.dummy_nullifiers,
            rho_signed: g.rho_signed,
            padded_cmx: g.padded_cmx,
            rseed_signed: g.rseed_signed,
            rseed_output: g.rseed_output,
            action_bytes: g.action_bytes,
            action_index: g.action_index as u32,
            padded_note_secrets: g
                .padded_note_secrets
                .into_iter()
                .map(|(rho, rseed)| vec![rho, rseed])
                .collect(),
            pczt_sighash: g.pczt_sighash,
        }
    }
}

/// JSON-serializable WitnessData.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonWitnessData {
    pub note_commitment: Vec<u8>,
    pub position: u64,
    pub root: Vec<u8>,
    pub auth_path: Vec<Vec<u8>>,
}

impl From<voting::WitnessData> for JsonWitnessData {
    fn from(w: voting::WitnessData) -> Self {
        Self {
            note_commitment: w.note_commitment,
            position: w.position,
            root: w.root,
            auth_path: w.auth_path,
        }
    }
}

impl From<JsonWitnessData> for voting::WitnessData {
    fn from(w: JsonWitnessData) -> Self {
        Self {
            note_commitment: w.note_commitment,
            position: w.position,
            root: w.root,
            auth_path: w.auth_path,
        }
    }
}

/// JSON-serializable DelegationProofResult.
#[allow(dead_code)]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonDelegationProofResult {
    pub proof: Vec<u8>,
    pub public_inputs: Vec<Vec<u8>>,
    pub nf_signed: Vec<u8>,
    pub cmx_new: Vec<u8>,
    pub gov_nullifiers: Vec<Vec<u8>>,
    pub van_comm: Vec<u8>,
    pub rk: Vec<u8>,
}

impl From<voting::DelegationProofResult> for JsonDelegationProofResult {
    fn from(r: voting::DelegationProofResult) -> Self {
        Self {
            proof: r.proof,
            public_inputs: r.public_inputs,
            nf_signed: r.nf_signed,
            cmx_new: r.cmx_new,
            gov_nullifiers: r.gov_nullifiers,
            van_comm: r.van_comm,
            rk: r.rk,
        }
    }
}

/// JSON-serializable DelegationPirPrecomputeResult.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonDelegationPirPrecomputeResult {
    pub cached_count: u32,
    pub fetched_count: u32,
}

impl From<voting::DelegationPirPrecomputeResult> for JsonDelegationPirPrecomputeResult {
    fn from(r: voting::DelegationPirPrecomputeResult) -> Self {
        Self {
            cached_count: r.cached_count,
            fetched_count: r.fetched_count,
        }
    }
}

/// JSON-serializable `voting::vote::VoteCommit`.
///
/// The helper-share payloads are deliberately absent: they are wire data owned
/// by `zcash_voting`, produced by `zcashlc_voting_recover_wire_json` once the
/// confirmed vote-commitment-tree position is known. Commit-time payloads are
/// provisional and must never be sent to helper servers.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonVoteCommit {
    pub proposal_id: u32,
    pub van_nullifier: Vec<u8>,
    pub vote_authority_note_new: Vec<u8>,
    pub vote_commitment: Vec<u8>,
    pub proof: Vec<u8>,
    pub anchor_height: u32,
    pub r_vpk: Vec<u8>,
    pub vote_auth_sig: Vec<u8>,
    pub enc_shares: Vec<voting::WireEncryptedShare>,
}

impl From<voting::vote::VoteCommit> for JsonVoteCommit {
    fn from(c: voting::vote::VoteCommit) -> Self {
        Self {
            proposal_id: c.proposal_id,
            van_nullifier: c.van_nullifier.to_vec(),
            vote_authority_note_new: c.vote_authority_note_new.to_vec(),
            vote_commitment: c.vote_commitment.to_vec(),
            proof: c.proof,
            anchor_height: c.anchor_height,
            r_vpk: c.r_vpk.to_vec(),
            vote_auth_sig: c.vote_auth_sig.to_vec(),
            enc_shares: c.encrypted_shares,
        }
    }
}

/// JSON-serializable DelegationInputs.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonDelegationInputs {
    pub fvk_bytes: Vec<u8>,
    pub g_d_new_x: Vec<u8>,
    pub pk_d_new_x: Vec<u8>,
    pub hotkey_raw_address: Vec<u8>,
    pub seed_fingerprint: Vec<u8>,
}
