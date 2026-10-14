//! Ledger hardware-wallet support: the C ABI over [`pczt_ledger`].
//!
//! `pczt_ledger` is sans-I/O. It builds the APDUs a Ledger's Zcash app consumes and parses what the
//! device answers, and the platform layer moves the bytes over Bluetooth LE. This module is the
//! thin layer between the two:
//!
//! - one-shot commands: the app version (`GET_FIRMWARE_VERSION`), the device identity (a silent
//!   `GET_WALLET_PUBLIC_KEY`), and the unified-address display (`GET_SHIELD_ADDR`);
//! - the unified full viewing key export (`GET_VK`), as an opaque [`FfiLedgerUfvkExport`] handle;
//! - the pairing checks: [`zcashlc_ledger_check_account_zero_identity`] and
//!   [`zcashlc_ledger_device_unified_address`];
//! - BLE framing: the MTU handshake, [`zcashlc_ledger_ble_frames`], and an opaque
//!   [`FfiLedgerBleDeframer`] handle;
//! - the PCZT signing ceremony, as an opaque [`FfiLedgerSignSession`] handle built from the wallet
//!   database.
//!
//! # Errors
//!
//! Every failure is stored in the thread-local last-error slot as a [`LedgerError`], which
//! [`zcashlc_ledger_take_last_error`] returns as a structured [`FfiLedgerError`]. Its `reason` is
//! either a constant written here or the `Display` rendering of a `pczt_ledger` error that carries
//! no secret. Nothing this module formats ever includes APDU or reply bytes, a PCZT, a viewing key,
//! an address, a device identity, or a signature, and nothing here logs any of them.
//!
//! # One reply per command
//!
//! A reply is only ever the answer to the command last handed out. When an exchange fails after the
//! command was written — a timeout, a disconnect, a frame that does not reassemble — the platform
//! layer drops the handle and closes the connection; it never resends on the same handle. The one
//! legitimate resend is the device SDK's `0x6901`, which the handles report as a status for the
//! platform layer to act on after `CMD_NOT_ACCEPTED_BACKOFF`.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::fmt;
use std::os::raw::c_char;
use std::panic::AssertUnwindSafe;
use std::ptr;
use std::slice;
use std::sync::Mutex;

use ffi_helpers::panic::catch_panic;
use pczt::{Pczt, roles::updater::Updater};
use pczt_ledger::{
    apdu::{Deadline, StatusWord},
    framing::{self, BleFrameSize, Deframer, FramingError},
    limits::{DeviceCaps, LimitViolation},
    pairing::{self, DeviceIdentity, InvalidDeviceIdentity, PairingError, VkExchange, VkStep},
    session::{
        LedgerSignSession, LedgerViolation, PumpStep, SessionError, SessionParams, SessionStatus,
        Stage,
    },
    shape::{self, BIP44_PURPOSE, ChangeInfo, HARDENED, TRANSPARENT_INTERNAL_SCOPE},
    viewing::{AccountViewingKeys, TransparentAccountKey},
};
use tracing::debug;
use transparent::{
    address::TransparentAddress,
    keys::{AccountPubKey, NonHardenedChildIndex, TransparentKeyScope},
};
use zcash_address::unified::{self, Encoding as _};
use zcash_client_backend::data_api::{Account as _, WalletRead, wallet::SignerView};
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_protocol::consensus::Parameters as _;
use zeroize::Zeroize;
use zip32::AccountId;

use crate::{
    account_uuid_from_bytes, ffi, free_ptr_from_vec, parse_network, ptr_from_vec, wallet_db,
    zcashlc_string_free,
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Stable discriminants for the ways a Ledger operation can fail.
///
/// These values are part of the FFI contract and are read by the Swift layer: append new ones,
/// never renumber existing ones.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LedgerErrorKind {
    /// A failure with no more specific classification, including misuse of a handle.
    Internal = 0,
    /// The user declined on the device (`0x6985`).
    UserRejected = 1,
    /// The device is not running the Zcash app, or runs a version that does not know the
    /// instruction (`0x6E00`, `0x6D00`).
    WrongApp = 2,
    /// The Zcash app on the device is too old for what was asked: it predates the PCZT
    /// instructions, or the Ironwood pool a V6 transaction needs.
    AppTooOld = 3,
    /// The connected device is not the Ledger the account was paired with, or the exported viewing
    /// key of account 0 does not derive the identity of the device that exported it.
    DeviceMismatch = 4,
    /// The connected device runs another app version than the one the session was built for.
    CapsMismatch = 5,
    /// The app's per-run Orchard derivation budget is spent; closing and reopening the Zcash app
    /// on the device clears it.
    DerivationBudgetExhausted = 6,
    /// The device refused the command with a status word that has no more specific kind.
    DeviceRefused = 7,
    /// The transaction cannot be signed by a Ledger: a validation, shaping or device-limit rule
    /// refuses it before anything is sent.
    TransactionNotSignable = 8,
    /// The device's reply did not have the shape the protocol promises, a frame did not reassemble,
    /// or a returned signature did not verify.
    MalformedReply = 9,
    /// A caller-supplied value was refused before any device I/O: a device identity string, an
    /// account index, a network, or an account that is not in the wallet.
    InvalidInput = 10,
    /// The device SDK refused the frame before the app saw it (`0x6901`). Not a failure: resend the
    /// identical command after the backoff.
    CmdNotAccepted = 11,
}

/// A classified Ledger failure whose `reason` carries no secret.
///
/// Stored in the last-error slot as an `anyhow::Error`, which preserves the concrete type, so
/// [`zcashlc_ledger_take_last_error`] recovers it by downcast.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LedgerError {
    kind: LedgerErrorKind,
    status_word: Option<u16>,
    is_transient: bool,
    is_restartable: bool,
    reason: String,
}

impl LedgerError {
    fn new(kind: LedgerErrorKind, reason: impl Into<String>) -> Self {
        Self {
            kind,
            status_word: None,
            is_transient: false,
            is_restartable: false,
            reason: reason.into(),
        }
    }

    fn with_status(mut self, status: StatusWord) -> Self {
        self.status_word = Some(status.to_u16());
        self.is_transient = status.is_transient();
        self
    }

    fn restartable(mut self, is_restartable: bool) -> Self {
        self.is_restartable = is_restartable;
        self
    }

    fn internal(reason: impl Into<String>) -> Self {
        Self::new(LedgerErrorKind::Internal, reason)
    }

    fn invalid_input(reason: impl Into<String>) -> Self {
        Self::new(LedgerErrorKind::InvalidInput, reason)
    }

    fn not_signable(reason: impl Into<String>) -> Self {
        Self::new(LedgerErrorKind::TransactionNotSignable, reason)
    }

    #[cfg(test)]
    pub(crate) fn kind(&self) -> LedgerErrorKind {
        self.kind
    }
}

impl fmt::Display for LedgerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reason)
    }
}

impl std::error::Error for LedgerError {}

/// Classifies a pairing-command failure.
fn pairing_error(e: &PairingError) -> LedgerError {
    use LedgerErrorKind::*;
    match e {
        PairingError::Decode(_) => LedgerError::new(MalformedReply, e.to_string()),
        PairingError::Encode(_) => LedgerError::internal(e.to_string()),
        PairingError::UserRejected => {
            LedgerError::new(UserRejected, e.to_string()).restartable(true)
        }
        PairingError::WrongApp { status } => {
            LedgerError::new(WrongApp, e.to_string()).with_status(*status)
        }
        PairingError::Device { status } => {
            let error = LedgerError::new(DeviceRefused, e.to_string()).with_status(*status);
            let transient = error.is_transient;
            error.restartable(transient)
        }
        PairingError::PathOutOfRange { .. } => LedgerError::invalid_input(e.to_string()),
        PairingError::DerivationBudgetExhausted => {
            LedgerError::new(DerivationBudgetExhausted, e.to_string())
                .with_status(StatusWord::NotEnoughMemorySpace)
        }
        PairingError::CmdNotAccepted => LedgerError::new(CmdNotAccepted, e.to_string())
            .with_status(StatusWord::CmdNotAccepted)
            .restartable(true),
        PairingError::OutOfOrder => LedgerError::internal(e.to_string()),
        // The carried `zcash_address` parse messages describe the reply, so they are not rendered.
        PairingError::UnifiedAddress(_) => LedgerError::new(
            MalformedReply,
            "the reply to the unified-address request is not a unified address",
        ),
        PairingError::UnifiedViewingKey(_) => LedgerError::new(
            MalformedReply,
            "the reply to the unified viewing key request is not a unified full viewing key",
        ),
        PairingError::AddressNetworkMismatch { .. }
        | PairingError::InvalidOrchardAddress
        | PairingError::ViewingKeyNetworkMismatch { .. }
        | PairingError::InvalidOrchardViewingKey => LedgerError::new(MalformedReply, e.to_string()),
        _ => LedgerError::internal("the Ledger pairing command failed in an unclassified way"),
    }
}

