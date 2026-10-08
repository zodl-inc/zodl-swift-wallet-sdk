//! Tests for the ZIP 317 constants this library exposes.

use super::*;

/// The constant crosses the FFI as the 5000 zatoshis ZIP 317 specifies.
#[test]
fn the_marginal_fee_is_5000_zatoshis() {
    assert_eq!(zcashlc_zip317_marginal_fee(), 5_000);
}
