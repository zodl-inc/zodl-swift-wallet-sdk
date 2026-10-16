//! Holding a proposal to a size below what consensus allows.
//!
//! Consensus caps a transaction at the size of a block, and `zcash_client_backend` already
//! enforces that. A wallet often needs a tighter bound: relays refuse transactions well below a
//! block, proving a transaction takes memory in proportion to its actions, and an external signer
//! can only sign so many inputs or outputs at once. [`TransactionSizeBound`] states such a bound
//! and [`enforce`] holds a proposal to it.
//!
//! Every count here is `zcash_client_backend`'s own: the proposal's estimated serialized size
//! (`Proposal::estimated_serialized_size`), the action counts the builder produces
//! (`Step::orchard_action_count`, `Step::ironwood_action_count`, the Sapling builder's padding),
//! and the step's input and output counts. Nothing is re-estimated here.
//!
//! The pinned `zcash_client_backend` has no bound of its own yet. When it gains one
//! (`Proposal::check_transaction_size_within`), this module collapses to a conversion from
//! [`TransactionSizeBound`] into it, and [`enforce`] to a call of that check.
//!
//! A bound is applied only where a caller passes one: the user's send-max, proposing a transfer
//! (to an address or from a payment URI), and creating transactions or a PCZT from a proposal.
//! The migration lanes and shielding never take one, so they propose as they always have.

use std::fmt;

use nonempty::NonEmpty;
use orchard::ValuePool;
use tracing::debug;
use zcash_client_backend::proposal::{Proposal, Step, StepOutput, StepOutputIndex};
use zcash_primitives::transaction::{
    builder::BundlePadding, components::orchard::bundle_version_for_branch,
};
use zcash_protocol::{
    PoolType, ShieldedPool,
    consensus::{BlockHeight, BranchId, Parameters},
};

use crate::error_report::{ClassifiedError, ErrorKind};
use crate::ffi::FfiTransactionSizeBound;

#[cfg(test)]
mod tests;

/// Caps on a proposal's transactions, each optional. A bound with no caps is consensus only.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct TransactionSizeBound {
    max_bytes: Option<usize>,
    max_shielded_actions: Option<usize>,
    max_sapling_actions: Option<usize>,
    max_orchard_actions: Option<usize>,
    max_ironwood_actions: Option<usize>,
    max_transparent_inputs: Option<usize>,
    max_transparent_outputs: Option<usize>,
    max_shielded_payment_outputs: Option<usize>,
}

// The builders and `intersect` mirror the API upstream is gaining, which this type collapses to.
// The wallet combines its bounds on the Swift side and the FFI conversion sets fields directly, so
// outside the tests nothing here calls them yet.
#[cfg_attr(not(test), allow(dead_code))]
impl TransactionSizeBound {
    /// Consensus only: no cap beyond what `zcash_client_backend` already enforces.
    pub(crate) const CONSENSUS: Self = Self {
        max_bytes: None,
        max_shielded_actions: None,
        max_sapling_actions: None,
        max_orchard_actions: None,
        max_ironwood_actions: None,
        max_transparent_inputs: None,
        max_transparent_outputs: None,
        max_shielded_payment_outputs: None,
    };

    /// Caps the estimated serialized size of the proposal's transactions together.
    pub(crate) fn with_max_bytes(self, n: usize) -> Self {
        Self {
            max_bytes: Some(n),
            ..self
        }
    }

    /// Caps Sapling, Orchard and Ironwood actions together, in each transaction.
    pub(crate) fn with_max_shielded_actions(self, n: usize) -> Self {
        Self {
            max_shielded_actions: Some(n),
            ..self
        }
    }

    /// Caps the actions of one pool in each transaction; `0` forbids the pool.
    pub(crate) fn with_max_pool_actions(self, pool: ShieldedPool, n: usize) -> Self {
        match pool {
            ShieldedPool::Sapling => Self {
                max_sapling_actions: Some(n),
                ..self
            },
            ShieldedPool::Orchard => Self {
                max_orchard_actions: Some(n),
                ..self
            },
            ShieldedPool::Ironwood => Self {
                max_ironwood_actions: Some(n),
                ..self
            },
        }
    }

