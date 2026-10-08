//! Tests for [`super::propose`] and its failure classification.
//!
//! The wallet tests run against `zcash_client_backend`'s synthetic test wallet, so every
//! category a real wallet can reach is produced by a real proposal: insufficient funds, a memo
//! for a transparent or TEX recipient, a wallet that has not scanned, and a send-max of more
//! notes than fit in a block. A recipient with no payable receiver cannot be produced that way
//! (with the `orchard` feature enabled every unified address has one), so that category, and the
//! alternative forms the others can take, are covered with constructed errors.

use std::collections::BTreeSet;
use std::convert::Infallible;

use transparent::address::TransparentAddress;
use zcash_client_backend::{
    data_api::{
        Account as _,
        testing::{AddressType, FakeCompactOutput, TestBuilder, TestState},
    },
    fees::ChangeError,
};
use zcash_client_sqlite::{
    ReceivedNoteId,
    testing::{
        BlockCache,
        db::{TestDb, TestDbFactory},
    },
};
use zcash_keys::address::{Address, UnifiedAddress};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{consensus::BlockHeight, local_consensus::LocalNetwork, value::Zatoshis};

use super::*;
use crate::error_report::Shortfall;

/// A synthetic wallet with one account, as `zcash_client_backend`'s test harness builds it.
type TestWallet = TestState<BlockCache, TestDb, LocalNetwork>;

/// A send-max proposal over a [`TestWallet`].
type TestProposal = SendMaxProposal<ReceivedNoteId>;

/// The `context` the tests classify under.
const CONTEXT: &str = "propose_send_max_transfer";

/// The value of each note [`funded_wallet`] receives.
const NOTE_VALUE: u64 = 100_000;

/// The ZIP 317 fee of a single-transaction send-max whose inputs and output all fit in the
/// two-action minimum of one Orchard bundle.
const MINIMUM_FEE: u64 = 10_000;

/// Received funds need ten confirmations under the default confirmations policy.
const CONFIRMATIONS: usize = 10;

/// A wallet on the default test network that has scanned nothing.
fn unscanned_wallet() -> TestWallet {
    TestBuilder::new()
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_account_from_sapling_activation(BlockHash([0; 32]))
        .build()
}

fn orchard_fvk(st: &TestWallet) -> orchard::keys::FullViewingKey {
    orchard::keys::FullViewingKey::from(st.test_account().unwrap().usk().orchard())
}

/// Mines `count` empty blocks.
fn mine_empty_blocks(st: &mut TestWallet, count: usize) {
    for _ in 0..count {
        st.generate_empty_block();
    }
}

/// Scans every cached block from `from` to the tip.
fn scan_from(st: &mut TestWallet, from: BlockHeight) {
    let tip = st.latest_cached_block().unwrap().height();
    st.scan_cached_blocks(
        from,
        usize::try_from(u32::from(tip) - u32::from(from) + 1).unwrap(),
    );
}

/// A wallet holding one spendable Orchard note of each value in `values`. With no values, the
/// wallet has scanned one empty block, so it knows the chain tip.
fn wallet_with_orchard_notes(values: &[u64]) -> TestWallet {
    let mut st = unscanned_wallet();
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
    mine_empty_blocks(&mut st, CONFIRMATIONS);
    scan_from(&mut st, first);
    st
}

/// A wallet whose only funds are one spendable Orchard note of [`NOTE_VALUE`].
fn funded_wallet() -> TestWallet {
    wallet_with_orchard_notes(&[NOTE_VALUE])
}

/// The transparent receiver of an account outside the test wallet.
const OUTSIDE_TRANSPARENT: [u8; 20] = [7; 20];

/// An Orchard-only unified address that belongs to nobody in the test wallet.
fn external_recipient(st: &TestWallet) -> ZcashAddress {
    let key = orchard::keys::SpendingKey::from_bytes([9; 32]).unwrap();
    let address =
        orchard::keys::FullViewingKey::from(&key).address_at(0u32, orchard::keys::Scope::External);
    let ua = UnifiedAddress::from_receivers(Some(address), None, None, None, None)
        .expect("an Orchard receiver");
    Address::from(ua).to_zcash_address(st.network())
}

/// A transparent P2PKH address that belongs to nobody in the test wallet.
fn transparent_recipient(st: &TestWallet) -> ZcashAddress {
    Address::Transparent(TransparentAddress::PublicKeyHash(OUTSIDE_TRANSPARENT))
        .to_zcash_address(st.network())
}

/// A ZIP 320 (TEX) address that belongs to nobody in the test wallet.
fn tex_recipient(st: &TestWallet) -> ZcashAddress {
    Address::Tex(OUTSIDE_TRANSPARENT).to_zcash_address(st.network())
}

fn memo() -> Option<MemoBytes> {
    Some(MemoBytes::from_bytes(b"gift").unwrap())
}

