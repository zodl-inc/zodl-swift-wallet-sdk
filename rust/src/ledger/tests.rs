use std::ffi::CStr;

use orchard::{
    keys::{FullViewingKey, Scope, SpendAuthorizingKey},
    note::{Note, NoteVersion, RandomSeed, Rho},
    tree::{MerkleHashOrchard, MerklePath},
    value::NoteValue,
};
use pczt::roles::{
    combiner::Combiner, creator::Creator, io_finalizer::IoFinalizer, signer::Signer,
    spend_finalizer::SpendFinalizer, tx_extractor::TransactionExtractor,
};
use transparent::{
    bundle::{OutPoint, TxOut},
    keys::IncomingViewingKey as _,
};
use zcash_address::unified::{Encoding as _, Fvk, Revision, Ufvk, Uitem};
use zcash_keys::keys::{UnifiedFullViewingKey, UnifiedSpendingKey};
use zcash_primitives::transaction::{
    builder::{BuildConfig, Builder, BundlePadding, PcztResult},
    fees::zip317,
};
use zcash_protocol::{
    consensus::BlockHeight, local_consensus::LocalNetwork, memo::MemoBytes, value::Zatoshis,
};

use super::*;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// What [`zcashlc_ledger_take_last_error`] reported, copied out of the FFI value.
#[derive(Debug)]
struct TakenError {
    kind: u32,
    status_word: Option<u16>,
    is_transient: bool,
    is_restartable: bool,
    reason: String,
}

fn take_error() -> TakenError {
    let ptr = zcashlc_ledger_take_last_error();
    assert!(!ptr.is_null(), "an error was expected");
    let error = unsafe { &*ptr };
    let taken = TakenError {
        kind: error.kind,
        status_word: error.has_status_word.then_some(error.status_word),
        is_transient: error.is_transient,
        is_restartable: error.is_restartable,
        reason: unsafe { CStr::from_ptr(error.reason) }
            .to_str()
            .expect("UTF-8")
            .to_owned(),
    };
    unsafe { zcashlc_ledger_free_error(ptr) };
    assert!(
        zcashlc_ledger_take_last_error().is_null(),
        "taking the error clears it"
    );
    taken
}

/// Copies a boxed slice out and frees it.
fn boxed(ptr: *mut ffi::BoxedSlice) -> Option<Vec<u8>> {
    assert!(!ptr.is_null(), "a boxed slice was expected");
    let bytes = unsafe { (*ptr).as_slice() }.to_vec();
    let is_none = unsafe { (*ptr).as_slice() }.is_empty();
    unsafe { ffi::zcashlc_free_boxed_slice(ptr) };
    (!is_none).then_some(bytes)
}

fn with_status(mut data: Vec<u8>, status: u16) -> Vec<u8> {
    data.extend_from_slice(&status.to_be_bytes());
    data
}

fn frames_of(bytes: &[u8], frame_size: u32) -> Vec<Vec<u8>> {
    let ptr = unsafe { zcashlc_ledger_ble_frames(bytes.as_ptr(), bytes.len(), frame_size) };
    assert!(!ptr.is_null(), "framing succeeds");
    let frames = unsafe { slice::from_raw_parts((*ptr).ptr, (*ptr).len) }
        .iter()
        .map(|frame| unsafe { slice::from_raw_parts(frame.ptr, frame.len) }.to_vec())
        .collect();
    unsafe { zcashlc_ledger_free_frames(ptr) };
    frames
}

/// The key the fake device answers `GET_WALLET_PUBLIC_KEY` with.
fn device_key(byte: u8) -> secp256k1::PublicKey {
    let sk = secp256k1::SecretKey::from_secret_bytes([byte; 32]).expect("a valid secret key");
    secp256k1::PublicKey::from_secret_key(&sk)
}

/// A `GET_WALLET_PUBLIC_KEY` reply for `key`: `pk_len ‖ pk ‖ addr_len ‖ addr ‖ chain_code`.
fn wallet_public_key_reply(key: &secp256k1::PublicKey) -> Vec<u8> {
    let pk = key.serialize_uncompressed();
    let address = b"tmFakeLedgerFirstAddress";
    let mut reply = vec![pk.len() as u8];
    reply.extend_from_slice(&pk);
    reply.push(address.len() as u8);
    reply.extend_from_slice(address);
    reply.extend_from_slice(&[0x11; 32]);
    with_status(reply, 0x9000)
}

fn firmware_version_reply(major: u8, minor: u8, patch: u8) -> Vec<u8> {
    with_status(vec![0x38, 0x30, major, minor, patch, 2, 3, 22], 0x9000)
}

// ---------------------------------------------------------------------------
// Transport policy
// ---------------------------------------------------------------------------

