//
//  LedgerReconnectCeremonyTests.swift
//  OfflineTests
//
//  A pairing that reconnects partway through keeps its ceremony on the reconnected transport: nothing
//  else may run on the device, or on that transport, until the pairing itself is over.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Polls `condition` with a short yield between checks, failing the test after `timeoutSeconds` if
/// it never becomes true. Not named `waitUntil`: `XCTestCase` has a member of that name (from
/// `TestUtils`) that returns the outcome instead of failing, and member lookup would win.
private func expectEventually(
    timeoutSeconds: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = DispatchTime.now() + timeoutSeconds
    while DispatchTime.now() < deadline {
        if await condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("condition did not become true within \(timeoutSeconds) s", file: file, line: line)
}

/// A transport that answers the firmware-version and identity reads from a script, and on its first
/// `GET_VK` reply waits for ``releaseExport()`` instead of answering at once -- standing in for the
/// device waiting on the user's on-device approval of the export, which has no timeout of its own.
/// Later `GET_VK` chunks, once that first one is released, answer without waiting again.
private actor SignaledExportTransport: LedgerAPDUTransport {
    private(set) var received: [Data] = []
    private(set) var closeCount = 0
    private(set) var isWaitingForExportSignal = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let chunks: [Data]

    init(ufvk: String) {
        self.chunks = LedgerReplies.viewingKeyChunks(ufvk)
    }

    var instructions: [UInt8] { received.map { $0[1] } }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        let history = received
        received.append(apdu)
        switch apdu[1] {
        case LedgerReplies.getFirmwareVersion:
            return LedgerReplies.firmwareVersion(3, 9, 3)
        case LedgerReplies.getWalletPublicKey:
            return LedgerReplies.walletPublicKey(LedgerReplies.seedIdentityPoint)
        case LedgerReplies.getVK:
            if !released {
                isWaitingForExportSignal = true
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseContinuation = continuation
                }
                isWaitingForExportSignal = false
            }
            return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
        default:
            return LedgerReplies.status(0x6D00)
        }
    }

    func close() async {
        closeCount += 1
    }

    /// Lets a `GET_VK` reply waiting in `exchange(_:timeout:)` proceed; every export chunk after it
    /// answers at once.
    func releaseExport() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// A replacement transport two devices share: it answers the firmware-version and identity reads
/// and the first `GET_VK` chunk normally, parking on that first reply for ``releaseExport()`` like
/// `SignaledExportTransport`, and parks again on its first ``close()`` for ``releaseClose()``. An
/// exchange reaching it once `close()` has fully finished is refused.
private actor SignaledExportAndCloseTransport: LedgerAPDUTransport {
    private(set) var received: [Data] = []
    private(set) var closeCount = 0
    private(set) var isWaitingForExportSignal = false
    private(set) var isClosing = false
    private var releaseExportContinuation: CheckedContinuation<Void, Never>?
    private var releaseCloseContinuation: CheckedContinuation<Void, Never>?
    private var exportReleased = false
    private var isClosed = false
    private let chunks: [Data]

    init(ufvk: String) {
        self.chunks = LedgerReplies.viewingKeyChunks(ufvk)
    }

    var instructions: [UInt8] { received.map { $0[1] } }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        guard !isClosed else { throw ZcashError.ledgerTransportClosed }
        let history = received
        received.append(apdu)
        switch apdu[1] {
        case LedgerReplies.getFirmwareVersion:
            return LedgerReplies.firmwareVersion(3, 9, 3)
        case LedgerReplies.getWalletPublicKey:
            return LedgerReplies.walletPublicKey(LedgerReplies.seedIdentityPoint)
        case LedgerReplies.getVK:
            if !exportReleased {
                isWaitingForExportSignal = true
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseExportContinuation = continuation
                }
                isWaitingForExportSignal = false
            }
            return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
        default:
            return LedgerReplies.status(0x6D00)
        }
    }

    /// Parks on the first call, for ``releaseClose()``, before counting itself done; every call
    /// after that one returns at once, closing twice having no effect beyond the count.
    func close() async {
        closeCount += 1
        guard !isClosing, !isClosed else { return }
        isClosing = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseCloseContinuation = continuation
        }
        isClosing = false
        isClosed = true
    }

    /// Lets a `GET_VK` reply waiting in `exchange(_:timeout:)` proceed; every export chunk after it
    /// answers at once.
    func releaseExport() {
        exportReleased = true
        releaseExportContinuation?.resume()
        releaseExportContinuation = nil
    }

    /// Lets a `close()` waiting to finish proceed.
    func releaseClose() {
        releaseCloseContinuation?.resume()
        releaseCloseContinuation = nil
    }
}

