//! Sapling proving for transaction creation without requiring the Sapling parameters when a
//! proposal never touches the Sapling pool.
//!
//! [`LocalTxProver::new`] reads (and panics on missing) the ~50 MB Sapling spend and output
//! parameter files. A proposal that has no Sapling inputs, no Sapling payments, no Sapling change
//! and no Sapling dummy outputs builds a transaction without a Sapling bundle, so the builder never
//! asks the prover for a Sapling proof. For those proposals [`SaplingProver::Unavailable`] stands
//! in for the real prover, which lets a brand-new wallet spend Orchard or Ironwood funds without
//! first downloading the parameters.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::slice;

use ffi_helpers::panic::catch_panic;
use prost::Message;
use rand::rand_core::Rng;
use sapling::{
    Diversifier, MerklePath, PaymentAddress, ProofGenerationKey, Rseed,
    bundle::GrothProofBytes,
    circuit,
    keys::EphemeralSecretKey,
    prover::{OutputProver, SpendProver},
    value::{NoteValue, ValueCommitTrapdoor},
};
use zcash_client_backend::proto::proposal::{Proposal, ValuePool, proposed_input};
use zcash_proofs::prover::LocalTxProver;

use crate::unwrap_exc_or;

/// Returns `true` when building the transactions of `proposal` may require a Sapling proof.
///
/// The check is conservative: any input, payment, change output or dummy output in the Sapling
/// pool counts, and so does a pool the proposal leaves unspecified. Inputs that consume the
/// outputs of an earlier step are covered by that earlier step's payments and change.
pub(crate) fn proposal_requires_sapling_proving(proposal: &Proposal) -> bool {
    let touches_sapling = |pool: i32| match ValuePool::try_from(pool) {
        Ok(ValuePool::Sapling) | Ok(ValuePool::PoolNotSpecified) | Err(_) => true,
        Ok(ValuePool::Transparent) | Ok(ValuePool::Orchard) | Ok(ValuePool::Ironwood) => false,
    };

    proposal.steps.iter().any(|step| {
        let sapling_inputs = step.inputs.iter().any(|input| match &input.value {
            Some(proposed_input::Value::ReceivedOutput(output)) => {
                touches_sapling(output.value_pool)
            }
            Some(proposed_input::Value::PriorStepOutput(_))
            | Some(proposed_input::Value::PriorStepChange(_)) => false,
            None => true,
        });
        let sapling_payments = step
            .payment_output_pools
            .iter()
            .any(|output| touches_sapling(output.value_pool));
        let sapling_change_or_padding = step.balance.as_ref().is_none_or(|balance| {
            balance
                .proposed_change
                .iter()
                .any(|change| touches_sapling(change.value_pool))
                || balance
                    .dummy_outputs
                    .as_ref()
                    .is_some_and(|dummies| dummies.sapling > 0)
        });

        sapling_inputs || sapling_payments || sapling_change_or_padding
    })
}

/// A Sapling prover that loads the proving parameters only when a proposal needs them.
pub(crate) enum SaplingProver {
    /// The parameters are loaded and Sapling proofs can be created.
    Local(LocalTxProver),
    /// The parameters were not loaded because the proposal has no Sapling bundle.
    ///
    /// The transaction builder only invokes the prover for a Sapling bundle, so creating a proof
    /// here means [`proposal_requires_sapling_proving`] misjudged the proposal. That is a bug,
    /// and the prover traits cannot return an error, so it panics; every FFI entry point catches
    /// panics and reports them as an error, so no transaction is created.
    Unavailable,
}

impl SaplingProver {
    /// Chooses the prover for a proposal.
    ///
    /// # Safety
    ///
    /// `spend_params` and `output_params` must each be null or valid for reads for the
    /// corresponding length, as described by `zcashlc_create_proposed_transactions`.
    pub(crate) unsafe fn for_proposal(
        proposal: &Proposal,
        spend_params: *const u8,
        spend_params_len: usize,
        output_params: *const u8,
        output_params_len: usize,
    ) -> anyhow::Result<Self> {
        if !proposal_requires_sapling_proving(proposal) {
            return Ok(SaplingProver::Unavailable);
        }
        if spend_params.is_null() || output_params.is_null() {
            return Err(anyhow::anyhow!(
                "Sapling proving parameters are required to create this proposal's transactions"
            ));
        }
        let spend_params = Path::new(OsStr::from_bytes(unsafe {
            slice::from_raw_parts(spend_params, spend_params_len)
        }));
        let output_params = Path::new(OsStr::from_bytes(unsafe {
            slice::from_raw_parts(output_params, output_params_len)
        }));
        Ok(SaplingProver::Local(LocalTxProver::new(
            spend_params,
            output_params,
        )))
    }