#[test]
fn the_transport_policy_is_the_engines() {
    assert_eq!(zcashlc_ledger_max_cmd_not_accepted_retries(), 32);
    assert_eq!(zcashlc_ledger_cmd_not_accepted_backoff_ms(), 50);
    assert_eq!(zcashlc_ledger_default_timeout_ms(), 120_000);
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

#[test]
fn ble_frames_round_trip_through_the_deframer_handle() {
    // A reply spanning several frames: BLE framing is the same in both directions.
    let reply = with_status((0..300u16).map(|i| i as u8).collect(), 0x9000);
    let frames = frames_of(&reply, 64);
    assert!(frames.len() > 1);
    assert!(frames.iter().all(|frame| frame.len() <= 64));

    let deframer = zcashlc_ledger_ble_deframer_new();
    let (last, rest) = frames.split_last().expect("frames");
    for frame in rest {
        let pushed =
            unsafe { zcashlc_ledger_ble_deframer_push(deframer, frame.as_ptr(), frame.len()) };
        assert_eq!(boxed(pushed), None, "no reply before the last frame");
    }
    let pushed = unsafe { zcashlc_ledger_ble_deframer_push(deframer, last.as_ptr(), last.len()) };
    assert_eq!(boxed(pushed), Some(reply));

    // A frame with the wrong tag is refused, and the refusal sticks.
    let mut bad = frames[0].clone();
    bad[0] = 0x06;
    let pushed = unsafe { zcashlc_ledger_ble_deframer_push(deframer, bad.as_ptr(), bad.len()) };
    assert!(pushed.is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::MalformedReply as u32);
    let pushed =
        unsafe { zcashlc_ledger_ble_deframer_push(deframer, frames[0].as_ptr(), frames[0].len()) };
    assert!(pushed.is_null(), "a refused reassembly stays refused");
    assert_eq!(take_error().kind, LedgerErrorKind::MalformedReply as u32);

    unsafe { zcashlc_ledger_free_ble_deframer(deframer) };
}

#[test]
fn the_mtu_handshake_is_parsed_and_malformed_responses_refused() {
    assert_eq!(
        boxed(zcashlc_ledger_ble_mtu_request()),
        Some(vec![0x08, 0, 0, 0, 0])
    );

    let response = [0x08, 0, 0, 0, 1, 0x99];
    assert_eq!(
        unsafe { zcashlc_ledger_parse_ble_mtu_response(response.as_ptr(), response.len()) },
        0x99
    );

    let response = [0x05, 0, 0, 0, 1, 0x99];
    assert_eq!(
        unsafe { zcashlc_ledger_parse_ble_mtu_response(response.as_ptr(), response.len()) },
        -1
    );
    assert_eq!(take_error().kind, LedgerErrorKind::MalformedReply as u32);

    let apdu = [0u8; 10];
    let frames = unsafe { zcashlc_ledger_ble_frames(apdu.as_ptr(), apdu.len(), 5) };
    assert!(frames.is_null(), "a frame size below the header is refused");
    assert_eq!(take_error().kind, LedgerErrorKind::MalformedReply as u32);
}

// ---------------------------------------------------------------------------
// One-shot commands
// ---------------------------------------------------------------------------

#[test]
fn a_device_identity_parses_and_a_malformed_one_is_refused_without_echoing_it() {
    let reply = wallet_public_key_reply(&device_key(0x5D));
    let identity = unsafe { zcashlc_ledger_parse_device_identity(reply.as_ptr(), reply.len()) };
    assert!(!identity.is_null());
    let parsed = unsafe { CStr::from_ptr(identity) }
        .to_str()
        .expect("ASCII")
        .to_owned();
    assert!(parsed.starts_with("tpk0-"));
    assert_eq!(
        parsed,
        DeviceIdentity::from_compressed_pubkey(&device_key(0x5D).serialize()).to_string()
    );
    assert!(unsafe { zcashlc_ledger_validate_device_identity(identity) });
    unsafe { zcashlc_string_free(identity) };

    let malformed = c"tpk0-NOTHEXNOTHEXNOTHEXNOTHEXNOTHEXNOTHEXNOTHEXNOTHEXNOTHEXNOTHEX12";
    assert!(!unsafe { zcashlc_ledger_validate_device_identity(malformed.as_ptr()) });
    let error = take_error();
    assert_eq!(error.kind, LedgerErrorKind::InvalidInput as u32);
    assert!(!error.reason.contains("NOTHEX"), "{}", error.reason);

    let apdu = boxed(zcashlc_ledger_device_identity_apdu(
        crate::NETWORK_ID_TESTNET,
    ))
    .expect("an APDU");
    assert_eq!(&apdu[..2], &[0xE0, 0x40]);
}

#[test]
fn app_versions_and_status_words_map_to_structured_kinds() {
    let reply = firmware_version_reply(3, 9, 3);
    let version = unsafe { zcashlc_ledger_parse_app_version(reply.as_ptr(), reply.len()) };
    assert!(!version.is_null());
    unsafe {
        assert_eq!(
            ((*version).major, (*version).minor, (*version).patch),
            (3, 9, 3)
        );
        assert!((*version).supports_pczt);
        zcashlc_ledger_free_app_version(version);
    }

    let reply = firmware_version_reply(3, 5, 0);
    let version = unsafe { zcashlc_ledger_parse_app_version(reply.as_ptr(), reply.len()) };
    assert!(!unsafe { (*version).supports_pczt });
    unsafe { zcashlc_ledger_free_app_version(version) };

    let refused = |status: u16| {
        let reply = with_status(vec![], status);
        let version = unsafe { zcashlc_ledger_parse_app_version(reply.as_ptr(), reply.len()) };
        assert!(version.is_null());
        take_error()
    };

    let error = refused(0x6985);
    assert_eq!(error.kind, LedgerErrorKind::UserRejected as u32);
    assert!(error.is_restartable);

    let error = refused(0x6E00);
    assert_eq!(error.kind, LedgerErrorKind::WrongApp as u32);
    assert_eq!(error.status_word, Some(0x6E00));

    let error = refused(0x6901);
    assert_eq!(error.kind, LedgerErrorKind::CmdNotAccepted as u32);

    let error = refused(0x5515);
    assert_eq!(error.kind, LedgerErrorKind::DeviceRefused as u32);
    assert_eq!(error.status_word, Some(0x5515));
    assert!(error.is_transient && error.is_restartable);

    let error = refused(0x6A80);
    assert_eq!(error.kind, LedgerErrorKind::DeviceRefused as u32);
    assert!(!error.is_transient && !error.is_restartable);

    // The same status word means a spent derivation budget on a command that derives an
    // Orchard key.
    let reply = with_status(vec![], 0x6A84);
    let address = unsafe {
        zcashlc_ledger_parse_unified_address(reply.as_ptr(), reply.len(), crate::NETWORK_ID_TESTNET)
    };
    assert!(address.is_null());
    assert_eq!(
        take_error().kind,
        LedgerErrorKind::DerivationBudgetExhausted as u32
    );

    // Regtest has no Ledger app build.
    assert!(zcashlc_ledger_device_identity_apdu(99).is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::Internal as u32);
}

#[test]
fn the_address_display_command_bounds_its_indices() {
    let apdu = zcashlc_ledger_unified_address_apdu(crate::NETWORK_ID_TESTNET, 0, 7, true);
    assert_eq!(&boxed(apdu).expect("an APDU")[..2], &[0xE0, 0x51]);

    let apdu = zcashlc_ledger_unified_address_apdu(crate::NETWORK_ID_TESTNET, 0, 50_001, true);
    assert!(apdu.is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::InvalidInput as u32);
}

// ---------------------------------------------------------------------------
// Viewing key export
// ---------------------------------------------------------------------------

/// The device encodes in revision 0 (`pczt_ledger::pairing::DEVICE_UNIFIED_REVISION`), unlike
/// `zcash_keys`'s own `encode`, which is revision 2 unconditionally.
fn testnet_ufvk() -> String {
    device_ufvk(&[7u8; 32], AccountId::ZERO, true)
}

/// The revision 0 testnet key the device exports for `account` of `seed`, with or without its
/// P2PKH item.
fn device_ufvk(seed: &[u8], account: AccountId, with_transparent: bool) -> String {
    let usk =
        UnifiedSpendingKey::from_seed(&zcash_protocol::consensus::TEST_NETWORK, seed, account)
            .expect("a spending key derives");
    let ufvk = usk.to_unified_full_viewing_key();

    let items = [
        ufvk.orchard()
            .map(|fvk| Uitem::Data(Fvk::Orchard(fvk.to_bytes()))),
        ufvk.sapling()
            .map(|dfvk| Uitem::Data(Fvk::Sapling(dfvk.to_bytes()))),
        ufvk.p2pkh().filter(|_| with_transparent).map(|pubkey| {
            Uitem::Data(Fvk::P2pkh(
                pubkey
                    .serialize()
                    .try_into()
                    .expect("account public key is 65 bytes"),
            ))
        }),
    ]
    .into_iter()
    .flatten()
    .collect();

    Ufvk::try_from_items(Revision::R0, items)
        .expect("the test key's items form a valid revision 0 container")
        .encode(&zcash_protocol::consensus::NetworkType::Test)
}

#[test]
fn a_viewing_key_export_reassembles_the_key_across_continuations() {
    let ufvk = testnet_ufvk();
    let mut transfer = (ufvk.len() as u16).to_be_bytes().to_vec();
    transfer.extend_from_slice(ufvk.as_bytes());
    let chunks = transfer.chunks(255).collect::<Vec<_>>();
    assert!(chunks.len() > 1, "the key spans continuations");

    let export = zcashlc_ledger_ufvk_export_new(crate::NETWORK_ID_TESTNET, 0);
    assert!(!export.is_null());
    assert!(unsafe { zcashlc_ledger_ufvk_export_waits_for_user(export) });

    let mut exported = None;
    for (index, chunk) in chunks.iter().enumerate() {
        let apdu = boxed(unsafe { zcashlc_ledger_ufvk_export_next_apdu(export) }).expect("APDU");
        assert_eq!(apdu[1], 0x50, "GET_VK");
        assert_eq!(apdu[2], if index == 0 { 0x00 } else { 0x80 });

        let reply = with_status(chunk.to_vec(), 0x9000);
        let step = unsafe {
            zcashlc_ledger_ufvk_export_process_response(export, reply.as_ptr(), reply.len())
        };
        assert!(!step.is_null());
        let status = unsafe { (*step).status };
        if index + 1 == chunks.len() {
            assert_eq!(status, ZCASHLC_LEDGER_UFVK_EXPORT_COMPLETE);
            exported = Some(
                unsafe { CStr::from_ptr((*step).ufvk) }
                    .to_str()
                    .expect("UTF-8")
                    .to_owned(),
            );
        } else {
            assert_eq!(status, ZCASHLC_LEDGER_UFVK_EXPORT_MORE_CHUNKS);
            assert!(unsafe { (*step).ufvk }.is_null());
            assert!(!unsafe { zcashlc_ledger_ufvk_export_waits_for_user(export) });
        }
        unsafe { zcashlc_ledger_free_ufvk_export_step(step) };
    }
    assert_eq!(exported, Some(ufvk));

    unsafe { zcashlc_ledger_free_ufvk_export(export) };
}

#[test]
fn a_declined_viewing_key_export_cannot_be_reissued() {
    let export = zcashlc_ledger_ufvk_export_new(crate::NETWORK_ID_TESTNET, 0);
    let request = boxed(unsafe { zcashlc_ledger_ufvk_export_next_apdu(export) }).expect("APDU");

    // A `0x6901` hands out the identical request again.
    let reply = with_status(vec![], 0x6901);
    let step =
        unsafe { zcashlc_ledger_ufvk_export_process_response(export, reply.as_ptr(), reply.len()) };
    assert_eq!(
        unsafe { (*step).status },
        ZCASHLC_LEDGER_UFVK_EXPORT_RETRY_SAME_APDU
    );
    unsafe { zcashlc_ledger_free_ufvk_export_step(step) };
    let resend = boxed(unsafe { zcashlc_ledger_ufvk_export_next_apdu(export) }).expect("APDU");
    assert_eq!(resend, request);

    let reply = with_status(vec![], 0x6985);
    let step =
        unsafe { zcashlc_ledger_ufvk_export_process_response(export, reply.as_ptr(), reply.len()) };
    assert!(step.is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::UserRejected as u32);

    assert!(unsafe { zcashlc_ledger_ufvk_export_next_apdu(export) }.is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::Internal as u32);

    unsafe { zcashlc_ledger_free_ufvk_export(export) };
}

// ---------------------------------------------------------------------------
// Pairing checks
// ---------------------------------------------------------------------------

const PAIRING_SEED: [u8; 32] = [7u8; 32];

/// The identity a device holding `seed` answers, built the way the device builds it: from the
/// secret key at `m/44'/1'/0'/0/0`, through a `GET_WALLET_PUBLIC_KEY` reply.
fn device_identity_of_seed(seed: &[u8]) -> CString {
    let secret = transparent::keys::AccountPrivKey::from_seed(
        &zcash_protocol::consensus::TEST_NETWORK,
        seed,
        AccountId::ZERO,
    )
    .expect("an account key derives")
    .derive_external_secret_key(NonHardenedChildIndex::ZERO)
    .expect("the first external key derives");
    let reply = wallet_public_key_reply(&secp256k1::PublicKey::from_secret_key(&secret));
    let identity = unsafe { zcashlc_ledger_parse_device_identity(reply.as_ptr(), reply.len()) };
    assert!(!identity.is_null());
    unsafe { CString::from_raw(identity) }
}

fn check_identity(network_id: u32, ufvk: &str, identity: &CStr) -> bool {
    let ufvk = CString::new(ufvk).expect("no NUL");
    unsafe {
        zcashlc_ledger_check_account_zero_identity(network_id, ufvk.as_ptr(), identity.as_ptr())
    }
}

#[test]
fn the_account_zero_key_derives_the_identity_of_its_device() {
    let identity = device_identity_of_seed(&PAIRING_SEED);
    // A pinned vector, so a change to the identity derivation cannot pass unnoticed.
    assert_eq!(
        identity.to_str().expect("ASCII"),
        "tpk0-0664357ce23cfc75503e4b9f963dd88756bb0708657298d038a90fa757f01c5d"
    );

    assert!(check_identity(
        crate::NETWORK_ID_TESTNET,
        &testnet_ufvk(),
        &identity
    ));
    assert!(
        zcashlc_ledger_take_last_error().is_null(),
        "a match sets no error"
    );
}

#[test]
fn a_key_from_another_seed_or_account_does_not_derive_the_identity() {
    let identity = device_identity_of_seed(&PAIRING_SEED);

    let other_seed = device_ufvk(&[8u8; 32], AccountId::ZERO, true);
    assert!(!check_identity(
        crate::NETWORK_ID_TESTNET,
        &other_seed,
        &identity
    ));
    let error = take_error();
    assert_eq!(error.kind, LedgerErrorKind::DeviceMismatch as u32);
    assert!(!error.reason.contains("tpk0"), "{}", error.reason);

    // The identity is a key of account 0; the key of account 1 of the same seed never derives it.
    let account_one = device_ufvk(&PAIRING_SEED, AccountId::try_from(1).expect("valid"), true);
    assert!(!check_identity(
        crate::NETWORK_ID_TESTNET,
        &account_one,
        &identity
    ));
    assert_eq!(take_error().kind, LedgerErrorKind::DeviceMismatch as u32);
}

#[test]
fn a_key_without_a_transparent_item_is_refused() {
    let identity = device_identity_of_seed(&PAIRING_SEED);
    let shielded_only = device_ufvk(&PAIRING_SEED, AccountId::ZERO, false);

    assert!(!check_identity(
        crate::NETWORK_ID_TESTNET,
        &shielded_only,
        &identity
    ));
    assert_eq!(take_error().kind, LedgerErrorKind::MalformedReply as u32);
}

#[test]
fn the_identity_check_refuses_inputs_that_do_not_parse() {
    let identity = device_identity_of_seed(&PAIRING_SEED);

    // A testnet key checked on mainnet.
    assert!(!check_identity(
        crate::NETWORK_ID_MAINNET,
        &testnet_ufvk(),
        &identity
    ));
    assert_eq!(take_error().kind, LedgerErrorKind::InvalidInput as u32);

    assert!(!check_identity(
        crate::NETWORK_ID_TESTNET,
        "not a key",
        &identity
    ));
    let error = take_error();
    assert_eq!(error.kind, LedgerErrorKind::InvalidInput as u32);
    assert!(!error.reason.contains("not a key"), "{}", error.reason);

    assert!(!check_identity(
        crate::NETWORK_ID_TESTNET,
        &testnet_ufvk(),
        c"tpk0-short"
    ));
    assert_eq!(take_error().kind, LedgerErrorKind::InvalidInput as u32);
}

fn device_address(network_id: u32, ufvk: &str) -> Option<String> {
    let ufvk = CString::new(ufvk).expect("no NUL");
    let address = unsafe { zcashlc_ledger_device_unified_address(network_id, ufvk.as_ptr()) };
    (!address.is_null()).then(|| {
        unsafe { CString::from_raw(address) }
            .into_string()
            .expect("UTF-8")
    })
}

/// A `GET_SHIELD_ADDR` reply carrying `address`: a two-byte length, then the string.
fn unified_address_reply(address: &str) -> Vec<u8> {
    let mut reply = (address.len() as u16).to_be_bytes().to_vec();
    reply.extend_from_slice(address.as_bytes());
    with_status(reply, 0x9000)
}

fn parse_displayed(reply: &[u8]) -> String {
    let parsed = unsafe {
        zcashlc_ledger_parse_unified_address(reply.as_ptr(), reply.len(), crate::NETWORK_ID_TESTNET)
    };
    assert!(!parsed.is_null());
    unsafe { CString::from_raw(parsed) }
        .into_string()
        .expect("UTF-8")
}

#[test]
fn the_device_address_is_the_orchard_receiver_at_index_zero_alone() {
    let expected = device_address(crate::NETWORK_ID_TESTNET, &testnet_ufvk()).expect("an address");
    // A pinned vector, so a change to the derivation or the encoding cannot pass unnoticed.
    assert_eq!(
        expected,
        "utest1qzf74qz7g56frxcxlttm475jdqd3wrtzy042kc33myjnhhhzr0mxty70tkzcqfzsfqz0cva4czqy6jz2xvj4y2xjsrwekpg8r5d6xqua"
    );

    // What the device answers: the Orchard receiver at diversifier index 0 of the account's
    // spending key, external scope, alone in a revision 0 container.
    let usk = UnifiedSpendingKey::from_seed(
        &zcash_protocol::consensus::TEST_NETWORK,
        &PAIRING_SEED,
        AccountId::ZERO,
    )
    .expect("a spending key derives");
    let receiver = FullViewingKey::from(usk.orchard())
        .address_at(0u32, Scope::External)
        .to_raw_address_bytes();
    let on_device = zcash_address::unified::Address::try_from_items(
        Revision::R0,
        vec![Uitem::Data(zcash_address::unified::Receiver::Orchard(
            receiver,
        ))],
    )
    .expect("a valid address")
    .encode(&zcash_protocol::consensus::NetworkType::Test);

    assert_eq!(
        parse_displayed(&unified_address_reply(&on_device)),
        expected
    );

    // The SDK's address validation accepts it as a testnet unified address.
    let encoded = CString::new(expected.clone()).expect("no NUL");
    let (mut network_id, mut kind) = (u32::MAX, u32::MAX);
    assert!(unsafe {
        crate::derivation::zcashlc_get_address_metadata(
            encoded.as_ptr(),
            &mut network_id,
            &mut kind,
        )
    });
    assert_eq!((network_id, kind), (crate::NETWORK_ID_TESTNET, 3));

    // Another seed's device shows another address.
    let other = device_address(
        crate::NETWORK_ID_TESTNET,
        &device_ufvk(&[8u8; 32], AccountId::ZERO, true),
    )
    .expect("an address");
    assert_ne!(other, expected);
}

#[test]
fn the_device_address_refuses_keys_it_cannot_use() {
    assert_eq!(
        device_address(crate::NETWORK_ID_MAINNET, &testnet_ufvk()),
        None
    );
    assert_eq!(take_error().kind, LedgerErrorKind::InvalidInput as u32);

    // A key with only a transparent item has no Orchard receiver to show.
    let usk = UnifiedSpendingKey::from_seed(
        &zcash_protocol::consensus::TEST_NETWORK,
        &PAIRING_SEED,
        AccountId::ZERO,
    )
    .expect("a spending key derives");
    let pubkey = usk
        .to_unified_full_viewing_key()
        .p2pkh()
        .expect("transparent")
        .serialize();
    let transparent_only = Ufvk::try_from_items(
        Revision::R0,
        vec![
            Uitem::Data(Fvk::P2pkh(pubkey.try_into().expect("65 bytes"))),
            Uitem::Data(Fvk::Unknown {
                typecode: 0xFFF0,
                data: vec![0; 32],
            }),
        ],
    )
    .expect("a valid container")
    .encode(&zcash_protocol::consensus::NetworkType::Test);
    assert_eq!(
        device_address(crate::NETWORK_ID_TESTNET, &transparent_only),
        None
    );
    let error = take_error();
    assert_eq!(error.kind, LedgerErrorKind::InvalidInput as u32);
    assert!(error.reason.contains("Orchard"), "{}", error.reason);
}

// ---------------------------------------------------------------------------
// Signing sessions
// ---------------------------------------------------------------------------

/// A regtest network stopping at NU6.2, so the builder emits V5 transactions. Its coin type is
/// testnet's, which is the Ledger network the sessions are built for.
fn v5_network() -> LocalNetwork {
    LocalNetwork {
        overwinter: Some(BlockHeight::from_u32(1)),
        sapling: Some(BlockHeight::from_u32(2)),
        blossom: Some(BlockHeight::from_u32(3)),
        heartwood: Some(BlockHeight::from_u32(4)),
        canopy: Some(BlockHeight::from_u32(5)),
        nu5: Some(BlockHeight::from_u32(6)),
        nu6: Some(BlockHeight::from_u32(7)),
        nu6_1: Some(BlockHeight::from_u32(8)),
        nu6_2: Some(BlockHeight::from_u32(9)),
        nu6_3: None,
        nu7: None,
    }
}

const TARGET_HEIGHT: u32 = 10_000_000;
const DEVICE_KEY_BYTE: u8 = 0x5D;

/// A seed-derived account standing in for the Ledger's, with the keys a fake device signs with.
struct Wallet {
    usk: UnifiedSpendingKey,
    ufvk: UnifiedFullViewingKey,
}

impl Wallet {
    fn new() -> Self {
        let usk = UnifiedSpendingKey::from_seed(&v5_network(), &[1u8; 32], AccountId::ZERO)
            .expect("a spending key derives");
        let ufvk = usk.to_unified_full_viewing_key();
        Wallet { usk, ufvk }
    }

    fn external(&self) -> (TransparentAddress, NonHardenedChildIndex) {
        self.ufvk
            .transparent()
            .expect("transparent")
            .derive_external_ivk()
            .expect("external ivk")
            .default_address()
    }

    fn internal(&self) -> (TransparentAddress, NonHardenedChildIndex) {
        self.ufvk
            .transparent()
            .expect("transparent")
            .derive_internal_ivk()
            .expect("internal ivk")
            .default_address()
    }

    /// What the wallet database knows about the account's transparent addresses.
    fn lookup(
        &self,
        address: &TransparentAddress,
    ) -> Result<Option<(TransparentKeyScope, NonHardenedChildIndex)>, LedgerError> {
        let (external, external_index) = self.external();
        let (internal, internal_index) = self.internal();
        Ok(if *address == external {
            Some((TransparentKeyScope::EXTERNAL, external_index))
        } else if *address == internal {
            Some((TransparentKeyScope::INTERNAL, internal_index))
        } else {
            None
        })
    }

    fn inputs(&self, caps: DeviceCaps) -> SessionInputs {
        SessionInputs {
            network: pczt_ledger::Network::Test,
            device: DeviceIdentity::from_compressed_pubkey(
                &device_key(DEVICE_KEY_BYTE).serialize(),
            ),
            zip32_account: AccountId::ZERO,
            seed_fingerprint: None,
            orchard_fvk: self.ufvk.orchard().cloned(),
            transparent_key: self.ufvk.transparent().cloned(),
            caps,
        }
    }
}

fn unpadded_config() -> BuildConfig {
    BuildConfig::Standard {
        sapling_anchor: None,
        orchard_anchor: None,
        ironwood_anchor: None,
        orchard_padding: BundlePadding {
            bundle_required: false,
            pad_to_minimum: None,
        },
        ironwood_padding: BundlePadding {
            bundle_required: false,
            pad_to_minimum: None,
        },
    }
}

/// The PCZT `create_pczt_from_proposal` would produce for a viewing-key account: built, created
/// and IO-finalized, with no derivation stamped anywhere and nothing redacted.
fn finish(parts: PcztResult<LocalNetwork>) -> Pczt {
    let pczt = Creator::build_from_parts(parts.pczt_parts).expect("creator");
    IoFinalizer::new(pczt)
        .finalize_io(crate::system_rng())
        .expect("io finalizer")
}

/// V5, one transparent input from the account's external address, paying the account's internal
/// (change) address. It needs no proof, so a signed copy can be finalized and extracted.
fn transparent_only_pczt(wallet: &Wallet) -> Pczt {
    let (external, _) = wallet.external();
    let (internal, _) = wallet.internal();
    let (_, external_index) = wallet.external();
    let pubkey = wallet
        .ufvk
        .transparent()
        .expect("transparent")
        .derive_address_pubkey(TransparentKeyScope::EXTERNAL, external_index)
        .expect("pubkey");

    let mut builder = Builder::new(v5_network(), TARGET_HEIGHT.into(), unpadded_config());
    builder
        .add_transparent_p2pkh_input(
            pubkey,
            OutPoint::new([1u8; 32], 1),
            TxOut::new(
                Zatoshis::const_from_u64(1_000_000),
                external.script().into(),
            ),
        )
        .expect("transparent input");
    builder
        .add_transparent_output(&internal, Zatoshis::const_from_u64(990_000))
        .expect("transparent output");
    finish(
        builder
            .build_for_pczt(crate::system_rng(), &zip317::FeeRule::standard())
            .expect("build_for_pczt"),
    )
}

/// A note of `value` to the account's first external Orchard address, with a single-leaf tree.
fn synthetic_note(fvk: &FullViewingKey, value: u64) -> (Note, MerklePath, orchard::Anchor) {
    let recipient = fvk.address_at(0u32, Scope::External);
    let mut rho_bytes = [0u8; 32];
    rho_bytes[0] = 1;
    let rho = Option::<Rho>::from(Rho::from_bytes(&rho_bytes)).expect("valid rho");
    let note = (0u8..=255)
        .find_map(|seed| {
            let rseed = Option::<RandomSeed>::from(RandomSeed::from_bytes([seed; 32], &rho))?;
            Option::<Note>::from(Note::from_parts(
                recipient,
                NoteValue::from_raw(value),
                rho,
                rseed,
                NoteVersion::V2,
            ))
        })
        .expect("a valid note exists for some rseed");
    let empty = Option::<MerkleHashOrchard>::from(MerkleHashOrchard::from_bytes(&[0u8; 32]))
        .expect("zero is a valid Pallas base");
    let merkle_path = MerklePath::from_parts(0, [empty; 32]);
    let anchor = merkle_path.root(note.commitment().into());
    (note, merkle_path, anchor)
}

/// V5, a real Orchard spend paying one Orchard output to the account and transparent change to the
/// account's internal address.
fn orchard_spend_pczt(wallet: &Wallet) -> Pczt {
    let fvk = wallet.ufvk.orchard().expect("orchard").clone();
    let (internal, _) = wallet.internal();
    let (note, merkle_path, anchor) = synthetic_note(&fvk, 1_000_000);

    let mut builder = Builder::new(
        v5_network(),
        TARGET_HEIGHT.into(),
        BuildConfig::Standard {
            sapling_anchor: None,
            orchard_anchor: Some(anchor),
            ironwood_anchor: None,
            orchard_padding: BundlePadding::DEFAULT,
            ironwood_padding: BundlePadding::DEFAULT,
        },
    );
    builder
        .add_orchard_spend::<zip317::FeeRule>(fvk.clone(), note, merkle_path)
        .expect("orchard spend");
    builder
        .add_orchard_output::<zip317::FeeRule>(
            Some(fvk.to_ovk(Scope::External)),
            fvk.address_at(0u32, Scope::External),
            Zatoshis::const_from_u64(100_000),
            MemoBytes::empty(),
        )
        .expect("orchard output");
    builder
        .add_transparent_output(&internal, Zatoshis::const_from_u64(885_000))
        .expect("transparent change output");
    finish(
        builder
            .build_for_pczt(crate::system_rng(), &zip317::FeeRule::standard())
            .expect("build_for_pczt"),
    )
}

/// A scripted Ledger that signs the session's shaped PCZT with the wallet's keys.
struct FakeLedger<'a> {
    wallet: &'a Wallet,
    shaped: Pczt,
    version: (u8, u8, u8),
    /// The instruction bytes received, in order.
    received: Vec<u8>,
}

