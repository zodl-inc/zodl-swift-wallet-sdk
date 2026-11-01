import Foundation
import os

/// The lease is retained until actual work, including outcome recovery, ends. A caller timeout
/// never releases another task's lease or changes its selected route.
final class TorNetworkLease: Sendable {
    let owner: TorNetworkAdmission
    let enabled: Bool
    init(owner: TorNetworkAdmission, enabled: Bool) {
        self.owner = owner
        self.enabled = enabled
    }
    deinit { owner.release() }
}

final class TorNetworkAdmission: Sendable {
    @TaskLocal static var current: TorNetworkLease?
    private struct State {
        var enabled: Bool
        var required: Bool?
        var fenced = false
        var active = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(enabled: Bool) { state = OSAllocatedUnfairLock(initialState: State(enabled: enabled)) }

    var isFenced: Bool { state.withLock { $0.fenced } }

    var selectedTor: Bool {
        if let lease = Self.current, lease.owner === self { return lease.enabled }
        return state.withLock { $0.required ?? $0.enabled }
    }

    func require(_ enabled: Bool) {
        state.withLock {
            $0.required = enabled
            $0.fenced = true
        }
    }

    func updateEffective(_ enabled: Bool) { state.withLock { $0.enabled = enabled } }

    func install(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            $0.required = enabled
            $0.fenced = false
        }
    }

    func acquire() throws -> TorNetworkLease {
        if let lease = Self.current, lease.owner === self { return lease }
        return try state.withLock {
            guard !$0.fenced else { throw TorTransitionState.Failure.routeUnavailable }
            $0.active += 1
            return TorNetworkLease(owner: self, enabled: $0.enabled)
        }
    }

    func withLease<T>(_ operation: () async throws -> T) async throws -> T {
        let lease = try acquire()
        return try await Self.$current.withValue(lease, operation: operation)
    }

    func release() { state.withLock { $0.active -= 1 } }

    func drain(deadline: UInt64) async throws {
        while state.withLock({ $0.active > 0 }) {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw TorTransitionState.Failure.acquisitionTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Keeps an already dispatched response admitted until its lazy body ends or is dropped.
final class TorAdmittedResponseBody: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private var lease: TorNetworkLease?

    init(body: AsyncThrowingStream<Data, Error>, lease: TorNetworkLease) {
        iterator = body.makeAsyncIterator()
        self.lease = lease
    }

    func next() async throws -> Data? {
        guard let lease else { return nil }
        do {
            let data = try await TorNetworkAdmission.$current.withValue(lease) { try await self.iterator.next() }
            if data == nil { self.lease = nil }
            return data
        } catch {
            self.lease = nil
            throw error
        }
    }
}
