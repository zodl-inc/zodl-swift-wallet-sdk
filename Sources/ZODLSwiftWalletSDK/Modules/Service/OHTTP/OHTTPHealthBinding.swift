import Foundation
import os

public enum OHTTPHealthBindingPhase: Sendable, Equatable {
    case unavailable, replacing, ready
}

/// Local ownership identities, never serialized into requests. Ready describes a settled selected
/// route, independently of whether a wallet engine exists or a network request has succeeded.
public struct OHTTPHealthBindingSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let bindingID: UUID
    public let continuityID: UUID
    public let phase: OHTTPHealthBindingPhase

    public init(revision: UInt64, bindingID: UUID, continuityID: UUID, phase: OHTTPHealthBindingPhase) {
        self.revision = revision
        self.bindingID = bindingID
        self.continuityID = continuityID
        self.phase = phase
    }
}

/// One synchronizer's retained health admission state. It owns neither the provider nor sessions.
public final class OHTTPHealthBinding: Sendable {
    let ownerID = UUID()
    private struct WeakSession: Sendable { weak var session: OHTTPHealthSession? }
    private struct State {
        var endpoint: LightWalletEndpoint
        var snapshot = OHTTPHealthBindingSnapshot(
            revision: 0,
            bindingID: UUID(),
            continuityID: UUID(),
            phase: .ready
        )
        var transitions: Set<UUID> = []
        var retired = false
        var sessions: [WeakSession] = []
        var subscribers: [UUID: BindingMailbox] = [:]
    }
    private struct Retirement {
        let sessions: [OHTTPHealthSession]
        let subscribers: [BindingMailbox]
        let snapshot: OHTTPHealthBindingSnapshot
    }
    private let state: OSAllocatedUnfairLock<State>

    init(endpoint: LightWalletEndpoint) {
        state = OSAllocatedUnfairLock(initialState: State(endpoint: endpoint))
    }

    public func snapshot() -> OHTTPHealthBindingSnapshot { state.withLock { $0.snapshot } }

    public func updates() -> AsyncStream<OHTTPHealthBindingSnapshot> {
        let id = UUID()
        let mailbox = BindingMailbox()
        let initial = state.withLock { state in
            state.subscribers[id] = mailbox
            return (state.snapshot, state.retired)
        }
        mailbox.publish(initial.0)
        if initial.1 { mailbox.close() }
        let lifetime = BindingLifetime(mailbox: mailbox) { [weak self] in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
            mailbox.close()
        }
        return AsyncStream(unfolding: { await lifetime.mailbox.next() }, onCancel: { lifetime.cancel() })
    }

    func readyToken() throws -> UUID {
        try state.withLock {
            guard !$0.retired, $0.snapshot.phase == .ready else { throw OHTTPHealthError.bindingUnavailable }
            return $0.snapshot.bindingID
        }
    }

    /// The candidate was constructed outside this lock for a token captured before async lookup.
    /// Rejection closes outside the lock, including the native callback fence.
    func admit(_ candidate: OHTTPHealthSession) throws {
        let admitted = state.withLock { state in
            guard !state.retired, state.snapshot.phase == .ready,
                  candidate.ownerID == ownerID, candidate.bindingID == state.snapshot.bindingID, candidate.isValid else { return false }
            state.sessions.removeAll { $0.session == nil }
            state.sessions.append(WeakSession(session: candidate))
            return true
        }
        if !admitted {
            candidate.close()
            throw OHTTPHealthError.bindingUnavailable
        }
    }

    func accepts(_ session: OHTTPHealthSession) -> Bool {
        state.withLock { state in
            !state.retired && state.snapshot.phase == .ready && session.isValid &&
                state.sessions.contains { $0.session === session }
        }
    }

    @discardableResult
    func beginTransition(walletReset: Bool = false) -> UUID {
        let token = UUID()
        let effects = state.withLock { state -> Retirement in
            guard !state.retired else { return Retirement(sessions: [], subscribers: [], snapshot: state.snapshot) }
            state.transitions.insert(token)
            state.snapshot = OHTTPHealthBindingSnapshot(
                revision: state.snapshot.revision + 1,
                bindingID: UUID(),
                continuityID: walletReset ? UUID() : state.snapshot.continuityID,
                phase: .replacing
            )
            let sessions = state.sessions.compactMap(\.session)
            return Retirement(sessions: sessions, subscribers: Array(state.subscribers.values), snapshot: state.snapshot)
        }
        for session in effects.sessions { session.close() }
        // Keep weak registrations visible until the native fence completes: overlapping begins
        // must join sessions already closing. Remove only this captured batch, never a newer owner.
        state.withLock { state in
            state.sessions.removeAll { entry in
                entry.session == nil || effects.sessions.contains { $0 === entry.session }
            }
        }
        for subscriber in effects.subscribers { subscriber.publish(effects.snapshot) }
        return token
    }