impl FakeLedger<'_> {
    fn exchange(&mut self, apdu: &[u8]) -> Vec<u8> {
        let (ins, p2) = (apdu[1], apdu[3]);
        self.received.push(ins);
        match ins {
            0xC4 => firmware_version_reply(self.version.0, self.version.1, self.version.2),
            0x40 => wallet_public_key_reply(&device_key(DEVICE_KEY_BYTE)),
            0x57 => {
                let index = usize::from(p2);
                let ask = SpendAuthorizingKey::from(self.wallet.usk.orchard());
                let mut signer = Signer::new(self.shaped.clone()).expect("signer");
                signer
                    .sign_orchard(crate::system_rng(), index, &ask)
                    .expect("orchard signature");
                let signed = signer.finish();
                let sig = signed.orchard().actions()[index]
                    .spend()
                    .spend_auth_sig()
                    .expect("signed");
                with_status(sig.to_vec(), 0x9000)
            }
            0x55 => {
                let index = usize::from(p2);
                let signer = Signer::new(self.shaped.clone()).expect("signer");
                let sighash = signer.transparent_sighash(index).expect("sighash");
                let (_, external_index) = self.wallet.external();
                // `derive_external_secret_key` returns `zcash_transparent`'s own secp256k1
                // `SecretKey` — this crate's own secp256k1 dev-dependency, pinned to the same
                // version, so it is usable here directly rather than carried across by its bytes.
                let sk = self
                    .wallet
                    .usk
                    .transparent()
                    .derive_external_secret_key(external_index)
                    .expect("secret key");
                let sig = secp256k1::Secp256k1::signing_only()
                    .sign_ecdsa(secp256k1::Message::from_digest(sighash), &sk);
                let mut der = sig.serialize_der().to_vec();
                der.push(0x01);
                with_status(der, 0x9000)
            }
            _ => with_status(vec![], 0x9000),
        }
    }
}