/// Classifies a signing-session failure. `is_restartable` is the session's own verdict.
fn session_error(e: &SessionError, is_restartable: bool) -> LedgerError {
    use LedgerErrorKind::*;
    let error = match e {
        SessionError::Parse(_) => LedgerError::invalid_input("the PCZT could not be parsed"),
        SessionError::Validation(violations) => {
            let too_old = violations.iter().any(|v| {
                matches!(
                    v,
                    LedgerViolation::Limit(
                        LimitViolation::PcztUnsupported { .. }
                            | LimitViolation::IronwoodUnsupported { .. }
                    )
                )
            });
            LedgerError::new(
                if too_old {
                    AppTooOld
                } else {
                    TransactionNotSignable
                },
                e.to_string(),
            )
        }
        SessionError::Shape(_)
        | SessionError::AccountMismatch { .. }
        | SessionError::NonCompliantPath { .. }
        | SessionError::TransparentKeyMismatch { .. }
        | SessionError::TransparentAccountKeyRequired { .. } => {
            LedgerError::not_signable(e.to_string())
        }
        SessionError::UnshapedAction { .. } | SessionError::OutOfOrder => {
            LedgerError::internal(e.to_string())
        }
        // `EncodeError` renders a value sum, so the reason is a constant.
        SessionError::Encode(_) => {
            LedgerError::internal("a signing record could not be encoded onto the wire")
        }
        SessionError::UserRejected { .. } => LedgerError::new(UserRejected, e.to_string()),
        SessionError::WrongApp { status } => {
            LedgerError::new(WrongApp, e.to_string()).with_status(*status)
        }
        SessionError::CapsMismatch { .. } => LedgerError::new(CapsMismatch, e.to_string()),
        // The crate's rendering names both identities, which identify transparent addresses.
        SessionError::DeviceMismatch { .. } => LedgerError::new(
            DeviceMismatch,
            "the connected device is not the Ledger this account was paired with; no transaction \
             data was sent to it",
        ),
        SessionError::Device { status, .. } => {
            LedgerError::new(DeviceRefused, e.to_string()).with_status(*status)
        }
        SessionError::Decode(_) | SessionError::Apply(_) => {
            LedgerError::new(MalformedReply, e.to_string())
        }
        _ => LedgerError::internal("the Ledger signing session failed in an unclassified way"),
    };
    error.restartable(is_restartable)
}

/// Classifies a BLE framing failure.
fn framing_error(e: &FramingError) -> LedgerError {
    match e {
        FramingError::ApduTooLong { .. } => LedgerError::invalid_input(e.to_string()),
        _ => LedgerError::new(LedgerErrorKind::MalformedReply, e.to_string()),
    }
}

/// Classifies a stored device identity that does not parse. The rendering names only the prefix
/// and a length, never the value.
fn identity_error(e: &InvalidDeviceIdentity) -> LedgerError {
    LedgerError::invalid_input(format!("invalid Ledger device identity: {e}"))
}

/// The Ledger network for an FFI `network_id`.
///
/// Regtest has no Ledger app build, so it is refused rather than signed "as testnet"; a custom
/// network is mapped through its base identity.
fn ledger_network(network_id: u32) -> Result<pczt_ledger::Network, anyhow::Error> {
    let network = parse_network(network_id)?;
    pczt_ledger::Network::try_from(network.network_type())
        .map_err(|e| LedgerError::invalid_input(e.to_string()).into())
}

/// A ZIP 32 account index from the FFI.
fn ledger_account(index: u32) -> Result<AccountId, LedgerError> {
    AccountId::try_from(index)
        .map_err(|_| LedgerError::invalid_input("the ZIP 32 account index must be below 2^31"))
}

/// The bytes a `(ptr, len)` pair names, or an empty slice for a null pointer with length zero.
///
/// # Safety
///
/// When `len > 0`, `ptr` must be non-null and valid for reads for `len` bytes for the lifetime of
/// the returned slice.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], LedgerError> {
    if len == 0 {
        Ok(&[])
    } else if ptr.is_null() {
        Err(LedgerError::internal(
            "a null buffer was passed with a nonzero length",
        ))
    } else {
        Ok(unsafe { slice::from_raw_parts(ptr, len) })
    }
}

/// Locks a handle's state, turning a poisoned lock into an error rather than a panic.
fn lock<T>(mutex: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>, LedgerError> {
    mutex
        .lock()
        .map_err(|_| LedgerError::internal("a Ledger handle was poisoned by an earlier panic"))
}

/// A structured Ledger failure, as [`zcashlc_ledger_take_last_error`] returns it.
///
/// # Safety
///
/// - Free the value with [`zcashlc_ledger_free_error`], which releases `reason` with it.
/// - `reason` is non-null and points to a null-terminated UTF-8 string.
#[repr(C)]
pub struct FfiLedgerError {
    /// A [`LedgerErrorKind`] discriminant.
    pub kind: u32,
    /// Whether `status_word` carries the device's status word.
    pub has_status_word: bool,
    /// The status word the device answered, when `has_status_word` is set.
    pub status_word: u16,
    /// Whether the status word describes a device condition that can clear on its own (a locked
    /// device, a desynchronized transport), as opposed to a function of what was sent.
    pub is_transient: bool,
    /// Whether a fresh ceremony over the same transaction could succeed: after a user rejection,
    /// or a transient device refusal. It never means "resend the last command".
    pub is_restartable: bool,
    /// A human-readable reason. It carries no APDU, reply, PCZT, viewing key, address, device
    /// identity or signature, and is safe to log.
    pub reason: *mut c_char,
}

/// Takes the most recent error as a structured Ledger failure, clearing it exactly as
/// `zcashlc_clear_last_error` would.
///
/// Returns null when there is no error. An error that did not come from a Ledger call site is
/// reported as [`LedgerErrorKind::Internal`] with a generic reason.
///
/// The returned pointer must be freed with [`zcashlc_ledger_free_error`].
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_take_last_error() -> *mut FfiLedgerError {
    let Some(err) = ffi_helpers::error_handling::take_last_error() else {
        return ptr::null_mut();
    };

    let error = match err.downcast_ref::<LedgerError>() {
        Some(ledger) => ledger.clone(),
        None => {
            // Not raised by this module, so it did not pass through a Ledger classifier: a wallet
            // database or path failure. Its text stays on the device.
            debug!("unclassified error on a Ledger call: {err:#}");
            LedgerError::internal("an internal error occurred in the Ledger integration")
        }
    };

    Box::into_raw(Box::new(FfiLedgerError {
        kind: error.kind as u32,
        has_status_word: error.status_word.is_some(),
        status_word: error.status_word.unwrap_or(0),
        is_transient: error.is_transient,
        is_restartable: error.is_restartable,
        reason: CString::new(error.reason)
            .unwrap_or_else(|_| c"the Ledger error reason contained a NUL byte".to_owned())
            .into_raw(),
    }))
}

/// Frees an [`FfiLedgerError`].
///
/// # Safety
///
/// - `ptr` must be null, or a pointer returned by [`zcashlc_ledger_take_last_error`] that has not
///   been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_error(ptr: *mut FfiLedgerError) {
    if !ptr.is_null() {
        let error = unsafe { Box::from_raw(ptr) };
        unsafe { zcashlc_string_free(error.reason) };
    }
}

// ---------------------------------------------------------------------------
// Transport policy
// ---------------------------------------------------------------------------

/// Returns how many consecutive `0x6901` refusals a one-shot command is resent after: the budget
/// the signing session and the viewing key export apply to themselves, and which the caller of a
/// one-shot parser applies by hand. A command is sent at most this many times plus one.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_max_cmd_not_accepted_retries() -> u32 {
    pczt_ledger::session::MAX_CMD_NOT_ACCEPTED_RETRIES
}

