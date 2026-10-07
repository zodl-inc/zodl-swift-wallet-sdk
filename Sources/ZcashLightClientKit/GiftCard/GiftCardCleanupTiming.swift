import Foundation

struct GiftCardCleanupTiming: Sendable {
    let now: @Sendable () -> UInt64
    let sleepUntil: @Sendable (UInt64) async throws -> Void

    static let live = GiftCardCleanupTiming(
        now: { DispatchTime.now().uptimeNanoseconds },
        sleepUntil: { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                try await Task.sleep(nanoseconds: deadline - now)
            } else {
                try Task.checkCancellation()
            }
        }
    )
}

enum GiftCardCleanupWaitError: Error {
    case timedOut
}
