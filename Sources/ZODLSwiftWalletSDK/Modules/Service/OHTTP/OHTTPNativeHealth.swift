import Foundation
import libzcashlc
import os

/// Owns only native subscription resources. Its callback copies borrowed memory before returning.
final class OHTTPNativeHealth: Sendable {
    static let maximumObservationCount = 126

    final class CallbackBox: Sendable {
        let route: OHTTPHealthRoute
        let generation: UUID
        let nativeGeneration: UInt64
        let receive: @Sendable ([OHTTPHealthObservation]) -> Void

        init(route: OHTTPHealthRoute, generation: UUID, nativeGeneration: UInt64, receive: @escaping @Sendable ([OHTTPHealthObservation]) -> Void) {
            self.route = route
            self.generation = generation
            self.nativeGeneration = nativeGeneration
            self.receive = receive
        }

        func copy(_ entries: UnsafePointer<FfiOHTTPHealthObservationV1>?, count: Int, generation: UInt64) {
            guard generation == nativeGeneration, count <= OHTTPNativeHealth.maximumObservationCount, count >= 0, let entries else { return }
            let observations = UnsafeBufferPointer(start: entries, count: count).compactMap {
                OHTTPNativeHealth.observation($0, route: route, generation: self.generation, nativeGeneration: nativeGeneration)
            }
            receive(observations)
        }
    }

    private struct Ownership {
        let subscription: OpaquePointer
        let context: UnsafeMutableRawPointer
    }
    // Raw FFI pointers are used only under this ownership lock or after uniquely taking ownership.
    private let ownership = OSAllocatedUnfairLock<Ownership?>(uncheckedState: nil)
    private static let generations = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func checkVersion(_ version: UInt32) throws {
        guard version == 1 else { throw OHTTPHealthError.unsupportedNativeVersion(version) }
    }

    init(route: OHTTPHealthRoute, generation: UUID, receive: @escaping @Sendable ([OHTTPHealthObservation]) -> Void) throws {
        try Self.checkVersion(zcashlc_ohttp_health_api_version())
        guard !route.gatewayHost.utf8.contains(0), !route.relayURL.utf8.contains(0) else { throw OHTTPHealthError.subscriptionFailed }
        let nativeGeneration = Self.generations.withLock { next in
            precondition(next < UInt64.max, "OHTTP native generation identity exhausted")
            next += 1
            return next
        }
        let box = CallbackBox(route: route, generation: generation, nativeGeneration: nativeGeneration, receive: receive)
        let context = Unmanaged.passRetained(box).toOpaque()
        let subscription = route.gatewayHost.withCString { gateway in
            route.relayURL.withCString { relay in
                zcashlc_ohttp_health_subscribe_v1(gateway, relay, route.viaTor, nativeGeneration, { entries, count, _, generation, context in
                    guard let context else { return }
                    // Strong local ownership also protects a callback that retires its own subscription.
                    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                    box.copy(entries, count: Int(count), generation: generation)
                }, context)
            }
        }
        guard let subscription else {
            Unmanaged<CallbackBox>.fromOpaque(context).release()
            throw OHTTPHealthError.subscriptionFailed
        }
        ownership.withLockUnchecked { $0 = Ownership(subscription: subscription, context: context) }
        // Replay synchronously; a racing worker copy is deduplicated by original source version/time.
        var entries = Array(repeating: FfiOHTTPHealthObservationV1(), count: Self.maximumObservationCount)
        var version: UInt64 = 0
        var owner: UInt64 = 0
        let count = zcashlc_ohttp_health_snapshot_v1(subscription, &entries, UInt(entries.count), &version, &owner)
        guard count <= UInt(entries.count) else {
            close()
            throw OHTTPHealthError.subscriptionFailed
        }
        entries.withUnsafeBufferPointer { box.copy($0.baseAddress, count: Int(count), generation: owner) }
    }

    func close() {
        let retired = ownership.withLockUnchecked { ownership in
            let retired = ownership
            ownership = nil
            return retired
        }
        guard let retired else { return }
        // The callback never needs this lock, and the box remains retained through the native fence.
        zcashlc_ohttp_health_unsubscribe_v1(retired.subscription)
        Unmanaged<CallbackBox>.fromOpaque(retired.context).release()
    }

    deinit { close() }

    static func observation(
        _ entry: FfiOHTTPHealthObservationV1,
        route: OHTTPHealthRoute,
        generation: UUID,
        nativeGeneration: UInt64
    ) -> OHTTPHealthObservation? {
        guard let scope = OHTTPHealthScope(rawValue: entry.scope),
              let stage = OHTTPHealthStage(rawValue: entry.stage),
              let purpose = OHTTPHealthPurpose(rawValue: entry.purpose),
              let outcome = outcome(entry.outcome, retryNotBefore: entry.retry_not_before_nanoseconds) else { return nil }
        let operation = entry.has_operation ? OHTTPHealthOperation(
            id: UUID(uuid: entry.operation_id),
            startedAtNanoseconds: entry.operation_started_at_nanoseconds
        ) : nil
        return OHTTPHealthObservation(
            source: .native,
            route: route,
            scope: scope,
            outcome: outcome,
            stage: stage,
            generation: entry.generation == nativeGeneration ? generation : nil,
            nativeGeneration: entry.generation,
            version: entry.version,
            requestID: entry.request_id,
            startedAtNanoseconds: entry.started_at_nanoseconds,
            observedAtNanoseconds: entry.observed_at_nanoseconds,
            operation: operation,
            purpose: purpose,
            historical: entry.historical
        )
    }

    private static func outcome(_ tag: UInt32, retryNotBefore: UInt64) -> OHTTPHealthOutcome? {
        switch tag {
        case 0: return .usable
        case 1: return .transportUnavailable
        case 2: return .backendUnavailable
        case 3: return .rateLimited(retryNotBefore: retryNotBefore)
        case 4: return .policyRejected
        case 5: return .configurationFailure
        case 6: return .responseRejected
        case 7: return .cancelled
        case 8: return .inconclusive
        default: return nil
        }
    }
}