/// Returns the pause, in milliseconds, between a `0x6901` refusal and the resend of the identical
/// command.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_cmd_not_accepted_backoff_ms() -> u32 {
    u32::try_from(pczt_ledger::ceremony::CMD_NOT_ACCEPTED_BACKOFF.as_millis()).unwrap_or(u32::MAX)
}

/// Returns the timeout, in milliseconds, for a reply the device produces without waiting on the
/// user. A reply that waits on the user has no timeout.
///
/// Generous by two orders of magnitude on purpose: a timeout ends the connection, and a spurious
/// one costs the user a restart of the ceremony.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_default_timeout_ms() -> u32 {
    u32::try_from(pczt_ledger::transport::DEFAULT_TIMEOUT.as_millis()).unwrap_or(u32::MAX)
}

// ---------------------------------------------------------------------------
// App version
// ---------------------------------------------------------------------------

/// The Zcash app version a `GET_FIRMWARE_VERSION` reply reports.
#[repr(C)]
pub struct FfiLedgerAppVersion {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
    /// Whether this version has the PCZT instructions, and so can sign.
    pub supports_pczt: bool,
}

/// Returns the `GET_FIRMWARE_VERSION` command.
///
/// Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_firmware_version_apdu() -> *mut ffi::BoxedSlice {
    ffi::BoxedSlice::some(pairing::firmware_version_apdu())
}

/// Parses a `GET_FIRMWARE_VERSION` reply (data plus status word).
///
/// Returns null with the last error set on failure; a `0x6901` refusal is reported as
/// [`LedgerErrorKind::CmdNotAccepted`], for the caller to resend.
///
/// # Safety
///
/// - `reply` must be valid for reads for `reply_len` bytes (or `reply_len` must be zero).
/// - Call [`zcashlc_ledger_free_app_version`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_parse_app_version(
    reply: *const u8,
    reply_len: usize,
) -> *mut FfiLedgerAppVersion {
    let res = catch_panic(|| {
        let reply = unsafe { bytes(reply, reply_len)? };
        let version =
            pairing::parse_firmware_version_response(reply).map_err(|e| pairing_error(&e))?;
        let caps = DeviceCaps::from_version(version.major(), version.minor(), version.patch());
        Ok(Box::into_raw(Box::new(FfiLedgerAppVersion {
            major: version.major(),
            minor: version.minor(),
            patch: version.patch(),
            supports_pczt: caps.pczt(),
        })))
    });
    crate::unwrap_exc_or_null(res)
}

/// Frees an [`FfiLedgerAppVersion`].
///
/// # Safety
///
/// - `ptr` must be null, or a pointer returned by [`zcashlc_ledger_parse_app_version`] that has
///   not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_app_version(ptr: *mut FfiLedgerAppVersion) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr) });
    }
}

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------

/// Returns the silent `GET_WALLET_PUBLIC_KEY` command that identifies the connected device on
/// `network_id`.
///
/// Returns null with the last error set for a network no Ledger app build exists for.
///
/// Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_device_identity_apdu(network_id: u32) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let apdu = pairing::device_identity_apdu(network).map_err(|e| pairing_error(&e))?;
        Ok(ffi::BoxedSlice::some(apdu))
    });
    crate::unwrap_exc_or_null(res)
}

/// Parses the reply to [`zcashlc_ledger_device_identity_apdu`] into the device's `tpk0-…`
/// identity string.
///
/// The string identifies the device's first transparent address to anyone who can see the chain:
/// store it, never log it.
///
/// Returns null with the last error set on failure.
///
/// # Safety
///
/// - `reply` must be valid for reads for `reply_len` bytes (or `reply_len` must be zero).
/// - Call [`zcashlc_string_free`] to free the returned string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_parse_device_identity(
    reply: *const u8,
    reply_len: usize,
) -> *mut c_char {
    let res = catch_panic(|| {
        let reply = unsafe { bytes(reply, reply_len)? };
        let identity =
            pairing::parse_device_identity_response(reply).map_err(|e| pairing_error(&e))?;
        Ok(CString::new(identity.to_string())
            .expect("an identity string is ASCII")
            .into_raw())
    });
    crate::unwrap_exc_or_null(res)
}

/// Returns whether `identity` is a well-formed `tpk0-<64 lowercase hex>` device identity.
///
/// Returns `false` with the last error set ([`LedgerErrorKind::InvalidInput`]) otherwise; the
/// error's reason never repeats the value.
///
/// # Safety
///
/// - `identity` must be a non-null pointer to a null-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_validate_device_identity(identity: *const c_char) -> bool {
    let res = catch_panic(|| {
        parse_identity(identity)?;
        Ok(true)
    });
    crate::unwrap_exc_or(res, false)
}

/// Parses a device identity passed across the FFI.
fn parse_identity(identity: *const c_char) -> Result<DeviceIdentity, LedgerError> {
    if identity.is_null() {
        return Err(LedgerError::invalid_input(
            "no Ledger device identity was supplied",
        ));
    }
    let identity = unsafe { CStr::from_ptr(identity) }
        .to_str()
        .map_err(|_| LedgerError::invalid_input("the Ledger device identity is not UTF-8"))?;
    DeviceIdentity::parse(identity).map_err(|e| identity_error(&e))
}

// ---------------------------------------------------------------------------
// Unified full viewing key export
// ---------------------------------------------------------------------------

/// An in-progress `GET_VK` export of one account's unified full viewing key.
///
/// The exchange is terminal on any error but `0x6901`: once it has failed, it hands out no further
/// command, so a caller cannot put the export approval screen back in front of a user who declined
/// it.
pub struct FfiLedgerUfvkExport {
    inner: Mutex<VkExchange>,
}

/// Starts a unified full viewing key export for ZIP 32 account `account_index` on `network_id`.
///
/// Returns null with the last error set for an unsupported network or an account index at or
/// above `2^31`.
///
/// Call [`zcashlc_ledger_free_ufvk_export`] to free the returned handle.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_ufvk_export_new(
    network_id: u32,
    account_index: u32,
) -> *mut FfiLedgerUfvkExport {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let account = ledger_account(account_index)?;
        let exchange = VkExchange::ufvk(network, account).map_err(|e| pairing_error(&e))?;
        Ok(Box::into_raw(Box::new(FfiLedgerUfvkExport {
            inner: Mutex::new(exchange),
        })))
    });
    crate::unwrap_exc_or_null(res)
}

/// Returns the next command of the export: the request, a continuation, or the same command again
/// after a `0x6901`.
///
/// Returns null with the last error set once the export has completed or failed.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_ufvk_export_new`].
/// - Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ufvk_export_next_apdu(
    handle: *mut FfiLedgerUfvkExport,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(AssertUnwindSafe(|| {
        let export = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger export handle was passed"))?;
        let mut exchange = lock(&export.inner)?;
        let apdu = exchange.next_apdu().ok_or_else(|| {
            LedgerError::internal("the Ledger viewing key export has no further command to send")
        })?;
        Ok(ffi::BoxedSlice::some(apdu))
    }));
    crate::unwrap_exc_or_null(res)
}

/// Returns whether the reply to the next command waits on the user: `true` until the device has
/// answered the request that shows the export approval screen.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_ufvk_export_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ufvk_export_waits_for_user(
    handle: *mut FfiLedgerUfvkExport,
) -> bool {
    let res = catch_panic(AssertUnwindSafe(|| {
        let export = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger export handle was passed"))?;
        Ok(lock(&export.inner)?.next_deadline() == Deadline::UserReview)
    }));
    crate::unwrap_exc_or(res, true)
}

/// [`FfiLedgerUfvkExportStep::status`]: absorbed, and a continuation follows.
pub const ZCASHLC_LEDGER_UFVK_EXPORT_MORE_CHUNKS: u32 = 0;
/// [`FfiLedgerUfvkExportStep::status`]: `0x6901`; resend the same command after the backoff.
pub const ZCASHLC_LEDGER_UFVK_EXPORT_RETRY_SAME_APDU: u32 = 1;
/// [`FfiLedgerUfvkExportStep::status`]: complete; `ufvk` holds the key.
pub const ZCASHLC_LEDGER_UFVK_EXPORT_COMPLETE: u32 = 2;

