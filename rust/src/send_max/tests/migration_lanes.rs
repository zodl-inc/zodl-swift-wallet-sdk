//! Characterization tests for the two migration lanes that share upstream's send-max with the
//! user's Send Max, pinning that neither picked up Send Max's proposal-time size gate or its
//! classification.
//!
//! - The immediate migration lane, [`crate::propose_orchard_only_send_max`], is what
//!   `zcashlc_propose_send_max_transfer` runs with `orchard_only` true. The Swift SDK calls it
//!   with `MaxSpendable` only.
//! - The turnstile, [`crate::migration_turnstile::propose_orchard_to_ironwood`], runs with
//!   `Everything` behind its NU6.3 gate.
//!
//! Each lane must propose a sweep of more notes than fit in a block, as it always has, and
//! report its failures as it always has; the user's Send Max over the same wallet is still
//! refused as too large.

use zcash_protocol::consensus::NetworkUpgrade;

use super::*;
use crate::migration_turnstile::propose_orchard_to_ironwood;

/// The height NU6.3 activates at on [`ironwood_network`], after every note the fixtures here
/// receive, so the notes are ordinary pre-NU6.3 Orchard notes and the chain tip is past it.
const NU6_3_HEIGHT: u32 = 100_030;

/// The test harness's default network, with NU6 through NU6.3 active.
fn ironwood_network() -> LocalNetwork {
    let base = TestBuilder::<(), ()>::DEFAULT_NETWORK;
    LocalNetwork {
        nu6: base.nu5,
        nu6_1: base.nu5,
        nu6_2: base.nu5,
        nu6_3: Some(BlockHeight::from_u32(NU6_3_HEIGHT)),
        ..base
    }
}

/// An unscanned wallet on [`ironwood_network`].
fn unscanned_ironwood_wallet() -> TestWallet {
    TestBuilder::new()
        .with_network(ironwood_network())
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_account_from_sapling_activation(BlockHash([0; 32]))
        .build()
}

/// Mines empty blocks until the chain tip is past NU6.3's activation, then scans from `first`.
fn scan_past_nu6_3(st: &mut TestWallet, first: BlockHeight) {
    while u32::from(st.latest_cached_block().unwrap().height()) < NU6_3_HEIGHT {
        st.generate_empty_block();
    }
    scan_from(st, first);
}

/// An Ironwood-era wallet holding one spendable Orchard note of each value in `values`.
fn ironwood_wallet_with_orchard_notes(values: &[u64]) -> TestWallet {
    let mut st = unscanned_ironwood_wallet();
    let fvk = orchard_fvk(&st);
    let heights: Vec<BlockHeight> = values
        .iter()
        .map(|value| {
            st.generate_next_block(
                &fvk,
                AddressType::DefaultExternal,
                Zatoshis::const_from_u64(*value),
            )
            .0
        })
        .collect();
    let first = match heights.first() {
        Some(height) => *height,
        None => st.generate_empty_block().0,
    };
    scan_past_nu6_3(&mut st, first);
    st
}

/// An Ironwood-era wallet holding [`TOO_MANY_NOTES`] spendable Orchard notes, as
/// [`wallet_with_too_many_notes`] builds them.
fn ironwood_wallet_with_too_many_notes() -> TestWallet {
    let mut st = unscanned_ironwood_wallet();
    let output = FakeCompactOutput::new(
        orchard_fvk(&st),
        AddressType::DefaultExternal,
        Zatoshis::const_from_u64(MINIMUM_FEE),
    );
    let block = vec![output; NOTES_PER_BLOCK];
    let first = (0..TOO_MANY_NOTES / NOTES_PER_BLOCK)
        .map(|_| st.generate_next_block_multi(&block).0)
        .min()
        .unwrap();
    scan_past_nu6_3(&mut st, first);
    st
}

/// Receives one more Orchard note of [`NOTE_VALUE`] in a new block and scans it, so the wallet
/// holds a note that is not yet spendable under the default confirmations policy.
fn receive_unconfirmed_note(st: &mut TestWallet) {
    let fvk = orchard_fvk(st);
    let (height, _, _) = st.generate_next_block(
        &fvk,
        AddressType::DefaultExternal,
        Zatoshis::const_from_u64(NOTE_VALUE),
    );
    scan_from(st, height);
}

/// The immediate migration lane against the test wallet's account, as the Swift SDK calls it:
/// to the account's own address, no memo, `MaxSpendable`, the default confirmations policy.
fn propose_immediate(st: &mut TestWallet) -> Result<TestProposal, ClassifiedError> {
    let account = st.test_account().unwrap().id();
    let network = *st.network();
    let own = Address::from(
        st.test_account()
            .unwrap()
            .usk()
            .to_unified_full_viewing_key()
            .default_address(zcash_keys::keys::UnifiedAddressRequest::AllAvailableKeys)
            .unwrap()
            .0,
    )
    .to_zcash_address(st.network());
    crate::propose_orchard_only_send_max(
        st.wallet_mut(),
        &network,
        account,
        own,
        None,
        MaxSpendMode::MaxSpendable,
        ConfirmationsPolicy::default(),
        CONTEXT,
    )
}

