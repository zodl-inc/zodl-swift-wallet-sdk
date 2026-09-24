//! Software delegation signing and the Keystone signature the device sends back.
//!
//! Two ways to reach the same 64-byte RedPallas SpendAuth signature the crate
//! needs for one delegation bundle. A software wallet derives it here from its
//! own seed; a Keystone wallet's device produced it, and [`keystone_signature`]
//! is where it is lifted out of the PCZT the device signed — after which
//! [`verified_signature_input`] checks that it signs what this wallet asked
//! for, whichever of the two produced it.
//!
//! The crate stopped deriving account keys on the caller's behalf in 2.0 and
//! documents the replacement on `delegate::DelegationSigningRequest`: a
//! software wallet uses `account_index`, `network`, `sighash` and `alpha` to
//! derive its account SpendAuth key locally, randomize it, sign `sighash`, and
//! hand back the signature. So the seed never crosses into `zcash_voting`.
//!
//! # Key material
//!
//! [`SeedSpendAuthSigner`] is the only thing in the voting FFI that holds root
//! seed material, and it holds it for one round-driver run: the session builds
//! it when the run starts, hands the crate an `Arc<dyn SpendAuthSigner>` over
//! it, and drops it when the run ends, at which point [`Zeroizing`] wipes the
//! bytes. Nothing is logged, nothing is persisted, and nothing but the 64-byte
//! signature leaves the signer — not the sighash, not the alpha, not the
//! derived keys. It deliberately has no `Debug`: there is no redacted rendering
//! of a seed worth the risk that someone prints one.

use ff::PrimeField;
use orchard::primitives::redpallas::{Signature, SpendAuth, VerificationKey};
use pasta_curves::pallas;
use zcash_voting::delegate::{
    DelegationSigningRequest, KeystoneSigningRequest, spend_auth_signature,
};
use zcash_voting::storage::KeystoneSignatureInput;
use zcash_voting::{Network, SpendAuthSigner, VotingError};
use zeroize::Zeroizing;
use zip32::AccountId;

use super::constants::MIN_SEED_LEN;
use super::helpers::{usk_from_seed, voting_network};

/// One run's software signer: the wallet seed, and the chain to derive on.
///
/// `network_id` is the SDK's own numeric network, which is what
/// [`usk_from_seed`] derives through, so a custom-parameter chain resolves its
/// consensus parameters the same way every other `zcashlc_*` entry point does.
/// `network` is the crate's view of the same chain, and every request the crate
/// hands over must name it — see [`sign_delegation_request`].
pub(super) struct SeedSpendAuthSigner {
    seed: Zeroizing<Vec<u8>>,
    network_id: u32,
    network: Network,
}

impl SeedSpendAuthSigner {
    /// A signer over `seed`, rejecting anything too short to derive from and
    /// any `network_id` / `network` pair that does not name one chain.
    ///
    /// The seed arrives already wrapped — the FFI moves it into [`Zeroizing`]
    /// the moment it is decoded — so even a rejected one is wiped when this
    /// returns rather than left in a freed allocation.
    ///
    /// The pair is checked once, here, rather than on every signature: it is
    /// what makes deriving through the SDK's numeric network equivalent to
    /// deriving through the network each request names, and the session builds
    /// both from one value, so a disagreement is a host bug and not something
    /// a request can provoke.
    pub(super) fn new(
        seed: Zeroizing<Vec<u8>>,
        network_id: u32,
        network: Network,
    ) -> anyhow::Result<Self> {
        if seed.len() < MIN_SEED_LEN {
            return Err(anyhow::anyhow!(
                "seed must be at least {} bytes, got {}",
                MIN_SEED_LEN,
                seed.len()
            ));
        }
        let id_network = voting_network(network_id)?;
        if id_network != network {
            return Err(anyhow::anyhow!(
                "network id {} is {:?}, which is not the signer's network {:?}",
                network_id,
                id_network,
                network
            ));
        }
        Ok(Self {
            seed,
            network_id,
            network,
        })
    }
}

impl SpendAuthSigner for SeedSpendAuthSigner {
    fn sign(&self, request: DelegationSigningRequest) -> Result<[u8; 64], VotingError> {
        sign_delegation_request(&self.seed, self.network_id, self.network, request)
    }
}