/// What one reply did to a unified full viewing key export.
///
/// # Safety
///
/// - Free the value with [`zcashlc_ledger_free_ufvk_export_step`], which releases `ufvk` with it.
#[repr(C)]
pub struct FfiLedgerUfvkExportStep {
    /// One of the `ZCASHLC_LEDGER_UFVK_EXPORT_*` constants.
    pub status: u32,
    /// The encoded unified full viewing key when `status` is
    /// [`ZCASHLC_LEDGER_UFVK_EXPORT_COMPLETE`], and null otherwise. The device has already checked
    /// that it decodes for the requested network.
    pub ufvk: *mut c_char,
}

/// Absorbs the reply (data plus status word) to the command last handed out.
///
/// Returns null with the last error set on failure, after which the export is dead.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_ufvk_export_new`].
/// - `reply` must be valid for reads for `reply_len` bytes (or `reply_len` must be zero).
/// - Call [`zcashlc_ledger_free_ufvk_export_step`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ufvk_export_process_response(
    handle: *mut FfiLedgerUfvkExport,
    reply: *const u8,
    reply_len: usize,
) -> *mut FfiLedgerUfvkExportStep {
    let res = catch_panic(AssertUnwindSafe(|| {
        let export = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger export handle was passed"))?;
        let reply = unsafe { bytes(reply, reply_len)? };
        let mut exchange = lock(&export.inner)?;
        let (status, ufvk) = match exchange.process_response(reply) {
            Ok(VkStep::MoreChunks) => (ZCASHLC_LEDGER_UFVK_EXPORT_MORE_CHUNKS, ptr::null_mut()),
            Ok(VkStep::RetrySameApdu) => {
                (ZCASHLC_LEDGER_UFVK_EXPORT_RETRY_SAME_APDU, ptr::null_mut())
            }
            Ok(VkStep::Complete(pairing_response)) => match pairing_response {
                pczt_ledger::apdu::decode::VkResponse::Ufvk(encoded) => (
                    ZCASHLC_LEDGER_UFVK_EXPORT_COMPLETE,
                    CString::new(encoded)
                        .map_err(|_| {
                            LedgerError::new(
                                LedgerErrorKind::MalformedReply,
                                "the exported viewing key contains a NUL byte",
                            )
                        })?
                        .into_raw(),
                ),
                mut other => {
                    other.zeroize();
                    return Err(LedgerError::internal(
                        "a unified viewing key export completed with another key kind",
                    )
                    .into());
                }
            },
            Err(e) => return Err(pairing_error(&e).into()),
        };
        Ok(Box::into_raw(Box::new(FfiLedgerUfvkExportStep {
            status,
            ufvk,
        })))
    }));
    crate::unwrap_exc_or_null(res)
}

/// Frees an [`FfiLedgerUfvkExportStep`], wiping the viewing key it carries.
///
/// # Safety
///
/// - `ptr` must be null, or a pointer returned by
///   [`zcashlc_ledger_ufvk_export_process_response`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_ufvk_export_step(ptr: *mut FfiLedgerUfvkExportStep) {
    if !ptr.is_null() {
        let step = unsafe { Box::from_raw(ptr) };
        if !step.ufvk.is_null() {
            let mut bytes = unsafe { CString::from_raw(step.ufvk) }.into_bytes();
            bytes.zeroize();
        }
    }
}

/// Frees an [`FfiLedgerUfvkExport`].
///
/// # Safety
///
/// - `handle` must be null, or a pointer returned by [`zcashlc_ledger_ufvk_export_new`] that has
///   not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_ufvk_export(handle: *mut FfiLedgerUfvkExport) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

// ---------------------------------------------------------------------------
// Unified address display
// ---------------------------------------------------------------------------

/// Returns the `GET_SHIELD_ADDR` command for account `account_index`'s unified address.
///
/// With `display` set, the device shows the address (and the transparent address at
/// `transparent_address_index`) for the user to confirm before it replies. The reply only ever
/// carries the account's Orchard receiver at diversifier index 0, whatever
/// `transparent_address_index` is; see [`zcashlc_ledger_parse_unified_address`].
///
/// Returns null with the last error set for an unsupported network, an account index above 100, or
/// an address index above 50000 — the bounds the device enforces on the transparent path.
///
/// Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_unified_address_apdu(
    network_id: u32,
    account_index: u32,
    transparent_address_index: u32,
    display: bool,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let account = ledger_account(account_index)?;
        let index =
            NonHardenedChildIndex::from_index(transparent_address_index).ok_or_else(|| {
                LedgerError::invalid_input("the transparent address index must be below 2^31")
            })?;
        let apdu = pairing::unified_address_apdu(network, account, index, display)
            .map_err(|e| pairing_error(&e))?;
        Ok(ffi::BoxedSlice::some(apdu))
    });
    crate::unwrap_exc_or_null(res)
}

/// Parses a `GET_SHIELD_ADDR` unified-address reply into the encoded address.
///
/// The address holds the account's Orchard receiver at diversifier index 0 and nothing else. A
/// wallet verifying it compares it with the string [`zcashlc_ledger_device_unified_address`]
/// returns for the account's viewing key; the account's default unified address also carries a
/// transparent receiver and never matches.
///
/// Returns null with the last error set on failure; a declined display is
/// [`LedgerErrorKind::UserRejected`].
///
/// # Safety
///
/// - `reply` must be valid for reads for `reply_len` bytes (or `reply_len` must be zero).
/// - Call [`zcashlc_string_free`] to free the returned string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_parse_unified_address(
    reply: *const u8,
    reply_len: usize,
    network_id: u32,
) -> *mut c_char {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let reply = unsafe { bytes(reply, reply_len)? };
        let address =
            pairing::parse_unified_address(reply, network).map_err(|e| pairing_error(&e))?;
        let encoded = address.encode(&network.network_type());
        Ok(CString::new(encoded)
            .expect("a Bech32m string has no NUL byte")
            .into_raw())
    });
    crate::unwrap_exc_or_null(res)
}

// ---------------------------------------------------------------------------
// Pairing checks
// ---------------------------------------------------------------------------

/// Decodes a unified full viewing key passed across the FFI, for the Ledger network `network`.
///
/// The error never repeats the value.
fn parse_ufvk(
    ufvk: *const c_char,
    network: pczt_ledger::Network,
) -> Result<UnifiedFullViewingKey, LedgerError> {
    if ufvk.is_null() {
        return Err(LedgerError::invalid_input(
            "no unified full viewing key was supplied",
        ));
    }
    let encoded = unsafe { CStr::from_ptr(ufvk) }
        .to_str()
        .map_err(|_| LedgerError::invalid_input("the unified full viewing key is not UTF-8"))?;
    let (found, _revision, container) = unified::Ufvk::decode(encoded)
        .map_err(|_| LedgerError::invalid_input("the value is not a unified full viewing key"))?;
    if found != network.network_type() {
        return Err(LedgerError::invalid_input(
            "the unified full viewing key is for another network",
        ));
    }
    UnifiedFullViewingKey::parse(&container).map_err(|_| {
        LedgerError::invalid_input("the unified full viewing key holds an invalid item")
    })
}

/// The device identity that the transparent key in `ufvk` derives, when `ufvk` belongs to ZIP 32
/// account 0.
///
/// The identity is the hash of the public key at `m/44'/coin'/0'/0/0`. That is account 0's
/// external transparent key at index 0, so only the key of account 0 derives it.
fn account_zero_identity(ufvk: &UnifiedFullViewingKey) -> Result<DeviceIdentity, LedgerError> {
    // The Zcash app always exports a P2PKH item next to the Orchard item, so a key without one
    // is not what the device sent.
    let account_key = ufvk.p2pkh().ok_or_else(|| {
        LedgerError::new(
            LedgerErrorKind::MalformedReply,
            "the exported viewing key has no transparent item",
        )
    })?;
    let pubkey = account_key
        .derive_address_pubkey(TransparentKeyScope::EXTERNAL, NonHardenedChildIndex::ZERO)
        .map_err(|_| {
            LedgerError::new(
                LedgerErrorKind::MalformedReply,
                "the exported transparent key does not derive its first address",
            )
        })?;
    Ok(DeviceIdentity::from_compressed_pubkey(&pubkey.serialize()))
}

