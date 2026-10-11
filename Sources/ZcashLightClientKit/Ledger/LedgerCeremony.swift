//
//  LedgerCeremony.swift
//  ZcashLightClientKit
//

import Foundation

/// Ownership of a transport for the whole of one ceremony.
///
/// A transport admits one exchange at a time, and a ``LedgerDevice`` runs one call at a time, but
/// neither protects what the device actually cares about: a pairing, a signing ceremony or an app
/// switch is a run of commands whose order the device's state depends on. One command from another
/// ceremony in the middle of that run -- a second `LedgerDevice` over the same transport reading the
/// app version while the first is exporting a viewing key, say -- corrupts the device's ceremony and
/// fails both callers.
///
/// Every entry point that talks to a device therefore takes the transport's ceremony gate before its
/// first command and holds it until it is done, success or failure: ``LedgerDevice``'s commands and
/// pairing, ``LedgerSigner``'s signing ceremony, and `LedgerZcashApp`'s app queries and switches. Two
/// ceremonies on one transport run one after the other, whichever objects started them.
///
/// The gate belongs to the transport, not to the SDK object using it: ``LedgerCeremonyGates`` keeps
/// one per transport instance that has a ceremony running or queued, so two devices over one
/// transport, or a device and a signing ceremony, find the same gate. A caller cancelled while queued
/// for it throws `CancellationError` without touching the transport: it never sent anything, and the
/// transport stays with whoever holds it.
enum LedgerCeremony {
    /// Runs `body` as the only ceremony on `transport`, waiting for any ceremony already running or
    /// queued on it to finish first.
    ///
    /// - Parameters:
    ///   - transport: The transport the ceremony's commands go over.
    ///   - isolation: Keeps `body` running on the caller's own actor, exactly as if it were inlined
    ///     there, rather than on whatever executor this free function would otherwise run on.
    ///   - body: The ceremony: every command it sends goes over `transport`.
    /// - Throws: `CancellationError` when the calling task is cancelled before the ceremony is admitted;
    ///   nothing was sent and nothing is closed. Otherwise whatever `body` throws.
    static func run<T>(
        on transport: any LedgerAPDUTransport,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        let gates = LedgerCeremonyGates.shared
        let gate = await gates.gate(for: transport)
        do {
            try await gate.acquire()
        } catch {
            await gates.release(transport)
            throw CancellationError()
        }
        let hold = LedgerCeremonyHold(transport: transport, gate: gate)

        do {
            let result = try await body()
            await hold.release()
            return result
        } catch {
            await hold.release()
            throw error
        }
    }

    /// Takes `transport` for a ceremony already in progress that moves onto it partway through -- a
    /// pairing or an app switch whose link dropped and that reconnected -- and keeps it until the
    /// returned hold is released.
    ///
    /// A transport nothing else is using is taken at once, even by a task that is already cancelled:
    /// the ceremony is then the transport's only user, and its own cancellation handling closes the
    /// transport as it would any other it is on, instead of leaving a fresh connection open that
    /// nothing owns. A transport another ceremony holds is waited for, and a cancellation while
    /// queued throws `CancellationError` without taking it: the transport stays with its holder, and
    /// the caller must not have adopted it, so that its cleanup closes nothing of the holder's.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled while queued behind another
    ///   ceremony on `transport`.
    static func adopt(_ transport: any LedgerAPDUTransport) async throws -> LedgerCeremonyHold {
        let gates = LedgerCeremonyGates.shared
        let gate = await gates.gate(for: transport)
        if await gate.tryAcquire() {
            return LedgerCeremonyHold(transport: transport, gate: gate)
        }
        do {
            try await gate.acquire()
        } catch {
            await gates.release(transport)
            throw CancellationError()
        }
        return LedgerCeremonyHold(transport: transport, gate: gate)
    }

    /// Closes `transport` unless some ceremony holds it.
    ///
    /// A `reconnect` may hand back a transport another ceremony is already running, or the caller's
    /// own transport reconnecting internally -- `adopt(_:)`'s documentation covers both. Closing such
    /// a transport out from under its ceremony would disconnect it, so this leaves it alone instead,
    /// closing only a transport nothing holds.
    ///
    /// - Parameters:
    ///   - transport: The transport to close if nothing holds its ceremony.
    static func closeIfUnowned(_ transport: any LedgerAPDUTransport) async {
        let gates = LedgerCeremonyGates.shared
        let gate = await gates.gate(for: transport)
        if await gate.tryAcquire() {
            await transport.close()
            await gate.release()
        }
        await gates.release(transport)
    }
}

/// A ceremony's hold on one transport, from `LedgerCeremony.adopt(_:)`; `LedgerCeremony.run(on:_:)`
/// holds its transport the same way for the span of its body. Release it exactly once, when the
/// ceremony is done with the transport, success or failure.
struct LedgerCeremonyHold {
    fileprivate let transport: any LedgerAPDUTransport
    fileprivate let gate: LedgerSerialGate

    /// Lets the next ceremony queued on the transport, if any, proceed.
    func release() async {
        await gate.release()
        await LedgerCeremonyGates.shared.release(transport)
    }
}

/// The ceremony gate of every transport with a ceremony running or queued on it.
///
/// Keyed by the transport instance, so every ceremony on one transport, from whatever object, waits
/// on the same ``LedgerSerialGate``. An entry lives as long as some ceremony holds or waits for it and
/// goes away with the last one, so a transport that is released and deallocated leaves nothing behind,
/// and an instance address reused by a later transport never finds a stale gate.
actor LedgerCeremonyGates {
    static let shared = LedgerCeremonyGates()

    private var gates: [ObjectIdentifier: (gate: LedgerSerialGate, users: Int)] = [:]

    /// How many transports currently have a ceremony running or queued. Test-only visibility into
    /// otherwise-private state.
    var transportsInUse: Int { gates.count }

    /// How many ceremonies are queued behind the one running on `transport`; `0` when none runs.
    /// Test-only visibility, so a test can wait for a caller to actually be queued instead of
    /// guessing with a sleep.
    func queuedCeremonies(on transport: any LedgerAPDUTransport) async -> Int {
        guard let gate = gates[ObjectIdentifier(transport)]?.gate else {
            return 0
        }
        return await gate.queuedCount
    }

    /// The gate for `transport`, counting the caller as one of its users until ``release(_:)``.
    func gate(for transport: any LedgerAPDUTransport) -> LedgerSerialGate {
        let key = ObjectIdentifier(transport)
        if var entry = gates[key] {
            entry.users += 1
            gates[key] = entry
            return entry.gate
        }
        let gate = LedgerSerialGate()
        gates[key] = (gate, 1)
        return gate
    }

    /// Drops one user of `transport`'s gate, and the gate itself with the last user.
    func release(_ transport: any LedgerAPDUTransport) {
        let key = ObjectIdentifier(transport)
        guard var entry = gates[key] else {
            return
        }
        entry.users -= 1
        if entry.users == 0 {
            gates[key] = nil
        } else {
            gates[key] = entry
        }
    }
}