/// Signs one delegation bundle's PCZT sighash with the account's own Orchard
/// SpendAuth key, randomized by the request's `alpha`.
///
/// Every check here is about refusing to sign something this wallet was not
/// asked to sign:
///
/// - the seed must be the one the request names, by ZIP-32 fingerprint, before
///   any key is derived from it;
/// - the request must be for `expected_network`, the network the session was
///   opened on;
/// - `alpha` must decode as a canonical Pallas scalar, so a signature is never
///   produced under a randomizer the crate could not have chosen.
///
/// Only the resulting signature is returned; the request itself is copied
/// nowhere.
///
/// `network_id` is what the derivation uses and `expected_network` is what the
/// request is matched against, so the caller must pass two that name one chain
/// or the derived key is not the account key the request's `alpha` was drawn
/// against. [`SeedSpendAuthSigner::new`] is where that is checked for the
/// signer path.
pub(super) fn sign_delegation_request(
    seed: &[u8],
    network_id: u32,
    expected_network: Network,
    request: DelegationSigningRequest,
) -> Result<[u8; 64], VotingError> {
    // Bind the request to this exact wallet seed before deriving any keys.
    // `from_seed` is also the seed-length check: it returns `None` for anything
    // outside ZIP-32's accepted range, short seeds included.
    let seed_fingerprint = zip32::fingerprint::SeedFingerprint::from_seed(seed)
        .ok_or_else(|| invalid_input("seed length is not valid for ZIP-32"))?;
    if seed_fingerprint.to_bytes() != request.seed_fingerprint {
        return Err(invalid_input(
            "wallet seed fingerprint does not match the delegation signing request",
        ));
    }

    if request.network != expected_network {
        return Err(invalid_input(
            "delegation signing request network does not match the open voting session",
        ));
    }

    let account = AccountId::try_from(request.account_index).map_err(|_| {
        invalid_input(format!(
            "account_index must be < 2^31, got {}",
            request.account_index
        ))
    })?;

    // Decode the randomizer before deriving, so a malformed request never
    // produces key material.
    let alpha = Option::<pallas::Scalar>::from(pallas::Scalar::from_repr(request.alpha))
        .ok_or_else(|| invalid_input("delegation alpha is not a canonical Pallas scalar"))?;

    let usk = usk_from_seed(network_id, seed, account)
        .map_err(|e| internal(format!("failed to derive the account spending key: {e}")))?;
    let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());

    let signature = ask
        .randomize(&alpha)
        .sign(rand::rngs::OsRng, &request.sighash);
    let bytes: [u8; 64] = (&signature).into();
    Ok(bytes)
}

/// Lifts the SpendAuth signature a Keystone device produced out of the PCZT it
/// signed: the action the request named, or, failing that, the first action
/// that carries a signature.
///
/// The signature bytes are the only thing taken from the device's PCZT.
/// Whether they are the signature this wallet asked for is
/// [`verified_signature_input`]'s question, not this one's.
///
/// Every way the lift can fail — bytes that are not a PCZT, a PCZT the wallet
/// cannot read a governance action out of, a readable one carrying no
/// signature at all — is a fault of the response the host handed over, so all
/// of them are the same refusal a host is told to expect and can act on by
/// scanning that bundle's QR again. The response's own bytes stay out of the
/// message.
pub(super) fn keystone_signature(
    request: &KeystoneSigningRequest,
    signed_pczt: &[u8],
) -> Result<[u8; 64], VotingError> {
    spend_auth_signature(signed_pczt, request.action_index as usize).map_err(|_| {
        invalid_input(format!(
            "the response for bundle {} is not a signed PCZT this wallet can read a delegation signature out of",
            request.bundle_index
        ))
    })
}

