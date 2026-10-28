//! The transaction id a PCZT commits to, before it carries proofs or signatures.
//!
//! A v5 transaction id (ZIP 244) commits to the transaction's effects only, never to its proofs
//! or authorizing signatures. A PCZT's effects are fixed once it is created, so the id is known
//! from the moment `zcashlc_create_pczt_from_proposal` returns, and stays the same through
//! serialization and parsing, proving, signing and combining, up to the transaction
//! `zcashlc_extract_and_store_from_pczt` stores. The SDK keys what it must remember about a
//! transaction it has not built yet (whether it is an Orchard migration, which must never be
//! recorded as rejected) on this id.

use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use pczt::Pczt;
use zcash_primitives::transaction::{
    TxVersion,
    txid::{TxIdDigester, to_txid},
};

use crate::unwrap_exc_or;

#[cfg(test)]
mod tests;

/// The id of the transaction the serialized PCZT `pczt_bytes` commits to.
pub(crate) fn pczt_txid(pczt_bytes: &[u8]) -> anyhow::Result<[u8; 32]> {
    let pczt = Pczt::parse(pczt_bytes).map_err(|e| anyhow!("Invalid PCZT: {:?}", e))?;
    let effects = pczt
        .into_effects()
        .map_err(|e| anyhow!("The PCZT's effects cannot be extracted: {:?}", e))?;
    let version = effects.version();
    // Before v5 the id hashes the whole serialized transaction, proofs and signatures included,
    // so it is not known until the transaction is complete.
    if !matches!(version, TxVersion::V5 | TxVersion::V6) {
        return Err(anyhow!(
            "A {:?} transaction's id is not known before it is authorized",
            version
        ));
    }
    let txid = to_txid(
        version,
        effects.consensus_branch_id(),
        &effects.digest(TxIdDigester),
    )
    .ok_or_else(|| {
        anyhow!(
            "A {:?} transaction's id is not known before it is authorized",
            version
        )
    })?;
    Ok(*txid.as_ref())
}

/// Writes the id of the transaction the given PCZT commits to into `txid_ret`, in the SDK's
/// raw/internal byte order (matching `zcashlc_extract_and_store_from_pczt`'s).
///
/// Returns `true` on success, and `false` (with the error message set) when the bytes are not a
/// PCZT or its effects cannot be read.
///
/// # Safety
///
/// - `pczt_ptr` must be non-null and valid for reads for `pczt_len` bytes, and it must have an
///   alignment of `1`.
/// - The memory referenced by `pczt_ptr` must not be mutated for the duration of the function
///   call.
/// - The total size `pczt_len` must be no larger than `isize::MAX`. See the safety documentation
///   of `pointer::offset`.
/// - `txid_ret` must be non-null and valid for writes of 32 bytes, with an alignment of `1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_pczt_txid(
    pczt_ptr: *const u8,
    pczt_len: usize,
    txid_ret: *mut u8,
) -> bool {
    let res = catch_panic(|| {
        if pczt_ptr.is_null() || txid_ret.is_null() {
            return Err(anyhow!("pczt_ptr and txid_ret must be non-null"));
        }
        let pczt_bytes = unsafe { slice::from_raw_parts(pczt_ptr, pczt_len) };
        let txid = pczt_txid(pczt_bytes)?;
        unsafe { txid_ret.copy_from(txid.as_ptr(), 32) };
        Ok(true)
    });
    unwrap_exc_or(res, false)
}