final class LedgerReconnectCeremonyTests: XCTestCase {
    private func testnetUFVK() throws -> UnifiedFullViewingKey {
        let tool = DerivationTool(networkType: .testnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    /// A transport whose every exchange fails on the connection, as if the device were out of range:
    /// `pairAccount`'s first read never gets further than this.
    private func stalledTransport() -> ScriptedLedgerTransport {
        ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
    }

    /// The instructions a pairing of account 0 sends on the transport it ends up exporting over, then
    /// the one probe command after it, in order.
    private func pairingThenProbeInstructions(ufvk: String) -> [UInt8] {
        [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey]
            + Array(repeating: LedgerReplies.getVK, count: LedgerReplies.viewingKeyChunks(ufvk).count)
            + [LedgerReplies.getFirmwareVersion]
    }

    // MARK: - A call on the same device waits for a reconnected export

    /// While a reconnected pairing's export waits on the device, a second call on the same
    /// `LedgerDevice` must not put its command on the reconnected transport until the pairing is over:
    /// its probe comes after every one of the export's chunks, never between two of them.
    func testAVersionProbeOnTheSameDeviceWaitsForAReconnectedExportToFinish() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        // Waits for the export to have actually reached its signal, so it provably holds the
        // reconnected transport's ceremony once the probe below is dispatched.
        await expectEventually { await fresh.isWaitingForExportSignal }

        let probe = Task { try await ledger.appVersion() }
        // Waits for the probe to have actually queued behind the pairing on this device, so
        // releasing the export next provably races a caller that is really waiting, not one that
        // simply has not been scheduled yet.
        await expectEventually { await ledger.queuedCount == 1 }

        await fresh.releaseExport()

        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)
        let probeVersion = try await probe.value
        XCTAssertEqual(probeVersion.description, "3.9.3")

        let instructions = await fresh.instructions
        XCTAssertEqual(
            instructions,
            pairingThenProbeInstructions(ufvk: ufvk.stringEncoded),
            "the export's chunks stay contiguous on the reconnected transport, and the probe comes after every one of them"
        )
        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1, "the stalled transport is closed once the read retries on a fresh connection")
        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "the caller closes the reconnected transport")
    }

    /// The same setup, but the queued probe is cancelled instead of completing: the pairing still
    /// finishes, and the reconnected transport is never closed over a call that never reached it.
    func testACallCancelledWhileQueuedBehindAReconnectedExportClosesNothing() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        await expectEventually { await fresh.isWaitingForExportSignal }

        let probe = Task { try await ledger.appVersion() }
        // Waits for the probe to have actually queued before cancelling it: cancelling any earlier
        // would exercise the already-cancelled-on-entry path instead of the queued one this test
        // means to cover.
        await expectEventually { await ledger.queuedCount == 1 }
        probe.cancel()

        do {
            _ = try await probe.value
            XCTFail("a call cancelled while queued must fail")
        } catch is CancellationError {
            // Expected.
        }

        await fresh.releaseExport()
        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)

        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "a call cancelled while only queued for its turn closes nothing")
    }

    // MARK: - A reconnect that hands back the same transport

    /// A transport that reconnects internally hands itself back from `reconnect`. The pairing already
    /// holds that transport's ceremony, so it must not take it a second time -- that would wait on
    /// itself forever -- and the retried reads and the export run on it as on any replacement.
    func testAReconnectThatReturnsTheSameTransportDoesNotWaitOnItself() async throws {
        let ufvk = try testnetUFVK()
        let chunks = LedgerReplies.viewingKeyChunks(ufvk.stringEncoded)
        // The first read fails on the link; everything after answers.
        let transport = ScriptedLedgerTransport { apdu, history in
            if history.isEmpty { throw ZcashError.ledgerTimeout }
            switch apdu[1] {
            case LedgerReplies.getFirmwareVersion:
                return LedgerReplies.firmwareVersion(3, 9, 3)
            case LedgerReplies.getWalletPublicKey:
                return LedgerReplies.walletPublicKey(LedgerReplies.seedIdentityPoint)
            case LedgerReplies.getVK:
                return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
            default:
                return LedgerReplies.status(0x6D00)
            }
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { transport })
        }
        // A pairing that waits on itself never returns: cancel it after a while, so the regression
        // fails this test with `CancellationError` instead of hanging it.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            pairing.cancel()
        }
        let result = try await pairing.value
        watchdog.cancel()

        XCTAssertEqual(result.ufvk, ufvk)
        let instructions = await transport.instructions
        XCTAssertEqual(
            instructions,
            [LedgerReplies.getFirmwareVersion] + Array(pairingThenProbeInstructions(ufvk: ufvk.stringEncoded).dropLast()),
            "the failed read, then the retried reads and the export, all on the one transport"
        )
        let current = await ledger.transport
        XCTAssertEqual(ObjectIdentifier(current), ObjectIdentifier(transport))
    }

    // MARK: - A replacement another ceremony holds

    /// The transport a `reconnect` returns can already be in use: here another device's pairing holds
    /// it, waiting on the user for its export. The reconnecting pairing queues for it, and when it is
    /// cancelled while queued it closes nothing -- not the replacement, which it never came to hold
    /// and must not adopt -- and the pairing holding the replacement finishes undisturbed.
    func testAPairingCancelledWhileQueuedForAReplacementAnotherCeremonyHoldsClosesNothing() async throws {
        let ufvk = try testnetUFVK()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let holder = LedgerDevice(transport: fresh, networkType: .testnet)
        let holderPairing = Task {
            try await holder.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))
        }
        await expectEventually { await fresh.isWaitingForExportSignal }

        let stalled = stalledTransport()
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)
        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        // Waits for the reconnecting pairing to have actually queued on the replacement's ceremony
        // gate, behind the holder, before cancelling it.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: fresh) == 1 }
        pairing.cancel()

        do {
            _ = try await pairing.value
            XCTFail("a pairing cancelled while queued must fail")
        } catch is CancellationError {
            // Expected.
        }

        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "a replacement the cancelled pairing never came to hold is not closed")
        let current = await ledger.transport
        XCTAssertEqual(ObjectIdentifier(current), ObjectIdentifier(stalled), "a replacement the pairing never came to hold is not adopted")

        await fresh.releaseExport()
        let holderResult = try await holderPairing.value
        XCTAssertEqual(holderResult.ufvk, ufvk)

        let instructions = await fresh.instructions
        XCTAssertEqual(
            instructions,
            Array(pairingThenProbeInstructions(ufvk: ufvk.stringEncoded).dropLast()),
            "only the holder's pairing ever sent anything on the replacement"
        )
    }

    // MARK: - A second device over the reconnected transport waits too

    /// A second `LedgerDevice` built directly over the reconnected transport waits for the pairing the
    /// same way a second call on the same device does. The per-device gate cannot be what stops it,
    /// since this is a different instance with its own, uncontended one; only the reconnected
    /// transport's own ceremony does.
    func testASecondDeviceOverTheReconnectedTransportWaitsForThePairingToFinish() async throws {
        let ufvk = try testnetUFVK()
        let stalled = stalledTransport()
        let fresh = SignaledExportTransport(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })
        }
        await expectEventually { await fresh.isWaitingForExportSignal }

        let second = LedgerDevice(transport: fresh, networkType: .testnet)
        let probe = Task { try await second.appVersion() }
        // Waits for the second device's call to have actually queued on the reconnected transport's
        // own ceremony gate before releasing the export.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: fresh) == 1 }

        await fresh.releaseExport()

        let pairingResult = try await pairing.value
        XCTAssertEqual(pairingResult.ufvk, ufvk)
        let probeVersion = try await probe.value
        XCTAssertEqual(probeVersion.description, "3.9.3")

        let instructions = await fresh.instructions
        XCTAssertEqual(
            instructions,
            pairingThenProbeInstructions(ufvk: ufvk.stringEncoded),
            "the second device's probe comes after every command of the pairing on the reconnected transport"
        )
    }

    // MARK: - A replacement closed by a cancelled pairing

    /// Device 1 reconnects onto a replacement and is cancelled while exporting, between two of its
    /// chunks. Closing the replacement is this call's own to do, and it must finish before device 2,
    /// queued on the same replacement, is handed its turn: device 2 must not be admitted while that
    /// close is still in flight, only once it is done, and then finds the replacement already closed.
    func testAPairingCancelledOnAReplacementClosesItBeforeASecondDeviceIsAdmitted() async throws {
        let ufvk = try testnetUFVK()
        XCTAssertGreaterThan(
            LedgerReplies.viewingKeyChunks(ufvk.stringEncoded).count,
            1,
            "the export must take more than one chunk for a cancellation between two of them to be possible"
        )
        let stalled = stalledTransport()
        let replacement = SignaledExportAndCloseTransport(ufvk: ufvk.stringEncoded)
        let device1 = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = Task {
            try await device1.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { replacement })
        }
        await expectEventually { await replacement.isWaitingForExportSignal }

        let device2 = LedgerDevice(transport: replacement, networkType: .testnet)
        let probe = Task { try await device2.appVersion() }
        // Waits for the second device to have actually queued on the replacement's own ceremony
        // gate, behind device 1's hold, before device 1 is cancelled.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: replacement) == 1 }

        // Cancelling here is inert: device 1 is parked in `replacement.exchange(_:timeout:)`, on a
        // continuation that does not observe cancellation. It takes effect only at the next chunk's
        // `LedgerCommands.exchange`, whose cancellation check runs before it ever touches the
        // replacement -- so the chunk below is never sent, and the close that follows is this call's
        // own, not one forced by a failed exchange.
        pairing.cancel()
        await replacement.releaseExport()

        // The replacement's own close has started -- device 1's cancellation reached it -- but has
        // not finished: it is parked here for `releaseClose()`. Device 2 must still be queued behind
        // device 1's hold at this point, never handed the gate while this close was still in flight.
        await expectEventually { await replacement.isClosing }
        let queuedWhileClosing = await LedgerCeremonyGates.shared.queuedCeremonies(on: replacement)
        XCTAssertEqual(queuedWhileClosing, 1, "device 2 is still queued while the replacement's close is in flight")

        await replacement.releaseClose()

        do {
            _ = try await pairing.value
            XCTFail("a pairing cancelled while exporting must fail")
        } catch is CancellationError {
            // Expected.
        }

        do {
            _ = try await probe.value
            XCTFail("a call admitted to an already-closed replacement must fail")
        } catch let error as ZcashError {
            guard case .ledgerTransportClosed = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let instructions = await replacement.instructions
        XCTAssertEqual(
            instructions,
            [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey, LedgerReplies.getVK],
            "only device 1's retried reads and its first export chunk reached the replacement; nothing from device 2"
        )
    }
}