    fn local(&self) -> &LocalTxProver {
        match self {
            SaplingProver::Local(prover) => prover,
            SaplingProver::Unavailable => panic!(
                "a Sapling proof was requested for a proposal that was judged to have no Sapling bundle"
            ),
        }
    }
}

impl SpendProver for SaplingProver {
    type Proof = <LocalTxProver as SpendProver>::Proof;

    fn prepare_circuit(
        proof_generation_key: ProofGenerationKey,
        diversifier: Diversifier,
        rseed: Rseed,
        value: NoteValue,
        alpha: jubjub::Fr,
        rcv: ValueCommitTrapdoor,
        anchor: bls12_381::Scalar,
        merkle_path: MerklePath,
    ) -> Option<circuit::Spend> {
        <LocalTxProver as SpendProver>::prepare_circuit(
            proof_generation_key,
            diversifier,
            rseed,
            value,
            alpha,
            rcv,
            anchor,
            merkle_path,
        )
    }

    fn create_proof<R: Rng>(&self, circuit: circuit::Spend, rng: &mut R) -> Self::Proof {
        SpendProver::create_proof(self.local(), circuit, rng)
    }

    fn encode_proof(proof: Self::Proof) -> GrothProofBytes {
        <LocalTxProver as SpendProver>::encode_proof(proof)
    }
}

impl OutputProver for SaplingProver {
    type Proof = <LocalTxProver as OutputProver>::Proof;

    fn prepare_circuit(
        esk: &EphemeralSecretKey,
        payment_address: PaymentAddress,
        rcm: jubjub::Fr,
        value: NoteValue,
        rcv: ValueCommitTrapdoor,
    ) -> circuit::Output {
        <LocalTxProver as OutputProver>::prepare_circuit(esk, payment_address, rcm, value, rcv)
    }

    fn create_proof<R: Rng>(&self, circuit: circuit::Output, rng: &mut R) -> Self::Proof {
        OutputProver::create_proof(self.local(), circuit, rng)
    }

    fn encode_proof(proof: Self::Proof) -> GrothProofBytes {
        <LocalTxProver as OutputProver>::encode_proof(proof)
    }
}

