use anyhow::anyhow;
use serde::Serialize;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_voting as voting;
use zip32::AccountId;

use super::constants::MIN_SEED_LEN;
use super::errors::{internal, invalid_input};
use super::ffi_types::FfiVotingHotkey;

// =============================================================================
// Helper functions
// =============================================================================

/// Borrow a byte slice from a raw `(ptr, len)` pair.
///
/// When `len == 0`, returns an empty slice without reading `ptr`, so `ptr` may be null.
///
/// Centralizing the null + length check here lets every voting FFI byte input - strings,
/// JSON payloads, anything else - share one boundary contract instead of open-coding it
/// per call site. `str_from_ptr` delegates to this helper.
///
/// # Safety
///
/// When `len > 0`, `ptr` must be non-null and valid for reads for `len` bytes, and the
/// memory must not be mutated for the duration of the call. The returned slice must not
/// outlive the underlying allocation.
pub(super) unsafe fn bytes_from_ptr<'a>(ptr: *const u8, len: usize) -> anyhow::Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(invalid_input("FFI pointer is null but length is non-zero"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Parse a UTF-8 string from a raw pointer and length.
///
/// When `len == 0`, returns the empty string without reading `ptr`, so `ptr` may be null.
///
/// # Safety
///
/// Same contract as `bytes_from_ptr`.
pub(super) unsafe fn str_from_ptr(ptr: *const u8, len: usize) -> anyhow::Result<String> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    let text = std::str::from_utf8(bytes)
        .map_err(|e| invalid_input(format!("FFI string is not valid UTF-8: {e}")))?;
    Ok(text.to_string())
}

/// Return JSON-serialized bytes as `*mut ffi::BoxedSlice`.
///
/// A DTO this crate defines that will not serialize is this crate's fault, not
/// the host's, so the failure crosses as `internal` rather than `invalid_input`.
pub(super) fn json_to_boxed_slice<T: Serialize>(
    value: &T,
) -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
    let json =
        serde_json::to_vec(value).map_err(|e| internal(format!("failed to encode JSON: {e}")))?;
    Ok(crate::ffi::BoxedSlice::some(json))
}

/// Derive the account's unified spending key from `seed`.
///
/// The network is resolved through [`crate::parse_network`] rather than from a
/// bare `Network`, so a custom (modified-mainnet or regtest) chain derives
/// through the same consensus parameters as every other `zcashlc_*` entry
/// point.
pub(super) fn usk_from_seed(
    network_id: u32,
    seed: &[u8],
    account: AccountId,
) -> anyhow::Result<UnifiedSpendingKey> {
    if seed.len() < MIN_SEED_LEN {
        return Err(anyhow!(
            "seed must be at least {} bytes, got {}",
            MIN_SEED_LEN,
            seed.len()
        ));
    }

    let network = crate::parse_network(network_id)?;
    let usk = UnifiedSpendingKey::from_seed(&network, seed, account)
        .map_err(|e| anyhow!("failed to derive UnifiedSpendingKey: {}", e))?;

    Ok(usk)
}

/// Map the SDK's numeric network id onto `zcash_voting`'s network selector.
///
/// `zcash_voting` replaced the numeric `network_id` convention with a typed
/// enum, so every call into the crate needs this conversion at the boundary.
///
/// The custom slot ([`crate::NETWORK_ID_REGTEST`]) has no voting identity of
/// its own: a modified-mainnet chain votes with mainnet hotkeys and HRPs, so
/// its voting network follows the registered base network. Deriving it through
/// [`crate::parse_network`] also means an unconfigured custom slot errors here
/// rather than silently passing for Regtest.
///
/// **Only the base network survives this mapping — the registered activation
/// heights do not.** `zcash_voting::Network` is a three-variant enum with
/// librustzcash's own heights baked in and no room for caller-supplied ones,
/// and the crate re-derives the delegation branch id from that enum in three
/// independent validators, so there is nowhere to put them. A custom chain is
/// therefore only safe to vote on where the branch its heights select equals
/// the one the base network selects; [`require_branch_agreement`] is what
/// enforces that, at session open, before any delegation is built.
pub(super) fn voting_network(network_id: u32) -> anyhow::Result<voting::Network> {
    match network_id {
        crate::NETWORK_ID_TESTNET => Ok(voting::Network::Testnet),
        crate::NETWORK_ID_MAINNET => Ok(voting::Network::Mainnet),
        crate::NETWORK_ID_REGTEST => {
            use zcash_protocol::consensus::{NetworkType, Parameters};
            // `parse_network` reports an unconfigured custom slot as a bare
            // message; re-wrap it so this failure reaches Swift as typed JSON
            // like every other one.
            let params =
                crate::parse_network(network_id).map_err(|e| invalid_input(e.to_string()))?;
            match params.network_type() {
                NetworkType::Main => Ok(voting::Network::Mainnet),
                NetworkType::Test => Ok(voting::Network::Testnet),
                NetworkType::Regtest => Ok(voting::Network::Regtest),
            }
        }
        other => Err(invalid_input(format!(
            "Invalid network type: {}. Expected {}, {}, or {} for Testnet, Mainnet, or a custom network, respectively.",
            other,
            crate::NETWORK_ID_TESTNET,
            crate::NETWORK_ID_MAINNET,
            crate::NETWORK_ID_REGTEST,
        ))),
    }
}