/// Drives a session handle to completion over the C ABI, answering from `device`, and returns the
/// signed PCZT.
fn run_ceremony(state: SessionState, wallet: &Wallet) -> (Vec<u8>, Vec<u8>) {
    let shaped = state.session.shaped_pczt().clone();
    let mut device = FakeLedger {
        wallet,
        shaped,
        version: state.session.caps().version(),
        received: Vec::new(),
    };
    let handle = Box::into_raw(Box::new(FfiLedgerSignSession {
        inner: Mutex::new(state),
    }));

    let mut reviews = 0;
    let mut waiting_since_review = false;
    let mut last_acknowledged = 0;
    let total = loop {
        let step = unsafe { zcashlc_ledger_sign_session_next_step(handle) };
        assert!(!step.is_null());
        let step_ref = unsafe { &*step };
        assert!(step_ref.stream_acknowledged >= last_acknowledged);
        last_acknowledged = step_ref.stream_acknowledged;
        if step_ref.starts_review {
            reviews += 1;
            waiting_since_review = true;
        }
        if waiting_since_review && step_ref.kind == ZCASHLC_LEDGER_SIGN_STEP_SEND {
            assert!(step_ref.waits_for_user, "no timeout from the review onward");
        }
        if step_ref.kind != ZCASHLC_LEDGER_SIGN_STEP_SEND {
            assert_eq!(step_ref.kind, ZCASHLC_LEDGER_SIGN_STEP_DONE);
            assert_eq!(step_ref.stage, ZCASHLC_LEDGER_STAGE_COMPLETE);
            let total = step_ref.stream_total;
            unsafe { zcashlc_ledger_free_sign_step(step) };
            break total;
        }
        let apdu = unsafe { slice::from_raw_parts(step_ref.apdu, step_ref.apdu_len) }.to_vec();
        unsafe { zcashlc_ledger_free_sign_step(step) };

        let reply = device.exchange(&apdu);
        let status = unsafe {
            zcashlc_ledger_sign_session_process_response(handle, reply.as_ptr(), reply.len())
        };
        assert!(status >= 0, "the ceremony proceeds: {:?}", take_error());
    };
    assert_eq!(reviews, 1, "the review is announced exactly once");
    assert!(total > 0);
    assert_eq!(
        last_acknowledged, total,
        "every streamed command was acknowledged"
    );

    let signed = boxed(unsafe { zcashlc_ledger_sign_session_finish(handle) }).expect("signed");
    assert!(unsafe { zcashlc_ledger_sign_session_finish(handle) }.is_null());
    assert_eq!(take_error().kind, LedgerErrorKind::Internal as u32);
    unsafe { zcashlc_ledger_free_sign_session(handle) };
    (signed, device.received)
}