    func settle(transition: UUID, endpoint: LightWalletEndpoint) {
        let effects = state.withLock { state -> ([BindingMailbox], OHTTPHealthBindingSnapshot)? in
            guard !state.retired, state.transitions.remove(transition) != nil else { return nil }
            state.snapshot = OHTTPHealthBindingSnapshot(
                revision: state.snapshot.revision + 1,
                bindingID: state.snapshot.bindingID,
                continuityID: state.endpoint.isSameServer(as: endpoint) ? state.snapshot.continuityID : UUID(),
                phase: state.transitions.isEmpty ? .ready : .replacing
            )
            state.endpoint = endpoint
            return (Array(state.subscribers.values), state.snapshot)
        }
        if let effects { for subscriber in effects.0 { subscriber.publish(effects.1) } }
    }

    /// Record each committed route publication before a subsequent suspension. Overlapping
    /// replacements can publish A → B → A before either settles; both changes break continuity.
    func recordPublishedEndpoint(_ endpoint: LightWalletEndpoint) {
        let effects = state.withLock { state -> ([BindingMailbox], OHTTPHealthBindingSnapshot)? in
            guard !state.retired, !state.transitions.isEmpty, !state.endpoint.isSameServer(as: endpoint) else { return nil }
            state.endpoint = endpoint
            state.snapshot = OHTTPHealthBindingSnapshot(
                revision: state.snapshot.revision + 1,
                bindingID: state.snapshot.bindingID,
                continuityID: UUID(),
                phase: .replacing
            )
            return (Array(state.subscribers.values), state.snapshot)
        }
        if let effects { for subscriber in effects.0 { subscriber.publish(effects.1) } }
    }

    func retire() {
        let effects = state.withLock { state -> Retirement in
            state.retired = true
            state.transitions = []
            state.snapshot = OHTTPHealthBindingSnapshot(
                revision: state.snapshot.revision + 1,
                bindingID: UUID(),
                continuityID: state.snapshot.continuityID,
                phase: .unavailable
            )
            let effects = Retirement(
                sessions: state.sessions.compactMap(\.session),
                subscribers: Array(state.subscribers.values),
                snapshot: state.snapshot
            )
            state.sessions = []
            state.subscribers = [:]
            return effects
        }
        for session in effects.sessions { session.close() }
        for subscriber in effects.subscribers {
            subscriber.publish(effects.snapshot)
            subscriber.close()
        }
    }

    deinit { retire() }
}

/// One retained newest slot. Revision comparison also fences publication racing initial replay.
private final class BindingMailbox: Sendable {
    private struct State {
        var latest: OHTTPHealthBindingSnapshot?
        var revision: UInt64?
        var closed = false
        var waiter: CheckedContinuation<OHTTPHealthBindingSnapshot?, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func publish(_ snapshot: OHTTPHealthBindingSnapshot) {
        let waiter = state.withLock { state -> CheckedContinuation<OHTTPHealthBindingSnapshot?, Never>? in
            guard !state.closed, state.revision.map({ snapshot.revision > $0 }) ?? true else { return nil }
            state.revision = snapshot.revision
            let waiter = state.waiter
            state.waiter = nil
            state.latest = waiter == nil ? snapshot : nil
            return waiter
        }
        waiter?.resume(returning: snapshot)
    }

    func next() async -> OHTTPHealthBindingSnapshot? {
        await withCheckedContinuation { continuation in
            let delivery = state.withLock { state -> (Bool, OHTTPHealthBindingSnapshot?) in
                if let latest = state.latest {
                    state.latest = nil
                    return (true, latest)
                }
                if state.closed { return (true, nil) }
                state.waiter = continuation
                return (false, nil)
            }
            if delivery.0 { continuation.resume(returning: delivery.1) }
        }
    }

    func close() {
        let waiter = state.withLock { state in
            state.closed = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}

private final class BindingLifetime: Sendable {
    let mailbox: BindingMailbox
    let cancel: @Sendable () -> Void

    init(mailbox: BindingMailbox, cancel: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox
        self.cancel = cancel
    }

    deinit { cancel() }
}
