//
//  LedgerCeremonyTests.swift
//  OfflineTests
//
//  Ceremony-wide ownership of a transport: a pairing, a signing ceremony or an app query holds the
//  transport for all of its commands, so another caller over the same transport -- a second
//  `LedgerDevice`, the signer, `LedgerZcashApp` -- cannot put a command between two of them, and a
//  caller cancelled while it waits for its turn never closes the connection the holder is using.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Polls `condition` with a short yield between checks, failing the test after `timeoutSeconds` if
/// it never becomes true. Not named `waitUntil`: `XCTestCase` has a member of that name (from
/// `TestUtils`) that returns the outcome instead of failing, and member lookup would win.
private func expectEventually(
    timeoutSeconds: TimeInterval = 5,
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

/// A transport whose exchanges throw ``LedgerExchangeNotStarted`` without sending anything, the way a
/// transport's own admission gate refuses a caller it cancels while queued.
private actor RefusingLedgerTransport: LedgerAPDUTransport {
    private(set) var closeCount = 0
    private(set) var attempts = 0

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        attempts += 1
        throw LedgerExchangeNotStarted()
    }

    func close() async {
        closeCount += 1
    }
}

/// A transport that answers its first exchange and then throws ``LedgerExchangeNotStarted`` without
/// sending anything for every exchange after it, the way a transport's own admission gate refuses a
/// caller it cancels while queued behind one already in flight.
private actor RefusingAfterFirstExchangeLedgerTransport: LedgerAPDUTransport {
    private(set) var closeCount = 0
    private(set) var attempts = 0

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        attempts += 1
        guard attempts == 1 else {
            throw LedgerExchangeNotStarted()
        }
        return LedgerReplies.firmwareVersion(3, 9, 3)
    }

    func close() async {
        closeCount += 1
    }
}

final class LedgerCeremonyTests: XCTestCase {
    private let dashboardQuery: UInt8 = 0x01

