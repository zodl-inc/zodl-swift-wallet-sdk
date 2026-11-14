//! The user's Send Max held to a [`TransactionSizeBound`]: each cap is honoured, caps combine,
//! and a consensus bound changes nothing. Max stays all-or-nothing: a send-max that exceeds its
//! bound is refused as too large, never cut down to what fits.

use zcash_protocol::{ShieldedPool, consensus::BranchId};

use super::*;
use crate::size_bound::{StepCounts, step_serialized_sizes};

/// The notes [`five_note_wallet`] holds.
const NOTES: usize = 5;

/// A wallet holding [`NOTES`] spendable Orchard notes.
fn five_note_wallet() -> TestWallet {
    wallet_with_note_count(NOTES)
}

/// The user's Send Max to an Orchard recipient outside the wallet, held to `bound`.
fn bounded_send_max(st: &TestWallet, bound: TransactionSizeBound) -> SendMaxRequest {
    SendMaxRequest {
        size_bound: bound,
        ..user_send_max(external_recipient(st), None)
    }
}

/// [`propose`] of the user's Send Max held to `bound`.
fn propose_bounded(
    st: &mut TestWallet,
    bound: TransactionSizeBound,
) -> Result<TestProposal, ClassifiedError> {
    let request = bounded_send_max(st, bound);
    propose_max(st, request)
}

/// The classification of a bounded Send Max the wallet refuses.
fn refuse_bounded(st: &mut TestWallet, bound: TransactionSizeBound) -> ClassifiedError {
    propose_bounded(st, bound).expect_err("the bounded send-max is refused")
}

/// The counts of a send-max's only step, under the consensus rules it is built under.
fn counts(st: &TestWallet, proposal: &TestProposal) -> StepCounts {
    let steps = proposal.steps();
    assert_eq!(
        steps.len(),
        1,
        "a send-max to a shielded recipient is one step"
    );
    let branch = BranchId::for_height(
        st.network(),
        BlockHeight::from(proposal.min_target_height()),
    );
    StepCounts::of(steps, steps.first(), branch)
}

/// The bound a proposal over [`five_note_wallet`] just fits, in shielded actions.
fn actions_of_unbounded_max(st: &mut TestWallet) -> usize {
    let recipient = external_recipient(st);
    let max = propose_max(st, user_send_max(recipient, None)).expect("proposes");
    counts(st, &max).shielded_actions()
}

#[test]
fn a_consensus_bound_proposes_what_an_unbounded_send_max_does() {
    let mut st = five_note_wallet();

    let bounded = propose_bounded(&mut st, TransactionSizeBound::CONSENSUS)
        .expect("a consensus bound admits the send-max");

    assert_eq!(spent_note_count(&bounded), NOTES);
    assert_eq!(
        u64::from(payment_total(&bounded)) + u64::from(total_fee(&bounded)),
        NOTES as u64 * MINIMUM_FEE
    );
}

/// The action count is the builder's: before NU6.3 an Orchard action carries a spend and an
/// output, so five spends and one payment take five actions.
#[test]
fn a_send_max_is_counted_as_the_builder_builds_it() {
    let mut st = five_note_wallet();

    let actions = actions_of_unbounded_max(&mut st);

    assert_eq!(actions, NOTES);
}

#[test]
fn the_shielded_action_cap_is_inclusive() {
    let mut st = five_note_wallet();
    let actions = actions_of_unbounded_max(&mut st);

    let at = TransactionSizeBound::CONSENSUS.with_max_shielded_actions(actions);
    propose_bounded(&mut st, at).expect("a bound it meets admits it");

    let below = TransactionSizeBound::CONSENSUS.with_max_shielded_actions(actions - 1);
    let e = refuse_bounded(&mut st, below);
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
    assert_eq!(e.amounts(), None);
    assert_eq!(
        e.message(),
        "the transaction would exceed the size bound it was proposed under"
    );
    assert_redacted(&e, &[]);
}