    /// Caps the transparent inputs of each transaction.
    pub(crate) fn with_max_transparent_inputs(self, n: usize) -> Self {
        Self {
            max_transparent_inputs: Some(n),
            ..self
        }
    }

    /// Caps the transparent outputs of each transaction, change included.
    pub(crate) fn with_max_transparent_outputs(self, n: usize) -> Self {
        Self {
            max_transparent_outputs: Some(n),
            ..self
        }
    }

    /// Caps the shielded outputs of each transaction that pay a recipient rather than return
    /// change to the wallet.
    pub(crate) fn with_max_shielded_payment_outputs(self, n: usize) -> Self {
        Self {
            max_shielded_payment_outputs: Some(n),
            ..self
        }
    }

    /// The tighter of `self` and `other` in every dimension, so a relay bound, a proving-memory
    /// bound and a signer's bound can be combined into one.
    pub(crate) fn intersect(&self, other: &Self) -> Self {
        fn min(a: Option<usize>, b: Option<usize>) -> Option<usize> {
            match (a, b) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            }
        }
        Self {
            max_bytes: min(self.max_bytes, other.max_bytes),
            max_shielded_actions: min(self.max_shielded_actions, other.max_shielded_actions),
            max_sapling_actions: min(self.max_sapling_actions, other.max_sapling_actions),
            max_orchard_actions: min(self.max_orchard_actions, other.max_orchard_actions),
            max_ironwood_actions: min(self.max_ironwood_actions, other.max_ironwood_actions),
            max_transparent_inputs: min(self.max_transparent_inputs, other.max_transparent_inputs),
            max_transparent_outputs: min(
                self.max_transparent_outputs,
                other.max_transparent_outputs,
            ),
            max_shielded_payment_outputs: min(
                self.max_shielded_payment_outputs,
                other.max_shielded_payment_outputs,
            ),
        }
    }

    /// Whether this bound caps nothing beyond consensus.
    pub(crate) fn is_consensus(&self) -> bool {
        *self == Self::CONSENSUS
    }

    fn max_pool_actions(&self, pool: ShieldedPool) -> Option<usize> {
        match pool {
            ShieldedPool::Sapling => self.max_sapling_actions,
            ShieldedPool::Orchard => self.max_orchard_actions,
            ShieldedPool::Ironwood => self.max_ironwood_actions,
        }
    }

    /// Checks `proposal` against this bound, returning the first cap it exceeds. `params` decide
    /// the consensus rules the proposal's transactions are built under, and so their actions.
    ///
    /// The byte cap applies to the proposal's transactions together, which is exact for the
    /// single-transaction proposals a bound is meant for and conservative otherwise. Every other
    /// cap applies to each transaction on its own.
    pub(crate) fn check<P: Parameters, FeeRuleT, NoteRef>(
        &self,
        proposal: &Proposal<FeeRuleT, NoteRef>,
        params: &P,
    ) -> Result<(), SizeBoundViolation> {
        if self.is_consensus() {
            return Ok(());
        }
        if let Some(limit) = self.max_bytes {
            let estimated = proposal.estimated_serialized_size();
            if estimated > limit {
                return Err(SizeBoundViolation::Bytes { estimated, limit });
            }
        }
        let branch = BranchId::for_height(params, BlockHeight::from(proposal.min_target_height()));
        let steps = proposal.steps();
        for (step_index, step) in steps.iter().enumerate() {
            let counts = StepCounts::of(steps, step, branch);
            self.check_step(&counts)
                .map_err(|violation| violation.at(step_index))?;
        }
        Ok(())
    }

    fn check_step(&self, counts: &StepCounts) -> Result<(), StepViolation> {
        fn cap(
            count: usize,
            limit: Option<usize>,
            dimension: Dimension,
        ) -> Result<(), StepViolation> {
            match limit {
                Some(limit) if count > limit => Err(StepViolation {
                    dimension,
                    count,
                    limit,
                }),
                _ => Ok(()),
            }
        }
        cap(
            counts.shielded_actions(),
            self.max_shielded_actions,
            Dimension::ShieldedActions,
        )?;
        for pool in [
            ShieldedPool::Sapling,
            ShieldedPool::Orchard,
            ShieldedPool::Ironwood,
        ] {
            cap(
                counts.pool_actions(pool),
                self.max_pool_actions(pool),
                Dimension::PoolActions(pool),
            )?;
        }
        cap(
            counts.transparent_inputs,
            self.max_transparent_inputs,
            Dimension::TransparentInputs,
        )?;
        cap(
            counts.transparent_outputs,
            self.max_transparent_outputs,
            Dimension::TransparentOutputs,
        )?;
        cap(
            counts.shielded_payment_outputs,
            self.max_shielded_payment_outputs,
            Dimension::ShieldedPaymentOutputs,
        )
    }
}

