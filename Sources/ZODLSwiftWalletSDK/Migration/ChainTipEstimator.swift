//
//  ChainTipEstimator.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// A pure, measured-block-rate chain-tip estimator: projects a wall-clock ESTIMATED chain tip
/// from the most recently scanned blocks' `(height, header time)` samples
/// (`ZcashRustBackendWelding.migrationBlockRateSamples(window:)`).
///
/// The projection feeds the migration delivery lane's `estimatedTip` inputs
/// (`migrationHasOverdueTransfers(for:estimatedTip:)` / `migrationAdvanceStep(for:estimatedTip:)`)
/// AND — since upstream #2927 — the overdue re-spread inside `advance_migration`, which is
/// **judged and sized at the estimate and PERSISTED**: an over-estimate is no longer "at worst an
/// early due answer"; it writes phantom deferral into the stored schedule. Accuracy here is
/// load-bearing. (Field incident, 2026-08-08 `data37`: a burst-skewed measurement compounded by
/// two wake-time re-spreads parked a live testnet run ~2,690 blocks — half a day — past the real
/// chain. The engine-side hardening — bounding what a caller estimate may size — is tracked
/// separately; this type's job is to not hand it poison in the first place.)
///
/// THE RATE IS A SPAN, NOT A DELTA MEAN. In one era, `secondsPerBlock()` divides the window's total
/// header-time span by its total height span. The previous implementation averaged consecutive
/// per-delta spacings, each clamped to [``minSecondsPerBlock``, ``maxSecondsPerBlock``] — a
/// statistic that is biased LOW on bimodal spacing: testnet's min-difficulty rule yields bursts
/// (seconds apart, clamped UP to 5) punctuated by gaps (clamped DOWN to 150), and the bursts
/// dominate by count. A span is immune: a gap and the burst it triggers average out inside it. A
/// span also needs no adjacency assumption — non-consecutive sample heights divide by the true
/// height distance instead of counting rows.
///
/// THE WINDOW IS ABSENCE-SCALED. The rate is extrapolated across app-dead gaps measured in hours,
/// so the sample span must cover hours: ``sampleWindow`` is 1000 blocks (~21 h at the 75 s target
/// spacing, ~7 h at NU7's 25 s; ~6–9 h on a burst-fast testnet). The prior 100-block window (~2 h
/// at target, and as little as ~30 min on a fast chain) measured whatever regime the chain
/// happened to be in right before sleep and projected it across the whole night — in the field
/// incident the pre-sleep half hour ran ~20 s/block while the night averaged 31 s/block, an error
/// the span statistic alone cannot fix.
///
/// THE WINDOW CROSSES SPACING CHANGES, SO IT MEASURES SPEED. A height span across a change such as
/// NU7 activation averages two targets into a rate neither era runs at, yet a window cut at the
/// change would rest on the few blocks mined since, as burst-prone as the 100-block window above.
/// So the window keeps up to ``sampleWindow`` samples across a change and measures the chain's
/// SPEED: its header-time span over the target time of the same blocks. A window straddling NU7
/// yields the post-NU7 rate with the full window's smoothing. A rate is expressed in the era of the
/// block after its reference height (the latest sample, or a projected tip) as the speed times that
/// block's target spacing, and the clamps and the fallback follow the same spacing; inside one era
/// that is the plain span rate. A projection that reaches the next change keeps the measured speed
/// past it, and the schedule places the blocks.
/// A window spanning Blossom, seen only early in a restore from a pre-Blossom birthday, measures
/// speed too, and below Blossom the 150 s spacing scales the bounds to [10, 300] s and makes the
/// fallback 150 s.
///
/// Constants heritage: the clamps and fallback still mirror the Android SDK's estimator; the
/// method (span vs clamped-delta mean) and the window (1000 vs 100) deliberately diverge — the
/// Kotlin estimator retains the biased statistic and the short window and needs the same fix.
struct ChainTipEstimator {
    /// How many of the latest samples participate, at most. Widened from the Android-parity 100:
    /// the rate extrapolates across absence-scale gaps, so the sample span must cover
    /// absence-scale regime changes (see the type doc).
    static let sampleWindow = 1000
    /// The lower sanity clamp on the final rate at the 75 s spacing, in seconds (Android parity:
    /// 5); scaled by the spacing the rate is expressed in (see ``clampReferenceSpacing``).
    static let minSecondsPerBlock: Double = 5
    /// The upper sanity clamp on the final rate at the 75 s spacing, in seconds (Android parity:
    /// 150); scaled by the spacing the rate is expressed in (see ``clampReferenceSpacing``).
    static let maxSecondsPerBlock: Double = 150
    /// The seconds-per-block assumed with no samples and no scanned height (Android parity: 75 —
    /// the target spacing from Blossom to NU7).
    static let fallbackSecondsPerBlock: Double = 75
    /// The target spacing the clamps are stated at. A rate expressed at another spacing has them
    /// scaled by that spacing over this one; at exactly this spacing they apply unscaled.
    static let clampReferenceSpacing: Double = 75