    private func testnetUFVK() throws -> UnifiedFullViewingKey {
        let tool = DerivationTool(networkType: .testnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    /// A slow device on app 3.9.3 that exports `ufvk`, answers the identity probe with the identity of
    /// `Environment.seedBytes`, and refuses everything else with `0x6D00`. Every exchange takes
    /// `delayNanoseconds`, so a ceremony of several commands is observably in progress while another
    /// caller tries to start.
    private func slowDevice(ufvk: String, delayNanoseconds: UInt64 = 50_000_000) -> ScriptedLedgerTransport {
        let chunks = LedgerReplies.viewingKeyChunks(ufvk)
        return ScriptedLedgerTransport(delayNanoseconds: delayNanoseconds) { apdu, history in
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
    }

    /// The commands one pairing of account 0 sends over `slowDevice`, in order.
    private func pairingInstructions(ufvk: String) -> [UInt8] {
        [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey]
            + Array(repeating: LedgerReplies.getVK, count: LedgerReplies.viewingKeyChunks(ufvk).count)
    }

    private func signer(session: LedgerSigningSession) -> LedgerSigner {
        let backend = ZcashRustBackendWeldingMock()
        backend.createLedgerSignSessionAccountUUIDPcztBindingFirmwareReplyReturnValue = session
        return LedgerSigner(rustBackend: backend, logger: OSLogger(logLevel: .debug))
    }

    private func binding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-\(String(repeating: "cd", count: 32))"),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    // MARK: - Ceremonies do not interleave

    /// A second `LedgerDevice` over the same transport starts its command only once the first device's
    /// pairing has sent its last one: the per-exchange gate alone would have let its query in between
    /// the pairing's version read and the identity probe.
    func testASecondDeviceOverTheSameTransportWaitsForThePairingToFinish() async throws {
        let ufvk = try testnetUFVK()
        let transport = slowDevice(ufvk: ufvk.stringEncoded)
        let first = LedgerDevice(transport: transport, networkType: .testnet)
        let second = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = Task { try await first.pairAccount(zip32AccountIndex: Zip32AccountIndex(0)) }
        // Waits for the pairing to have put its first command on the wire, so it provably holds the
        // transport when the second device starts.
        await expectEventually { await transport.received.count == 1 }
        let version = Task { try await second.appVersion() }

        _ = try await pairing.value
        let appVersion = try await version.value
        XCTAssertEqual(appVersion.description, "3.9.3")

        let instructions = await transport.instructions
        let expected = pairingInstructions(ufvk: ufvk.stringEncoded)
        XCTAssertEqual(
            instructions,
            expected + [LedgerReplies.getFirmwareVersion],
            "the second device's query must come after every command of the pairing, not between two of them"
        )
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    /// The signing ceremony waits for a pairing in progress on the same transport, and the pairing
    /// started while a signing ceremony runs waits for that: neither puts a command inside the other.
    func testASigningCeremonyAndAPairingOverTheSameTransportDoNotInterleave() async throws {
        let ufvk = try testnetUFVK()
        let transport = slowDevice(ufvk: ufvk.stringEncoded)
        let device = LedgerDevice(transport: transport, networkType: .testnet)
        let session = ScriptedSigningSession(
            commands: [
                LedgerSignCommand(apdu: Data([0xE0, 0x52, 0, 0, 0]), waitsForUser: false, startsReview: false, stage: .streaming, streamAcknowledged: 0, streamTotal: 1),
                LedgerSignCommand(apdu: Data([0xE0, 0x57, 0, 0, 0]), waitsForUser: true, startsReview: false, stage: .signingOrchard, streamAcknowledged: 1, streamTotal: 1)
            ],
            statuses: [.moreAPDUs, .complete]
        )
        let ledgerSigner = signer(session: session)
        let binding = try binding()
        let accountUUID = AccountUUID(id: [UInt8](repeating: 1, count: 16))

        let pairing = Task { try await device.pairAccount(zip32AccountIndex: Zip32AccountIndex(0)) }
        await expectEventually { await transport.received.count == 1 }
        let signing = Task {
            try await ledgerSigner.sign(pczt: Data([1]), accountUUID: accountUUID, binding: binding, transport: transport, progress: nil)
        }

        _ = try await pairing.value
        let signed = try await signing.value
        XCTAssertEqual(signed, Data([0x5A]))

        let instructions = await transport.instructions
        XCTAssertEqual(
            instructions,
            pairingInstructions(ufvk: ufvk.stringEncoded) + [LedgerReplies.getFirmwareVersion, 0x52, 0x57],
            "the signing ceremony's commands must all come after the pairing's"
        )
    }

    /// `LedgerZcashApp.currentApp` holds the transport too: its query lands after the pairing's last
    /// command, never between two of them.
    func testTheAppQueryWaitsForAPairingOverTheSameTransport() async throws {
        let ufvk = try testnetUFVK()
        let transport = slowDevice(ufvk: ufvk.stringEncoded)
        let device = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = Task { try await device.pairAccount(zip32AccountIndex: Zip32AccountIndex(0)) }
        await expectEventually { await transport.received.count == 1 }
        // The scripted device refuses the dashboard query; only its place in the order matters here.
        let query = Task { try? await LedgerZcashApp.currentApp(transport: transport) }

        _ = try await pairing.value
        _ = await query.value

        let instructions = await transport.instructions
        XCTAssertEqual(
            instructions,
            pairingInstructions(ufvk: ufvk.stringEncoded) + [dashboardQuery],
            "the app query must come after every command of the pairing"
        )
    }

    // MARK: - A waiter never closes the holder's connection

    /// Two `LedgerDevice`s over one transport: the second is cancelled while it waits for the first's
    /// call to finish. It throws `CancellationError`, sends nothing, and closes nothing, so the first
    /// device's call completes on an open transport.
    func testACallOnASecondDeviceCancelledWhileQueuedClosesNothing() async throws {
        let ufvk = try testnetUFVK()
        let transport = slowDevice(ufvk: ufvk.stringEncoded, delayNanoseconds: 300_000_000)
        let first = LedgerDevice(transport: transport, networkType: .testnet)
        let second = LedgerDevice(transport: transport, networkType: .testnet)

        let active = Task { try await first.appVersion() }
        await expectEventually { await transport.received.count == 1 }
        let queued = Task { try await second.appVersion() }
        // Waits for `queued` to actually be queued at the transport's ceremony gate behind `active`:
        // cancelling any earlier would exercise the already-cancelled-on-entry path instead.
        await expectEventually { await LedgerCeremonyGates.shared.queuedCeremonies(on: transport) == 1 }
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("a call cancelled while queued must fail")
        } catch is CancellationError {
            // Expected.
        }

        let version = try await active.value
        XCTAssertEqual(version.description, "3.9.3", "the call that holds the transport completes normally")
        let received = await transport.received
        XCTAssertEqual(received.count, 1, "the cancelled call never reached the device")
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a call cancelled while it waits for its turn closes nothing")
    }

    /// A transport that refuses an exchange before sending it, as a transport's own gate does for a
    /// caller it cancels while queued, leaves `LedgerDevice`'s call with a `CancellationError` and the
    /// transport open: the device never saw the command, so there is nothing to abandon.
    func testADeviceCallTheTransportRefusedBeforeSendingClosesNothing() async throws {
        let transport = RefusingLedgerTransport()
        let device = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await device.appVersion()
            XCTFail("a refused exchange must fail the call")
        } catch is CancellationError {
            // Expected.
        }

        let attempts = await transport.attempts
        XCTAssertEqual(attempts, 1)
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "an exchange the transport never sent must not close it")
    }

    /// The same for the signing ceremony: a refusal before anything was sent is a cancellation that
    /// closes nothing, unlike a cancellation once the ceremony's first command reached the device.
    /// The transport answers the version probe first, so the ceremony holds the device before its
    /// next exchange -- the first signing command -- is the one refused.
    func testASigningCeremonyTheTransportRefusedBeforeSendingClosesNothing() async throws {
        let transport = RefusingAfterFirstExchangeLedgerTransport()
        let session = ScriptedSigningSession(
            commands: [
                LedgerSignCommand(apdu: Data([0xE0, 0x52, 0, 0, 0]), waitsForUser: false, startsReview: false, stage: .streaming, streamAcknowledged: 0, streamTotal: 1)
            ],
            statuses: [.complete]
        )
        let ledgerSigner = signer(session: session)
        let binding = try binding()

        do {
            _ = try await ledgerSigner.sign(
                pczt: Data([1]),
                accountUUID: AccountUUID(id: [UInt8](repeating: 1, count: 16)),
                binding: binding,
                transport: transport,
                progress: nil
            )
            XCTFail("a refused exchange must fail the ceremony")
        } catch is CancellationError {
            // Expected.
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "an exchange the transport never sent must not close it, even once the ceremony holds the device")
    }

    // MARK: - The gate registry

    /// A transport's ceremony gate exists only while a ceremony runs or waits on it, so nothing is
    /// kept per transport once every caller is done.
    func testATransportsCeremonyGateGoesAwayWithItsLastUser() async throws {
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.firmwareVersion(3, 9, 3) }
        let device = LedgerDevice(transport: transport, networkType: .testnet)

        _ = try await device.appVersion()

        let inUse = await LedgerCeremonyGates.shared.transportsInUse
        XCTAssertEqual(inUse, 0)
    }
}