#[test]
fn a_session_is_refused_for_an_app_that_predates_pczt_signing() {
    let wallet = Wallet::new();
    let result = build_session(
        transparent_only_pczt(&wallet),
        wallet.inputs(DeviceCaps::from_version(3, 5, 0)),
        &|address| wallet.lookup(address),
    );
    assert_eq!(
        result.err().map(|e| e.kind()),
        Some(LedgerErrorKind::AppTooOld)
    );
}

#[test]
fn a_session_is_refused_for_a_transaction_the_device_cannot_sign() {
    // Without the wallet's address metadata the input gets no derivation, and the device would
    // have no path to sign it at.
    let wallet = Wallet::new();
    let result = build_session(
        transparent_only_pczt(&wallet),
        wallet.inputs(DeviceCaps::from_version(3, 9, 3)),
        &|_| Ok(None),
    );
    let error = result.err().expect("refused");
    assert_eq!(error.kind(), LedgerErrorKind::TransactionNotSignable);
    assert!(!error.is_restartable);
}

#[test]
fn a_different_device_is_refused_before_the_transaction_is_streamed() {
    let wallet = Wallet::new();
    let mut inputs = wallet.inputs(DeviceCaps::from_version(3, 9, 3));
    inputs.device = DeviceIdentity::from_compressed_pubkey(&device_key(0x42).serialize());
    let state = build_session(transparent_only_pczt(&wallet), inputs, &|address| {
        wallet.lookup(address)
    })
    .expect("session");
    let shaped = state.session.shaped_pczt().clone();
    let mut device = FakeLedger {
        wallet: &wallet,
        shaped,
        version: (3, 9, 3),
        received: Vec::new(),
    };
    let handle = Box::into_raw(Box::new(FfiLedgerSignSession {
        inner: Mutex::new(state),
    }));

    let status = loop {
        let step = unsafe { zcashlc_ledger_sign_session_next_step(handle) };
        let apdu = unsafe { slice::from_raw_parts((*step).apdu, (*step).apdu_len) }.to_vec();
        unsafe { zcashlc_ledger_free_sign_step(step) };
        let reply = device.exchange(&apdu);
        let status = unsafe {
            zcashlc_ledger_sign_session_process_response(handle, reply.as_ptr(), reply.len())
        };
        if status < 0 {
            break status;
        }
    };
    assert_eq!(status, -1);
    let error = take_error();
    assert_eq!(error.kind, LedgerErrorKind::DeviceMismatch as u32);
    assert!(!error.is_restartable);
    assert!(!error.reason.contains("tpk0-"), "{}", error.reason);
    assert_eq!(
        device.received,
        vec![0xC4, 0x40],
        "nothing of the transaction was sent"
    );

    unsafe { zcashlc_ledger_free_sign_session(handle) };
}

