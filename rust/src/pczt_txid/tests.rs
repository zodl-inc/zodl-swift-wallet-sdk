//! Tests for reading a PCZT's transaction id. The id of a real sweep PCZT, and its stability
//! through serialization, is covered with the migration lanes' fixtures in
//! `send_max::tests::migration_lanes`.

use super::*;

#[test]
fn bytes_that_are_not_a_pczt_have_no_txid() {
    assert!(pczt_txid(&[]).is_err());
    assert!(pczt_txid(b"not a pczt").is_err());
}

#[test]
fn the_ffi_reports_a_failure_without_writing_the_txid() {
    let bytes = b"not a pczt";
    let mut txid = [0xAAu8; 32];
    let ok = unsafe { zcashlc_pczt_txid(bytes.as_ptr(), bytes.len(), txid.as_mut_ptr()) };
    assert!(!ok);
    assert_eq!(txid, [0xAAu8; 32]);
}

#[test]
fn the_ffi_refuses_null_pointers() {
    let mut txid = [0u8; 32];
    assert!(!unsafe { zcashlc_pczt_txid(std::ptr::null(), 0, txid.as_mut_ptr()) });
    let bytes = [0u8; 4];
    assert!(!unsafe { zcashlc_pczt_txid(bytes.as_ptr(), bytes.len(), std::ptr::null_mut()) });
}
