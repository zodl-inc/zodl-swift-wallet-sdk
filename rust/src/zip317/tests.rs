//! Tests for the ZIP 317 constants this library exposes.

use super::*;

/// The constant crosses the FFI unchanged, and is the 5000 zatoshis ZIP 317 specifies.
#[test]
fn the_marginal_fee_is_librustzcash_s_and_is_5000_zatoshis() {
    assert_eq!(zcashlc_zip317_marginal_fee(), u64::from(MARGINAL_FEE));
    assert_eq!(zcashlc_zip317_marginal_fee(), 5_000);
}