#[test]
fn a_pool_cap_applies_to_its_own_pool_only() {
    let mut st = five_note_wallet();
    let actions = actions_of_unbounded_max(&mut st);

    // No Sapling or Ironwood bundle, so forbidding those pools admits the send-max.
    let other_pools = TransactionSizeBound::CONSENSUS
        .with_max_pool_actions(ShieldedPool::Sapling, 0)
        .with_max_pool_actions(ShieldedPool::Ironwood, 0);
    propose_bounded(&mut st, other_pools).expect("other pools are unused");

    let orchard =
        TransactionSizeBound::CONSENSUS.with_max_pool_actions(ShieldedPool::Orchard, actions - 1);
    let e = refuse_bounded(&mut st, orchard);
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);

    let forbidden = TransactionSizeBound::CONSENSUS.with_max_pool_actions(ShieldedPool::Orchard, 0);
    let e = refuse_bounded(&mut st, forbidden);
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

#[test]
fn the_byte_cap_holds_the_estimated_size() {
    let mut st = five_note_wallet();
    let recipient = external_recipient(&st);
    let size = propose_max(&mut st, user_send_max(recipient, None))
        .expect("proposes")
        .estimated_serialized_size();

    let at = TransactionSizeBound::CONSENSUS.with_max_bytes(size);
    propose_bounded(&mut st, at).expect("a bound it meets admits it");

    let below = TransactionSizeBound::CONSENSUS.with_max_bytes(size - 1);
    let e = refuse_bounded(&mut st, below);
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

/// A send-max to a TEX address takes two transactions; the byte cap holds each of them, as
/// consensus does, so the proposal passes at its largest transaction's size.
#[test]
fn the_byte_cap_holds_each_transaction_of_a_multi_step_proposal() {
    let mut st = five_note_wallet();
    let recipient = tex_recipient(&st);
    let tex = propose_max(&mut st, user_send_max(recipient.clone(), None)).expect("proposes");

    let sizes = step_serialized_sizes(&tex);
    assert_eq!(
        sizes.len(),
        2,
        "a TEX payment goes through an ephemeral address"
    );
    assert_eq!(sizes.iter().sum::<usize>(), tex.estimated_serialized_size());
    let largest = *sizes.iter().max().unwrap();
    assert!(largest < tex.estimated_serialized_size());

    let request = |bytes| SendMaxRequest {
        size_bound: TransactionSizeBound::CONSENSUS.with_max_bytes(bytes),
        ..user_send_max(recipient.clone(), None)
    };
    propose_max(&mut st, request(largest))
        .expect("a bound its largest transaction meets admits it");
    let e = refusal(&mut st, request(largest - 1));
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

/// A wallet holding one spendable Sapling note of [`NOTE_VALUE`].
fn sapling_funded_wallet() -> TestWallet {
    let mut st = unscanned_wallet();
    let fvk = st
        .test_account()
        .unwrap()
        .usk()
        .sapling()
        .to_diversifiable_full_viewing_key();
    let height = st
        .generate_next_block(
            &fvk,
            AddressType::DefaultExternal,
            Zatoshis::const_from_u64(NOTE_VALUE),
        )
        .0;
    mine_empty_blocks(&mut st, CONFIRMATIONS);
    scan_from(&mut st, height);
    st
}

/// A Sapling address that belongs to nobody in the test wallet.
fn sapling_recipient(st: &TestWallet) -> ZcashAddress {
    let (_, address) = sapling::zip32::ExtendedSpendingKey::master(&[9; 32])
        .expect("a valid seed")
        .default_address();
    Address::Sapling(Box::new(address)).to_zcash_address(st.network())
}

/// The canonical Send Max shapes are counted as the builder builds them: three Orchard notes to
/// an Orchard recipient take three actions, and one Sapling note to a Sapling recipient takes a
/// spend and two padded outputs. Upstream's estimator charges two more per bundle
/// (`spends + outputs + 2`), so once this check collapses to upstream's a cap of `n` actions admits
/// about `n - 2` notes.
#[test]
fn canonical_shapes_are_counted_as_built() {
    let mut st = wallet_with_orchard_notes(&[NOTE_VALUE; 3]);
    let recipient = external_recipient(&st);
    let max = propose_max(&mut st, user_send_max(recipient, None)).expect("proposes");
    let orchard = counts(&st, &max);
    assert_eq!(
        [
            orchard.pool_actions(ShieldedPool::Sapling),
            orchard.pool_actions(ShieldedPool::Orchard),
            orchard.pool_actions(ShieldedPool::Ironwood),
        ],
        [0, 3, 0]
    );

    let mut st = sapling_funded_wallet();
    let recipient = sapling_recipient(&st);
    let max = propose_max(&mut st, user_send_max(recipient, None)).expect("proposes");
    let sapling = counts(&st, &max);
    assert_eq!(
        [
            sapling.pool_actions(ShieldedPool::Sapling),
            sapling.pool_actions(ShieldedPool::Orchard),
            sapling.pool_actions(ShieldedPool::Ironwood),
        ],
        [3, 0, 0]
    );
}

#[test]
fn the_payment_output_cap_counts_the_recipient_not_the_padding() {
    let mut st = five_note_wallet();

    let one = TransactionSizeBound::CONSENSUS.with_max_shielded_payment_outputs(1);
    propose_bounded(&mut st, one).expect("one payment");

    let none = TransactionSizeBound::CONSENSUS.with_max_shielded_payment_outputs(0);
    let e = refuse_bounded(&mut st, none);
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

#[test]
fn transparent_caps_count_transparent_inputs_and_outputs() {
    let mut st = five_note_wallet();

    // A send-max never spends transparent funds.
    let no_inputs = TransactionSizeBound::CONSENSUS.with_max_transparent_inputs(0);
    propose_bounded(&mut st, no_inputs).expect("no transparent inputs");

    // Paying a transparent recipient creates a transparent output.
    let no_outputs = TransactionSizeBound::CONSENSUS.with_max_transparent_outputs(0);
    let recipient = transparent_recipient(&st);
    let e = refusal(
        &mut st,
        SendMaxRequest {
            size_bound: no_outputs,
            ..user_send_max(recipient.clone(), None)
        },
    );
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);

    let one_output = TransactionSizeBound::CONSENSUS.with_max_transparent_outputs(1);
    propose_max(
        &mut st,
        SendMaxRequest {
            size_bound: one_output,
            ..user_send_max(recipient, None)
        },
    )
    .expect("one transparent output");
}

/// A relay bound, a proving-memory bound and a signer's bound combine into the tightest.
#[test]
fn an_intersected_bound_refuses_what_any_part_refuses() {
    let mut st = five_note_wallet();
    let actions = actions_of_unbounded_max(&mut st);

    let relay = TransactionSizeBound::CONSENSUS.with_max_bytes(250_000);
    let memory = TransactionSizeBound::CONSENSUS.with_max_shielded_actions(75);
    let signer =
        TransactionSizeBound::CONSENSUS.with_max_pool_actions(ShieldedPool::Orchard, actions - 1);

    propose_bounded(&mut st, relay.intersect(&memory))
        .expect("relay and memory both admit five notes");
    let e = refuse_bounded(&mut st, relay.intersect(&memory).intersect(&signer));
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

/// A failure the wallet reports before the bound is reached keeps its own classification.
#[test]
fn a_bound_does_not_mask_insufficient_funds() {
    let mut st = wallet_with_orchard_notes(&[]);

    let e = refuse_bounded(
        &mut st,
        TransactionSizeBound::CONSENSUS.with_max_shielded_actions(0),
    );

    assert_eq!(e.kind(), ErrorKind::InsufficientFunds);
}
