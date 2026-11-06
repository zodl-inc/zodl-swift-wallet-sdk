//! The SDK's voting dependency must accept NU7 snapshots without changing TX1 signing.

use orchard::keys::Scope;
use orchard::note::{Note, NoteVersion, RandomSeed, Rho};
use orchard::value::NoteValue;
use zcash_protocol::consensus::BranchId;
use zcash_voting::delegate::{
    DelegationKeys, LightwalletdBranchIdProvider, PreparedDelegationBundle,
};
use zcash_voting::storage::VotingDb;
use zcash_voting::{
    GovernancePczt, Network, NoopProgressReporter, NoteInfo, VotingError, VotingHotkey,
};
use zip32::AccountId;

struct SnapshotRound {
    db: VotingDb,
    round_id: String,
    notes: Vec<NoteInfo>,
    keys: DelegationKeys,
}

impl SnapshotRound {
    fn at_height(snapshot_height: u64) -> Self {
        let usk =
            super::helpers::usk_from_seed(crate::NETWORK_ID_MAINNET, &[0x42; 32], AccountId::ZERO)
                .expect("sender spending key");
        let ufvk = usk.to_unified_full_viewing_key();
        let fvk = ufvk.orchard().expect("sender Orchard viewing key");
        let recipient = fvk.address_at(0u32, Scope::External);
        let mut rho_bytes = [0u8; 32];
        rho_bytes[0] = 1;
        let rho = Rho::from_bytes(&rho_bytes).into_option().expect("rho");
        let note = (0u8..=255)
            .find_map(|seed| {
                let rseed = RandomSeed::from_bytes([seed; 32], &rho).into_option()?;
                Note::from_parts(
                    recipient,
                    NoteValue::from_raw(13_000_000),
                    rho,
                    rseed,
                    NoteVersion::V3,
                )
                .into_option()
            })
            .expect("valid Ironwood note");
        let notes = vec![
            NoteInfo::from_orchard_note(&note, 7, Scope::External, &ufvk, &Network::Mainnet)
                .expect("eligible note metadata"),
        ];
        let hotkey =
            VotingHotkey::from_stored_secret(&[0x43; 64], Network::Mainnet).expect("voting hotkey");
        let keys = DelegationKeys::with_voting_hotkey(
            fvk.to_bytes().to_vec(),
            &hotkey,
            [0x42; 32],
            0,
            "snapshot compatibility".to_string(),
        )
        .expect("delegation keys");
        let db = VotingDb::open(":memory:").expect("in-memory voting database");
        db.set_wallet_id("snapshot-compatibility-wallet");
        let params = super::test_support::synthetic_round_params(1, snapshot_height);
        db.init_round(Network::Mainnet, &params, None)
            .expect("persist round snapshot");
        db.ensure_bundles(&params.vote_round_id, &notes)
            .expect("persist note bundle");
        Self {
            db,
            round_id: params.vote_round_id,
            notes,
            keys,
        }
    }

    fn build_pczt(&self, branch: BranchId) -> Result<GovernancePczt, VotingError> {
        self.db.build_governance_pczt(
            &self.round_id,
            0,
            &self.notes,
            &self.keys,
            u32::from(branch),
        )
    }
}

fn assert_fixed_tx1_profile(result: &GovernancePczt) {
    let pczt = pczt::Pczt::parse(&result.pczt_bytes).expect("valid serialized PCZT");
    assert_eq!(*pczt.global().tx_version(), 6);
    assert_eq!(
        *pczt.global().consensus_branch_id(),
        u32::from(BranchId::Nu6_3)
    );
    assert_eq!(pczt.ironwood().actions().len(), 1);
    zcash_voting::tx1::validate_tx1_effects(&result.tx1_effects).expect("valid TX1 effects");
}

#[test]
fn nu7_snapshot_uses_fixed_tx1_profile() {
    let round = SnapshotRound::at_height(3_543_405);
    let result = round.build_pczt(BranchId::Nu7).expect("NU7 snapshot PCZT");
    assert_fixed_tx1_profile(&result);
}

#[test]
fn nu6_3_snapshot_keeps_tx1_profile() {
    let round = SnapshotRound::at_height(3_500_000);
    let result = round
        .build_pczt(BranchId::Nu6_3)
        .expect("NU6.3 snapshot PCZT");
    assert_fixed_tx1_profile(&result);
}

#[test]
fn snapshot_branch_mismatch_is_rejected() {
    let round = SnapshotRound::at_height(3_543_405);
    assert!(matches!(
        round.build_pczt(BranchId::Nu6_3),
        Err(VotingError::InvalidInput { .. })
    ));
}

#[test]
fn existing_round_reuses_pczt() {
    let round = SnapshotRound::at_height(3_543_405);
    let first = round.build_pczt(BranchId::Nu7).expect("initial NU7 PCZT");
    // The low-level builder is write-once. Retried signing work must load its
    // exact persisted transaction through the prepared bundle's public API.
    assert!(matches!(
        round.build_pczt(BranchId::Nu7),
        Err(VotingError::SetupAlreadyPersisted { .. })
    ));
    let layout = round
        .db
        .ensure_bundles(&round.round_id, &round.notes)
        .expect("existing bundle layout");
    let prepared = PreparedDelegationBundle {
        round_id: round.round_id.clone(),
        round_params: super::test_support::synthetic_round_params(1, 3_543_405),
        bundle_index: 0,
        layout,
        bundle_note_infos: round.notes.clone(),
        delegation_keys: round.keys.clone(),
        branch_id_provider: LightwalletdBranchIdProvider::for_height(Network::Mainnet, 3_543_405)
            .expect("NU7 snapshot branch"),
        // Signing a stored PCZT needs no anchor fetch or wallet access.
        anchor_tree_state_bytes: Vec::new(),
        network: Network::Mainnet,
        round_name: "snapshot compatibility".to_string(),
    };
    for _ in 0..2 {
        let retry = prepared
            .keystone_request(&round.db, &NoopProgressReporter)
            .expect("reload persisted signing transaction");
        assert_eq!(retry.pczt_bytes, first.pczt_bytes);
        let effects = zcash_voting::storage::queries::load_tx1_effects(
            &round.db.conn(),
            &round.round_id,
            &round.db.wallet_id(),
            0,
        )
        .expect("persisted TX1 effects");
        assert_eq!(effects, first.tx1_effects);
    }
}
