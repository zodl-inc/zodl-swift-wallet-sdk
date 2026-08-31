//
//  ServerSwitchDecision.swift
//  ZcashLightClientKit
//

import Foundation

/// The pure policy behind `Synchronizer.evaluateServerSwitch`: given the current endpoint and
/// the benchmark's ranked results, decide whether switching is worth a synchronizer teardown.
///
/// A switch tears down and rebuilds the whole synchronizer (sync restart, connection and Tor
/// warmup), so a marginally faster server is all cost and no benefit — and the benchmark's
/// single-shot measurements are noisy enough that small deltas carry no signal at all.
enum ServerSwitchDecision {
    /// One benchmarked endpoint. `score` is whatever the benchmark ranks by (lower is better);
    /// scores are only comparable within a single benchmark run.
    struct MeasuredEndpoint {
        let endpoint: LightWalletEndpoint
        let score: TimeInterval
    }

    enum Thresholds {
        /// Minimum absolute score improvement worth a switch. Below ~200 ms the gain is
        /// imperceptible for sync workloads and sits inside single-shot measurement noise.
        static let minAbsoluteImprovement: TimeInterval = 0.2
        /// Minimum improvement relative to the current server's score. In high-latency
        /// regimes (e.g. Tor) a fixed 200 ms is within normal jitter; requiring 25% of the
        /// current score as well keeps noise from triggering switches there.
        static let minRelativeImprovement: Double = 0.25
    }

    enum Outcome {
        /// The benchmark produced no healthy results — stay.
        case noResults
        /// The fastest survivor is the current server — stay.
        case alreadyBest
        /// The current server produced no score (failed health checks, unreachable, failed the
        /// fetch, or was not among the candidates) — switch to the best regardless of magnitude.
        case currentUnhealthy(switchTo: LightWalletEndpoint)
        /// The best server beats the current one by enough on both gates — switch.
        case improvementSufficient(switchTo: LightWalletEndpoint, improvement: TimeInterval)
        /// The best server is faster, but not by enough to justify the teardown — stay.
        case improvementInsufficient(improvement: TimeInterval)

        var endpointToSwitchTo: LightWalletEndpoint? {
            switch self {
            case .noResults, .alreadyBest, .improvementInsufficient:
                return nil
            case let .currentUnhealthy(endpoint), let .improvementSufficient(endpoint, _):
                return endpoint
            }
        }

        var logDescription: String {
            switch self {
            case .noResults:
                return "stay (no healthy results)"
            case .alreadyBest:
                return "stay (current server is the best)"
            case let .currentUnhealthy(endpoint):
                return "switch to \(endpoint.host):\(endpoint.port) (current server unhealthy or unmeasured)"
            case let .improvementSufficient(endpoint, improvement):
                return "switch to \(endpoint.host):\(endpoint.port) (improvement \(Int(improvement * 1000)) ms)"
            case let .improvementInsufficient(improvement):
                return "stay (improvement \(Int(improvement * 1000)) ms below threshold)"
            }
        }
    }

    /// Decides whether to leave `current` for the best entry of `ranked`.
    /// - Parameters:
    ///   - current: The endpoint the wallet is connected to right now.
    ///   - ranked: Healthy benchmark survivors sorted ascending by `score` (best first).
    static func decide(current: LightWalletEndpoint, ranked: [MeasuredEndpoint]) -> Outcome {
        guard let best = ranked.first else { return .noResults }

        guard !matches(best.endpoint, current) else { return .alreadyBest }

        guard let currentMeasurement = ranked.first(where: { matches($0.endpoint, current) }) else {
            return .currentUnhealthy(switchTo: best.endpoint)
        }

        let improvement = currentMeasurement.score - best.score
        let meetsAbsoluteGate = improvement >= Thresholds.minAbsoluteImprovement
        let meetsRelativeGate = improvement >= Thresholds.minRelativeImprovement * currentMeasurement.score

        if meetsAbsoluteGate && meetsRelativeGate {
            return .improvementSufficient(switchTo: best.endpoint, improvement: improvement)
        } else {
            return .improvementInsufficient(improvement: improvement)
        }
    }

    private static func matches(_ lhs: LightWalletEndpoint, _ rhs: LightWalletEndpoint) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }
}
