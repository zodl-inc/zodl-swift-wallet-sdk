//! Tests for the shared classifier and the error report it feeds.

use super::*;
use std::convert::Infallible;

type TestError = WalletError<Infallible, Infallible, Infallible, Infallible, Infallible, u32>;

#[test]
fn scan_required_is_classified_and_says_so() {
    let e = ClassifiedError::classify("propose_transfer", &TestError::ScanRequired);

    assert_eq!(e.kind(), ErrorKind::ScanRequired);
    assert_eq!(e.amounts(), None);
    assert!(e.to_string().contains("must finish scanning"));
}

#[test]
fn insufficient_funds_reports_amounts_out_of_band() {
    let available = Zatoshis::const_from_u64(120_000_000);
    let required = Zatoshis::const_from_u64(200_000_000);
    let e = ClassifiedError::classify(
        "propose_transfer",
        &TestError::InsufficientFunds {
            available,
            required,
        },
    );

    assert_eq!(e.kind(), ErrorKind::InsufficientFunds);
    assert_eq!(
        e.amounts(),
        Some(Shortfall {
            available,
            required
        })
    );

    // The whole point: the wallet gets the numbers, the report does not.
    let rendered = e.to_string();
    assert!(!rendered.contains("120000000"));
    assert!(!rendered.contains("200000000"));
    assert!(!rendered.contains("1.2"));
}

/// The oversized-transaction rejection `zcash_client_backend` reports, with arbitrary counts.
pub(crate) fn too_large() -> ProposalError {
    ProposalError::TransactionTooLarge {
        estimated_size: 2_000_001,
        limit: 2_000_000,
        sapling_input_count: 0,
        orchard_input_count: 700,
        ironwood_input_count: 0,
    }
}

/// A transaction too large for a block is its own kind when proposing: as a wallet error from
/// proposing, and as the bare proposal error a size check returns.
#[test]
fn an_oversized_transaction_is_classified_as_too_large() {
    let from_wallet =
        ClassifiedError::classify_proposing("propose_transfer", &TestError::Proposal(too_large()));
    let from_check = ClassifiedError::classify_proposal("propose_send_max_transfer", &too_large());

    for e in [from_wallet, from_check] {
        assert_eq!(e.kind(), ErrorKind::TransactionTooLarge);
        assert_eq!(e.amounts(), None);
        assert!(!e.to_string().contains("2000001"));
        assert!(!e.to_string().contains("700"));
    }
}