/// Checks that the unified full viewing key `ufvk` of ZIP 32 account 0 belongs to the device whose
/// identity is `identity`.
///
/// The check derives the public key at `m/44'/coin'/0'/0/0` from the transparent item of `ufvk`,
/// hashes it into a device identity, and compares that with `identity`. Use it only for account 0:
/// the key of any other account never derives the identity.
///
/// Returns `true` when the two match. Returns `false` with the last error set otherwise:
/// [`LedgerErrorKind::DeviceMismatch`] when the identities differ,
/// [`LedgerErrorKind::MalformedReply`] when `ufvk` has no transparent item, and
/// [`LedgerErrorKind::InvalidInput`] when `ufvk` or `identity` does not parse or `ufvk` is for
/// another network. No error repeats a value.
///
/// # Safety
///
/// - `ufvk` must be a non-null pointer to a null-terminated string.
/// - `identity` must be a non-null pointer to a null-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_check_account_zero_identity(
    network_id: u32,
    ufvk: *const c_char,
    identity: *const c_char,
) -> bool {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let expected = parse_identity(identity)?;
        let ufvk = parse_ufvk(ufvk, network)?;
        if account_zero_identity(&ufvk)? == expected {
            Ok(true)
        } else {
            Err(LedgerError::new(
                LedgerErrorKind::DeviceMismatch,
                "the exported viewing key does not belong to the device that was identified",
            )
            .into())
        }
    });
    crate::unwrap_exc_or(res, false)
}

/// The unified address the device displays for the account whose viewing key is `ufvk`: the
/// external Orchard receiver at diversifier index 0, alone, in the revision the device encodes.
fn device_unified_address(
    ufvk: &UnifiedFullViewingKey,
    network: pczt_ledger::Network,
) -> Result<String, LedgerError> {
    let fvk = ufvk.orchard().ok_or_else(|| {
        LedgerError::invalid_input("the unified full viewing key has no Orchard item")
    })?;
    let receiver = fvk
        .address_at(0u32, orchard::keys::Scope::External)
        .to_raw_address_bytes();
    let address = unified::Address::try_from_items(
        pairing::DEVICE_UNIFIED_REVISION,
        vec![unified::Uitem::Data(unified::Receiver::Orchard(receiver))],
    )
    .map_err(|_| LedgerError::internal("the Orchard receiver does not form a unified address"))?;
    Ok(address.encode(&network.network_type()))
}

/// Returns the unified address a Ledger device displays for the account whose unified full viewing
/// key is `ufvk`, on `network_id`.
///
/// The address holds only the external Orchard receiver at diversifier index 0. It is encoded
/// exactly as [`zcashlc_ledger_parse_unified_address`] encodes the device's reply, so the two
/// strings are equal when the device shows the address of this key. Show this address to the user
/// to compare with the device screen.
///
/// Returns null with the last error set ([`LedgerErrorKind::InvalidInput`]) when `ufvk` does not
/// parse, is for another network, or has no Orchard item.
///
/// # Safety
///
/// - `ufvk` must be a non-null pointer to a null-terminated string.
/// - Call [`zcashlc_string_free`] to free the returned string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_device_unified_address(
    network_id: u32,
    ufvk: *const c_char,
) -> *mut c_char {
    let res = catch_panic(|| {
        let network = ledger_network(network_id)?;
        let ufvk = parse_ufvk(ufvk, network)?;
        let encoded = device_unified_address(&ufvk, network)?;
        let encoded = CString::new(encoded).map_err(|_| {
            LedgerError::internal("the encoded unified address contains a NUL byte")
        })?;
        Ok(encoded.into_raw())
    });
    crate::unwrap_exc_or_null(res)
}

// ---------------------------------------------------------------------------
// BLE framing
// ---------------------------------------------------------------------------

/// Returns the BLE MTU-handshake request, written before any APDU on a new connection.
///
/// Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_ble_mtu_request() -> *mut ffi::BoxedSlice {
    ffi::BoxedSlice::some(framing::ble_mtu_request().to_vec())
}

/// Parses the BLE MTU-handshake response into the negotiated frame size.
///
/// Returns the frame size, or `-1` with the last error set for a malformed response.
///
/// # Safety
///
/// - `response` must be valid for reads for `response_len` bytes (or `response_len` must be zero).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_parse_ble_mtu_response(
    response: *const u8,
    response_len: usize,
) -> i32 {
    let res = catch_panic(|| {
        let response = unsafe { bytes(response, response_len)? };
        let size = framing::parse_ble_mtu_response(response).map_err(|e| framing_error(&e))?;
        i32::try_from(size.get()).map_err(|_| {
            LedgerError::internal("the negotiated frame size does not fit in i32").into()
        })
    });
    crate::unwrap_exc_or(res, -1)
}

/// One BLE frame.
#[repr(C)]
pub struct FfiLedgerFrame {
    pub ptr: *mut u8,
    pub len: usize,
}

/// The BLE frames of one APDU, to be written in order.
///
/// # Safety
///
/// - Free the value with [`zcashlc_ledger_free_frames`], which wipes and releases every frame.
#[repr(C)]
pub struct FfiLedgerFrames {
    pub ptr: *mut FfiLedgerFrame,
    pub len: usize,
}

/// Splits an APDU into BLE frames of at most `frame_size` bytes.
///
/// Returns null with the last error set for a frame size the handshake could not have negotiated.
///
/// # Safety
///
/// - `apdu` must be valid for reads for `apdu_len` bytes (or `apdu_len` must be zero).
/// - Call [`zcashlc_ledger_free_frames`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ble_frames(
    apdu: *const u8,
    apdu_len: usize,
    frame_size: u32,
) -> *mut FfiLedgerFrames {
    let res = catch_panic(|| {
        let apdu = unsafe { bytes(apdu, apdu_len)? };
        let frame_size = usize::try_from(frame_size)
            .map_err(|_| LedgerError::invalid_input("the BLE frame size does not fit in usize"))
            .and_then(|size| BleFrameSize::new(size).map_err(|e| framing_error(&e)))?;
        let frames = framing::ble_frames(apdu, frame_size).map_err(|e| framing_error(&e))?;
        let frames = frames
            .into_iter()
            .map(|frame| {
                let (ptr, len) = ptr_from_vec(frame);
                FfiLedgerFrame { ptr, len }
            })
            .collect::<Vec<_>>();
        let (ptr, len) = ptr_from_vec(frames);
        Ok(Box::into_raw(Box::new(FfiLedgerFrames { ptr, len })))
    });
    crate::unwrap_exc_or_null(res)
}

/// Frees an [`FfiLedgerFrames`], wiping every frame: a frame carries the command's payload.
///
/// # Safety
///
/// - `ptr` must be null, or a pointer returned by [`zcashlc_ledger_ble_frames`] that has not been
///   freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_frames(ptr: *mut FfiLedgerFrames) {
    if !ptr.is_null() {
        let frames = unsafe { Box::from_raw(ptr) };
        crate::free_ptr_from_vec_with(frames.ptr, frames.len, |frame| {
            if !frame.ptr.is_null() {
                unsafe { slice::from_raw_parts_mut(frame.ptr, frame.len) }.zeroize();
            }
            free_ptr_from_vec(frame.ptr, frame.len);
        });
    }
}

/// A reassembler for the notifications of one BLE reply.
pub struct FfiLedgerBleDeframer {
    inner: Mutex<Deframer>,
}

/// Returns a new BLE deframer.
///
/// Call [`zcashlc_ledger_free_ble_deframer`] to free the returned handle.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ledger_ble_deframer_new() -> *mut FfiLedgerBleDeframer {
    Box::into_raw(Box::new(FfiLedgerBleDeframer {
        inner: Mutex::new(Deframer::ble()),
    }))
}

/// Absorbs one notification frame.
///
/// Returns a boxed slice whose pointer is null (length zero) while more frames are expected, and
/// the complete reply — data plus status word — on the frame that finishes it. Returns null with
/// the last error set when the frame is refused, after which the deframer stays refused: the
/// caller closes the connection rather than resetting it.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_ble_deframer_new`].
/// - `frame` must be valid for reads for `frame_len` bytes (or `frame_len` must be zero).
/// - Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ble_deframer_push(
    handle: *mut FfiLedgerBleDeframer,
    frame: *const u8,
    frame_len: usize,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(AssertUnwindSafe(|| {
        let deframer = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger deframer handle was passed"))?;
        let frame = unsafe { bytes(frame, frame_len)? };
        let mut inner = lock(&deframer.inner)?;
        match inner.push(frame).map_err(|e| framing_error(&e))? {
            Some(reply) => Ok(ffi::BoxedSlice::some(reply)),
            None => Ok(ffi::BoxedSlice::none()),
        }
    }));
    crate::unwrap_exc_or_null(res)
}