/// The flow the SDK documents: the unredacted PCZT goes to the prover and to the Ledger, and the
/// two results are combined. The Ledger-signed copy carries more than signatures — stamped input
/// and change derivations, zeroed seed fingerprints, `hash160` preimages, a redacted signer view
/// — and the pinned Combiner has to accept every one of those differences. A transparent-only
/// transaction needs no proof, so the combined PCZT is finalized and extracted here too.
#[test]
fn a_ledger_signed_transparent_pczt_combines_with_the_proving_pczt_and_extracts() {
    let wallet = Wallet::new();
    let original = transparent_only_pczt(&wallet);
    let state = build_session(
        original.clone(),
        wallet.inputs(DeviceCaps::from_version(3, 9, 3)),
        &|address| wallet.lookup(address),
    )
    .expect("session");
    assert!(
        state.session.plan().stream().transparent_outputs()[0]
            .derivation()
            .is_some(),
        "the internal-address output is marked as change"
    );

    let (signed, received) = run_ceremony(state, &wallet);
    assert_eq!(received.last(), Some(&0x55), "the input was signed");
    let signed = Pczt::parse(&signed).expect("the signed PCZT parses");

    let combined = Combiner::new(vec![original, signed])
        .combine()
        .expect("the Combiner accepts the proving and the Ledger-signed PCZTs");
    let finalized = SpendFinalizer::new(combined)
        .finalize_spends()
        .expect("the spend finalizer assembles the script_sig");
    TransactionExtractor::new(finalized)
        .extract(crate::system_rng())
        .expect("the combined PCZT extracts to a transaction");
}

