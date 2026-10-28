//
//  TargetBlockSpacing.swift
//  ZODLSwiftWalletSDK
//

import Foundation
import libzcashlc

/// The proof-of-work target spacing schedule of a Zcash network: how many seconds the consensus
/// rules aim to put between consecutive blocks at each height. 150 seconds before Blossom, 75 from
/// Blossom, 25 from NU7. A block count converted to time with one constant goes wrong as soon as
/// the span crosses an activation, so convert through this type. The schedule comes from the Rust
/// core, which reads the network's consensus parameters, a registered custom network's included.
///
/// An ``Initializer`` registers its custom network's activation heights. A value for a custom
/// network nothing has registered is a host bug: it fails an assertion in debug builds and answers
/// with the 75-second schedule in release builds.
public struct TargetBlockSpacing: Sendable, Equatable {
    /// A maximal run of heights whose blocks share one target spacing.
    struct Era: Equatable {
        /// The first height of the era.
        let start: BlockHeight
        /// The first height after the era, or `nil` when no later upgrade changes the spacing.
        let end: BlockHeight?
        /// The target spacing of every block in the era, in seconds.
        let spacing: TimeInterval
    }

    /// Answered when the Rust core has no schedule for the network: the post-Blossom 75 seconds.
    private static let unavailableScheduleSpacing: TimeInterval = 75
    /// Answered when the Rust core has no schedule for the network: the pre-NU7 40 blocks.
    private static let unavailableScheduleExpiryDelta: BlockHeight = 40
    /// The most target time any span of expressible heights takes. Seconds beyond it are clamped
    /// before crossing the FFI, so their integer conversion cannot trap.
    private static let maxTargetSeconds = Double(UInt32.max) * 150

    /// The network whose schedule this is; values are equal exactly when their networks are.
    let networkType: NetworkType

    /// Creates the schedule of `network`.
    public init(network: ZcashNetwork) {
        self.init(networkType: network.networkType)
    }

    init(networkType: NetworkType) {
        self.networkType = networkType
    }

    /// The target spacing of the block at `height`, in seconds: the time the consensus rules aim to
    /// put between the blocks at `height - 1` and `height`.
    public func spacing(at height: BlockHeight) -> TimeInterval {
        era(containing: height).spacing
    }

    /// The target time of the blocks after `from` up to and including `to`, in seconds. Negative
    /// when `to` is below `from`, zero when equal. Heights outside `0...UInt32.max` count as the
    /// nearest height inside it.
    public func seconds(from: BlockHeight, to: BlockHeight) -> TimeInterval {
        var seconds: Int64 = 0
        guard zcashlc_target_seconds_between(networkType.networkId, Self.ffiHeight(from), Self.ffiHeight(to), &seconds) else {
            reportUnavailableSchedule()
            return (Double(Self.ffiHeight(to)) - Double(Self.ffiHeight(from))) * Self.unavailableScheduleSpacing
        }
        return TimeInterval(seconds)
    }

    /// The wall-clock time the blocks after `from` up to and including `to` take at
    /// `secondsPerBlock`, the measured pace of the era of block `from + 1`, the first block counted.
    /// A caller switches its rate at the activation block, so a range that starts at an activation
    /// takes the new era's pace, not the one measured before it. Zero when `to` is not above
    /// `from`. Exactly `Double(to - from) * secondsPerBlock` when no spacing change lies in
    /// between. Otherwise the blocks before the change take `secondsPerBlock` each, and every later
    /// block takes its own target spacing scaled by the rate's speed relative to the target spacing
    /// at `from + 1`. Heights outside `0...UInt32.max` count as the nearest height inside it, as in
    /// ``seconds(from:to:)``.
    public func estimatedSeconds(from: BlockHeight, to: BlockHeight, secondsPerBlock: Double) -> TimeInterval {
        // Clamp first, as `seconds(from:to:)` does, so none of the arithmetic below can overflow.
        let from = BlockHeight(Self.ffiHeight(from))
        let to = BlockHeight(Self.ffiHeight(to))
        guard to > from else {
            return 0
        }

        let firstEra = era(containing: from + 1)
        guard let change = firstEra.end, change <= to else {
            return Double(to - from) * secondsPerBlock
        }

        let speedFactor = secondsPerBlock / firstEra.spacing
        return Double(change - 1 - from) * secondsPerBlock + seconds(from: change - 1, to: to) * speedFactor
    }