/// Drops any partial reply. Only for a deframer being reused after a reply completed; a refused
/// frame is answered by closing the connection, not by a reset.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_ble_deframer_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_ble_deframer_reset(handle: *mut FfiLedgerBleDeframer) {
    if let Some(deframer) = unsafe { handle.as_ref() }
        && let Ok(mut inner) = deframer.inner.lock()
    {
        inner.reset();
    }
}

/// Frees an [`FfiLedgerBleDeframer`], wiping any partial reply.
///
/// # Safety
///
/// - `handle` must be null, or a pointer returned by [`zcashlc_ledger_ble_deframer_new`] that has
///   not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_ble_deframer(handle: *mut FfiLedgerBleDeframer) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

// ---------------------------------------------------------------------------
// Signing session
// ---------------------------------------------------------------------------

/// A PCZT signing ceremony against one paired Ledger.
pub struct FfiLedgerSignSession {
    inner: Mutex<SessionState>,
}

/// The session plus the progress counters the platform layer reports.
pub(crate) struct SessionState {
    session: LedgerSignSession,
    /// The number of APDUs that stream the transaction to the device.
    stream_total: u32,
    /// How many of them the device has acknowledged.
    stream_acknowledged: u32,
}

/// What the session needs from the wallet, gathered before the PCZT is touched.
pub(crate) struct SessionInputs {
    pub(crate) network: pczt_ledger::Network,
    pub(crate) device: DeviceIdentity,
    pub(crate) zip32_account: AccountId,
    /// The account's ZIP 32 seed fingerprint, when the wallet knows its derivation. A Ledger
    /// account imported by viewing key has none.
    pub(crate) seed_fingerprint: Option<[u8; 32]>,
    pub(crate) orchard_fvk: Option<orchard::keys::FullViewingKey>,
    pub(crate) transparent_key: Option<AccountPubKey>,
    pub(crate) caps: DeviceCaps,
}

/// The wallet's knowledge of one transparent address of the account: `Some((scope, index))` when
/// the account derived it.
pub(crate) type AddressLookup<'a> = dyn Fn(
        &TransparentAddress,
    ) -> Result<Option<(TransparentKeyScope, NonHardenedChildIndex)>, LedgerError>
    + 'a;

/// The BIP 44 change-level component a derived scope occupies in a path, for the scopes a wallet
/// derives addresses under.
fn scope_component(scope: TransparentKeyScope) -> Option<u32> {
    if scope == TransparentKeyScope::EXTERNAL {
        Some(0)
    } else if scope == TransparentKeyScope::INTERNAL {
        Some(TRANSPARENT_INTERNAL_SCOPE)
    } else if scope == TransparentKeyScope::EPHEMERAL {
        Some(2)
    } else {
        None
    }
}

/// Stamps a BIP 44 `bip32_derivation` on every transparent input that carries none and pays one of
/// the account's derived addresses.
///
/// `zcash_client_backend`'s `create_pczt_from_proposal` stamps input derivations only for an
/// account with a known ZIP 32 derivation, and a Ledger account imported by viewing key has none,
/// so its inputs arrive bare and the device would have no path to sign them at. The derivation is
/// the one that backend writes for a derived account — the account's own path, keyed by the pubkey
/// the account's transparent key derives there — with the seed fingerprint the session shapes
/// every other record with. The session then checks each stamped path against the pubkey and the
/// pubkey against the input's script, exactly as it does for a derivation the backend wrote.
fn stamp_transparent_input_derivations(
    pczt: Pczt,
    inputs: &SessionInputs,
    lookup: &AddressLookup<'_>,
) -> Result<Pczt, LedgerError> {
    let Some(transparent_key) = inputs.transparent_key.as_ref() else {
        return Ok(pczt);
    };
    let scripts = pczt
        .transparent()
        .inputs()
        .iter()
        .map(|input| input.script_pubkey().clone())
        .collect::<Vec<_>>();
    if scripts.is_empty() {
        return Ok(pczt);
    }

    let mut bare = BTreeSet::new();
    let updater = Updater::new(pczt)
        .update_transparent_with(|updater| {
            for (index, input) in updater.bundle().inputs().iter().enumerate() {
                if input.bip32_derivation().is_empty() {
                    bare.insert(index);
                }
            }
            Ok(())
        })
        .map_err(|e| LedgerError::internal(format!("reading the transparent inputs: {e:?}")))?;

    let fingerprint = inputs.seed_fingerprint.unwrap_or([0u8; 32]);
    let mut stamps = Vec::new();
    for index in bare {
        let Some(hash) = shape::p2pkh_hash(&scripts[index]) else {
            continue;
        };
        let Some((scope, address_index)) = lookup(&TransparentAddress::PublicKeyHash(hash))? else {
            continue;
        };
        let Some(scope_component) = scope_component(scope) else {
            continue;
        };
        let pubkey = transparent_key
            .derive_address_pubkey(scope, address_index)
            .map_err(|_| {
                LedgerError::not_signable(format!(
                    "the account's transparent key cannot derive the key for transparent input \
                     {index}"
                ))
            })?
            .serialize();
        let path = vec![
            BIP44_PURPOSE | HARDENED,
            inputs.network.coin_type() | HARDENED,
            u32::from(inputs.zip32_account) | HARDENED,
            scope_component,
            address_index.index(),
        ];
        let derivation = transparent::pczt::Bip32Derivation::parse(fingerprint, path)
            .map_err(|e| LedgerError::internal(format!("building an input derivation: {e:?}")))?;
        stamps.push((index, pubkey, derivation));
    }

    if stamps.is_empty() {
        return Ok(updater.finish());
    }

    updater
        .update_transparent_with(|mut updater| {
            for (index, pubkey, derivation) in stamps {
                updater.update_input_with(index, |mut input| {
                    input.set_bip32_derivation(pubkey, derivation);
                    Ok(())
                })?;
            }
            Ok(())
        })
        .map(Updater::finish)
        .map_err(|e| LedgerError::internal(format!("stamping the transparent inputs: {e:?}")))
}

/// The transparent change output, if exactly one output pays an internal-scope (change) address
/// of the account.
///
/// The SDK's proposals return change to a shielded pool, so a PCZT it builds carries no
/// transparent change today; the lookup still runs, since a transaction that does carry change
/// must say so or the device shows the wallet's own change address as a recipient.
fn transparent_change(
    pczt: &Pczt,
    inputs: &SessionInputs,
    lookup: &AddressLookup<'_>,
) -> Result<Option<ChangeInfo>, LedgerError> {
    let Some(transparent_key) = inputs.transparent_key.as_ref() else {
        return Ok(None);
    };
    let mut change = Vec::new();
    for (output_index, output) in pczt.transparent().outputs().iter().enumerate() {
        let Some(hash) = shape::p2pkh_hash(output.script_pubkey()) else {
            continue;
        };
        if let Some((scope, address_index)) = lookup(&TransparentAddress::PublicKeyHash(hash))?
            && scope == TransparentKeyScope::INTERNAL
        {
            change.push((output_index, address_index, output.script_pubkey()));
        }
    }

    match change.as_slice() {
        [(output_index, address_index, script)] => ChangeInfo::derive(
            transparent_key,
            TRANSPARENT_INTERNAL_SCOPE,
            *address_index,
            *output_index,
            script,
        )
        .map(Some)
        .map_err(|e| LedgerError::not_signable(e.to_string())),
        _ => Ok(None),
    }
}