/// The shielded half of the same property, run to the end: the prover's copy gets its Orchard proof
/// from the unredacted PCZT, the Ledger's copy its signatures from the redacted one, and the
/// combined PCZT has to finalize and extract. `TransactionExtractor` verifies the Orchard bundle
/// as it goes -- the proof, and every spend authorization signature against the shielded sighash
/// of the transaction that was actually built -- so this is also the check that the device's
/// signature, made over the redacted and stamped copy, is a valid signature on the real
/// transaction: a stamp or redaction that changed a sighash-relevant field would fail here, not
/// after the user's approval on a device.
///
/// Building the Orchard proving key is the slow part, so the quicker merge check below runs
/// separately as well.
#[test]
fn a_ledger_signed_orchard_pczt_combines_with_the_proving_pczt_and_extracts() {
    use orchard::circuit::{OrchardCircuitVersion, ProvingKey};
    use pczt::roles::prover::Prover;

    let wallet = Wallet::new();
    let original = orchard_spend_pczt(&wallet);
    let state = build_session(
        original.clone(),
        wallet.inputs(DeviceCaps::from_version(3, 9, 3)),
        &|address| wallet.lookup(address),
    )
    .expect("session");

    let (signed, received) = run_ceremony(state, &wallet);
    assert_eq!(received.last(), Some(&0x57), "the spend was signed");
    let signed = Pczt::parse(&signed).expect("the signed PCZT parses");

    // `v5_network()` activates NU6.2 and nothing after it, so the bundle is proven with the fixed
    // post-NU6.2 circuit; the extractor builds the matching verifying key from the bundle itself.
    let proving_key = ProvingKey::build(OrchardCircuitVersion::FixedPostNu6_2);
    let proven = Prover::new(original)
        .create_orchard_proof(crate::system_rng(), &proving_key)
        .expect("the unredacted PCZT proves")
        .finish();

    let combined = Combiner::new(vec![proven, signed])
        .combine()
        .expect("the Combiner accepts the proven and the Ledger-signed PCZTs");
    let finalized = SpendFinalizer::new(combined)
        .finalize_spends()
        .expect("the spend finalizer accepts the combined PCZT");
    let transaction = TransactionExtractor::new(finalized)
        .extract(crate::system_rng())
        .expect("the combined PCZT extracts to a transaction whose Orchard bundle verifies");
    assert!(
        transaction.orchard_bundle().is_some(),
        "the extracted transaction carries the Orchard bundle"
    );
}