/// Change selection's shortfall is lifted into the same amount-carrying kind as input
/// selection's when proposing.
#[test]
fn every_form_of_insufficient_funds_is_classified_alike() {
    let available = Zatoshis::const_from_u64(1);
    let required = Zatoshis::const_from_u64(2);
    let errors: [TestError; 2] = [
        TestError::InsufficientFunds {
            available,
            required,
        },
        TestError::Change(ChangeError::InsufficientFunds {
            available,
            required,
        }),
    ];

    for error in &errors {
        let e = ClassifiedError::classify_proposing("propose_transfer", error);
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

/// A memo for a recipient that cannot receive one is one kind when proposing, whether payment
/// construction or the proposal reported it.
#[test]
fn every_form_of_a_transparent_memo_is_classified_alike() {
    let errors: [TestError; 2] = [
        TestError::Payment(PaymentError::TransparentMemo),
        TestError::Proposal(ProposalError::Zip321(Zip321Error::TransparentMemo(0))),
    ];

    for error in &errors {
        let e = ClassifiedError::classify_proposing("propose_transfer", error);
        assert_eq!(e.kind(), ErrorKind::TransparentMemo, "{error:?}");
    }
    assert_eq!(
        ClassifiedError::classify_proposal(
            "propose_send_max_transfer",
            &ProposalError::Zip321(Zip321Error::TransparentMemo(0))
        )
        .kind(),
        ErrorKind::TransparentMemo
    );
}

/// Building transactions, and the migration lanes, classify as they always have: none of the
/// proposing categories is lifted, so each keeps the kind and message it had.
#[test]
fn classify_keeps_the_kinds_it_always_had() {
    let cases: [(TestError, ErrorKind, &str); 4] = [
        (
            TestError::Proposal(too_large()),
            ErrorKind::ProposalInvalid,
            "the transaction proposal was rejected as invalid",
        ),
        (
            TestError::Proposal(ProposalError::Zip321(Zip321Error::TransparentMemo(0))),
            ErrorKind::ProposalInvalid,
            "the transaction proposal was rejected as invalid",
        ),
        (
            TestError::Payment(PaymentError::TransparentMemo),
            ErrorKind::InvalidPaymentRequest,
            "the payment could not be constructed from this request",
        ),
        (
            TestError::Change(ChangeError::InsufficientFunds {
                available: Zatoshis::const_from_u64(1),
                required: Zatoshis::const_from_u64(2),
            }),
            ErrorKind::ChangeSelectionFailed,
            "change selection failed, possibly for lack of spendable funds",
        ),
    ];

    for (error, kind, message) in &cases {
        let e = ClassifiedError::classify("create_proposed_transactions", error);
        assert_eq!(e.kind(), *kind, "{error:?}");
        assert_eq!(e.message(), *message, "{error:?}");
        assert_eq!(e.amounts(), None, "{error:?}");
    }
}

#[test]
fn anchor_not_found_is_classified_and_says_so() {
    let e = ClassifiedError::classify(
        "propose_transfer",
        &TestError::Proposal(ProposalError::AnchorNotFound(1_000_000.into())),
    );

    assert_eq!(e.kind(), ErrorKind::AnchorNotFound);
    assert_eq!(e.amounts(), None);
    assert!(e.to_string().contains("anchor"));
    // the height is a wallet-state detail; it must not reach the report
    assert!(!e.to_string().contains("1000000"));
}

#[test]
fn any_other_proposal_error_is_still_an_invalid_proposal() {
    let e = ClassifiedError::classify(
        "create_proposed_transactions",
        &TestError::Proposal(ProposalError::RequestTotalInvalid),
    );

    assert_eq!(e.kind(), ErrorKind::ProposalInvalid);
}

fn take_report() -> Option<(u32, String, i64, i64)> {
    let ptr = zcashlc_take_last_error_report();
    if ptr.is_null() {
        return None;
    }

    let report = unsafe { &*ptr };
    let taken = (
        report.kind,
        unsafe { std::ffi::CStr::from_ptr(report.message) }
            .to_string_lossy()
            .into_owned(),
        report.available,
        report.required,
    );

    unsafe { zcashlc_free_error_report(ptr) };

    Some(taken)
}

#[test]
fn no_error_reports_nothing() {
    ffi_helpers::error_handling::clear_last_error();

    assert!(take_report().is_none());
}

#[test]
fn a_classified_error_round_trips_its_kind_and_amounts() {
    ffi_helpers::error_handling::update_last_error(anyhow::Error::from(ClassifiedError::classify(
        "propose_transfer",
        &TestError::InsufficientFunds {
            available: Zatoshis::const_from_u64(120_000_000),
            required: Zatoshis::const_from_u64(200_000_000),
        },
    )));

    let (kind, message, available, required) = take_report().expect("an error was recorded");

    assert_eq!(kind, ErrorKind::InsufficientFunds as u32);
    assert_eq!(available, 120_000_000);
    assert_eq!(required, 200_000_000);
    assert!(!message.contains("120000000"));

    // Taking is destructive, exactly as `zcashlc_clear_last_error` would be.
    assert!(take_report().is_none());
}

/// An error that never passed through the classifier must not have its text forwarded: the
/// anyhow strings elsewhere in this crate have not been audited for amounts or addresses.
#[test]
fn an_unclassified_error_reports_a_generic_message() {
    ffi_helpers::error_handling::update_last_error(anyhow::anyhow!(
        "Insufficient balance (have 1.2, need 2.0 including fee)"
    ));

    let (kind, message, available, required) = take_report().expect("an error was recorded");

    assert_eq!(kind, ErrorKind::Unclassified as u32);
    assert_eq!(message, "an unclassified error occurred");
    assert_eq!((available, required), (NO_AMOUNT, NO_AMOUNT));
}

/// The regression guard for the leak this module exists to prevent. Every classification
/// must render to a message this file owns, so no upstream `Display` can reach a report.
#[test]
fn every_classification_renders_a_constant_message() {
    let cases: Vec<TestError> = vec![
        TestError::ProposalNotSupported,
        TestError::AccountIdNotRecognized,
        TestError::KeyNotRecognized,
        TestError::AccountCannotSpend,
        TestError::ScanRequired,
        TestError::InsufficientFunds {
            available: Zatoshis::const_from_u64(1),
            required: Zatoshis::const_from_u64(2),
        },
        TestError::ExpiryHeightConflictsWithCanonicalCrossing {
            requested: 1_000_000.into(),
        },
        TestError::Proposal(ProposalError::AnchorNotFound(1_000_000.into())),
        TestError::Proposal(too_large()),
    ];

    for case in &cases {
        let e = ClassifiedError::classify("ctx", case);
        assert_eq!(e.to_string(), format!("ctx: {}", e.message()));
    }
}
