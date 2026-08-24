//! Classification and redaction of errors that cross the FFI boundary.
//!
//! Two audiences read a failure and they need different things. The WALLET needs to branch on
//! the condition -- "still syncing", "not enough spendable funds" -- so it gets a stable
//! discriminant plus, where the condition is quantitative, the amounts as typed values. An
//! ERROR REPORT pasted into a support ticket needs a string carrying no amount, address, note
//! identifier or txid. `ClassifiedError::classify` serves both from one match.
//!
//! Every message returned here is a constant written in this file. None is `Display` output of
//! the error being classified. For the four generic payloads (`DataSource`, `CommitmentTree`,
//! `NoteSelection`, `Change`) that is enforced by the type system rather than by review:
//! `classify` places no `Display` or `Debug` bound on those parameters, so by parametricity it
//! has no way to render them. The concrete payloads (`NoteId`, `UnifiedAddress`,
//! `TransparentAddress`, `Zatoshis`) could be rendered and are withheld by choice.
//!
//! The unredacted text is not discarded: call sites log it at `debug!`, where it stays on the
//! device.
//!
//! `Display` on `ClassifiedError` is what `zcashlc_last_error_message` returns, so the legacy
//! one-string path is redacted for these call sites too, not only the new report path.

use std::ffi::CString;
use std::fmt;
use std::os::raw::c_char;

use tracing::debug;
use zcash_client_backend::data_api::error::Error as WalletError;
use zcash_protocol::value::Zatoshis;

/// Stable discriminants for the conditions a wallet is expected to render itself rather than
/// show as an opaque error.
///
/// These values are part of the FFI contract and are read by `ZcashRustBackend`: append new
/// ones, never renumber existing ones.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// No classification applies, or the error did not come from a classified call site. The
    /// message carries no detail; consult the device log.
    Unclassified = 0,
    /// The wallet must finish scanning before this operation can succeed.
    ScanRequired = 1,
    /// The spendable balance does not cover the payment plus its fee. Amounts are reported
    /// alongside, not in the message.
    InsufficientFunds = 2,
    /// The requested amount is negative or out of the representable range.
    InvalidAmount = 3,
    /// The recipient address could not be parsed, or is not one this wallet can pay.
    InvalidRecipient = 4,
    /// The memo was rejected (too long, or not valid for the recipient pool).
    InvalidMemo = 5,
    /// The payment request or payment URI was malformed.
    InvalidPaymentRequest = 6,
    /// No account matches the supplied identifier or spending key.
    AccountNotFound = 7,
    /// The account exists but cannot spend, so it cannot maintain an accurate balance.
    AccountCannotSpend = 8,
    /// A key required to spend an input of some pool is not available.
    KeyNotAvailable = 9,
    /// The recipient's unified address exposes no receiver this wallet can pay.
    NoSupportedReceivers = 10,
    /// The proposal is structurally valid but uses something this build does not support.
    ProposalNotSupported = 11,
    /// The transaction builder failed.
    BuilderFailed = 12,
    /// The wallet database failed.
    DataSourceFailed = 13,
    /// Input selection failed for a reason other than insufficient funds.
    NoteSelectionFailed = 14,
    /// Change selection failed.
    ChangeSelectionFailed = 15,
    /// The note commitment tree failed.
    CommitmentTreeFailed = 16,
    /// The proposal itself was rejected as invalid.
    ProposalInvalid = 17,
    /// A requested expiry height conflicts with the proposal's constraints.
    ExpiryHeightInvalid = 18,
    /// An amount computation overflowed or underflowed.
    BalanceOverflow = 19,
    /// A note being spent belongs to neither the internal nor the external viewing key.
    NoteMismatch = 20,
}

/// A failure that has been classified and stripped of sensitive detail.
///
/// Stored in `LAST_ERROR` as an `anyhow::Error`, which preserves the concrete type, so
/// `zcashlc_take_last_error_report` recovers the classification by downcast rather than by
/// parsing the message back out.
#[derive(Clone, Debug)]
pub struct ClassifiedError {
    kind: ErrorKind,
    message: &'static str,
    context: &'static str,
    /// `(available, required)`, set only for [`ErrorKind::InsufficientFunds`]. These reach the
    /// wallet as typed values and never enter `message`.
    amounts: Option<(Zatoshis, Zatoshis)>,
}