impl TryFrom<FfiTransactionSizeBound> for TransactionSizeBound {
    type Error = anyhow::Error;

    fn try_from(ffi: FfiTransactionSizeBound) -> Result<Self, Self::Error> {
        fn cap(value: i64, field: &'static str) -> anyhow::Result<Option<usize>> {
            match value {
                -1 => Ok(None),
                n => usize::try_from(n)
                    .map(Some)
                    .map_err(|_| anyhow::anyhow!("{field} must be -1 (no cap) or non-negative")),
            }
        }
        Ok(Self {
            max_bytes: cap(ffi.max_bytes, "max_bytes")?,
            max_shielded_actions: cap(ffi.max_shielded_actions, "max_shielded_actions")?,
            max_sapling_actions: cap(ffi.max_sapling_actions, "max_sapling_actions")?,
            max_orchard_actions: cap(ffi.max_orchard_actions, "max_orchard_actions")?,
            max_ironwood_actions: cap(ffi.max_ironwood_actions, "max_ironwood_actions")?,
            max_transparent_inputs: cap(ffi.max_transparent_inputs, "max_transparent_inputs")?,
            max_transparent_outputs: cap(ffi.max_transparent_outputs, "max_transparent_outputs")?,
            max_shielded_payment_outputs: cap(
                ffi.max_shielded_payment_outputs,
                "max_shielded_payment_outputs",
            )?,
        })
    }
}

/// The cap a proposal exceeded, and by how much.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SizeBoundViolation {
    /// The proposal's estimated serialized size exceeds the byte cap.
    Bytes { estimated: usize, limit: usize },
    /// A transaction's shielded actions, all pools together, exceed their cap.
    ShieldedActions {
        step_index: usize,
        count: usize,
        limit: usize,
    },
    /// A transaction's actions in `pool` exceed that pool's cap.
    PoolActions {
        step_index: usize,
        pool: ShieldedPool,
        count: usize,
        limit: usize,
    },
    /// A transaction's transparent inputs exceed their cap.
    TransparentInputs {
        step_index: usize,
        count: usize,
        limit: usize,
    },
    /// A transaction's transparent outputs exceed their cap.
    TransparentOutputs {
        step_index: usize,
        count: usize,
        limit: usize,
    },
    /// A transaction's shielded payment outputs exceed their cap.
    ShieldedPaymentOutputs {
        step_index: usize,
        count: usize,
        limit: usize,
    },
}

impl fmt::Display for SizeBoundViolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Bytes { estimated, limit } => {
                write!(f, "estimated size {estimated} B exceeds the {limit} B cap")
            }
            Self::ShieldedActions {
                step_index,
                count,
                limit,
            } => write!(
                f,
                "step {step_index}: {count} shielded actions exceed the cap of {limit}"
            ),
            Self::PoolActions {
                step_index,
                pool,
                count,
                limit,
            } => write!(
                f,
                "step {step_index}: {count} {pool:?} actions exceed the cap of {limit}"
            ),
            Self::TransparentInputs {
                step_index,
                count,
                limit,
            } => write!(
                f,
                "step {step_index}: {count} transparent inputs exceed the cap of {limit}"
            ),
            Self::TransparentOutputs {
                step_index,
                count,
                limit,
            } => write!(
                f,
                "step {step_index}: {count} transparent outputs exceed the cap of {limit}"
            ),
            Self::ShieldedPaymentOutputs {
                step_index,
                count,
                limit,
            } => write!(
                f,
                "step {step_index}: {count} shielded payment outputs exceed the cap of {limit}"
            ),
        }
    }
}

