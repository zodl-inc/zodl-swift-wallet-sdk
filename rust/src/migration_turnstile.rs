//! The single-shot Orchard→Ironwood turnstile proposal, as released in 2.8.0-rc.1.
//!
//! Builds on [`crate::send_max::propose`], which spends the entire spendable
//! balance of a chosen set of shielded pools to one recipient with the fee
//! computed so nothing is left over. This module only pins the parameters that
//! make that call the pool migration.
//!
//! This is NOT the staged pool-migration engine — that lives in [`crate::migration`], which
//! splits, schedules and delivers a real Orchard balance over many transactions. This one
//! sweeps whatever fits in a single transaction, and stays because it shipped: an app on
//! 2.8.0-rc.1 calls it. It is the same primitive [`crate::zcashlc_propose_send_max_transfer`]
//! exposes generally, with the pool set, recipient and spend mode fixed.

use anyhow::anyhow;
use zcash_address::{ToAddress, ZcashAddress, unified, unified::Encoding as _};
use zcash_client_backend::data_api::{
    Account as _, InputSource, MaxSpendMode, WalletRead, wallet::ConfirmationsPolicy,
};
use zcash_client_sqlite::{AccountUuid, WalletDb, util::SystemClock};
use zcash_protocol::consensus::{NetworkUpgrade, Parameters};

use crate::NetworkParams;
use crate::send_max::{self, ORCHARD_ONLY, SendMaxProposal, SendMaxRequest};

// This line carries custom (regtest-style) networks, so the wallet handle is parameterized by
// `NetworkParams` rather than `zcash_protocol`'s fixed `Network`.
type Db = WalletDb<rusqlite::Connection, NetworkParams, SystemClock, crate::SystemRng>;

type MigrationProposal = SendMaxProposal<<Db as InputSource>::NoteRef>;

/// Proposes migrating the account's entire Orchard balance into the Ironwood
/// pool, sending the maximum from Orchard to the account's own internal Orchard
/// receiver so nothing is left behind when the Orchard turnstile closes at
/// NU6.3. Sapling and transparent funds are untouched.
///
/// Fails unless NU6.3 is active at the chain tip: before activation the same
/// call builds an Orchard-pool output (a fee-costing self-send that migrates
/// nothing). Uses `MaxSpendMode::Everything` so it fails rather than silently
/// migrating only the spendable subset.
pub(crate) fn propose_orchard_to_ironwood(
    db_data: &mut Db,
    network: &NetworkParams,
    account: AccountUuid,
) -> anyhow::Result<MigrationProposal> {
    let chain_tip = db_data
        .chain_height()
        .map_err(|e| anyhow!("Error reading the chain tip: {}", e))?
        .ok_or_else(|| anyhow!("Wallet has not yet scanned any blocks."))?;
    match network.activation_height(NetworkUpgrade::Nu6_3) {
        Some(h) if chain_tip >= h => (),
        _ => {
            return Err(anyhow!(
                "Ironwood (NU6.3) is not active yet; there is nothing to migrate to."
            ));
        }
    }

    let orchard_fvk = db_data
        .get_account(account)
        .map_err(|e| anyhow!("Error looking up account: {}", e))?
        .ok_or_else(|| anyhow!("Unknown account."))?
        .ufvk()
        .and_then(|ufvk| ufvk.orchard())
        .cloned()
        .ok_or_else(|| anyhow!("Account has no Orchard full viewing key."))?;

    // Internal scope: funds return to the account as change, not an external payment.
    let receiver = orchard_fvk.address_at(0u32, orchard::keys::Scope::Internal);
    let recipient = ZcashAddress::from_unified(
        network.network_type(),
        unified::Address::try_from_items(
            unified::Revision::R0,
            vec![unified::Uitem::Data(unified::Receiver::Orchard(
                receiver.to_raw_address_bytes(),
            ))],
        )
        .map_err(|e| anyhow!("Unable to construct the migration recipient: {}", e))?,
    );

    let request = SendMaxRequest {
        pools: &ORCHARD_ONLY,
        mode: MaxSpendMode::Everything,
        recipient,
        memo: None,
        confirmations_policy: ConfirmationsPolicy::default(),
    };

    // The classification is deliberately not forwarded: this entry point has always reported
    // its failures unclassified, and `send_max::propose` has already logged the unredacted
    // cause at `debug!`.
    send_max::propose(
        db_data,
        network,
        account,
        request,
        "propose_orchard_to_ironwood_migration",
    )
    .map_err(|e| anyhow!("Error creating the migration proposal: {}", e))
}