/// Pairs a signature with the request it was asked for, after checking that it
/// is one: a RedPallas spend-authorization signature over the request's
/// sighash under the request's randomized key.
///
/// The sighash and `rk` stored beside the signature come from the request this
/// wallet built, not from the PCZT the device returned, because they are what
/// the signature is verified against later — here and again when the
/// delegation is proved.
///
/// Checking before storing is the only moment this can be caught. The sidecar
/// keeps the first signature it is given for a bundle and compares only the
/// signing context afterwards, never the signature bytes, and it offers no way
/// to clear one bundle's row; a signature that does not verify would therefore
/// sit there until the whole round was thrown away.
pub(super) fn verified_signature_input(
    request: &KeystoneSigningRequest,
    sig: [u8; 64],
) -> Result<KeystoneSignatureInput, VotingError> {
    // One refusal for every way the pairing can fail. A host can act on all of
    // them the same way — scan the response for this bundle again — and the
    // values that would distinguish them are exactly the ones that must not be
    // rendered into a message.
    let refused = || {
        invalid_input(format!(
            "the signed PCZT for bundle {} does not carry a signature over that bundle's signing request",
            request.bundle_index
        ))
    };

    let rk: [u8; 32] = request.rk.as_slice().try_into().map_err(|_| refused())?;
    let sighash: [u8; 32] = request
        .pczt_sighash
        .as_slice()
        .try_into()
        .map_err(|_| refused())?;
    let key = VerificationKey::<SpendAuth>::try_from(rk).map_err(|_| refused())?;
    // The message is the raw 32 sighash bytes, with no prefix and no
    // personalization: the same thing the crate's own verifier passes when it
    // checks a stored signature, and the same thing the software path above
    // signs. Anything else here would accept signatures the crate then refuses.
    key.verify(&sighash, &Signature::<SpendAuth>::from(sig))
        .map_err(|_| refused())?;

    Ok(KeystoneSignatureInput {
        bundle_index: request.bundle_index,
        sig: sig.to_vec(),
        sighash: request.pczt_sighash.clone(),
        rk: request.rk.clone(),
    })
}

/// Something about the request, the seed or the pairing of the two is wrong —
/// all of it host-side, none of it the crate's.
fn invalid_input(message: impl Into<String>) -> VotingError {
    VotingError::InvalidInput {
        message: message.into(),
    }
}