/// The dimension a per-transaction cap applies to.
#[derive(Clone, Copy, Debug)]
enum Dimension {
    ShieldedActions,
    PoolActions(ShieldedPool),
    TransparentInputs,
    TransparentOutputs,
    ShieldedPaymentOutputs,
}

/// A per-transaction violation before the step it was found in is known.
struct StepViolation {
    dimension: Dimension,
    count: usize,
    limit: usize,
}

impl StepViolation {
    fn at(self, step_index: usize) -> SizeBoundViolation {
        let Self {
            dimension,
            count,
            limit,
        } = self;
        match dimension {
            Dimension::ShieldedActions => SizeBoundViolation::ShieldedActions {
                step_index,
                count,
                limit,
            },
            Dimension::PoolActions(pool) => SizeBoundViolation::PoolActions {
                step_index,
                pool,
                count,
                limit,
            },
            Dimension::TransparentInputs => SizeBoundViolation::TransparentInputs {
                step_index,
                count,
                limit,
            },
            Dimension::TransparentOutputs => SizeBoundViolation::TransparentOutputs {
                step_index,
                count,
                limit,
            },
            Dimension::ShieldedPaymentOutputs => SizeBoundViolation::ShieldedPaymentOutputs {
                step_index,
                count,
                limit,
            },
        }
    }
}

/// What one transaction of a proposal spends and creates.
///
/// The action counts are `zcash_client_backend`'s own: `Step::orchard_action_count` and
/// `Step::ironwood_action_count` with the padding the builder uses, and the Sapling builder's
/// default padding. To them are added the shielded notes the step spends from earlier steps,
/// which those counts do not consider; an action per such spend can only over-count.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct StepCounts {
    /// Actions per pool, after padding.
    pool_actions: PoolCounts,
    transparent_inputs: usize,
    transparent_outputs: usize,
    shielded_payment_outputs: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct PoolCounts {
    sapling: usize,
    orchard: usize,
    ironwood: usize,
}

impl PoolCounts {
    fn get(&self, pool: ShieldedPool) -> usize {
        match pool {
            ShieldedPool::Sapling => self.sapling,
            ShieldedPool::Orchard => self.orchard,
            ShieldedPool::Ironwood => self.ironwood,
        }
    }

    fn add(&mut self, pool: ShieldedPool, n: usize) {
        match pool {
            ShieldedPool::Sapling => self.sapling += n,
            ShieldedPool::Orchard => self.orchard += n,
            ShieldedPool::Ironwood => self.ironwood += n,
        }
    }
}

impl StepCounts {
    /// Counts `step`'s transaction as it is built under the consensus rules of `branch`,
    /// resolving the prior-step outputs it spends against `steps`.
    pub(crate) fn of<NoteRef>(
        steps: &NonEmpty<Step<NoteRef>>,
        step: &Step<NoteRef>,
        branch: BranchId,
    ) -> Self {
        let mut counts = Self::default();
        counts
            .pool_actions
            .add(ShieldedPool::Sapling, sapling_actions(step));
        counts.pool_actions.add(
            ShieldedPool::Orchard,
            orchard_style_actions(step, ValuePool::Orchard, branch),
        );
        counts.pool_actions.add(
            ShieldedPool::Ironwood,
            orchard_style_actions(step, ValuePool::Ironwood, branch),
        );
        counts.transparent_inputs = step.input_count_in_pool(PoolType::Transparent);
        counts.transparent_outputs = step.output_count_in_pool(PoolType::Transparent)
            + step.change_count_in_pool(PoolType::Transparent);
        counts.shielded_payment_outputs = step
            .payment_pools()
            .values()
            .filter(|pool| matches!(pool, PoolType::Shielded(_)))
            .count();
        for prior in step.prior_step_inputs() {
            match prior_output_pool(steps, prior) {
                PoolType::Transparent => counts.transparent_inputs += 1,
                PoolType::Shielded(pool) => counts.pool_actions.add(pool, 1),
            }
        }
        counts
    }