/// Refuse a round whose consensus branch the voting crate would get wrong.
///
/// `params` is the chain the wallet really runs on — for the custom slot, the
/// activation heights a host registered — and `network` is the flattened
/// identity `voting_network` handed `zcash_voting`. Note selection resolves the
/// voting note version through `params`, but everything the crate builds for
/// delegation resolves its consensus branch from `network` alone (and rejects
/// any branch id supplied from outside, in three separate validators). Where
/// the two schedules select different branches at the round's snapshot height,
/// the delegation would be built for a branch this chain is not on, so the
/// round is refused here instead — before the anchor is read, before a PCZT
/// exists and before anything reaches the network.
///
/// Standard networks are unaffected: `params` and `network` are then the same
/// schedule and agree at every height. So is a custom chain that agrees at the
/// snapshot height, even when its schedule differs elsewhere; the branch at
/// that one height is all delegation depends on.
///
/// Pure: reads no global state, so a caller that already resolved its
/// parameters can check any height without re-entering the network registry.
pub(super) fn require_branch_agreement(
    params: &impl zcash_protocol::consensus::Parameters,
    network: voting::Network,
    snapshot_height: u64,
) -> anyhow::Result<()> {
    use zcash_protocol::consensus::{BlockHeight, BranchId};

    // `zcash_voting::lwd::branch_id_for_height` refuses anything wider than a
    // `u32`, so a height that does not fit has no branch on either side.
    let height = u32::try_from(snapshot_height)
        .map(BlockHeight::from_u32)
        .map_err(|_| {
            invalid_input(format!(
                "the round's snapshot height {snapshot_height} does not fit in u32"
            ))
        })?;

    let registered = BranchId::for_height(params, height);
    // The crate's own derivation: `zcash_voting::Network` implements
    // `zcash_protocol::consensus::Parameters` with librustzcash's heights, and
    // `lwd::branch_id_for_height` is exactly this call. Going through the same
    // trait rather than restating the schedule keeps this from drifting when
    // the crate's baked-in heights move.
    let assumed = BranchId::for_height(&network, height);

    if registered != assumed {
        return Err(invalid_input(format!(
            "this network's activation heights select consensus branch {registered:?} at the \
             round's snapshot height {snapshot_height}, but voting delegation follows the \
             {network:?} schedule, which selects {assumed:?}; voting on a custom network is \
             supported only where the two agree"
        )));
    }

    Ok(())
}

// =============================================================================
// Internal helpers
// =============================================================================