/// The merge alone, without the proof: device signatures, the zip32 derivations shaping stamps on
/// every action (dummies included), the redacted witness and dummy keys, and the marked
/// transparent change all merge into the prover's PCZT, and the device's signature survives the
/// merge. Extraction needs the Orchard proof, which only the prover sets; the test above does that.
#[test]
fn a_ledger_signed_orchard_pczt_combines_with_the_proving_pczt() {
    let wallet = Wallet::new();
    let original = orchard_spend_pczt(&wallet);
    let state = build_session(
        original.clone(),
        wallet.inputs(DeviceCaps::from_version(3, 9, 3)),
        &|address| wallet.lookup(address),
    )
    .expect("session");
    let real_spends = state.session.plan().orchard_real_spends().to_vec();
    assert_eq!(real_spends.len(), 1);

    let (signed, received) = run_ceremony(state, &wallet);
    assert_eq!(received.last(), Some(&0x57), "the spend was signed");
    let signed = Pczt::parse(&signed).expect("the signed PCZT parses");
    let signature = signed.orchard().actions()[real_spends[0]]
        .spend()
        .spend_auth_sig()
        .expect("the device signature was applied");

    let combined = Combiner::new(vec![original, signed])
        .combine()
        .expect("the Combiner accepts the proving and the Ledger-signed PCZTs");
    assert_eq!(
        combined.orchard().actions()[real_spends[0]]
            .spend()
            .spend_auth_sig(),
        &Some(signature)
    );
}
