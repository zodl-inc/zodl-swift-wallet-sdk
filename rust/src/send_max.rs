//! Sending an account's entire spendable shielded balance to one recipient.
//!
//! The user's send-max goes through [`propose`]: `zcashlc_propose_send_max_transfer` with
//! `orchard_only` false (the wallet's Send Max and the gift card sweep). [`propose`] is the
//! only place that pins the fee rule and the input locking behaviour for it, applies the
//! transaction size limit, and sorts the failures `zcash_client_backend` reports into the
//! [`ErrorKind`]s a wallet branches on.
//!
//! The migration lanes do not use it: the immediate migration lane (`orchard_only` true) and
//! the single-shot Orchard to Ironwood turnstile in [`crate::migration_turnstile`] call
//! upstream's `propose_send_max_transfer` directly, exactly as they always have, with neither
//! the size limit nor this classification.
//!
//! The selection itself is upstream's [`propose_send_max_transfer`]: it selects every spendable
//! note in the chosen pools and computes the ZIP 317 fee internally, so the payment is exactly
//! the selected value minus that fee and no change is left behind.

use std::fmt;

use tracing::debug;
use zcash_address::ZcashAddress;
use zcash_client_backend::{
    data_api::{
        InputSource, MaxSpendMode, WalletRead, WalletWrite,
        error::Error as DataApiError,
        wallet::{
            ConfirmationsPolicy,
            input_selection::{GreedyInputSelectorError, LockedInputPolicy},
            propose_send_max_transfer,
        },
    },
    fees::StandardFeeRule,
    proposal::Proposal,
};
use zcash_protocol::{ShieldedPool, consensus::Parameters, memo::MemoBytes};

use crate::error_report::{ClassifiedError, ErrorKind};

#[cfg(test)]
mod tests;

/// A send-max proposal over a wallet whose received notes are identified by `NoteRef`.
pub(crate) type SendMaxProposal<NoteRef> = Proposal<StandardFeeRule, NoteRef>;

/// The shielded pools a user send-max spends from: all of them. Ironwood is included alongside
/// Sapling and Orchard, since omitting it would silently leave a post-NU6.3 wallet's Ironwood
/// funds behind; including it is a no-op for an account that holds no Ironwood notes.
/// Transparent funds are not swept; they are shielded separately.
pub(crate) const SEND_MAX_POOLS: [ShieldedPool; 3] = [
    ShieldedPool::Sapling,
    ShieldedPool::Orchard,
    ShieldedPool::Ironwood,
];

/// What to send the maximum of, and to whom.
#[derive(Debug, Clone)]
pub(crate) struct SendMaxRequest {
    /// The shielded pools whose notes are spent.
    pub(crate) pools: &'static [ShieldedPool],
    /// Whether notes that are not yet spendable are left behind or fail the proposal.
    pub(crate) mode: MaxSpendMode,
    /// The single recipient of the payment.
    pub(crate) recipient: ZcashAddress,
    /// The memo carried by the payment, if any.
    pub(crate) memo: Option<MemoBytes>,
    /// The confirmations a note needs before it is spendable.
    pub(crate) confirmations_policy: ConfirmationsPolicy,
}

/// Proposes sending the maximum `request` describes from `account`.
///
/// Always ZIP 317 fees. Locked outputs, which belong to another in-flight proposal, are never
/// selected, and the selected inputs are not locked: the proposal is built to be signed and
/// broadcast, not held open for a later commitment.
///
/// `context` names the FFI entry point, as [`ClassifiedError::new`] describes. A failure is
/// returned classified by [`classify`], and its unredacted description is logged at `debug!`,
/// where it stays on the device.
pub(crate) fn propose<DbT, P>(
    db: &mut DbT,
    params: &P,
    account: <DbT as InputSource>::AccountId,
    request: SendMaxRequest,
    context: &'static str,
) -> Result<SendMaxProposal<<DbT as InputSource>::NoteRef>, ClassifiedError>
where
    DbT: WalletWrite + InputSource<Error = <DbT as WalletRead>::Error>,
    <DbT as InputSource>::NoteRef: Copy + Eq + Ord + fmt::Display,
    <DbT as WalletRead>::Error: fmt::Display,
    P: Parameters + Clone,
{
    let proposal = propose_send_max_transfer::<_, _, _, std::convert::Infallible>(
        db,
        params,
        account,
        request.pools,
        &StandardFeeRule::Zip317,
        request.recipient,
        request.memo,
        request.mode,
        request.confirmations_policy,
        &LockedInputPolicy::Exclude,
        None,
    )
    .map_err(|e| {
        debug!("{context} failed: {e}");
        classify(context, &e)
    })?;

    // `propose_transfer` rejects a proposal whose transaction would not fit in a block, but
    // `propose_send_max_transfer` does not yet, so without this a send-max that spends too many
    // notes would pass review and fail only once its transaction is built. This mirrors
    // `propose_transfer`'s check, and can be removed once librustzcash gates send-max itself
    // (upstream fix in progress for zcash/librustzcash#2952).
    proposal.check_transaction_size().map_err(|e| {
        debug!("{context} failed: {e}");
        ClassifiedError::classify_proposal(context, &e)
    })?;

    Ok(proposal)
}

/// Sorts a `zcash_client_backend` send-max failure into the condition it describes.
///
/// The categories a wallet acts on, and the [`ErrorKind`] each crosses the FFI as:
///
/// - insufficient funds, [`ErrorKind::InsufficientFunds`], with its amounts;
/// - a transaction too large for a block, [`ErrorKind::TransactionTooLarge`];
/// - a memo for a recipient that cannot receive one, [`ErrorKind::TransparentMemo`];
/// - a recipient with no receiver this wallet can pay, [`ErrorKind::NoSupportedReceivers`];
/// - a wallet that must scan before it can propose, [`ErrorKind::ScanRequired`].
///
/// Only the unpayable recipient needs the concrete input selector's error to recognise, so it
/// is the one arm here; every other category, and anything else, is classified by
/// [`ClassifiedError::classify_proposing`], as it is when proposing a transfer. None of the messages carries
/// the recipient, the memo or an amount.
pub(crate) fn classify<DE, TE, FE, CE, N>(
    context: &'static str,
    error: &DataApiError<DE, TE, GreedyInputSelectorError, FE, CE, N>,
) -> ClassifiedError {
    match error {
        DataApiError::NoteSelection(
            GreedyInputSelectorError::UnsupportedAddress(_)
            | GreedyInputSelectorError::UnsupportedTexAddress,
        ) => ClassifiedError::new(
            context,
            ErrorKind::NoSupportedReceivers,
            "the recipient address exposes no receiver this wallet can pay",
        ),
        other => ClassifiedError::classify_proposing(context, other),
    }
}
