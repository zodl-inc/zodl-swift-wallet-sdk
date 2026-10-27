//! The network-upgrade gate for the pool migration: what the migration may do in the run-up to a
//! network upgrade that changes the consensus branch (NU7), and which transactions may still be
//! submitted once the chain is there.
//!
//! A transaction commits to the consensus branch it was built for, and a block accepts only
//! transactions of the branch its own height is under. The migration builds and signs a whole run
//! ahead of time and sends it over many blocks, so a run that straddles the NU7 activation would
//! be left holding signed transactions that no block can include, and the notes they spend would
//! stay reserved for them. The gate keeps a run on one side of the activation:
//!
//! - [`gate_phase`] says whether new scheduled work may start at the next height. Before NU7,
//!   the scheduled lane is paused ([`GatePhase::PausedUntil`]); the immediate lane stays open,
//!   and valid committed work may still be proved and submitted. From the activation on, on a
//!   network with no NU7 height, and for an internal host using the bypass, the gate is
//!   [`GatePhase::Open`].
//! - [`check_submittable`] is the check every submission passes, migration or not, whatever the
//!   phase: the transaction must be built for the branch the next block is under, and it must not
//!   have expired by then.
//! - [`upgrade_verdict`] decides, once the chain has reached the activation, whether a run that
//!   was under way when the branch changed is over, because a transaction of it that is not mined
//!   was built for the old branch and so never can be.
//!
//! Everything here is a pure function of the network parameters and the heights it is given. The
//! callers decide which height to ask about, and nothing here reads a wallet or a server.

use pczt::Pczt;
use zcash_pool_migration::engine::MigrationTxState;
use zcash_protocol::consensus::{BlockHeight, BranchId, NetworkUpgrade, Parameters};

/// What the migration may do at a given next height, as [`gate_phase`] decides it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GatePhase {
    /// No gate applies: the network has no NU7 height, NU7 is active at the next height, or the
    /// host opted out.
    Open,
    /// The next height is below activation: new scheduled work is paused until the upgrade,
    /// while the immediate lane and valid committed work remain available.
    PausedUntil { activation: BlockHeight },
}

/// The height at which the network activates NU7, or `None` when it never does.
pub(crate) fn nu7_activation<P: Parameters>(params: &P) -> Option<BlockHeight> {
    params.activation_height(NetworkUpgrade::Nu7)
}

/// The phase of the gate at `next_height`, the height of the next block to be mined: the wallet's
/// chain tip plus one. With `bypass` the gate is [`GatePhase::Open`] at every height.
pub(crate) fn gate_phase<P: Parameters>(
    params: &P,
    next_height: BlockHeight,
    bypass: bool,
) -> GatePhase {
    let Some(activation) = nu7_activation(params) else {
        return GatePhase::Open;
    };
    if bypass || next_height >= activation {
        GatePhase::Open
    } else {
        GatePhase::PausedUntil { activation }
    }
}

/// Why a transaction may not be submitted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SubmissionRefusal {
    /// The transaction is built for another consensus branch than the next block is under.
    WrongBranch,
    /// The transaction has expired by the next height.
    Expired,
}

impl SubmissionRefusal {
    /// The stable text the refusal is reported under. Callers outside this crate match on it, so
    /// it must not change.
    pub(crate) fn code(self) -> &'static str {
        match self {
            SubmissionRefusal::WrongBranch => "wrong_branch",
            SubmissionRefusal::Expired => "expired",
        }
    }
}

/// Whether a transaction may be submitted when the next block to be mined has height
/// `next_height`.
///
/// `branch_id` is the consensus branch ID the transaction's encoding carries, or `None` when the
/// encoding commits to no branch (before v5), in which case only the expiry is checked. The branch
/// is checked first, so a transaction that is wrong on both counts is refused as
/// [`SubmissionRefusal::WrongBranch`]. An `expiry_height` of 0 means the transaction does not
/// expire; otherwise it has expired when `expiry_height < next_height`, since it can still be
/// mined in the block at its expiry height.
pub(crate) fn check_submittable<P: Parameters>(
    params: &P,
    branch_id: Option<u32>,
    expiry_height: BlockHeight,
    next_height: BlockHeight,
) -> Result<(), SubmissionRefusal> {
    let next_branch = u32::from(BranchId::for_height(params, next_height));
    if branch_id.is_some_and(|branch_id| branch_id != next_branch) {
        return Err(SubmissionRefusal::WrongBranch);
    }
    if u32::from(expiry_height) != 0 && expiry_height < next_height {
        return Err(SubmissionRefusal::Expired);
    }
    Ok(())
}