/// The user's Send Max: every shielded pool, only what is spendable now.
fn user_send_max(recipient: ZcashAddress, memo: Option<MemoBytes>) -> SendMaxRequest {
    SendMaxRequest {
        pools: &SEND_MAX_POOLS,
        mode: MaxSpendMode::MaxSpendable,
        recipient,
        memo,
        confirmations_policy: ConfirmationsPolicy::default(),
    }
}

/// [`propose`] against the test wallet's account.
fn propose_max(
    st: &mut TestWallet,
    request: SendMaxRequest,
) -> Result<TestProposal, ClassifiedError> {
    let account = st.test_account().unwrap().id();
    let network = *st.network();
    propose(st.wallet_mut(), &network, account, request, CONTEXT)
}

/// The classification of a send-max the wallet refuses.
fn refusal(st: &mut TestWallet, request: SendMaxRequest) -> ClassifiedError {
    propose_max(st, request).expect_err("the send-max is refused")
}

/// The fee of all of a proposal's transactions together.
fn total_fee(proposal: &TestProposal) -> Zatoshis {
    proposal
        .steps()
        .iter()
        .map(|step| step.balance().fee_required())
        .sum::<Option<Zatoshis>>()
        .expect("fees are in range")
}

/// The total a proposal pays to its recipients, across all of its steps.
fn payment_total(proposal: &TestProposal) -> Zatoshis {
    proposal
        .steps()
        .iter()
        .map(|step| {
            step.transaction_request()
                .total()
                .expect("payments are in range")
                .unwrap_or(Zatoshis::ZERO)
        })
        .sum::<Option<Zatoshis>>()
        .expect("payments are in range")
}

/// The number of notes a proposal spends, across all of its steps.
fn spent_note_count(proposal: &TestProposal) -> usize {
    proposal
        .steps()
        .iter()
        .filter_map(|step| step.shielded_inputs())
        .flat_map(|inputs| inputs.notes().iter().map(|note| *note.internal_note_id()))
        .collect::<BTreeSet<_>>()
        .len()
}

/// Every message names the call site and carries none of the values involved.
fn assert_redacted(e: &ClassifiedError, values: &[&str]) {
    let rendered = e.to_string();
    assert!(
        rendered.starts_with("propose_send_max_transfer: "),
        "{rendered}"
    );
    for value in values {
        assert!(!rendered.contains(value), "{rendered} contains {value}");
    }
}

// Proposals

#[test]
fn send_max_pays_the_whole_balance_less_the_fee() {
    let mut st = funded_wallet();
    let recipient = external_recipient(&st);

    let max = propose_max(&mut st, user_send_max(recipient, None)).expect("proposes the send-max");

    assert_eq!(u64::from(total_fee(&max)), MINIMUM_FEE);
    assert_eq!(u64::from(payment_total(&max)), NOTE_VALUE - MINIMUM_FEE);
    assert_eq!(spent_note_count(&max), 1);
}

// Error classification, against a wallet

#[test]
fn a_wallet_with_nothing_spendable_is_insufficient_funds() {
    let mut st = wallet_with_orchard_notes(&[]);
    let recipient = external_recipient(&st);

    let e = refusal(&mut st, user_send_max(recipient, None));

    assert_eq!(e.kind(), ErrorKind::InsufficientFunds);
    assert_eq!(e.amounts().map(|s| s.available), Some(Zatoshis::ZERO));
}

/// The shortfall a send-max most often reports comes from change selection, which upstream
/// does not lift into `Error::InsufficientFunds`; it must still carry its amounts.
#[test]
fn a_balance_that_does_not_exceed_the_fee_is_insufficient_funds() {
    const BELOW_FEE: u64 = 9_000;
    let mut st = wallet_with_orchard_notes(&[BELOW_FEE]);
    let recipient = external_recipient(&st);

    let e = refusal(&mut st, user_send_max(recipient, None));

    assert_eq!(e.kind(), ErrorKind::InsufficientFunds);
    assert_eq!(
        e.amounts(),
        Some(Shortfall {
            available: Zatoshis::const_from_u64(BELOW_FEE),
            required: Zatoshis::const_from_u64(MINIMUM_FEE + 1),
        })
    );
    assert_redacted(&e, &["9000", "10001"]);
}

#[test]
fn a_memo_to_a_transparent_recipient_is_rejected() {
    let mut st = funded_wallet();
    let recipient = transparent_recipient(&st);
    let encoded = recipient.encode();

    let e = refusal(&mut st, user_send_max(recipient, memo()));

    assert_eq!(e.kind(), ErrorKind::TransparentMemo);
    assert_redacted(&e, &[&encoded, "gift"]);
}

#[test]
fn a_memo_to_a_tex_recipient_is_rejected() {
    let mut st = funded_wallet();
    let recipient = tex_recipient(&st);
    let encoded = recipient.encode();

    let e = refusal(&mut st, user_send_max(recipient, memo()));

    assert_eq!(e.kind(), ErrorKind::TransparentMemo);
    assert_redacted(&e, &[&encoded, "gift"]);
}

