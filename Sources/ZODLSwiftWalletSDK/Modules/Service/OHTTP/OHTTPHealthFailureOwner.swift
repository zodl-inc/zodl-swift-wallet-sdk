import Foundation

/// A mixed business owner must explicitly select the request that determines its failure.
/// Capturing this value also preserves the originating context across a lazy stream boundary.
struct OHTTPHealthFailureOwner: Sendable {
    let operation: OHTTPHealthOperation?
    let attempt: OHTTPHealthAttempt?

    init() {
        operation = OHTTPHealthContext.operation
        attempt = OHTTPHealthContext.attempt
        attempt?.beginDelegation()
    }

    func makeAttempt() -> OHTTPHealthAttempt? {
        operation.map { OHTTPHealthAttempt(operation: $0) }
    }

    func withAttempt<T>(_ child: OHTTPHealthAttempt?, operation work: () async throws -> T) async rethrows -> T {
        let admitted = child.map { $0.operation == operation && $0.enter() } ?? false
        defer { if admitted { child?.leave() } }
        return try await OHTTPHealthContext.$operation.withValue(operation) {
            try await OHTTPHealthContext.$attempt.withValue(admitted ? child : nil) { try await work() }
        }
    }

    func adoptFailure(from child: OHTTPHealthAttempt?) {
        if let child { attempt?.adoptFailure(from: child) }
    }

    /// Use only around an awaited request whose thrown error is propagated by this owner.
    func request<T>(operation work: () async throws -> T) async rethrows -> T {
        let child = makeAttempt()
        do {
            return try await withAttempt(child, operation: work)
        } catch {
            adoptFailure(from: child)
            throw error
        }
    }
}