    /// The actions of this transaction's bundle in `pool`, or `0` when it has none.
    pub(crate) fn pool_actions(&self, pool: ShieldedPool) -> usize {
        self.pool_actions.get(pool)
    }

    /// Sapling spends and outputs plus Orchard and Ironwood actions.
    pub(crate) fn shielded_actions(&self) -> usize {
        self.pool_actions.sapling + self.pool_actions.orchard + self.pool_actions.ironwood
    }
}

/// The Sapling spends plus outputs the builder produces for `step`, with the Sapling builder's
/// default padding.
fn sapling_actions<NoteRef>(step: &Step<NoteRef>) -> usize {
    let spends = step.input_count_in_pool(PoolType::SAPLING);
    let outputs =
        step.output_count_in_pool(PoolType::SAPLING) + step.change_count_in_pool(PoolType::SAPLING);
    let bundle_type = sapling::builder::BundleType::DEFAULT;
    // The default bundle type accepts any count; the fallbacks are never taken.
    bundle_type.num_spends(spends).unwrap_or(spends)
        + bundle_type.num_outputs(spends, outputs).unwrap_or(outputs)
}

/// The actions the builder produces for `step`'s bundle in `pool` under `branch`: the Orchard
/// bundle with the default padding, the Ironwood bundle with the padding the step records.
fn orchard_style_actions<NoteRef>(
    step: &Step<NoteRef>,
    pool: ValuePool,
    branch: BranchId,
) -> usize {
    let (pool_type, padding) = match pool {
        ValuePool::Orchard => (PoolType::ORCHARD, BundlePadding::DEFAULT),
        ValuePool::Ironwood => (PoolType::IRONWOOD, step.ironwood_bundle_padding()),
    };
    let spends = step.input_count_in_pool(pool_type);
    let outputs = step.output_count_in_pool(pool_type) + step.change_count_in_pool(pool_type);
    let counted = bundle_version_for_branch(branch, pool).and_then(|version| {
        match pool {
            ValuePool::Orchard => step.orchard_action_count(padding, version),
            ValuePool::Ironwood => step.ironwood_action_count(padding, version),
        }
        .ok()
    });
    // A pool that is not active under `branch` cannot be built at all; if the step uses it
    // anyway, every spend and output is counted as its own action so the bound never
    // under-counts.
    counted.unwrap_or(spends + outputs)
}

/// The pool of the earlier step's output that `prior` refers to.
fn prior_output_pool<NoteRef>(steps: &NonEmpty<Step<NoteRef>>, prior: &StepOutput) -> PoolType {
    let step = &steps[prior.step_index()];
    match prior.output_index() {
        StepOutputIndex::Payment(i) => *step
            .payment_pools()
            .get(&i)
            .expect("a proposal's prior-step input refers to an existing payment"),
        StepOutputIndex::Change(i) => step.balance().proposed_change()[i].output_pool(),
    }
}

/// Holds `proposal` to `bound`, classifying a violation as the wallet's "too many notes"
/// condition, [`ErrorKind::TransactionTooLarge`], the same condition consensus reports.
///
/// `context` names the FFI entry point, as [`ClassifiedError::new`] describes. Which cap was
/// exceeded, and by how much, is logged at `debug!`, where it stays on the device.
pub(crate) fn enforce<P: Parameters, FeeRuleT, NoteRef>(
    proposal: &Proposal<FeeRuleT, NoteRef>,
    params: &P,
    bound: &TransactionSizeBound,
    context: &'static str,
) -> Result<(), ClassifiedError> {
    bound.check(proposal, params).map_err(|violation| {
        debug!("{context}: the proposal exceeds its size bound: {violation}");
        ClassifiedError::new(
            context,
            ErrorKind::TransactionTooLarge,
            "the transaction would exceed the size bound it was proposed under",
        )
    })
}
