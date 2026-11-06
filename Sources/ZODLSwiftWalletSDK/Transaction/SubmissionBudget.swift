import Foundation

/// One endpoint attempt shares its deadline across admission, keys, height, send and outcome
/// recovery. Resource disposal drains before the budget scope returns, even after cancellation.
final class SubmissionBudget: Sendable {
    @TaskLocal static var current: SubmissionBudget?
    @TaskLocal static var monotonicNow: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    @TaskLocal static var legacyTimeoutMilliseconds: Int64 = 30_000

    let deadline: UInt64
    private let now: @Sendable () -> UInt64
    let connections = SubmissionConnections()

    init(milliseconds: Int64) throws {
        let now = Self.monotonicNow
        self.now = now
        deadline = try TorHTTPRequestExecutor.deadline(
            timeoutMilliseconds: UInt64(max(0, milliseconds)),
            now: now()
        )
    }

    func remainingMilliseconds() throws -> UInt64 {
        try Task.checkCancellation()
        let now = now()
        let remaining = deadline > now ? (deadline - now) / 1_000_000 : 0
        guard remaining > 0 else { throw URLError(.timedOut) }
        return remaining
    }

    static func withBudget<T>(milliseconds: Int64, operation: () async throws -> T) async throws -> T {
        let budget = try SubmissionBudget(milliseconds: milliseconds)
        return try await $current.withValue(budget) {
            do {
                let result = try await operation()
                await budget.connections.close()
                return result
            } catch {
                await budget.connections.close()
                throw error
            }
        }
    }
}

/// Submission connections never enter a long-lived service's ordinary circuit cache. The
/// enclosing budget owns them through known-transaction recovery, then closes their executors.
actor SubmissionConnections {
    private var connections: [String: TorLwdConn] = [:]

    func connection(endpoint: String, tor: TorClient) async throws -> TorLwdConn {
        _ = try SubmissionBudget.current?.remainingMilliseconds()
        if let connection = connections[endpoint] { return connection }
        let connection = try await tor.connectToLightwalletd(endpoint: endpoint)
        connections[endpoint] = connection
        return connection
    }

    func close() { connections.removeAll() }
}
