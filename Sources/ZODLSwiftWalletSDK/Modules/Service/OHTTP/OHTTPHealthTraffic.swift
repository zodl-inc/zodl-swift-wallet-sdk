import Foundation
import os
import libzcashlc

/// Local evidence accompanies the original error; it never changes the caller's result.
final class OHTTPHealthTraffic: Sendable {
    @TaskLocal static var current: OHTTPHealthTraffic?
    let ticket: OHTTPHealthRequest
    private struct State {
        var stage = OHTTPHealthStage.keyConfiguration
        var failure: OHTTPHealthOutcome?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(route: OHTTPHealthRoute, request: OHTTPRequest) {
        ticket = OHTTPHealthCenter.shared.begin(
            route: route,
            scope: Self.scope(request.authority),
            purpose: OHTTPHealthProbe.budget == nil ? nil : .diagnostic
        )
    }

    /// Immediate recovery keeps request identity, but discarded stream callbacks keep their own provenance.
    init(ticket: OHTTPHealthRequest) { self.ticket = ticket }

    func advance(_ stage: OHTTPHealthStage) {
        state.withLock {
            $0.stage = stage
            if stage == .connection || stage == .keyConfiguration { $0.failure = nil }
        }
    }

    func failed(_ error: Error) {
        let value = state.withLock { $0 }
        let outcome = Self.outcome(error)
        let resolved = outcome == .cancelled && OHTTPHealthProbe.budget == nil ? outcome : value.failure ?? outcome
        OHTTPHealthProbe.budget?.record(resolved)
        ticket.record(outcome: resolved, stage: value.stage)
    }

    var failure: OHTTPHealthOutcome? { state.withLock { $0.failure } }

    func classify(_ outcome: OHTTPHealthOutcome) {
        state.withLock {
            // A newly observed explicit pause also applies after a rejected fallback source.
            if case .rateLimited = outcome {
                if case .rateLimited = $0.failure { return }
                $0.failure = outcome
                return
            }
            switch $0.failure {
            case .backendUnavailable, .policyRejected, .configurationFailure, .responseRejected, .rateLimited:
                return
            default:
                $0.failure = outcome
            }
        }
    }

    func nativeFailure(_ kind: UInt32) {
        switch kind {
        case 2: classify(.transportUnavailable)
        case 3: classify(.configurationFailure)
        case 4: classify(.responseRejected)
        default: classify(.inconclusive)
        }
    }

    func nativeFailure(_ native: FfiOhttpDecodeOutcome, grpcStatus: Int32 = -1) {
        if decodedHead(native) { return }
        if (1...16).contains(grpcStatus) {
            classify(Self.grpcOutcome(grpcStatus))
        } else {
            nativeFailure(native.kind)
        }
    }

    @discardableResult
    func decodedHead(_ native: FfiOhttpDecodeOutcome) -> Bool {
        if native.http_status != 0 { ticket.recordRouteUsable(stage: .responseHead) }
        switch native.http_status {
        case 429: classify(.rateLimited(retryNotBefore: native.retry_not_before_ns))
        case 400, 401, 403, 404, 405, 409, 413, 415, 422, 426, 500...599:
            classify(Self.statusOutcome(Int(native.http_status)))
        default: return false
        }
        return true
    }

    func received(_ response: OHTTPResponse, stage: OHTTPHealthStage) {
        ticket.recordRouteUsable(stage: stage)
        var outcome = Self.responseOutcome(response)
        if case .rateLimited = outcome, case .rateLimited(let originalDeadline) = failure {
            outcome = .rateLimited(retryNotBefore: originalDeadline)
        }
        if outcome != .usable {
            classify(outcome)
            // RPC error wrapping must preserve rejections, while usable headers cannot establish body success.
            OHTTPHealthProbe.budget?.record(outcome)
        }
        ticket.record(outcome: outcome, stage: stage)
    }