    /// The window's measurement, which only a window of at least two samples that advances in both
    /// height and header time yields.
    private struct WindowSpan {
        /// The header-time seconds from the window's first sample to its last.
        let seconds: Double
        /// The blocks after the window's first sample, up to and including its last.
        let blocks: Double
        /// The target time of those blocks, in seconds.
        let targetSeconds: Double
        /// The target spacing every one of those blocks shares, or `nil` when they straddle a
        /// spacing change.
        let sharedSpacing: TimeInterval?

        /// The span of `window` on `spacing`'s schedule, or `nil` when it cannot be measured: fewer
        /// than two samples, no height span, or header times that do not advance across it.
        init?(window: ArraySlice<MigrationBlockRateSample>, spacing: TargetBlockSpacing) {
            guard window.count >= 2, let first = window.first, let last = window.last, last.height > first.height else {
                return nil
            }

            let seconds = Double(last.unixTime - first.unixTime)
            let targetSeconds = spacing.seconds(from: first.height, to: last.height)
            guard seconds > 0, targetSeconds > 0 else {
                return nil
            }

            let lastEra = spacing.era(containing: last.height)
            self.seconds = seconds
            self.blocks = Double(last.height - first.height)
            self.targetSeconds = targetSeconds
            self.sharedSpacing = lastEra.start <= first.height + 1 ? lastEra.spacing : nil
        }
    }

    /// The `(height, header time)` samples, ascending by height (the order the welding returns).
    private let samples: [MigrationBlockRateSample]
    /// The network's target spacing schedule: it measures the window in target time and gives each
    /// rate the spacing of its era.
    private let spacing: TargetBlockSpacing
    /// The wallet's max scanned height; with no samples, the block after it sets the rate.
    private let fallbackHeight: BlockHeight?
    /// The measurement over the last ``sampleWindow`` samples, or `nil` when they yield none.
    private let span: WindowSpan?

    /// Creates an estimator over `samples` (ascending by height; may be empty) on `spacing`'s
    /// schedule. `fallbackHeight`, the wallet's max scanned height, sets the rate when there are no
    /// samples at all.
    init(samples: [MigrationBlockRateSample], spacing: TargetBlockSpacing, fallbackHeight: BlockHeight? = nil) {
        self.samples = samples
        self.spacing = spacing
        self.fallbackHeight = fallbackHeight
        self.span = WindowSpan(window: samples.suffix(Self.sampleWindow), spacing: spacing)
    }

    /// The measured seconds-per-block after the latest sample: the window's speed against target
    /// time times the target spacing of the block after the latest sample, clamped once to
    /// [``minSecondsPerBlock``, ``maxSecondsPerBlock``] scaled by that spacing over
    /// ``clampReferenceSpacing``. When the window's blocks share that spacing, this is the SPAN
    /// rate over up to the last ``sampleWindow`` samples: total header-time span divided by total
    /// height span.
    ///
    /// The target spacing of that block when no rate can be measured: fewer than two samples, a
    /// window spanning no height, or header times that do not advance across the window (header
    /// times are miner-supplied and may locally regress; a whole window that fails to advance is a
    /// broken measurement, not a fast chain). With no samples at all, the target spacing of the
    /// block after the fallback height, or ``fallbackSecondsPerBlock`` without one.
    func secondsPerBlock() -> Double {
        guard let latest = samples.last else {
            guard let fallbackHeight else {
                return Self.fallbackSecondsPerBlock
            }
            return spacing.spacing(at: fallbackHeight + 1)
        }
        return rate(after: latest.height)
    }

    /// The estimated chain tip at `now`: the latest sample's height plus the whole blocks that
    /// fit into the wall-clock time elapsed since its header time at ``secondsPerBlock()``,
    /// never below the latest sample's height (a header time in the future adds zero). Once that
    /// count reaches the block before the next spacing change, the next block it would add
    /// belongs to the new era, so the elapsed time is instead converted to target time at the
    /// measured speed and the schedule places the blocks, each at its own spacing. `nil` when
    /// there are no samples at all — the wallet has never scanned, so there is nothing to project
    /// from.
    func estimatedTip(now: Date) -> BlockHeight? {
        guard let latest = samples.last else {
            return nil
        }

        let elapsed = now.timeIntervalSince1970 - Double(latest.unixTime)
        let singleRateTip = latest.height + max(0, Int(floor(elapsed / secondsPerBlock())))
        guard let nextChange = spacing.era(containing: latest.height + 1).end, singleRateTip >= nextChange - 1 else {
            return singleRateTip
        }
        return spacing.height(reachedAfter: targetSeconds(elapsed: elapsed), from: latest.height)
    }

    /// The measured seconds-per-block after `estimatedTip`: the speed and clamps of
    /// ``secondsPerBlock()`` at the target spacing of the block after `estimatedTip`, which
    /// differs from the rate after the latest sample once a projection crosses a spacing change.
    /// ``secondsPerBlock()`` itself when `estimatedTip` is `nil`.
    func secondsPerBlock(atEstimatedTip estimatedTip: BlockHeight?) -> Double {
        guard let estimatedTip else {
            return secondsPerBlock()
        }
        return rate(after: estimatedTip)
    }