    /// The maximal run of heights of one target spacing that contains `height`.
    func era(containing height: BlockHeight) -> Era {
        var eraStart: UInt32 = 0
        var eraEnd: Int64 = 0
        var eraSpacing: UInt32 = 0
        guard zcashlc_pow_target_spacing_era(networkType.networkId, Self.ffiHeight(height), &eraStart, &eraEnd, &eraSpacing) else {
            reportUnavailableSchedule()
            return Era(start: 0, end: nil, spacing: Self.unavailableScheduleSpacing)
        }
        return Era(start: BlockHeight(eraStart), end: eraEnd < 0 ? nil : BlockHeight(eraEnd), spacing: TimeInterval(eraSpacing))
    }

    /// The height `seconds` of target time reach from `height`, counting whole blocks only: the
    /// highest height whose blocks after `height` take no more than `seconds`. Negative `seconds`
    /// walk back to the lowest height whose blocks up to `height` take no more than the magnitude,
    /// never below 0.
    func height(reachedAfter seconds: TimeInterval, from height: BlockHeight) -> BlockHeight {
        let wholeSeconds = Self.ffiSeconds(seconds)
        var reached: UInt32 = 0
        guard zcashlc_height_after_target_seconds(networkType.networkId, Self.ffiHeight(height), wholeSeconds, &reached) else {
            reportUnavailableSchedule()
            let blocks = Int((Double(wholeSeconds) / Self.unavailableScheduleSpacing).rounded(.towardZero))
            return min(max(BlockHeight(Self.ffiHeight(height)) + blocks, 0), BlockHeight(UInt32.max))
        }
        return BlockHeight(reached)
    }

    /// The target height of a transaction with the default expiry delta that expires at
    /// `expiryHeight`: 40 blocks before it before NU7, 120 from NU7. An expiry no target produces
    /// (the 80 heights from 40 blocks after NU7 activation) answers the earlier candidate, so a
    /// derived height is never later than the real target height.
    func defaultTxTargetHeight(forExpiryHeight expiryHeight: BlockHeight) -> BlockHeight {
        var target: UInt32 = 0
        guard zcashlc_default_tx_target_height_for_expiry(networkType.networkId, Self.ffiHeight(expiryHeight), &target) else {
            reportUnavailableSchedule()
            return max(BlockHeight(Self.ffiHeight(expiryHeight)) - Self.unavailableScheduleExpiryDelta, 0)
        }
        return BlockHeight(target)
    }

    /// `height` clamped into the heights the consensus rules can express.
    private static func ffiHeight(_ height: BlockHeight) -> UInt32 {
        UInt32(clamping: height)
    }

    /// Whole seconds for the FFI. Truncating toward zero loses nothing, because only whole blocks
    /// count and every spacing is whole seconds; the clamp keeps the conversion from trapping.
    private static func ffiSeconds(_ seconds: TimeInterval) -> Int64 {
        guard !seconds.isNaN else {
            return 0
        }
        return Int64(min(max(seconds, -maxTargetSeconds), maxTargetSeconds).rounded(.towardZero))
    }

    /// Only a custom network used before anything registered it can leave the core without a
    /// schedule; fail loudly in debug builds and clear the error the call left behind.
    private func reportUnavailableSchedule() {
        zcashlc_clear_last_error()
        assertionFailure("No target block spacing for the \(networkType.chainName) network; create its Initializer before using it.")
    }
}