    func outerResponse(status: Int, retryAfter: String?) {
        if status == 429 {
            let seconds = OHTTPTransport.retryAfter(retryAfter) ?? OHTTPTransport.defaultRateLimitPause
            classify(.rateLimited(retryNotBefore: OHTTPHealthClock.nowNanoseconds + UInt64(seconds * 1_000_000_000)))
        } else if [400, 401, 403, 404, 405, 409, 413, 415, 422, 426].contains(status) {
            classify(Self.statusOutcome(status))
        }
    }

    func outerResponse(_ native: FfiTorHttpOutcome) {
        let status = Int(native.http_status)
        guard (400..<500).contains(status) else { return }
        if case .inconclusive = Self.statusOutcome(status) { return }
        classify(OHTTPNativeHTTPFailure(native).outcome)
    }

    static func scope(_ authority: String) -> OHTTPHealthScope {
        switch authority.lowercased() {
        case "cmc.zodl.com": return .exchangeRates
        case "near.zodl.com": return .swaps
        case "flexa.zodl.com": return .flexa
        case "vote.zodl.com": return .voting
        default: return OHTTPEndpoints.isGateway(authority) ? .lightwalletd : .other
        }
    }

    static func outcome(_ error: Error) -> OHTTPHealthOutcome {
        if let native = error as? OHTTPNativeHTTPFailure { return native.outcome }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed: return .transportUnavailable
            default: return .inconclusive
            }
        }
        guard let error = error as? OHTTPError else { return .inconclusive }
        switch error {
        case .httpStatusError(let status, _): return status >= 500 ? .transportUnavailable : statusOutcome(status)
        case .keyConfigError, .hpkeError: return .configurationFailure
        case .binaryHttpError, .requestTooLarge, .responseTooLarge: return .responseRejected
        case .transportError: return .inconclusive
        }
    }

    static func statusOutcome(_ status: Int) -> OHTTPHealthOutcome {
        switch status {
        case 200..<300: return .usable
        case 429: return .rateLimited(retryNotBefore: OHTTPHealthClock.nowNanoseconds + 30_000_000_000)
        case 401, 403, 426: return .policyRejected
        case 400, 404, 405, 409, 413, 415, 422: return .responseRejected
        case 500..<600: return .backendUnavailable
        default: return .inconclusive
        }
    }

    static func responseOutcome(_ response: OHTTPResponse) -> OHTTPHealthOutcome {
        if response.status == 429 {
            let delay = OHTTPTransport.retryAfter(response.field("retry-after")) ?? OHTTPTransport.defaultRateLimitPause
            return .rateLimited(retryNotBefore: OHTTPHealthClock.nowNanoseconds + UInt64(delay * 1_000_000_000))
        }
        let outcome = statusOutcome(response.status)
        guard outcome == .usable, let status = response.field("grpc-status"), status != "0" else { return outcome }
        return grpcOutcome(Int32(status) ?? -1)
    }

    private static func grpcOutcome(_ status: Int32) -> OHTTPHealthOutcome {
        switch status {
        case 1: return .cancelled
        case 4, 14: return .backendUnavailable
        case 7, 16: return .policyRejected
        case 8: return .responseRejected
        default: return .responseRejected
        }
    }
}

/// Classification is copied before reading any thread-local native error text or disposing owners.
struct OHTTPNativeHTTPFailure: Error {
    let outcome: OHTTPHealthOutcome

    init(_ native: FfiTorHttpOutcome) {
        switch native.http_status {
        case 401, 403, 426: outcome = .policyRejected
        case 400, 404, 405, 409, 413, 415, 422: outcome = .responseRejected
        case 429:
            outcome = .rateLimited(retryNotBefore: native.retry_not_before_ns)
        default:
            switch native.kind {
            case 1, 2: outcome = .transportUnavailable
            case 3: outcome = .configurationFailure
            case 4: outcome = .responseRejected
            default: outcome = .inconclusive
            }
        }
    }
}

extension Result where Failure == Error {
    var hasAuthoritativeHTTPFailure: Bool {
        guard case .failure(let error) = self, let failure = error as? OHTTPNativeHTTPFailure else { return false }
        switch failure.outcome {
        case .policyRejected, .configurationFailure, .responseRejected, .rateLimited: return true
        default: return false
        }
    }
}