#[test]
fn a_wallet_that_has_not_scanned_requires_sync() {
    let mut st = unscanned_wallet();
    let recipient = external_recipient(&st);

    let e = refusal(&mut st, user_send_max(recipient, None));

    assert_eq!(e.kind(), ErrorKind::ScanRequired);
}

/// More Orchard notes than one transaction can spend within the block size limit (an Orchard
/// action with its signature and its share of the proof is a little over 3 kB, so a 2 MB block
/// holds about 630 of them).
const TOO_MANY_NOTES: usize = 700;

/// Notes per block when receiving [`TOO_MANY_NOTES`], to keep the chain short.
const NOTES_PER_BLOCK: usize = 50;

/// A wallet holding [`TOO_MANY_NOTES`] spendable Orchard notes, each worth more than the
/// marginal fee it costs to spend.
fn wallet_with_too_many_notes() -> TestWallet {
    let mut st = unscanned_wallet();
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
    mine_empty_blocks(&mut st, CONFIRMATIONS);
    scan_from(&mut st, first);
    st
}

/// A send-max that would spend more notes than fit in a block is refused when it is proposed,
/// not only once its transaction is built.
#[test]
fn a_send_max_of_too_many_notes_is_too_large() {
    let mut st = wallet_with_too_many_notes();
    let recipient = external_recipient(&st);

    let e = refusal(&mut st, user_send_max(recipient, None));

    assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
    assert_eq!(e.amounts(), None);
    assert_redacted(&e, &["700"]);
}

// Error classification, of constructed `zcash_client_backend` errors

/// A `zcash_client_backend` send-max failure with display-only type parameters.
type BackendError =
    DataApiError<String, Infallible, GreedyInputSelectorError, String, String, String>;

fn too_large() -> ProposalError {
    ProposalError::TransactionTooLarge {
        estimated_size: 2_000_001,
        limit: 2_000_000,
        sapling_input_count: 0,
        orchard_input_count: 3_000,
        ironwood_input_count: 0,
    }
}

#[test]
fn an_oversized_transaction_is_classified_as_too_large() {
    let error: BackendError = DataApiError::Proposal(too_large());

    assert_eq!(
        classify(CONTEXT, &error).kind(),
        ErrorKind::TransactionTooLarge
    );
    assert_eq!(
        classify_proposal_error(CONTEXT, &too_large()).kind(),
        ErrorKind::TransactionTooLarge
    );
}

#[test]
fn an_unpayable_recipient_is_classified_as_unsupported() {
    let st = funded_wallet();
    let Address::Unified(ua) =
        Address::try_from_zcash_address(st.network(), external_recipient(&st))
            .expect("decodes the test address")
    else {
        unreachable!("the test recipient is a unified address");
    };

    let errors: [BackendError; 3] = [
        DataApiError::NoteSelection(GreedyInputSelectorError::UnsupportedAddress(ua.clone())),
        DataApiError::NoteSelection(GreedyInputSelectorError::UnsupportedTexAddress),
        DataApiError::NoSupportedReceivers(ua),
    ];

    for error in &errors {
        let e = classify(CONTEXT, error);
        assert_eq!(e.kind(), ErrorKind::NoSupportedReceivers, "{error:?}");
        assert_redacted(&e, &[&external_recipient(&st).encode()]);
    }
}

#[test]
fn every_form_of_a_transparent_memo_is_classified_alike() {
    let errors: [BackendError; 2] = [
        DataApiError::Payment(PaymentError::TransparentMemo),
        DataApiError::Proposal(ProposalError::Zip321(Zip321Error::TransparentMemo(0))),
    ];

    for error in &errors {
        assert_eq!(
            classify(CONTEXT, error).kind(),
            ErrorKind::TransparentMemo,
            "{error:?}"
        );
    }
}

#[test]
fn every_form_of_insufficient_funds_is_classified_alike() {
    let available = Zatoshis::const_from_u64(1);
    let required = Zatoshis::const_from_u64(2);
    let errors: [BackendError; 2] = [
        DataApiError::InsufficientFunds {
            available,
            required,
        },
        DataApiError::Change(ChangeError::InsufficientFunds {
            available,
            required,
        }),
    ];

    for error in &errors {
        let e = classify(CONTEXT, error);
        assert_eq!(e.kind(), ErrorKind::InsufficientFunds, "{error:?}");
        assert_eq!(
            e.amounts(),
            Some(Shortfall {
                available,
                required
            })
        );
    }
}

#[test]
fn sync_required_is_classified_as_scan_required() {
    let error: BackendError = DataApiError::ScanRequired;

    assert_eq!(classify(CONTEXT, &error).kind(), ErrorKind::ScanRequired);
}

/// Anything outside the send-max categories is classified as any other wallet error is, and
/// keeps no part of the backend's description.
#[test]
fn any_other_failure_is_classified_generally_and_redacted() {
    let error: BackendError = DataApiError::DataSource("the database is locked".to_owned());

    let e = classify(CONTEXT, &error);

    assert_eq!(e.kind(), ErrorKind::DataSourceFailed);
    assert_redacted(&e, &["locked"]);
}