/// Builds a signing session: stamps the transparent input derivations the account's wallet did
/// not, redacts the PCZT to the full signer view, finds the transparent change output, and hands
/// the result to [`LedgerSignSession::new_from_pczt`], which runs every pre-flight check before a
/// single APDU exists.
pub(crate) fn build_session(
    pczt: Pczt,
    inputs: SessionInputs,
    lookup: &AddressLookup<'_>,
) -> Result<SessionState, LedgerError> {
    if !inputs.caps.pczt() {
        let (major, minor, patch) = inputs.caps.version();
        return Err(LedgerError::new(
            LedgerErrorKind::AppTooOld,
            format!(
                "the Zcash app on the device is v{major}.{minor}.{patch}, which predates PCZT \
                 signing"
            ),
        ));
    }
    let Some(orchard_fvk) = inputs.orchard_fvk.clone() else {
        return Err(LedgerError::not_signable(
            "the account's viewing key has no Orchard component, which every Ledger account has",
        ));
    };

    let pczt = stamp_transparent_input_derivations(pczt, &inputs, lookup)?;
    let pczt =
        zcash_client_backend::data_api::wallet::redact_pczt_for_signer(&pczt, SignerView::Full);
    let change = transparent_change(&pczt, &inputs, lookup)?;

    let params = SessionParams::new(inputs.network, inputs.device, inputs.zip32_account)
        .with_seed_fingerprint(inputs.seed_fingerprint)
        .with_change(change)
        .with_viewing_keys(Some(AccountViewingKeys::from_orchard_fvk(orchard_fvk)))
        .with_transparent_account_key(
            inputs
                .transparent_key
                .clone()
                .map(TransparentAccountKey::from_account_pubkey),
        );

    let session = LedgerSignSession::new_from_pczt(pczt, inputs.caps, params)
        .map_err(|e| session_error(&e, false))?;
    let stream_total = session
        .plan()
        .stream()
        .to_apdus()
        .map(|apdus| u32::try_from(apdus.len()).unwrap_or(u32::MAX))
        .map_err(|_| LedgerError::internal("the session's stream could not be counted"))?;

    Ok(SessionState {
        session,
        stream_total,
        stream_acknowledged: 0,
    })
}

/// Creates a signing session for `pczt` against the paired Ledger.
///
/// Parameters:
/// - `db_data`/`db_data_len`: the wallet database path.
/// - `network_id`: the wallet's network; regtest is refused.
/// - `account_uuid_bytes`: the 16-byte uuid of the account the PCZT spends from.
/// - `pczt_ptr`/`pczt_len`: the PCZT `zcashlc_create_pczt_from_proposal` returned. It is redacted
///   to the full signer view here, so the caller passes it unredacted and keeps it for proving.
/// - `device_identity`: the `tpk0-…` identity stored when the account was paired.
/// - `zip32_account_index`: the Ledger account index stored when the account was paired.
/// - `firmware_reply`/`firmware_reply_len`: the connected device's `GET_FIRMWARE_VERSION` reply.
///   The session re-reads the version before streaming and refuses a device that answers
///   differently.
///
/// Returns null with the last error set when the account cannot be used or the transaction cannot
/// be signed by the device; nothing is sent in that case.
///
/// # Safety
///
/// - `db_data` must be non-null and valid for reads for `db_data_len` bytes.
/// - `account_uuid_bytes` must be non-null and valid for reads for 16 bytes.
/// - `pczt_ptr` must be non-null and valid for reads for `pczt_len` bytes.
/// - `device_identity` must be a non-null pointer to a null-terminated string.
/// - `firmware_reply` must be valid for reads for `firmware_reply_len` bytes (or
///   `firmware_reply_len` must be zero).
/// - None of the memory may be mutated for the duration of the call.
/// - Call [`zcashlc_ledger_free_sign_session`] to free the returned handle.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn zcashlc_ledger_sign_session_new(
    db_data: *const u8,
    db_data_len: usize,
    network_id: u32,
    account_uuid_bytes: *const u8,
    pczt_ptr: *const u8,
    pczt_len: usize,
    device_identity: *const c_char,
    zip32_account_index: u32,
    firmware_reply: *const u8,
    firmware_reply_len: usize,
) -> *mut FfiLedgerSignSession {
    let res = catch_panic(|| {
        let network_params = parse_network(network_id)?;
        let network = ledger_network(network_id)?;
        let device = parse_identity(device_identity)?;
        let zip32_account = ledger_account(zip32_account_index)?;
        let firmware_reply = unsafe { bytes(firmware_reply, firmware_reply_len)? };
        let caps = pairing::device_caps(firmware_reply).map_err(|e| pairing_error(&e))?;

        let db_data =
            unsafe { wallet_db(crate::system_rng(), db_data, db_data_len, network_params)? };
        let account_uuid = account_uuid_from_bytes(account_uuid_bytes)?;
        let account = db_data
            .get_account(account_uuid)?
            .ok_or_else(|| LedgerError::invalid_input("the account is not in this wallet"))?;
        let ufvk = account.ufvk().ok_or_else(|| {
            LedgerError::not_signable("the account has no unified full viewing key")
        })?;
        let derivation = account.source().key_derivation();
        if let Some(derivation) = derivation
            && derivation.account_index() != zip32_account
        {
            return Err(LedgerError::invalid_input(
                "the paired Ledger account index is not the account's own ZIP 32 index",
            )
            .into());
        }

        let pczt_bytes = unsafe { bytes(pczt_ptr, pczt_len)? };
        let pczt = Pczt::parse(pczt_bytes)
            .map_err(|_| LedgerError::invalid_input("the PCZT could not be parsed"))?;

        let inputs = SessionInputs {
            network,
            device,
            zip32_account,
            seed_fingerprint: derivation.map(|d| d.seed_fingerprint().to_bytes()),
            orchard_fvk: ufvk.orchard().cloned(),
            transparent_key: ufvk.transparent().cloned(),
            caps,
        };
        let lookup = |address: &TransparentAddress| {
            db_data
                .get_transparent_address_metadata(account_uuid, address)
                .map(|metadata| metadata.and_then(|m| Some((m.scope()?, m.address_index()?))))
                .map_err(|_| {
                    LedgerError::internal("the wallet database could not look up an address")
                })
        };
        let state = build_session(pczt, inputs, &lookup)?;

        Ok(Box::into_raw(Box::new(FfiLedgerSignSession {
            inner: Mutex::new(state),
        })))
    });
    crate::unwrap_exc_or_null(res)
}

/// [`FfiLedgerSignStep::kind`]: send `apdu` and hand the reply to
/// [`zcashlc_ledger_sign_session_process_response`].
pub const ZCASHLC_LEDGER_SIGN_STEP_SEND: u32 = 0;
/// [`FfiLedgerSignStep::kind`]: a command is outstanding; its reply has not been processed.
pub const ZCASHLC_LEDGER_SIGN_STEP_AWAITING_REPLY: u32 = 1;
/// [`FfiLedgerSignStep::kind`]: nothing more will be sent; the session is complete or failed.
pub const ZCASHLC_LEDGER_SIGN_STEP_DONE: u32 = 2;

/// The next thing a signing session asks of the transport.
///
/// # Safety
///
/// - Free the value with [`zcashlc_ledger_free_sign_step`], which wipes and releases `apdu`.
#[repr(C)]
pub struct FfiLedgerSignStep {
    /// One of the `ZCASHLC_LEDGER_SIGN_STEP_*` constants.
    pub kind: u32,
    /// The command to send when `kind` is [`ZCASHLC_LEDGER_SIGN_STEP_SEND`], and null otherwise.
    /// It carries the transaction's per-action secrets: never log it.
    pub apdu: *mut u8,
    pub apdu_len: usize,
    /// Whether the reply to `apdu` may wait on the user, so that no timeout applies to it.
    pub waits_for_user: bool,
    /// Whether `apdu` is the packet that opens the on-device review, reported once.
    pub starts_review: bool,
    /// A `ZCASHLC_LEDGER_STAGE_*` constant: where the ceremony is.
    pub stage: u32,
    /// How many transaction-streaming commands the device has acknowledged.
    pub stream_acknowledged: u32,
    /// How many transaction-streaming commands there are.
    pub stream_total: u32,
}