/// The turnstile against the test wallet's account.
fn propose_turnstile(st: &mut TestWallet) -> anyhow::Result<TestProposal> {
    let account = st.test_account().unwrap().id();
    let network = *st.network();
    propose_orchard_to_ironwood(st.wallet_mut(), &network, account)
}

/// A lane's error is plain `anyhow` text, as on main: no [`ClassifiedError`] reaches the report.
fn assert_unclassified(e: &anyhow::Error) {
    assert!(e.downcast_ref::<ClassifiedError>().is_none(), "{e}");
}

// No size gate

/// The immediate lane proposes a sweep of more notes than fit in a block, as it did before
/// Send Max gained its size gate; the user's Send Max over the same wallet is refused.
#[test]
fn the_immediate_lane_is_not_size_gated_but_send_max_is() {
    let mut st = wallet_with_too_many_notes();

    let sweep = propose_immediate(&mut st).expect("the immediate lane proposes the sweep");

    assert_eq!(spent_note_count(&sweep), TOO_MANY_NOTES);
    assert!(
        sweep.check_transaction_size().is_err(),
        "the sweep is oversized"
    );

    let recipient = external_recipient(&st);
    let e = refusal(&mut st, user_send_max(recipient, None));
    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
}

/// The turnstile proposes a sweep of more notes than fit in a block, as it always has.
#[test]
fn the_turnstile_is_not_size_gated() {
    let mut st = ironwood_wallet_with_too_many_notes();

    let sweep = propose_turnstile(&mut st).expect("the turnstile proposes the sweep");

    assert_eq!(spent_note_count(&sweep), TOO_MANY_NOTES);
    assert!(
        sweep.check_transaction_size().is_err(),
        "the sweep is oversized"
    );
}

// Modes and gates

/// `MaxSpendable` leaves a note that is not yet spendable behind; `Everything` refuses.
#[test]
fn the_immediate_lane_sweeps_what_is_spendable_and_the_turnstile_everything() {
    let mut st = ironwood_wallet_with_orchard_notes(&[NOTE_VALUE]);
    receive_unconfirmed_note(&mut st);

    let sweep = propose_immediate(&mut st).expect("the immediate lane proposes the sweep");
    assert_eq!(spent_note_count(&sweep), 1);
    // Only the spendable note is swept, and all of it: the sweep pays its value less the fee.
    assert_eq!(
        u64::from(payment_total(&sweep)) + u64::from(total_fee(&sweep)),
        NOTE_VALUE
    );

    let e = propose_turnstile(&mut st).expect_err("the turnstile refuses unspendable funds");
    assert!(
        e.to_string()
            .starts_with("Error creating the migration proposal: "),
        "{e}"
    );
    assert_unclassified(&e);
}

/// The turnstile refuses before NU6.3 with its original message; the immediate lane has no
/// such gate.
#[test]
fn only_the_turnstile_is_gated_on_nu6_3() {
    let mut st = funded_wallet();
    assert_eq!(st.network().activation_height(NetworkUpgrade::Nu6_3), None);

    let e = propose_turnstile(&mut st).expect_err("NU6.3 is not active");
    assert_eq!(
        e.to_string(),
        "Ironwood (NU6.3) is not active yet; there is nothing to migrate to."
    );
    assert_unclassified(&e);

    propose_immediate(&mut st).expect("the immediate lane has no NU6.3 gate");
}

// Errors

/// The immediate lane reports through the shared classifier, under the FFI's call site.
#[test]
fn the_immediate_lane_reports_errors_as_before() {
    let mut empty = wallet_with_orchard_notes(&[]);
    let e = propose_immediate(&mut empty).expect_err("nothing to sweep");
    assert_eq!(e.kind(), ErrorKind::InsufficientFunds);
    assert_eq!(e.amounts().map(|s| s.available), Some(Zatoshis::ZERO));
    assert_redacted(&e, &[]);

    let mut unscanned = unscanned_wallet();
    let e = propose_immediate(&mut unscanned).expect_err("nothing scanned");
    assert_eq!(e.kind(), ErrorKind::ScanRequired);
}

/// The turnstile reports upstream's own text behind its original prefix, unclassified.
#[test]
fn the_turnstile_reports_errors_as_before() {
    let mut st = ironwood_wallet_with_orchard_notes(&[]);

    let e = propose_turnstile(&mut st).expect_err("nothing to migrate");

    assert!(
        e.to_string()
            .starts_with("Error creating the migration proposal: Insufficient balance"),
        "{e}"
    );
    assert_unclassified(&e);
}
