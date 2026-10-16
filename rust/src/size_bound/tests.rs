//! Tests for [`TransactionSizeBound`] itself: construction, combination, and its FFI form.
//!
//! Holding a real proposal to a bound is tested against the synthetic wallet in
//! `send_max::tests::size_bound`, where proposals can be made.

use zcash_protocol::ShieldedPool;

use super::*;

/// A bound with every cap set to a distinct value, so a mix-up between fields shows.
fn every_cap() -> TransactionSizeBound {
    TransactionSizeBound::CONSENSUS
        .with_max_bytes(250_000)
        .with_max_shielded_actions(75)
        .with_max_pool_actions(ShieldedPool::Sapling, 0)
        .with_max_pool_actions(ShieldedPool::Orchard, 32)
        .with_max_pool_actions(ShieldedPool::Ironwood, 31)
        .with_max_transparent_inputs(30)
        .with_max_transparent_outputs(10)
        .with_max_shielded_payment_outputs(4)
}

#[test]
fn the_default_bound_is_consensus_only() {
    assert_eq!(
        TransactionSizeBound::default(),
        TransactionSizeBound::CONSENSUS
    );
    assert!(TransactionSizeBound::CONSENSUS.is_consensus());
    assert!(
        !TransactionSizeBound::CONSENSUS
            .with_max_bytes(1)
            .is_consensus()
    );
}

#[test]
fn each_builder_sets_only_its_own_cap() {
    let bound = every_cap();
    assert_eq!(bound.max_bytes, Some(250_000));
    assert_eq!(bound.max_shielded_actions, Some(75));
    assert_eq!(bound.max_pool_actions(ShieldedPool::Sapling), Some(0));
    assert_eq!(bound.max_pool_actions(ShieldedPool::Orchard), Some(32));
    assert_eq!(bound.max_pool_actions(ShieldedPool::Ironwood), Some(31));
    assert_eq!(bound.max_transparent_inputs, Some(30));
    assert_eq!(bound.max_transparent_outputs, Some(10));
    assert_eq!(bound.max_shielded_payment_outputs, Some(4));
}

#[test]
fn intersect_takes_the_tighter_cap_in_every_dimension() {
    let phone = TransactionSizeBound::CONSENSUS
        .with_max_bytes(250_000)
        .with_max_shielded_actions(75)
        .with_max_pool_actions(ShieldedPool::Orchard, 75);
    let signer = TransactionSizeBound::CONSENSUS
        .with_max_shielded_actions(48)
        .with_max_pool_actions(ShieldedPool::Orchard, 100)
        .with_max_transparent_inputs(10);

    let both = phone.intersect(&signer);

    assert_eq!(both.max_bytes, Some(250_000));
    assert_eq!(both.max_shielded_actions, Some(48));
    assert_eq!(both.max_pool_actions(ShieldedPool::Orchard), Some(75));
    assert_eq!(both.max_transparent_inputs, Some(10));
    assert_eq!(both.max_transparent_outputs, None);
    assert_eq!(both, signer.intersect(&phone), "intersect is symmetric");
}

#[test]
fn intersecting_with_consensus_changes_nothing() {
    let bound = every_cap();
    assert_eq!(bound.intersect(&TransactionSizeBound::CONSENSUS), bound);
    assert_eq!(TransactionSizeBound::CONSENSUS.intersect(&bound), bound);
    assert_eq!(bound.intersect(&bound), bound);
}

#[test]
fn the_consensus_ffi_bound_converts_to_consensus() {
    let bound = TransactionSizeBound::try_from(FfiTransactionSizeBound::CONSENSUS).unwrap();
    assert!(bound.is_consensus());
}

#[test]
fn every_ffi_field_reaches_its_own_cap() {
    let ffi = FfiTransactionSizeBound {
        max_bytes: 250_000,
        max_shielded_actions: 75,
        max_sapling_actions: 0,
        max_orchard_actions: 32,
        max_ironwood_actions: 31,
        max_transparent_inputs: 30,
        max_transparent_outputs: 10,
        max_shielded_payment_outputs: 4,
    };
    assert_eq!(TransactionSizeBound::try_from(ffi).unwrap(), every_cap());
}

#[test]
fn a_negative_ffi_cap_other_than_none_is_rejected() {
    let ffi = FfiTransactionSizeBound {
        max_orchard_actions: -2,
        ..FfiTransactionSizeBound::CONSENSUS
    };
    let e = TransactionSizeBound::try_from(ffi).expect_err("-2 is not a cap");
    assert_eq!(
        e.to_string(),
        "max_orchard_actions must be -1 (no cap) or non-negative"
    );
}

#[test]
fn shielded_actions_sum_every_pool() {
    let mut counts = StepCounts::default();
    assert_eq!(counts.shielded_actions(), 0, "no bundle, no actions");

    counts.pool_actions.add(ShieldedPool::Sapling, 4);
    counts.pool_actions.add(ShieldedPool::Orchard, 5);
    counts.pool_actions.add(ShieldedPool::Ironwood, 6);

    assert_eq!(counts.pool_actions(ShieldedPool::Sapling), 4);
    assert_eq!(counts.pool_actions(ShieldedPool::Orchard), 5);
    assert_eq!(counts.pool_actions(ShieldedPool::Ironwood), 6);
    assert_eq!(counts.shielded_actions(), 15);
}

#[test]
fn a_step_violation_names_the_cap_and_the_step() {
    let mut counts = StepCounts::default();
    counts.pool_actions.add(ShieldedPool::Orchard, 43);
    counts.transparent_inputs = 2;

    let orchard = TransactionSizeBound::CONSENSUS.with_max_pool_actions(ShieldedPool::Orchard, 32);
    let violation = orchard.check_step(&counts).err().unwrap().at(1);
    assert_eq!(
        violation,
        SizeBoundViolation::PoolActions {
            step_index: 1,
            pool: ShieldedPool::Orchard,
            count: 43,
            limit: 32,
        }
    );
    assert_eq!(
        violation.to_string(),
        "step 1: 43 Orchard actions exceed the cap of 32"
    );

    // The total is checked before any single pool.
    let total = orchard.with_max_shielded_actions(16);
    assert!(matches!(
        total.check_step(&counts).err().unwrap().at(0),
        SizeBoundViolation::ShieldedActions {
            count: 43,
            limit: 16,
            ..
        }
    ));

    let transparent = TransactionSizeBound::CONSENSUS.with_max_transparent_inputs(1);
    assert!(matches!(
        transparent.check_step(&counts).err().unwrap().at(0),
        SizeBoundViolation::TransparentInputs {
            count: 2,
            limit: 1,
            ..
        }
    ));

    let roomy = every_cap()
        .with_max_pool_actions(ShieldedPool::Orchard, 43)
        .with_max_transparent_inputs(2);
    assert!(roomy.check_step(&counts).is_ok(), "a cap is inclusive");
}

#[test]
fn every_violation_renders_without_wallet_data_beyond_counts() {
    let rendered = [
        SizeBoundViolation::Bytes {
            estimated: 300_000,
            limit: 250_000,
        },
        SizeBoundViolation::TransparentOutputs {
            step_index: 0,
            count: 11,
            limit: 10,
        },
        SizeBoundViolation::ShieldedPaymentOutputs {
            step_index: 0,
            count: 5,
            limit: 4,
        },
    ]
    .map(|v| v.to_string());
    assert_eq!(
        rendered,
        [
            "estimated size 300000 B exceeds the 250000 B cap",
            "step 0: 11 transparent outputs exceed the cap of 10",
            "step 0: 5 shielded payment outputs exceed the cap of 4",
        ]
    );
}