/// Convert a `voting::VotingHotkey` to the FFI representation.
///
/// The caller owns the returned allocation and must release it with
/// `zcashlc_voting_free_hotkey`, which zeroizes the secret.
pub(super) fn voting_hotkey_to_ffi(
    hotkey: voting::VotingHotkey,
) -> anyhow::Result<FfiVotingHotkey> {
    let (secret_ptr, secret_len) = crate::ptr_from_vec(hotkey.stored_secret().to_vec());
    let (addr_ptr, addr_len) = crate::ptr_from_vec(hotkey.raw_orchard_address().to_vec());
    Ok(FfiVotingHotkey {
        stored_secret: secret_ptr,
        stored_secret_len: secret_len,
        raw_orchard_address: addr_ptr,
        raw_orchard_address_len: addr_len,
        address_index: hotkey.address_index(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::{
        BlockHeight, BranchId, MAIN_NETWORK, Network, NetworkType, NetworkUpgrade, Parameters,
        TEST_NETWORK,
    };
    use zcash_protocol::local_consensus::LocalNetwork;

    /// Every upgrade a `LocalNetwork` can carry, oldest first.
    ///
    /// `zcashlc_set_custom_network` takes a height for each of these, so a case
    /// that walks them walks the whole surface a host can move.
    const UPGRADES: &[NetworkUpgrade] = &[
        NetworkUpgrade::Overwinter,
        NetworkUpgrade::Sapling,
        NetworkUpgrade::Blossom,
        NetworkUpgrade::Heartwood,
        NetworkUpgrade::Canopy,
        NetworkUpgrade::Nu5,
        NetworkUpgrade::Nu6,
        NetworkUpgrade::Nu6_1,
        NetworkUpgrade::Nu6_2,
        NetworkUpgrade::Nu6_3,
    ];

    /// The standard network behind `base`, as the SDK's own parameters type.
    fn standard(base: NetworkType) -> crate::NetworkParams {
        match base {
            NetworkType::Main => crate::NetworkParams::Standard(Network::MainNetwork),
            NetworkType::Test => crate::NetworkParams::Standard(Network::TestNetwork),
            NetworkType::Regtest => panic!("these cases modify a standard base network"),
        }
    }

    /// `base`'s own activation heights with NU6.3 moved to `nu6_3`, in the shape
    /// [`crate::zcashlc_set_custom_network`] stores: a base identity plus a
    /// [`LocalNetwork`]. Building it here rather than registering it keeps these
    /// cases off the process-global slot.
    fn custom_with_nu6_3(base: NetworkType, nu6_3: u32) -> crate::NetworkParams {
        let standard = standard(base);
        let at = |nu| standard.activation_height(nu);
        crate::NetworkParams::Custom {
            base,
            local: LocalNetwork {
                overwinter: at(NetworkUpgrade::Overwinter),
                sapling: at(NetworkUpgrade::Sapling),
                blossom: at(NetworkUpgrade::Blossom),
                heartwood: at(NetworkUpgrade::Heartwood),
                canopy: at(NetworkUpgrade::Canopy),
                nu5: at(NetworkUpgrade::Nu5),
                nu6: at(NetworkUpgrade::Nu6),
                nu6_1: at(NetworkUpgrade::Nu6_1),
                nu6_2: at(NetworkUpgrade::Nu6_2),
                nu6_3: Some(BlockHeight::from_u32(nu6_3)),
            },
        }
    }

    /// The voting identity a custom network with `base` resolves to, which is
    /// what `voting_network` hands the crate.
    fn voting_identity(base: NetworkType) -> voting::Network {
        match base {
            NetworkType::Main => voting::Network::Mainnet,
            NetworkType::Test => voting::Network::Testnet,
            NetworkType::Regtest => voting::Network::Regtest,
        }
    }

    /// The `message` of a failure that crossed as `VotingErrorView` JSON, after
    /// asserting the kind, so a case reads text only once the envelope is right.
    fn invalid_input_message(err: &anyhow::Error) -> String {
        let view: voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        view.message
    }

    /// A standard network is its own schedule, so the check must never refuse
    /// one: mainnet and testnet, on both sides of every upgrade.
    #[test]
    fn a_standard_network_always_agrees_with_itself() {
        for base in [NetworkType::Main, NetworkType::Test] {
            let params = standard(base);
            let network = voting_identity(base);
            let mut heights = vec![0u64, 1, u64::from(u32::MAX)];
            for nu in UPGRADES {
                let activation = u64::from(u32::from(
                    params.activation_height(*nu).expect("standard activation"),
                ));
                heights.extend([activation - 1, activation, activation + 1]);
            }
            for height in heights {
                require_branch_agreement(&params, network, height)
                    .unwrap_or_else(|e| panic!("{network:?} at {height} must agree: {e}"));
            }
        }
    }

    /// The branch this check credits to the crate must be the branch the crate
    /// will really use, so it is compared against `zcash_voting`'s own public
    /// derivation (`lwd::branch_id_for_height`, which every delegation
    /// validator re-derives through) at every upgrade boundary of every network
    /// the crate has.
    #[test]
    fn the_assumed_branch_matches_the_crates_own_derivation_at_every_boundary() {
        for network in [
            voting::Network::Mainnet,
            voting::Network::Testnet,
            voting::Network::Regtest,
        ] {
            let mut heights = vec![0u64, 1, u64::from(u32::MAX)];
            for nu in UPGRADES {
                if let Some(activation) = network.activation_height(*nu) {
                    let activation = u64::from(u32::from(activation));
                    heights.extend([activation.saturating_sub(1), activation, activation + 1]);
                }
            }
            for height in heights {
                let ours = BranchId::for_height(
                    &network,
                    BlockHeight::from_u32(u32::try_from(height).expect("test height fits")),
                );
                let theirs = voting::lwd::branch_id_for_height(network, height)
                    .expect("the crate resolves a branch for a u32 height");
                assert_eq!(
                    u32::from(ours),
                    theirs,
                    "{network:?} at {height}: this check credits the crate with {ours:?}, \
                     but the crate derives 0x{theirs:08X}"
                );
            }
        }
    }

    /// A deployment that activated NU6.3 early: at a height where the base
    /// network is still pre-Overwinter, the two disagree and the round must be
    /// refused rather than delegated under the wrong branch.
    #[test]
    fn a_modified_mainnet_with_an_earlier_upgrade_is_refused_at_a_height_where_the_branches_differ()
    {
        let params = custom_with_nu6_3(NetworkType::Main, 100);
        let err = require_branch_agreement(&params, voting::Network::Mainnet, 200)
            .expect_err("an early NU6.3 must be refused at a height the base has not reached");
        let message = invalid_input_message(&err);
        assert!(message.contains("Nu6_3"), "{message}");
        assert!(message.contains("Sprout"), "{message}");
    }

    /// The other direction: the deployment has not activated NU6.3 yet at a
    /// height where mainnet already runs it, so the crate would build the
    /// delegation for a branch this chain is not on.
    #[test]
    fn a_custom_upgrade_later_than_the_standard_one_is_refused_too() {
        let params = custom_with_nu6_3(NetworkType::Main, 10_000_000);
        let err = require_branch_agreement(&params, voting::Network::Mainnet, 4_200_000)
            .expect_err("a not-yet-activated NU6.3 must be refused where mainnet has activated it");
        let message = invalid_input_message(&err);
        assert!(message.contains("Nu6_2"), "{message}");
        assert!(message.contains("Nu6_3"), "{message}");
    }

    /// Custom heights are not refused for being custom. A deployment whose
    /// schedule differs from the base but selects the same branch at the
    /// round's snapshot height votes exactly as the base network does.
    #[test]
    fn a_custom_network_that_agrees_at_the_snapshot_height_is_accepted() {
        // Mainnet's own schedule, re-registered by a host that mirrors the node
        // it connects to.
        let mirrored = custom_with_nu6_3(NetworkType::Main, 3_428_143);
        require_branch_agreement(&mirrored, voting::Network::Mainnet, 4_200_000)
            .expect("a mirrored mainnet schedule agrees");

        // NU6.3 moved, but still the newest upgrade at the snapshot height: the
        // branch is the same one, so the delegation the crate builds is valid.
        let moved = custom_with_nu6_3(NetworkType::Main, 3_400_000);
        require_branch_agreement(&moved, voting::Network::Mainnet, 4_200_000)
            .expect("a different schedule that selects the same branch agrees");
    }

    /// The same early-activation refusal on a testnet-based deployment.
    #[test]
    fn a_modified_testnet_with_an_earlier_upgrade_is_refused_at_a_height_where_the_branches_differ()
    {
        let params = custom_with_nu6_3(NetworkType::Test, 100);
        let err = require_branch_agreement(&params, voting::Network::Testnet, 200)
            .expect_err("an early NU6.3 must be refused on testnet too");
        let message = invalid_input_message(&err);
        assert!(message.contains("Nu6_3"), "{message}");
        assert!(message.contains("Testnet"), "{message}");
    }

    /// And the same late-activation refusal on a testnet-based deployment.
    #[test]
    fn a_custom_upgrade_later_than_the_standard_one_is_refused_on_a_modified_testnet_too() {
        let params = custom_with_nu6_3(NetworkType::Test, 10_000_000);
        let err = require_branch_agreement(&params, voting::Network::Testnet, 4_200_000)
            .expect_err("a not-yet-activated NU6.3 must be refused on testnet too");
        let message = invalid_input_message(&err);
        assert!(message.contains("Nu6_2"), "{message}");
        assert!(message.contains("Nu6_3"), "{message}");
    }

    /// A host that sees this refusal has to know which two schedules disagreed
    /// and where. It must not learn anything else it supplied: the registered
    /// activation heights are the host's own configuration and stay out of the
    /// message, which is the rule for every error text crossing this boundary.
    #[test]
    fn the_refusal_names_both_branches_and_the_height() {
        let params = custom_with_nu6_3(NetworkType::Main, 111_111);
        let err = require_branch_agreement(&params, voting::Network::Mainnet, 222_222)
            .expect_err("the branches differ at this height");
        let message = invalid_input_message(&err);
        assert!(message.contains("Nu6_3"), "registered branch: {message}");
        assert!(message.contains("Sprout"), "assumed branch: {message}");
        assert!(message.contains("222222"), "snapshot height: {message}");
        assert!(
            !message.contains("111111"),
            "the registered activation heights are not the host's to read back: {message}"
        );
    }

    /// The crate resolves a branch for `u32` heights only, so a height it could
    /// not take is the caller's input error, reported here rather than as
    /// whatever the crate makes of it later.
    #[test]
    fn a_snapshot_height_beyond_u32_is_refused_as_invalid_input() {
        let params = standard(NetworkType::Main);
        let err =
            require_branch_agreement(&params, voting::Network::Mainnet, u64::from(u32::MAX) + 1)
                .expect_err("a height beyond u32 has no branch");
        let message = invalid_input_message(&err);
        assert!(message.contains("4294967296"), "{message}");
    }

    #[test]
    fn bytes_from_ptr_zero_len_accepts_null() {
        let bytes = unsafe { bytes_from_ptr(std::ptr::null(), 0) }.expect("empty");
        assert!(bytes.is_empty());
    }

    #[test]
    fn bytes_from_ptr_rejects_null_when_nonzero_len() {
        let err = unsafe { bytes_from_ptr(std::ptr::null(), 3) }.expect_err("null");
        // The boundary contract is that every voting FFI failure is
        // `VotingErrorView` JSON, so Swift never has to parse message text.
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        assert!(view.message.contains("null"));
    }

    #[test]
    fn str_from_ptr_zero_len_accepts_null() {
        let s = unsafe { str_from_ptr(std::ptr::null(), 0) }.expect("empty");
        assert!(s.is_empty());
    }

    #[test]
    fn str_from_ptr_rejects_null_when_nonzero_len() {
        let err = unsafe { str_from_ptr(std::ptr::null(), 3) }.expect_err("null");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    /// The custom slot's voting identity follows the registered base network,
    /// so a modified-mainnet chain keeps mainnet hotkeys and HRPs. Asserted
    /// through the store FFI, which is where the process-global custom-network
    /// slot is configured exactly once (see
    /// `store_ffi::tests::db_open_custom_network_derives_voting_network_from_base`);
    /// here only the two standard ids and the rejection are checked, because a
    /// second writer of that global would race it.
    #[test]
    fn voting_network_maps_standard_ids_and_rejects_unknown() {
        assert_eq!(
            voting_network(crate::NETWORK_ID_TESTNET).unwrap(),
            voting::Network::Testnet
        );
        assert_eq!(
            voting_network(crate::NETWORK_ID_MAINNET).unwrap(),
            voting::Network::Mainnet
        );
        let err = voting_network(99).expect_err("unknown network id");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    #[test]
    fn usk_from_seed_uses_sdk_network_ids() {
        let seed = [7u8; 32];
        let account = AccountId::try_from(0).expect("account 0");

        let mainnet_usk = usk_from_seed(1, &seed, account).expect("mainnet usk");
        let expected_mainnet =
            UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &seed, account).expect("mainnet seed");
        assert_eq!(
            mainnet_usk
                .to_unified_full_viewing_key()
                .encode(&MAIN_NETWORK),
            expected_mainnet
                .to_unified_full_viewing_key()
                .encode(&MAIN_NETWORK)
        );

        let testnet_usk = usk_from_seed(0, &seed, account).expect("testnet usk");
        let expected_testnet =
            UnifiedSpendingKey::from_seed(&TEST_NETWORK, &seed, account).expect("testnet seed");
        assert_eq!(
            testnet_usk
                .to_unified_full_viewing_key()
                .encode(&TEST_NETWORK),
            expected_testnet
                .to_unified_full_viewing_key()
                .encode(&TEST_NETWORK)
        );
    }

    #[test]
    fn usk_from_seed_rejects_short_seed() {
        let seed = [7u8; MIN_SEED_LEN - 1];
        let account = AccountId::try_from(0).expect("account 0");

        let err = usk_from_seed(1, &seed, account).expect_err("short seed");

        assert!(
            err.to_string()
                .contains("seed must be at least 32 bytes, got 31")
        );
    }
}