/// Stage: confirming the connected device's app version and identity.
pub const ZCASHLC_LEDGER_STAGE_IDENTIFYING_DEVICE: u32 = 0;
/// Stage: streaming the transaction.
pub const ZCASHLC_LEDGER_STAGE_STREAMING: u32 = 1;
/// Stage: collecting Orchard signatures.
pub const ZCASHLC_LEDGER_STAGE_SIGNING_ORCHARD: u32 = 2;
/// Stage: collecting Ironwood signatures.
pub const ZCASHLC_LEDGER_STAGE_SIGNING_IRONWOOD: u32 = 3;
/// Stage: collecting transparent signatures.
pub const ZCASHLC_LEDGER_STAGE_SIGNING_TRANSPARENT: u32 = 4;
/// Stage: every command has been answered.
pub const ZCASHLC_LEDGER_STAGE_COMPLETE: u32 = 5;
/// Stage: the session failed.
pub const ZCASHLC_LEDGER_STAGE_FAILED: u32 = 6;

fn stage_code(stage: Stage) -> u32 {
    match stage {
        Stage::IdentifyingDevice => ZCASHLC_LEDGER_STAGE_IDENTIFYING_DEVICE,
        Stage::Streaming => ZCASHLC_LEDGER_STAGE_STREAMING,
        Stage::SigningOrchard => ZCASHLC_LEDGER_STAGE_SIGNING_ORCHARD,
        Stage::SigningIronwood => ZCASHLC_LEDGER_STAGE_SIGNING_IRONWOOD,
        Stage::SigningTransparent => ZCASHLC_LEDGER_STAGE_SIGNING_TRANSPARENT,
        Stage::Complete => ZCASHLC_LEDGER_STAGE_COMPLETE,
        Stage::Failed => ZCASHLC_LEDGER_STAGE_FAILED,
    }
}

impl SessionState {
    fn next_step(&mut self) -> FfiLedgerSignStep {
        // Announced before the review packet goes out, and only once: a `0x6901` resend of that
        // packet is the same review, which `is_past_review` already reports.
        let starts_review =
            self.session.pending_user_action().is_some() && !self.session.is_past_review();
        let step = self.session.next_step();
        let waits_for_user = self.session.next_deadline() == Deadline::UserReview;
        let (kind, apdu, apdu_len) = match step {
            PumpStep::Send(apdu) => {
                let (ptr, len) = ptr_from_vec(apdu);
                (ZCASHLC_LEDGER_SIGN_STEP_SEND, ptr, len)
            }
            PumpStep::AwaitingReply => {
                (ZCASHLC_LEDGER_SIGN_STEP_AWAITING_REPLY, ptr::null_mut(), 0)
            }
            PumpStep::Done => (ZCASHLC_LEDGER_SIGN_STEP_DONE, ptr::null_mut(), 0),
        };
        FfiLedgerSignStep {
            kind,
            apdu,
            apdu_len,
            waits_for_user,
            starts_review: starts_review && kind == ZCASHLC_LEDGER_SIGN_STEP_SEND,
            stage: stage_code(self.session.stage()),
            stream_acknowledged: self.stream_acknowledged,
            stream_total: self.stream_total,
        }
    }

    fn process_response(&mut self, reply: &[u8]) -> Result<SessionStatus, LedgerError> {
        let streaming = self.session.stage() == Stage::Streaming;
        match self.session.process_response(reply) {
            Ok(status) => {
                if streaming && status != SessionStatus::RetrySameApdu {
                    self.stream_acknowledged = self.stream_acknowledged.saturating_add(1);
                }
                Ok(status)
            }
            Err(e) => Err(session_error(&e, self.session.is_restartable())),
        }
    }

    fn finish(&mut self) -> Result<Vec<u8>, LedgerError> {
        let outcome = self
            .session
            .finish()
            .map_err(|e| session_error(&e, false))?;
        Ok(outcome.pczt_with_sigs().to_vec())
    }
}

/// Returns the next step of the ceremony.
///
/// Returns null with the last error set only for a misused handle.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_sign_session_new`].
/// - Call [`zcashlc_ledger_free_sign_step`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_sign_session_next_step(
    handle: *mut FfiLedgerSignSession,
) -> *mut FfiLedgerSignStep {
    let res = catch_panic(AssertUnwindSafe(|| {
        let session = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger session handle was passed"))?;
        let step = lock(&session.inner)?.next_step();
        Ok(Box::into_raw(Box::new(step)))
    }));
    crate::unwrap_exc_or_null(res)
}

/// Frees an [`FfiLedgerSignStep`], wiping its command.
///
/// # Safety
///
/// - `ptr` must be null, or a pointer returned by [`zcashlc_ledger_sign_session_next_step`] that
///   has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_sign_step(ptr: *mut FfiLedgerSignStep) {
    if !ptr.is_null() {
        let step = unsafe { Box::from_raw(ptr) };
        if !step.apdu.is_null() {
            unsafe { slice::from_raw_parts_mut(step.apdu, step.apdu_len) }.zeroize();
        }
        free_ptr_from_vec(step.apdu, step.apdu_len);
    }
}

/// [`zcashlc_ledger_sign_session_process_response`]: call next step again.
pub const ZCASHLC_LEDGER_SIGN_STATUS_MORE_APDUS: i32 = 0;
/// [`zcashlc_ledger_sign_session_process_response`]: `0x6901`; the next step is the same command,
/// to be sent after the backoff.
pub const ZCASHLC_LEDGER_SIGN_STATUS_RETRY_SAME_APDU: i32 = 1;
/// [`zcashlc_ledger_sign_session_process_response`]: the next command opens the on-device review.
pub const ZCASHLC_LEDGER_SIGN_STATUS_AWAITING_USER: i32 = 2;
/// [`zcashlc_ledger_sign_session_process_response`]: every command has been answered; call
/// [`zcashlc_ledger_sign_session_finish`].
pub const ZCASHLC_LEDGER_SIGN_STATUS_COMPLETE: i32 = 3;

/// Absorbs the reply (data plus status word) to the command last handed out.
///
/// Returns a `ZCASHLC_LEDGER_SIGN_STATUS_*` constant, or `-1` with the last error set when the
/// session failed; a failed session is dead, and the error's `is_restartable` says whether a fresh
/// one is worth building.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_sign_session_new`].
/// - `reply` must be valid for reads for `reply_len` bytes (or `reply_len` must be zero).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_sign_session_process_response(
    handle: *mut FfiLedgerSignSession,
    reply: *const u8,
    reply_len: usize,
) -> i32 {
    let res = catch_panic(AssertUnwindSafe(|| {
        let session = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger session handle was passed"))?;
        let reply = unsafe { bytes(reply, reply_len)? };
        let status = lock(&session.inner)?.process_response(reply)?;
        Ok(match status {
            SessionStatus::MoreApdus => ZCASHLC_LEDGER_SIGN_STATUS_MORE_APDUS,
            SessionStatus::RetrySameApdu => ZCASHLC_LEDGER_SIGN_STATUS_RETRY_SAME_APDU,
            SessionStatus::AwaitingUserAction { .. } => ZCASHLC_LEDGER_SIGN_STATUS_AWAITING_USER,
            SessionStatus::Complete => ZCASHLC_LEDGER_SIGN_STATUS_COMPLETE,
        })
    }));
    crate::unwrap_exc_or(res, -1)
}

/// Applies the device's signatures and returns the signed PCZT, serialized.
///
/// Valid once, after [`ZCASHLC_LEDGER_SIGN_STATUS_COMPLETE`]. The signed PCZT is the one to pass,
/// with the PCZT the prover returned, to `zcashlc_extract_and_store_from_pczt`.
///
/// Returns null with the last error set before completion, on a second call, or when a signature
/// the device returned does not verify.
///
/// # Safety
///
/// - `handle` must be a live pointer returned by [`zcashlc_ledger_sign_session_new`].
/// - Call [`ffi::zcashlc_free_boxed_slice`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_sign_session_finish(
    handle: *mut FfiLedgerSignSession,
) -> *mut ffi::BoxedSlice {
    let res = catch_panic(AssertUnwindSafe(|| {
        let session = unsafe { handle.as_ref() }
            .ok_or_else(|| LedgerError::internal("a null Ledger session handle was passed"))?;
        let signed = lock(&session.inner)?.finish()?;
        Ok(ffi::BoxedSlice::some(signed))
    }));
    crate::unwrap_exc_or_null(res)
}

/// Frees an [`FfiLedgerSignSession`].
///
/// # Safety
///
/// - `handle` must be null, or a pointer returned by [`zcashlc_ledger_sign_session_new`] that has
///   not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ledger_free_sign_session(handle: *mut FfiLedgerSignSession) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests;
