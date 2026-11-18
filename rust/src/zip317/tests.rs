//! Tests for the ZIP 317 constants this library exposes.

use super::*;

use zcash_client_backend::fees::StandardFeeRule;
use zcash_primitives::transaction::fees::{FeeRule, transparent::InputSize, zip317};
use zcash_protocol::consensus::{BlockHeight, MAIN_NETWORK};

/// The fee [`StandardFeeRule::Zip317`], the rule every proposal in this library is built with,
/// requires for a transaction of `orchard_actions` Orchard actions and nothing else.
fn standard_fee_for_orchard_actions(orchard_actions: usize) -> u64 {
    StandardFeeRule::Zip317
        .fee_required(
            &MAIN_NETWORK,
            BlockHeight::from_u32(3_000_000),
            std::iter::empty::<InputSize>(),
            std::iter::empty::<usize>(),
            0,
            0,
            orchard_actions,
            0,
        )
        .expect("the fee is computable")
        .into_u64()
}

/// The constant crosses the FFI as the 5000 zatoshis ZIP 317 specifies.
#[test]
fn the_marginal_fee_is_5000_zatoshis() {
    assert_eq!(zcashlc_zip317_marginal_fee(), 5_000);
}

/// The value exposed to Swift is what the proposals' fee rule actually charges per logical
/// action beyond the grace actions, not merely a constant that happens to share its name.
#[test]
fn the_marginal_fee_is_what_the_standard_fee_rule_charges_per_action() {
    for actions in 2..6 {
        assert_eq!(
            standard_fee_for_orchard_actions(actions + 1)
                - standard_fee_for_orchard_actions(actions),
            zcashlc_zip317_marginal_fee(),
            "between {actions} and {} actions",
            actions + 1
        );
    }
}

/// The grace actions are charged as if they were used: a transaction of up to two logical actions
/// costs two marginal fees (the ZIP 317 minimum), and the fee only grows with the third.
#[test]
fn the_grace_actions_cost_two_marginal_fees() {
    let marginal = zcashlc_zip317_marginal_fee();
    assert_eq!(zip317::GRACE_ACTIONS as u64 * marginal, 2 * marginal);
    assert_eq!(zip317::MINIMUM_FEE.into_u64(), 2 * marginal);
    for actions in 0..=2 {
        assert_eq!(
            standard_fee_for_orchard_actions(actions),
            2 * marginal,
            "{actions} actions"
        );
    }
    assert_eq!(standard_fee_for_orchard_actions(3), 3 * marginal);
}