/// Reports whether creating the transactions of a proposal requires the Sapling proving
/// parameters.
///
/// Returns 1 when the parameters are required, 0 when they are not, and -1 on error (the
/// proposal does not decode), in which case the error is available via
/// `zcashlc_last_error_message`. This performs no database access.
///
/// # Safety
///
/// - `proposal_ptr` must be non-null and valid for reads for `proposal_len` bytes, and it must
///   have an alignment of `1`. Its contents must be an encoded Proposal protobuf.
/// - The memory referenced by `proposal_ptr` must not be mutated for the duration of the
///   function call.
/// - The total size `proposal_len` must be no larger than `isize::MAX`. See the safety
///   documentation of `pointer::offset`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_proposal_requires_sapling_params(
    proposal_ptr: *const u8,
    proposal_len: usize,
) -> i8 {
    let res = catch_panic(|| {
        let proposal =
            Proposal::decode(unsafe { slice::from_raw_parts(proposal_ptr, proposal_len) })
                .map_err(|_| anyhow::anyhow!("the proposal could not be decoded"))?;
        Ok(if proposal_requires_sapling_proving(&proposal) {
            1
        } else {
            0
        })
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use zcash_client_backend::proto::proposal::{
        ChangeValue, DummyOutputs, PaymentOutputPool, PriorStepChange, ProposalStep, ProposedInput,
        ReceivedOutput, TransactionBalance,
    };

    use super::*;

    fn received(pool: ValuePool) -> ProposedInput {
        ProposedInput {
            value: Some(proposed_input::Value::ReceivedOutput(ReceivedOutput {
                txid: vec![0; 32],
                value_pool: pool as i32,
                index: 0,
                value: 100_000,
            })),
        }
    }

    fn change(pool: ValuePool) -> ChangeValue {
        ChangeValue {
            value: 1_000,
            value_pool: pool as i32,
            memo: None,
            is_ephemeral: false,
        }
    }

    fn step(
        inputs: Vec<ProposedInput>,
        payment_pools: &[ValuePool],
        change: Vec<ChangeValue>,
        sapling_dummies: u32,
    ) -> ProposalStep {
        ProposalStep {
            transaction_request: "zcash:".into(),
            payment_output_pools: payment_pools
                .iter()
                .enumerate()
                .map(|(i, pool)| PaymentOutputPool {
                    payment_index: i as u32,
                    value_pool: *pool as i32,
                })
                .collect(),
            anchor_height: 1,
            inputs,
            balance: Some(TransactionBalance {
                proposed_change: change,
                fee_required: 10_000,
                dummy_outputs: Some(DummyOutputs {
                    sapling: sapling_dummies,
                    orchard: 0,
                    ironwood: 0,
                }),
            }),
            is_shielding: false,
        }
    }

    fn proposal(steps: Vec<ProposalStep>) -> Proposal {
        Proposal {
            steps,
            ..Default::default()
        }
    }

    #[test]
    fn orchard_and_ironwood_only_proposals_do_not_need_sapling() {
        // The gift card redemption shape: Orchard or Ironwood notes swept to one recipient.
        for pool in [ValuePool::Orchard, ValuePool::Ironwood] {
            let p = proposal(vec![step(vec![received(pool)], &[pool], vec![], 0)]);
            assert!(!proposal_requires_sapling_proving(&p));
        }
        // Change and transparent payments outside Sapling do not need Sapling either.
        let p = proposal(vec![step(
            vec![received(ValuePool::Orchard)],
            &[ValuePool::Transparent, ValuePool::Ironwood],
            vec![change(ValuePool::Ironwood)],
            0,
        )]);
        assert!(!proposal_requires_sapling_proving(&p));
    }

    #[test]
    fn any_sapling_component_needs_sapling() {
        let cases = [
            step(
                vec![received(ValuePool::Sapling)],
                &[ValuePool::Orchard],
                vec![],
                0,
            ),
            step(
                vec![received(ValuePool::Orchard)],
                &[ValuePool::Sapling],
                vec![],
                0,
            ),
            step(
                vec![received(ValuePool::Orchard)],
                &[ValuePool::Orchard],
                vec![change(ValuePool::Sapling)],
                0,
            ),
            step(
                vec![received(ValuePool::Orchard)],
                &[ValuePool::Orchard],
                vec![],
                2,
            ),
            // An unspecified pool is treated as Sapling.
            step(
                vec![received(ValuePool::PoolNotSpecified)],
                &[ValuePool::Orchard],
                vec![],
                0,
            ),
        ];
        for case in cases {
            assert!(proposal_requires_sapling_proving(&proposal(vec![case])));
        }

        // A step without a balance is malformed; it is treated conservatively.
        let mut no_balance = step(
            vec![received(ValuePool::Orchard)],
            &[ValuePool::Orchard],
            vec![],
            0,
        );
        no_balance.balance = None;
        assert!(proposal_requires_sapling_proving(&proposal(vec![
            no_balance
        ])));
    }

    #[test]
    fn later_steps_are_checked() {
        let first = step(
            vec![received(ValuePool::Orchard)],
            &[ValuePool::Transparent],
            vec![],
            0,
        );
        let mut second = step(vec![], &[ValuePool::Sapling], vec![], 0);
        second.inputs = vec![ProposedInput {
            value: Some(proposed_input::Value::PriorStepChange(PriorStepChange {
                step_index: 0,
                change_index: 0,
            })),
        }];
        assert!(proposal_requires_sapling_proving(&proposal(vec![
            first.clone(),
            second
        ])));
        assert!(!proposal_requires_sapling_proving(&proposal(vec![first])));
    }

    #[test]
    fn non_sapling_proposals_never_load_parameters() {
        let p = proposal(vec![step(
            vec![received(ValuePool::Ironwood)],
            &[ValuePool::Ironwood],
            vec![],
            0,
        )]);
        // Null parameter paths are fine: the files are never opened.
        let prover =
            unsafe { SaplingProver::for_proposal(&p, std::ptr::null(), 0, std::ptr::null(), 0) }
                .unwrap();
        assert!(matches!(prover, SaplingProver::Unavailable));

        // A Sapling proposal without parameter paths is refused rather than proven badly.
        let sapling = proposal(vec![step(
            vec![received(ValuePool::Sapling)],
            &[ValuePool::Orchard],
            vec![],
            0,
        )]);
        let refused = unsafe {
            SaplingProver::for_proposal(&sapling, std::ptr::null(), 0, std::ptr::null(), 0)
        };
        assert!(refused.is_err());
    }

    #[test]
    #[should_panic(expected = "judged to have no Sapling bundle")]
    fn the_unavailable_prover_refuses_to_prove() {
        let _ = SaplingProver::Unavailable.local();
    }

    #[test]
    fn ffi_reports_sapling_requirement() {
        let orchard = proposal(vec![step(
            vec![received(ValuePool::Orchard)],
            &[ValuePool::Orchard],
            vec![],
            0,
        )])
        .encode_to_vec();
        let sapling = proposal(vec![step(
            vec![received(ValuePool::Sapling)],
            &[ValuePool::Orchard],
            vec![],
            0,
        )])
        .encode_to_vec();
        unsafe {
            assert_eq!(
                zcashlc_proposal_requires_sapling_params(orchard.as_ptr(), orchard.len()),
                0
            );
            assert_eq!(
                zcashlc_proposal_requires_sapling_params(sapling.as_ptr(), sapling.len()),
                1
            );
            let garbage = [0xffu8; 7];
            assert_eq!(
                zcashlc_proposal_requires_sapling_params(garbage.as_ptr(), garbage.len()),
                -1
            );
        }
    }
}