    /// The measured rate in the era of the block after `height`, clamped to the bounds scaled by
    /// that block's spacing; the spacing itself when the window yields no measurement.
    private func rate(after height: BlockHeight) -> Double {
        let blockSpacing = spacing.spacing(at: height + 1)
        guard let span else {
            return blockSpacing
        }

        // Inside one era the speed form is the same rate; the plain span computes it directly, so
        // single-era rates stay bit-identical to the ones this estimator has always reported.
        let unclamped = span.sharedSpacing == blockSpacing
            ? span.seconds / span.blocks
            : span.seconds * blockSpacing / span.targetSeconds
        let clampScale = blockSpacing / Self.clampReferenceSpacing
        return min(max(unclamped, Self.minSecondsPerBlock * clampScale), Self.maxSecondsPerBlock * clampScale)
    }

    /// `elapsed` wall-clock seconds as target time at the measured speed, clamped like the rate. The
    /// unclamped case multiplies before it divides, so a whole number of blocks' worth of target
    /// time stays whole and the schedule does not fall one block short of it.
    private func targetSeconds(elapsed: TimeInterval) -> TimeInterval {
        guard let span else {
            return elapsed
        }

        if span.seconds * Self.clampReferenceSpacing < Self.minSecondsPerBlock * span.targetSeconds {
            return elapsed * Self.clampReferenceSpacing / Self.minSecondsPerBlock
        }
        if span.seconds * Self.clampReferenceSpacing > Self.maxSecondsPerBlock * span.targetSeconds {
            return elapsed * Self.clampReferenceSpacing / Self.maxSecondsPerBlock
        }
        return elapsed * span.targetSeconds / span.seconds
    }
}

/// The ONE shared read-and-project composition behind every migration tip-estimate consumer: read
/// the welding's block-rate samples over ``ChainTipEstimator/sampleWindow`` and run
/// ``ChainTipEstimator`` at an INJECTED instant. Both `OrchardMigration` and
/// `OrchardMigrationHost` — the gate/delivery paths and the public
/// `estimatedMigrationChainTip()`/`estimatedMigrationSecondsPerBlock()` members — go through
/// here, so the window constant, the estimator wiring, and the clock injection cannot drift apart
/// between call sites.
enum MigrationTipEstimation {
    /// One projection over one samples read: the estimated tip (`nil` with no samples at all —
    /// the wallet has never scanned) and the measured seconds-per-block (the estimator's
    /// fallback when no rate can be measured).
    struct Projection {
        /// The wall-clock estimated chain tip, or `nil` when there are no samples to project from.
        let estimatedTip: BlockHeight?
        /// The measured seconds-per-block after the estimated tip (see
        /// ``ChainTipEstimator/secondsPerBlock(atEstimatedTip:)``).
        let secondsPerBlock: Double
    }

    /// Reads the samples and projects at `now` on `spacing`'s schedule. THROWING: a sample-read
    /// failure propagates — this is the core the public estimated members surface errors from;
    /// gate paths use ``gatingEstimatedTip(welding:spacing:now:)`` instead, which degrades.
    static func project(welding: ZcashRustBackendWelding, spacing: TargetBlockSpacing, now: Date) async throws -> Projection {
        let samples = try await welding.migrationBlockRateSamples(window: UInt32(ChainTipEstimator.sampleWindow))
        // Only an empty sample set needs the scanned height, for the fallback rate's spacing; a
        // failed read degrades to the constant fallback rather than failing the projection. Both
        // reads come from the `blocks` table, so empty samples come with no scanned height unless a
        // concurrent scan races or blocks the samples read, and this yields 75 s in practice.
        var fallbackHeight: BlockHeight?
        if samples.isEmpty {
            fallbackHeight = try? await welding.maxScannedHeight()
        }
        let estimator = ChainTipEstimator(samples: samples, spacing: spacing, fallbackHeight: fallbackHeight)
        let estimatedTip = estimator.estimatedTip(now: now)
        return Projection(estimatedTip: estimatedTip, secondsPerBlock: estimator.secondsPerBlock(atEstimatedTip: estimatedTip))
    }

    /// The estimated tip for gate/delivery due-ness checks: ``project(welding:spacing:now:)``'s
    /// tip, degraded to `nil` (scanned-tip behavior) on ANY failure — sample read errors included —
    /// so a read failure can only ever fall back to, never block or crash, the paths that consult
    /// it. NOTE: since upstream #2927 the non-nil estimate is not merely accelerating — it sizes
    /// the persisted overdue re-spread (see the type doc above).
    static func gatingEstimatedTip(welding: ZcashRustBackendWelding, spacing: TargetBlockSpacing, now: Date) async -> BlockHeight? {
        (try? await project(welding: welding, spacing: spacing, now: now))?.estimatedTip
    }
}
