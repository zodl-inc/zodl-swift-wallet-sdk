//! The ZIP 317 fee rule's constants, as librustzcash defines them.

use zcash_primitives::transaction::fees::zip317::MARGINAL_FEE;

#[cfg(test)]
mod tests;

/// Returns the ZIP 317 marginal fee in zatoshis: the fee charged per logical action beyond the
/// grace actions, and the value below which a note costs more to spend than it carries.
///
/// The value is librustzcash's `zcash_primitives::transaction::fees::zip317::MARGINAL_FEE`, so a
/// caller never has to restate it. Stateless: it reads no database and cannot fail.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_zip317_marginal_fee() -> u64 {
    u64::from(MARGINAL_FEE)
}