impl ClassifiedError {
    /// A classification that carries no amounts. `message` must be a constant, never
    /// interpolated from a value under attacker or wallet control.
    pub fn new(context: &'static str, kind: ErrorKind, message: &'static str) -> Self {
        Self {
            kind,
            message,
            context,
            amounts: None,
        }
    }

    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    pub fn message(&self) -> &'static str {
        self.message
    }

    pub fn amounts(&self) -> Option<(Zatoshis, Zatoshis)> {
        self.amounts
    }

    /// Classifies a wallet error from proposal construction or transaction creation.
    ///
    /// Total by construction: `WalletError` is `#[non_exhaustive]`, and a variant added upstream
    /// falls to the catch-all as [`ErrorKind::Unclassified`] rather than failing to compile or,
    /// worse, leaking through a `Display` fallback.
    pub fn classify<DbE, CtE, SelE, FeeE, ChE, NoteRef>(
        context: &'static str,
        e: &WalletError<DbE, CtE, SelE, FeeE, ChE, NoteRef>,
    ) -> Self {
        let (kind, message) = match e {
            WalletError::DataSource(_) => (
                ErrorKind::DataSourceFailed,
                "the wallet database returned an error",
            ),
            WalletError::CommitmentTree(_) => (
                ErrorKind::CommitmentTreeFailed,
                "the note commitment tree returned an error",
            ),
            // Upstream lifts the two interesting selector failures out before this point
            // (`InputSelectorError::SyncRequired` becomes `ScanRequired` and its
            // `InsufficientFunds` becomes ours), so what is left is the selector's own error and
            // there is nothing more specific to say without rendering it.
            WalletError::NoteSelection(_) => {
                (ErrorKind::NoteSelectionFailed, "input selection failed")
            }
            // Reachable as a second insufficient-funds path: `ChangeError` has its own
            // `InsufficientFunds` variant, which upstream does NOT lift into
            // `Error::InsufficientFunds`, so a shortfall found during change selection arrives
            // here rather than as the classified amount-carrying kind.
            WalletError::Change(_) => (
                ErrorKind::ChangeSelectionFailed,
                "change selection failed, possibly for lack of spendable funds",
            ),
            WalletError::Proposal(_) => (
                ErrorKind::ProposalInvalid,
                "the transaction proposal was rejected as invalid",
            ),
            WalletError::ProposalNotSupported => (
                ErrorKind::ProposalNotSupported,
                "the proposal requires a feature this build does not support",
            ),
            WalletError::AccountIdNotRecognized => (
                ErrorKind::AccountNotFound,
                "no account matches the supplied identifier",
            ),
            WalletError::KeyNotRecognized => (
                ErrorKind::AccountNotFound,
                "no account matches the supplied spending key",
            ),
            WalletError::AccountCannotSpend => (
                ErrorKind::AccountCannotSpend,
                "this account cannot spend, so it cannot maintain an accurate balance",
            ),
            WalletError::BalanceError(_) => (
                ErrorKind::BalanceOverflow,
                "an amount computation overflowed or underflowed",
            ),
            WalletError::InsufficientFunds {
                available,
                required,
            } => {
                return Self {
                    kind: ErrorKind::InsufficientFunds,
                    message: "the spendable balance does not cover this payment and its fee",
                    context,
                    amounts: Some((*available, *required)),
                };
            }
            WalletError::ScanRequired => (
                ErrorKind::ScanRequired,
                "the wallet must finish scanning before this payment can be prepared",
            ),
            WalletError::Builder(_) => (
                ErrorKind::BuilderFailed,
                "the transaction builder returned an error",
            ),
            WalletError::Payment(_) => (
                ErrorKind::InvalidPaymentRequest,
                "the payment could not be constructed from this request",
            ),
            WalletError::UnsupportedChangeType(_) => (
                ErrorKind::ProposalNotSupported,
                "change was directed to a pool this build does not support",
            ),
            WalletError::NoSupportedReceivers(_) => (
                ErrorKind::NoSupportedReceivers,
                "the recipient address exposes no receiver this wallet can pay",
            ),
            WalletError::KeyNotAvailable(_) => (
                ErrorKind::KeyNotAvailable,
                "a key required to spend one of the selected inputs is not available",
            ),
            WalletError::NoteMismatch(_) => (
                ErrorKind::NoteMismatch,
                "a note selected for spending does not belong to this account",
            ),
            WalletError::Address(_) => (
                ErrorKind::InvalidRecipient,
                "the recipient address in the payment request could not be parsed",
            ),
            WalletError::ExpiryHeightBelowTargetHeight { .. } => (
                ErrorKind::ExpiryHeightInvalid,
                "the requested expiry height is below the proposal's minimum target height",
            ),
            WalletError::ExpiryHeightConflictsWithCanonicalCrossing { .. } => (
                ErrorKind::ExpiryHeightInvalid,
                "the requested expiry height conflicts with the canonical ZIP 318 crossing",
            ),
            // Variants behind upstream feature gates (`AddressNotRecognized`, `Pczt`) and any
            // variant added by a future release land here. A dependency bump can widen the
            // enum without silently widening what this module is willing to print.
            _ => (
                ErrorKind::Unclassified,
                "an unclassified wallet error occurred",
            ),
        };

        Self::new(context, kind, message)
    }
}