/// The consensus branch ID a PCZT is built for, or `None` when `pczt` does not parse as one.
pub(crate) fn pczt_consensus_branch_id(pczt: &[u8]) -> Option<u32> {
    Pczt::parse(pczt)
        .ok()
        .map(|parsed| *parsed.global().consensus_branch_id())
}

/// Whether a migration run that was under way when NU7 activated is over, as [`upgrade_verdict`]
/// decides it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UpgradeVerdict {
    /// No transaction of the run is stranded by the upgrade.
    Clear,
    /// The run is over: a transaction that is not mined was built for the old branch, so it never
    /// can be.
    Interrupted,
    /// Every transaction that was built for the old branch and is not mined may already have been
    /// sent, so the wallet has to scan up to the block before the activation before it can tell
    /// whether the run is over.
    AwaitScan,
}

/// Whether the migration run whose transactions are `rows` is over, given that the next block to
/// be mined is at `next_height` and the wallet has scanned every block up to `fully_scanned`. Each
/// row is a transaction's lifecycle state and the bytes of its PCZT.
///
/// The answer is [`UpgradeVerdict::Clear`] on a network with no NU7 height and before the
/// activation. From the activation on, a row is stale when it is unmined, its PCZT parses, and the
/// branch it is built for is not the one the next block is under. A row whose PCZT does not parse
/// has no readable branch, so it is skipped. No stale row leaves the run
/// [`Clear`](UpgradeVerdict::Clear), and a stale row that was never sent (`AwaitingSignature` or
/// `Signed`) ends it at once. A stale `Proved` or `Broadcast` row may already have been sent, and
/// mined before the activation without the wallet's scan having seen the block yet, so it ends the
/// run only once the scan has reached the block before the activation: until then the answer is
/// [`UpgradeVerdict::AwaitScan`].
pub(crate) fn upgrade_verdict<'a, P: Parameters>(
    params: &P,
    rows: impl IntoIterator<Item = (MigrationTxState, &'a [u8])>,
    next_height: BlockHeight,
    fully_scanned: Option<BlockHeight>,
) -> UpgradeVerdict {
    let Some(activation) = nu7_activation(params) else {
        return UpgradeVerdict::Clear;
    };
    if next_height < activation {
        return UpgradeVerdict::Clear;
    }
    let next_branch = u32::from(BranchId::for_height(params, next_height));
    let mut awaiting_scan = false;
    for (state, pczt) in rows {
        let may_have_been_sent = match state {
            MigrationTxState::AwaitingSignature | MigrationTxState::Signed => false,
            MigrationTxState::Proved | MigrationTxState::Broadcast { .. } => true,
            // A mined transaction is settled, whichever branch it was built for.
            MigrationTxState::Mined { .. } => continue,
        };
        let Some(branch) = pczt_consensus_branch_id(pczt) else {
            continue;
        };
        if branch == next_branch {
            continue;
        }
        if !may_have_been_sent {
            return UpgradeVerdict::Interrupted;
        }
        awaiting_scan = true;
    }
    if !awaiting_scan {
        UpgradeVerdict::Clear
    } else if fully_scanned.is_some_and(|scanned| scanned >= activation - 1) {
        UpgradeVerdict::Interrupted
    } else {
        UpgradeVerdict::AwaitScan
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pczt::roles::creator::Creator;
    use zcash_protocol::TxId;
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};
    use zcash_protocol::local_consensus::LocalNetwork;

    const MAINNET_NU7: u32 = 3_543_405;
    const TESTNET_NU7: u32 = 4_465_026;

    fn h(height: u32) -> BlockHeight {
        BlockHeight::from_u32(height)
    }

    /// Every upgrade before NU7 at height 1, and NU7 where given. `None` is a network on which NU7
    /// never activates.
    fn custom(nu7: Option<u32>) -> LocalNetwork {
        let one = Some(h(1));
        LocalNetwork {
            overwinter: one,
            sapling: one,
            blossom: one,
            heartwood: one,
            canopy: one,
            nu5: one,
            nu6: one,
            nu6_1: one,
            nu6_2: one,
            nu6_3: one,
            nu7: nu7.map(h),
        }
    }

    /// The branch ID as a transaction's encoding carries it.
    fn encoded(branch: BranchId) -> Option<u32> {
        Some(u32::from(branch))
    }

    /// The encoding of an empty PCZT built for `branch`.
    fn pczt_for(branch: BranchId) -> Vec<u8> {
        Creator::new(u32::from(branch), 3_600_000, 133, None, None)
            .expect("a PCZT can be created for every branch from NU5 on")
            .build()
            .expect("an empty PCZT builds")
            .serialize()
            .expect("an empty PCZT serializes")
    }

    fn broadcast() -> MigrationTxState {
        MigrationTxState::Broadcast {
            txid: TxId::from_bytes([1u8; 32]),
        }
    }

    fn mined() -> MigrationTxState {
        MigrationTxState::Mined {
            txid: TxId::from_bytes([2u8; 32]),
            height: h(3_543_000),
        }
    }

    /// The verdict on mainnet for `rows` at the next height `next`, with the wallet fully scanned
    /// up to `scanned`.
    fn mainnet_verdict(
        rows: &[(MigrationTxState, &[u8])],
        next: u32,
        scanned: Option<u32>,
    ) -> UpgradeVerdict {
        upgrade_verdict(&MAIN_NETWORK, rows.iter().copied(), h(next), scanned.map(h))
    }

    // ----- gate_phase -----

    #[test]
    fn gate_phase_pauses_scheduled_work_until_mainnet_activation() {
        for next in [3_543_356, 3_543_357, 3_543_404] {
            assert_eq!(
                gate_phase(&MAIN_NETWORK, h(next), false),
                GatePhase::PausedUntil {
                    activation: h(MAINNET_NU7)
                },
                "next height {next}"
            );
        }
    }

    #[test]
    fn gate_phase_opens_at_activation() {
        for next in [3_543_405, 3_600_000] {
            assert_eq!(
                gate_phase(&MAIN_NETWORK, h(next), false),
                GatePhase::Open,
                "next height {next}"
            );
        }
    }

    #[test]
    fn gate_phase_is_open_with_the_bypass() {
        // Both earlier and immediately before activation, the bypass opens scheduled work.
        for next in [3_543_000, 3_543_400] {
            assert_eq!(
                gate_phase(&MAIN_NETWORK, h(next), true),
                GatePhase::Open,
                "next height {next}"
            );
        }
    }

    #[test]
    fn gate_phase_pauses_scheduled_work_until_testnet_activation() {
        assert_eq!(
            gate_phase(&TEST_NETWORK, h(TESTNET_NU7), false),
            GatePhase::Open
        );
        assert_eq!(
            gate_phase(&TEST_NETWORK, h(4_000_000), false),
            GatePhase::PausedUntil {
                activation: h(TESTNET_NU7)
            }
        );
        // New scheduled work stays paused through the final preactivation block.
        assert_eq!(
            gate_phase(&TEST_NETWORK, h(4_464_977), false),
            GatePhase::PausedUntil {
                activation: h(TESTNET_NU7)
            }
        );
        for next in [4_464_978, 4_465_025] {
            assert_eq!(
                gate_phase(&TEST_NETWORK, h(next), false),
                GatePhase::PausedUntil {
                    activation: h(TESTNET_NU7)
                },
                "next height {next}"
            );
        }
    }

    #[test]
    fn gate_phase_is_open_on_a_network_without_nu7() {
        // Mainnet's NU7 height is no fallback for a network that has none.
        for next in [3_543_000, 3_543_400, 3_543_405, 3_600_000] {
            assert_eq!(
                gate_phase(&custom(None), h(next), false),
                GatePhase::Open,
                "next height {next}"
            );
        }
    }

    #[test]
    fn gate_phase_handles_an_activation_near_genesis() {
        // Even an activation near genesis pauses new scheduled work at every earlier height.
        let early = custom(Some(10));
        for next in [0, 9] {
            assert_eq!(
                gate_phase(&early, h(next), false),
                GatePhase::PausedUntil { activation: h(10) },
                "next height {next}"
            );
        }
        assert_eq!(gate_phase(&early, h(10), false), GatePhase::Open);
        // An activation at 49 has the same policy at genesis and the following block.
        let network = custom(Some(49));
        assert_eq!(
            gate_phase(&network, h(0), false),
            GatePhase::PausedUntil { activation: h(49) }
        );
        assert_eq!(
            gate_phase(&network, h(1), false),
            GatePhase::PausedUntil { activation: h(49) }
        );
    }

    // ----- check_submittable -----

    #[test]
    fn check_submittable_accepts_the_next_heights_branch_unexpired() {
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu6_3),
                h(3_594_240),
                h(3_543_404)
            ),
            Ok(())
        );
    }

    #[test]
    fn check_submittable_refuses_a_branch_other_than_the_next_heights() {
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu6_3),
                h(3_600_000),
                h(3_543_405)
            ),
            Err(SubmissionRefusal::WrongBranch)
        );
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu7),
                h(3_600_000),
                h(3_543_404)
            ),
            Err(SubmissionRefusal::WrongBranch)
        );
        // An ID that is no known branch is just as wrong.
        assert_eq!(
            check_submittable(&MAIN_NETWORK, Some(0xdead_beef), h(3_600_000), h(3_543_404)),
            Err(SubmissionRefusal::WrongBranch)
        );
        // The branch is checked before the expiry: this transaction is wrong on both counts.
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu6_3),
                h(3_543_000),
                h(3_543_405)
            ),
            Err(SubmissionRefusal::WrongBranch)
        );
    }

    #[test]
    fn check_submittable_refuses_a_transaction_expired_at_the_next_height() {
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu7),
                h(3_600_000),
                h(3_600_001)
            ),
            Err(SubmissionRefusal::Expired)
        );
        // It can still be mined in the block at its expiry height.
        assert_eq!(
            check_submittable(
                &MAIN_NETWORK,
                encoded(BranchId::Nu7),
                h(3_600_000),
                h(3_600_000)
            ),
            Ok(())
        );
    }

    #[test]
    fn check_submittable_treats_expiry_zero_as_none() {
        assert_eq!(
            check_submittable(&MAIN_NETWORK, encoded(BranchId::Nu7), h(0), h(9_000_000)),
            Ok(())
        );
    }

    #[test]
    fn check_submittable_skips_the_branch_when_the_encoding_has_none() {
        assert_eq!(
            check_submittable(&MAIN_NETWORK, None, h(3_600_000), h(3_700_000)),
            Err(SubmissionRefusal::Expired)
        );
        assert_eq!(
            check_submittable(&MAIN_NETWORK, None, h(3_600_000), h(3_543_405)),
            Ok(())
        );
    }

    #[test]
    fn submission_refusals_are_reported_under_their_stable_codes() {
        assert_eq!(SubmissionRefusal::WrongBranch.code(), "wrong_branch");
        assert_eq!(SubmissionRefusal::Expired.code(), "expired");
    }

    // ----- pczt_consensus_branch_id -----

    #[test]
    fn pczt_consensus_branch_id_reads_the_global_branch() {
        assert_eq!(
            pczt_consensus_branch_id(&pczt_for(BranchId::Nu7)),
            Some(0x7719_0ad9)
        );
        assert_eq!(
            pczt_consensus_branch_id(&pczt_for(BranchId::Nu6_3)),
            encoded(BranchId::Nu6_3)
        );
        assert_eq!(pczt_consensus_branch_id(&[0u8]), None);
    }

    // ----- upgrade_verdict -----

    #[test]
    fn upgrade_verdict_is_clear_before_activation() {
        let old = pczt_for(BranchId::Nu6_3);
        assert_eq!(
            mainnet_verdict(
                &[(MigrationTxState::Signed, old.as_slice())],
                3_543_404,
                None
            ),
            UpgradeVerdict::Clear
        );
        // Nothing is judged before the activation, whatever branch a row is built for: this one
        // is built for NU7, which the block at 3,543,404 is not yet under.
        let ahead = pczt_for(BranchId::Nu7);
        assert_eq!(
            mainnet_verdict(
                &[(MigrationTxState::Signed, ahead.as_slice())],
                3_543_404,
                None
            ),
            UpgradeVerdict::Clear
        );
    }

    #[test]
    fn upgrade_verdict_interrupts_signed_and_awaiting_signature_rows_of_the_old_branch() {
        let old = pczt_for(BranchId::Nu6_3);
        for state in [
            MigrationTxState::Signed,
            MigrationTxState::AwaitingSignature,
        ] {
            assert_eq!(
                mainnet_verdict(&[(state, old.as_slice())], 3_543_405, None),
                UpgradeVerdict::Interrupted,
                "{state:?}"
            );
        }

        // Such a row ends the run at once, even beside a row that is still waiting for the scan.
        let unsent = (MigrationTxState::Signed, old.as_slice());
        let sent = (broadcast(), old.as_slice());
        assert_eq!(
            mainnet_verdict(&[sent, unsent], 3_543_405, Some(3_000_000)),
            UpgradeVerdict::Interrupted
        );
        assert_eq!(
            mainnet_verdict(&[unsent, sent], 3_543_405, Some(3_000_000)),
            UpgradeVerdict::Interrupted
        );
    }

    #[test]
    fn upgrade_verdict_awaits_the_scan_for_proved_and_broadcast_rows() {
        let old = pczt_for(BranchId::Nu6_3);
        let proved = (MigrationTxState::Proved, old.as_slice());
        let sent = (broadcast(), old.as_slice());
        for rows in [vec![proved], vec![sent], vec![proved, sent]] {
            // The row may have been mined before the activation without the scan having seen it,
            // until the scan has passed the block before the activation.
            assert_eq!(
                mainnet_verdict(&rows, 3_543_405, Some(3_543_403)),
                UpgradeVerdict::AwaitScan
            );
            assert_eq!(
                mainnet_verdict(&rows, 3_543_405, Some(3_543_404)),
                UpgradeVerdict::Interrupted
            );
            assert_eq!(
                mainnet_verdict(&rows, 3_543_405, Some(3_600_000)),
                UpgradeVerdict::Interrupted
            );
            assert_eq!(
                mainnet_verdict(&rows, 3_543_405, None),
                UpgradeVerdict::AwaitScan
            );
        }
    }

    #[test]
    fn upgrade_verdict_ignores_mined_current_branch_and_unparseable_rows() {
        let old = pczt_for(BranchId::Nu6_3);
        let current = pczt_for(BranchId::Nu7);
        assert_eq!(
            mainnet_verdict(
                &[
                    (mined(), old.as_slice()),
                    (MigrationTxState::Signed, current.as_slice()),
                    (MigrationTxState::Signed, &[0u8]),
                ],
                3_543_405,
                None
            ),
            UpgradeVerdict::Clear
        );
    }

    #[test]
    fn upgrade_verdict_is_clear_on_a_network_without_nu7() {
        // A row for another branch than the network's current one, which an upgrade would strand.
        let old = pczt_for(BranchId::Nu6_2);
        let rows = [(MigrationTxState::Signed, old.as_slice())];
        assert_eq!(
            upgrade_verdict(&custom(None), rows, h(3_543_405), None),
            UpgradeVerdict::Clear
        );
        // The same row, on a network that does upgrade, is stranded.
        assert_eq!(
            upgrade_verdict(&custom(Some(1)), rows, h(3_543_405), None),
            UpgradeVerdict::Interrupted
        );
    }
}