/// A derivation that should not have been able to fail did.
fn internal(message: impl Into<String>) -> VotingError {
    VotingError::Internal {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::test_support::{
        keystone_request_signed, keystone_request_signed_under, random_alpha,
        synthetic_keystone_request,
    };
    use zcash_voting::Network;
    use zcash_voting::delegate::DelegationSigningRequest;

    fn request_for(seed: &[u8], alpha: [u8; 32]) -> DelegationSigningRequest {
        let fp = zip32::fingerprint::SeedFingerprint::from_seed(seed)
            .unwrap()
            .to_bytes();
        DelegationSigningRequest {
            account_index: 0,
            network: Network::Testnet,
            seed_fingerprint: fp,
            sighash: [7u8; 32],
            alpha,
        }
    }

    /// The only property that matters for the derivation: what comes back is a
    /// signature the crate's own `rk` accepts, so the delegation it guards
    /// verifies on chain.
    #[test]
    fn signature_verifies_under_the_randomized_key() {
        let seed = [1u8; 32];
        let alpha = pasta_curves::pallas::Scalar::from(5u64);
        let request = request_for(&seed, ff::PrimeField::to_repr(&alpha));

        let sig =
            sign_delegation_request(&seed, crate::NETWORK_ID_TESTNET, Network::Testnet, request)
                .unwrap();

        let usk = crate::voting::helpers::usk_from_seed(
            crate::NETWORK_ID_TESTNET,
            &seed,
            zip32::AccountId::ZERO,
        )
        .unwrap();
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
        let rk = orchard::primitives::redpallas::VerificationKey::from(&ask.randomize(&alpha));
        let signature = orchard::primitives::redpallas::Signature::<
            orchard::primitives::redpallas::SpendAuth,
        >::from(sig);
        assert!(rk.verify(&request.sighash, &signature).is_ok());
    }

    #[test]
    fn fingerprint_mismatch_is_invalid_input() {
        let request = request_for(&[2u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("fingerprint"), "unexpected: {err}");
    }

    #[test]
    fn non_canonical_alpha_is_rejected() {
        let request = request_for(&[1u8; 32], [0xffu8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("alpha"), "unexpected: {err}");
    }

    #[test]
    fn network_mismatch_is_rejected() {
        let request = request_for(&[1u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Mainnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    #[test]
    fn short_seed_is_rejected() {
        let request = request_for(&[1u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 16],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("ZIP-32"), "unexpected: {err}");
    }

    /// ZIP-32 account indices are 31-bit; the hardened bit is the derivation's
    /// own. A request naming an index with that bit set has to be refused
    /// before any key is derived, or the derivation would silently sign under
    /// a different account than the one the request named.
    #[test]
    fn account_index_above_the_zip32_range_is_rejected() {
        let seed = [1u8; 32];
        let mut request = request_for(&seed, [0u8; 32]);
        request.account_index = 1 << 31;

        let err =
            sign_delegation_request(&seed, crate::NETWORK_ID_TESTNET, Network::Testnet, request)
                .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(
            err.to_string().contains("account_index"),
            "unexpected: {err}"
        );
    }

    #[test]
    fn seed_signer_rejects_a_seed_too_short_to_derive_from() {
        // The signer holds seed material and so has no `Debug`, which is what
        // keeps the success arm out of `unwrap_err`.
        let err = match SeedSpendAuthSigner::new(
            Zeroizing::new(vec![1u8; 16]),
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
        ) {
            Ok(_) => panic!("a seed too short to derive from must not build a signer"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("seed must be at least 32 bytes"));
    }

    /// The pair is what makes deriving through the SDK's numeric network
    /// equivalent to deriving through the network the request names, so a pair
    /// that disagrees must not become a signer at all.
    #[test]
    fn seed_signer_rejects_a_network_pair_that_disagrees() {
        let err = match SeedSpendAuthSigner::new(
            Zeroizing::new(vec![1u8; 32]),
            crate::NETWORK_ID_MAINNET,
            Network::Testnet,
        ) {
            Ok(_) => panic!("a network id and network that disagree must not build a signer"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    /// The trait impl is the only way the crate reaches the derivation, so it
    /// gets the same end-to-end check the free function does.
    #[test]
    fn seed_signer_signs_through_the_trait() {
        let seed = [1u8; 32];
        let alpha = pasta_curves::pallas::Scalar::from(9u64);
        let request = request_for(&seed, ff::PrimeField::to_repr(&alpha));
        let signer = SeedSpendAuthSigner::new(
            Zeroizing::new(seed.to_vec()),
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
        )
        .unwrap();

        let sig = zcash_voting::SpendAuthSigner::sign(&signer, request).unwrap();

        let usk = crate::voting::helpers::usk_from_seed(
            crate::NETWORK_ID_TESTNET,
            &seed,
            zip32::AccountId::ZERO,
        )
        .unwrap();
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
        let rk = orchard::primitives::redpallas::VerificationKey::from(&ask.randomize(&alpha));
        let signature = orchard::primitives::redpallas::Signature::<
            orchard::primitives::redpallas::SpendAuth,
        >::from(sig);
        assert!(rk.verify(&request.sighash, &signature).is_ok());
    }

    #[test]
    fn seed_signer_rejects_a_request_for_another_network() {
        let seed = [1u8; 32];
        let request = request_for(&seed, [0u8; 32]);
        let signer = SeedSpendAuthSigner::new(
            Zeroizing::new(seed.to_vec()),
            crate::NETWORK_ID_MAINNET,
            Network::Mainnet,
        )
        .unwrap();

        let err = zcash_voting::SpendAuthSigner::sign(&signer, request).unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    /// A signature can only be stored against a PCZT the crate can read, so
    /// bytes that are not one must not reach storage as an empty signature.
    #[test]
    fn keystone_signature_rejects_bytes_that_are_not_a_pczt() {
        let request = synthetic_keystone_request();

        let err = keystone_signature(&request, b"not a pczt").unwrap_err();

        assert!(err.to_string().contains("PCZT"), "unexpected error: {err}");
    }

    /// A PCZT a device could have produced and this wallet can read, holding
    /// no shielded action and so no spend-authorization signature to lift.
    fn pczt_carrying_no_signature() -> Vec<u8> {
        pczt::roles::creator::Creator::new(
            u32::from(zcash_protocol::consensus::BranchId::Nu6_3),
            0,
            1,
            None,
            None,
        )
        .expect("a v6 PCZT for the branch voting builds on")
        .build()
        .expect("an empty PCZT needs no anchor")
        .serialize()
        .expect("an empty PCZT encodes")
    }

    /// Both ways a response can fail to yield a signature are the device's
    /// answer being unusable, not the wallet asking for the wrong thing, so
    /// both are the typed refusal every document promises for a response that
    /// cannot be used — and both name the bundle whose QR to scan again.
    #[test]
    fn a_response_no_signature_can_be_lifted_from_is_refused_as_invalid_input() {
        let mut request = synthetic_keystone_request();
        request.bundle_index = 4;

        for response in [b"not a pczt".to_vec(), pczt_carrying_no_signature()] {
            let err = match keystone_signature(&request, &response) {
                Ok(sig) => panic!(
                    "a response carrying no signature must not yield {} bytes",
                    sig.len()
                ),
                Err(err) => err,
            };

            assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
            let message = err.to_string();
            assert!(message.contains("bundle 4"), "unexpected: {message}");
            assert!(message.contains("PCZT"), "unexpected: {message}");
            assert!(
                !message.contains(&hex::encode(&response)),
                "a refusal must not carry the response's bytes: {message}"
            );
        }
    }

    fn assert_refused(request: &KeystoneSigningRequest, sig: [u8; 64]) -> VotingError {
        let err = match verified_signature_input(request, sig) {
            Ok(input) => panic!(
                "a signature that does not sign the request must not be stored: {:?}",
                input.bundle_index
            ),
            Err(err) => err,
        };
        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        err
    }

    /// The pairing the sidecar stores is the request's own context beside the
    /// device's bytes, so what comes back must carry the request's bundle,
    /// sighash and `rk` — not anything re-derived from the signature.
    #[test]
    fn a_signature_over_the_requests_sighash_under_its_rk_is_accepted() {
        let (request, sig) = keystone_request_signed([0x11u8; 32]);

        let input = verified_signature_input(&request, sig).expect("the request's own signature");

        assert_eq!(input.bundle_index, request.bundle_index);
        assert_eq!(input.sig, sig.to_vec());
        assert_eq!(input.sighash, request.pczt_sighash);
        assert_eq!(input.rk, request.rk);
    }

    /// The defect this guards: a second QR scanned against the wrong bundle is
    /// a well-formed signature for a different request entirely.
    #[test]
    fn a_signature_made_for_another_request_is_refused() {
        let (a, _) = keystone_request_signed([0x11u8; 32]);
        let (b, b_sig) = keystone_request_signed([0x22u8; 32]);
        assert_ne!(a.rk, b.rk);
        assert_ne!(a.pczt_sighash, b.pczt_sighash);

        assert_refused(&a, b_sig);
    }

    #[test]
    fn a_signature_over_another_sighash_is_refused() {
        let alpha = random_alpha();
        let (request, _) = keystone_request_signed_under(&alpha, [0x11u8; 32]);
        let (other, other_sig) = keystone_request_signed_under(&alpha, [0x22u8; 32]);
        assert_eq!(request.rk, other.rk, "the same key signed both messages");

        assert_refused(&request, other_sig);
    }

    #[test]
    fn a_signature_under_another_key_is_refused() {
        let sighash = [0x33u8; 32];
        let (request, _) = keystone_request_signed(sighash);
        let (other, other_sig) = keystone_request_signed(sighash);
        assert_ne!(request.rk, other.rk);
        assert_eq!(
            request.pczt_sighash, other.pczt_sighash,
            "the same message was signed twice"
        );

        assert_refused(&request, other_sig);
    }

    /// A request the wallet could not have built is still a refusal rather
    /// than a panic: the check decodes before it verifies.
    #[test]
    fn a_request_whose_rk_is_not_a_valid_key_is_refused() {
        let (mut request, sig) = keystone_request_signed([0x44u8; 32]);
        request.rk = vec![0xffu8; 32];

        assert_refused(&request, sig);
    }

    #[test]
    fn a_request_with_a_short_sighash_or_rk_is_refused() {
        let (request, sig) = keystone_request_signed([0x55u8; 32]);

        let mut short_sighash = request.clone();
        short_sighash.pczt_sighash.truncate(31);
        let mut short_rk = request.clone();
        short_rk.rk.truncate(31);

        for bad in [short_sighash, short_rk] {
            assert_refused(&bad, sig);
        }
    }

    /// The refusal reaches a host's log, so it says which bundle to rescan and
    /// nothing else: not the signature, not the key, not the sighash.
    #[test]
    fn a_refusal_names_the_bundle_and_nothing_secret() {
        let (mut request, _) = keystone_request_signed([0x66u8; 32]);
        request.bundle_index = 3;
        let (_, other_sig) = keystone_request_signed([0x77u8; 32]);

        let message = assert_refused(&request, other_sig).to_string();

        assert!(message.contains("bundle 3"), "unexpected: {message}");
        for secret in [
            hex::encode(other_sig),
            hex::encode(&request.rk),
            hex::encode(&request.pczt_sighash),
        ] {
            assert!(
                !message.contains(&secret),
                "a refusal must not carry key, signature or sighash bytes: {message}"
            );
        }
    }
}