impl fmt::Display for ClassifiedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.context, self.message)
    }
}

impl std::error::Error for ClassifiedError {}

/// The classification of the most recent error, for callers that need to branch on the
/// condition instead of showing a string.
///
/// `message` is heap-allocated and the whole value must be freed by calling
/// [`zcashlc_free_error_report`].
///
/// # Safety
///
/// - `message` is a non-null, null-terminated UTF-8 string, redacted and safe to include in an
///   error report submitted off the device.
/// - `available` and `required` are zatoshi amounts, and are set only when `kind` is
///   [`ErrorKind::InsufficientFunds`]; both are `-1` otherwise. They are NOT redacted, because
///   they are for the wallet to render to the user whose balance they describe.
#[repr(C)]
pub struct ErrorReport {
    /// An [`ErrorKind`] discriminant.
    pub kind: u32,
    pub message: *mut c_char,
    pub available: i64,
    pub required: i64,
}

/// The sentinel for "this report carries no amount", chosen so a caller that forgets to check
/// `kind` cannot mistake an absent amount for a zero balance.
const NO_AMOUNT: i64 = -1;

/// Takes the most recent error and returns its classification, clearing it in the process
/// exactly as [`zcashlc_clear_last_error`](crate::zcashlc_clear_last_error) would.
///
/// Returns null when there is no error to report. An error that did not come from a classified
/// call site is reported as [`ErrorKind::Unclassified`] with a generic message, and its real
/// text is logged at `debug!` so it stays on the device.
///
/// The returned pointer must be freed with [`zcashlc_free_error_report`].
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_take_last_error_report() -> *mut ErrorReport {
    let Some(err) = ffi_helpers::error_handling::take_last_error() else {
        return std::ptr::null_mut();
    };

    let report = match err.downcast_ref::<ClassifiedError>() {
        Some(classified) => {
            let (available, required) = classified
                .amounts()
                .map_or((NO_AMOUNT, NO_AMOUNT), |(available, required)| {
                    (u64::from(available) as i64, u64::from(required) as i64)
                });

            ErrorReport {
                kind: classified.kind() as u32,
                message: message_ptr(classified.message()),
                available,
                required,
            }
        }
        None => {
            debug!("unclassified error crossing the FFI boundary: {err:#}");

            ErrorReport {
                kind: ErrorKind::Unclassified as u32,
                message: message_ptr("an unclassified error occurred"),
                available: NO_AMOUNT,
                required: NO_AMOUNT,
            }
        }
    };

    Box::into_raw(Box::new(report))
}

/// Frees an [`ErrorReport`] value.
///
/// # Safety
///
/// - `ptr` must be non-null and must point to a struct having the layout of [`ErrorReport`] as
///   returned by [`zcashlc_take_last_error_report`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_error_report(ptr: *mut ErrorReport) {
    if !ptr.is_null() {
        let report = unsafe { Box::from_raw(ptr) };
        unsafe { crate::zcashlc_string_free(report.message) };
        drop(report);
    }
}

/// Every message this module produces is a constant it owns, so the only way `CString::new` can
/// fail is an interior nul someone wrote into this file.
fn message_ptr(message: &'static str) -> *mut c_char {
    CString::new(message)
        .unwrap_or_else(|_| c"an unclassified error occurred".to_owned())
        .into_raw()
}

#[cfg(test)]
mod tests {
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
        assert_eq!(e.amounts(), Some((available, required)));

        // The whole point: the wallet gets the numbers, the report does not.
        let rendered = e.to_string();
        assert!(!rendered.contains("120000000"));
        assert!(!rendered.contains("200000000"));
        assert!(!rendered.contains("1.2"));
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
        ffi_helpers::error_handling::update_last_error(anyhow::Error::from(
            ClassifiedError::classify(
                "propose_transfer",
                &TestError::InsufficientFunds {
                    available: Zatoshis::const_from_u64(120_000_000),
                    required: Zatoshis::const_from_u64(200_000_000),
                },
            ),
        ));

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
        ];

        for case in &cases {
            let e = ClassifiedError::classify("ctx", case);
            assert_eq!(e.to_string(), format!("ctx: {}", e.message()));
        }
    }
}
