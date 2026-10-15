//
//  LedgerTests.swift
//  OfflineTests
//
//  The Ledger pairing commands and the signing runner, over a scripted transport. The pairing tests
//  drive the real Rust parsers and viewing key export; the runner tests replace the signing session,
//  which needs a funded wallet, with a scripted one.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

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

// MARK: - Scripted device

/// A transport that answers every command from a script and records what it was asked.
actor ScriptedLedgerTransport: LedgerAPDUTransport {
    typealias Script = @Sendable (_ apdu: Data, _ history: [Data]) throws -> Data

    private(set) var received: [Data] = []
    private(set) var timeouts: [TimeInterval?] = []
    private(set) var closeCount = 0
    private let delayNanoseconds: UInt64
    private let stallBeforeFailing: (@Sendable (TimeInterval?) async throws -> Void)?
    private let script: Script

    init(
        delayNanoseconds: UInt64 = 0,
        stallBeforeFailing: (@Sendable (TimeInterval?) async throws -> Void)? = nil,
        script: @escaping Script
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.stallBeforeFailing = stallBeforeFailing
        self.script = script
    }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        let history = received
        received.append(apdu)
        timeouts.append(timeout)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        do {
            return try script(apdu, history)
        } catch {
            if let stallBeforeFailing {
                // Waits out the timeout a stalled link would have spent before failing, on whatever
                // clock the test wires up, instead of failing at once and letting no time pass. A
                // test that does not pass this hook sees today's instant failure, unchanged.
                try await stallBeforeFailing(timeout)
            }
            throw error
        }
    }

    func close() async {
        closeCount += 1
    }

    var instructions: [UInt8] {
        received.map { $0[1] }
    }
}

/// `ScriptedLedgerTransport`'s own stall hook: proves the suite can script an exchange that waits
/// out its timeout before failing, which `LedgerZcashAppTests` needs to see what a stalled poll does
/// to the app switch's own time budget.
final class ScriptedLedgerTransportTests: XCTestCase {
    func testAStalledExchangeRunsTheStallHookWithItsTimeoutBeforeThrowing() async throws {
        actor Recorder {
            private(set) var calls: [TimeInterval?] = []
            func record(_ timeout: TimeInterval?) {
                calls.append(timeout)
            }
        }
        struct Boom: Error {}
        let recorder = Recorder()
        let transport = ScriptedLedgerTransport(
            stallBeforeFailing: { timeout in await recorder.record(timeout) },
            script: { _, _ in throw Boom() }
        )

        do {
            _ = try await transport.exchange(Data([0x00]), timeout: 5)
            XCTFail("the scripted failure must still be thrown")
        } catch is Boom {
            // Expected.
        }

        let calls = await recorder.calls
        XCTAssertEqual(calls, [5], "the stall hook runs with the exchange's own timeout before the scripted error is thrown")
    }

    func testAnExchangeWithNoStallHookFailsAtOnce() async throws {
        struct Boom: Error {}
        let transport = ScriptedLedgerTransport { _, _ in throw Boom() }

        do {
            _ = try await transport.exchange(Data([0x00]), timeout: 5)
            XCTFail("the scripted failure must still be thrown")
        } catch is Boom {
            // Expected: no stall hook was given, so nothing waits.
        }
    }
}

enum LedgerReplies {
    static let getFirmwareVersion: UInt8 = 0xC4
    static let getWalletPublicKey: UInt8 = 0x40
    static let getVK: UInt8 = 0x50
    static let getShieldAddress: UInt8 = 0x51

    static func status(_ statusWord: UInt16) -> Data {
        Data([UInt8(statusWord >> 8), UInt8(statusWord & 0xFF)])
    }

    static func ok(_ data: Data) -> Data {
        data + status(0x9000)
    }

    static func firmwareVersion(_ major: UInt8, _ minor: UInt8, _ patch: UInt8) -> Data {
        ok(Data([0x38, 0x30, major, minor, patch, 2, 3, 22]))
    }

    /// The secp256k1 generator, uncompressed.
    static let generatorPoint = Data(
        hex: [
            "04",
            "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"
        ].joined()
    )

    /// Twice the secp256k1 generator, uncompressed.
    static let doubledGeneratorPoint = Data(
        hex: [
            "04",
            "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
            "1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a"
        ].joined()
    )

    /// The testnet key at `m/44'/1'/0'/0/0` of `Environment.seedBytes`, uncompressed: what a device
    /// holding that seed answers the identity probe with.
    static let seedIdentityPoint = Data(
        hex: [
            "04",
            "feaa290589a20f795f302ba03847b0a6c9c2b571d75d80bc4ebb02382d0549da",
            "739e9df5fc227480857ddf7a91181ef7321cc325efd6e148c6784551fb9c5935"
        ].joined()
    )

    /// A `GET_WALLET_PUBLIC_KEY` reply: `pk_len ‖ pk ‖ addr_len ‖ addr ‖ chain_code`.
    static func walletPublicKey(_ publicKey: Data) -> Data {
        let address = Data("tmFakeLedgerFirstAddress".utf8)
        var reply = Data([UInt8(publicKey.count)])
        reply.append(publicKey)
        reply.append(UInt8(address.count))
        reply.append(address)
        reply.append(Data(repeating: 0x11, count: 32))
        return ok(reply)
    }

    /// A `GET_SHIELD_ADDR` unified-address reply: a two-byte length, then the address.
    static func unifiedAddress(_ address: String) -> Data {
        let bytes = Data(address.utf8)
        var reply = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        reply.append(bytes)
        return ok(reply)
    }

    /// The `GET_VK` reply chunks for a unified full viewing key: a two-byte length, then the key, 255
    /// bytes at a time.
    static func viewingKeyChunks(_ ufvk: String) -> [Data] {
        let key = Data(ufvk.utf8)
        var transfer = Data([UInt8(key.count >> 8), UInt8(key.count & 0xFF)])
        transfer.append(key)
        return stride(from: 0, to: transfer.count, by: 255).map { start in
            ok(transfer.subdata(in: start..<min(start + 255, transfer.count)))
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

private struct UnexpectedReconnect: Error {}

/// A `reconnect` that fails the test if it is ever called.
private func noReconnect() -> @Sendable () async throws -> any LedgerAPDUTransport {
    { throw UnexpectedReconnect() }
}

// MARK: - Pairing

final class LedgerDeviceTests: XCTestCase {
    private func testnetUFVK(accountIndex: UInt32 = 0) throws -> UnifiedFullViewingKey {
        let tool = DerivationTool(networkType: .testnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(accountIndex))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    /// A testnet unified full viewing key with a transparent and a Sapling item but no Orchard item,
    /// derived once, offline, from the all-`0x01` 32-byte seed -- nothing here ties it to a real
    /// wallet or device.
    private let testnetUFVKWithNoOrchardItem = """
    uviewtest1pfe0uls0td9a3zvqchscp9yvv2wumu6873hg8pqfe86tqlhsq60xdspfedc90j8y4fwfshtss3xahmhcwwxr8cugndfh9hsr4\
    sq3a8pvdezz48d57s7y87uv46dyvllsfaj4n24u9mejfpelsrvfuthp6j7lnf54qw0yq57ramzqrd0rt6s9sksseqqxrjf0d3vuj7nwnqkc\
    tsrw3xs2vgc5lrtr358hxhwg9ec5jr9hvatt95mech7p249znhjk5vgytkhvllakczp5v29fvmx8jnj4hee3sj0t5ytdk30ns5r5s2kcth2\
    e30h7gpany3nhxd9ycus6rarwy634zejy0ht
    """

    func testTheNoOrchardFixtureParsesAsAUnifiedFullViewingKey() throws {
        _ = try UnifiedFullViewingKey(encoding: testnetUFVKWithNoOrchardItem, network: .testnet)
    }

    /// The key of a nonzero account never derives the identity, so this exercises only the Orchard
    /// check, the same one account 0 would reach right after its own identity check.
    func testPairAccountRefusesAnAccountOneKeyWithNoOrchardItem() async throws {
        let transport = device(ufvk: testnetUFVKWithNoOrchardItem) { _ in LedgerReplies.generatorPoint }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(1))
            XCTFail("A key with no Orchard item must be refused")
        } catch let error as ZcashError {
            guard case let .ledgerMalformedReply(reason) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(reason, "the exported viewing key has no Orchard item")
        }
    }

    /// The same, for a second nonzero account: the Orchard check does not depend on which one.
    func testPairAccountRefusesAnAccountTwoKeyWithNoOrchardItem() async throws {
        let transport = device(ufvk: testnetUFVKWithNoOrchardItem) { _ in LedgerReplies.generatorPoint }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(2))
            XCTFail("A key with no Orchard item must be refused")
        } catch let error as ZcashError {
            guard case let .ledgerMalformedReply(reason) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(reason, "the exported viewing key has no Orchard item")
        }
    }

    /// A device on app 3.9.3 that exports `ufvk` and answers the identity probe with `identityKey(n)`
    /// for its n-th probe. By default it answers with the identity of `Environment.seedBytes`, the seed
    /// of `testnetUFVK()`.
    private func device(
        ufvk: String,
        version: Data = LedgerReplies.firmwareVersion(3, 9, 3),
        vkReply: Data? = nil,
        identityKey: @escaping @Sendable (Int) -> Data = { _ in LedgerReplies.seedIdentityPoint }
    ) -> ScriptedLedgerTransport {
        let chunks = LedgerReplies.viewingKeyChunks(ufvk)
        return ScriptedLedgerTransport { apdu, history in
            switch apdu[1] {
            case LedgerReplies.getFirmwareVersion:
                return version
            case LedgerReplies.getWalletPublicKey:
                let probes = history.filter { $0[1] == LedgerReplies.getWalletPublicKey }.count
                return LedgerReplies.walletPublicKey(identityKey(probes))
            case LedgerReplies.getVK:
                if let vkReply {
                    return vkReply
                }
                return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
            default:
                return LedgerReplies.status(0x6D00)
            }
        }
    }

    func testPairAccountReturnsTheExportedKeyAndTheDeviceBinding() async throws {
        let ufvk = try testnetUFVK()
        let transport = device(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))

        XCTAssertEqual(pairing.ufvk, ufvk)
        XCTAssertEqual(pairing.binding.zip32AccountIndex, Zip32AccountIndex(0))
        XCTAssertTrue(pairing.binding.deviceIdentity.stringEncoded.hasPrefix("tpk0-"))
        XCTAssertEqual(pairing.appVersion.description, "3.9.3")
        XCTAssertTrue(pairing.appVersion.supportsPczt)

        let identity = try await ledger.deviceIdentity()
        XCTAssertEqual(identity, pairing.binding.deviceIdentity)

        let instructions = await transport.instructions
        let chunkCount = LedgerReplies.viewingKeyChunks(ufvk.stringEncoded).count
        XCTAssertGreaterThan(chunkCount, 1)
        XCTAssertEqual(
            instructions,
            [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey]
                + Array(repeating: LedgerReplies.getVK, count: chunkCount)
                // The trailing probe is this test's own `deviceIdentity()` call: pairing itself
                // reads the identity once, before the export.
                + [LedgerReplies.getWalletPublicKey]
        )

        // Only the request that shows the approval screen waits on the user.
        let timeouts = await transport.timeouts
        XCTAssertNil(timeouts[2])
        XCTAssertNotNil(timeouts[3])
        XCTAssertEqual(timeouts[0], ZcashLedgerBackend.defaultTimeout, "readTimeout defaults to the engine's normal timeout")
    }

    func testPairAccountProbesTheIdentityOnceBeforeTheExport() async throws {
        let ufvk = try testnetUFVK()
        // A second probe would answer a different key; the pairing must never issue one — the Zcash
        // app leaves a status screen up after the export and drops the next command — so the binding
        // must carry the identity the first probe answered.
        let transport = device(ufvk: ufvk.stringEncoded) { probe in
            probe == 0 ? LedgerReplies.seedIdentityPoint : LedgerReplies.doubledGeneratorPoint
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))

        let reference = LedgerDevice(transport: device(ufvk: ufvk.stringEncoded), networkType: .testnet)
        let referencePairing = try await reference.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))
        XCTAssertEqual(pairing.binding.deviceIdentity, referencePairing.binding.deviceIdentity)
        XCTAssertEqual(pairing.ufvk, referencePairing.ufvk)
    }

    func testPairAccountRefusesAnAccountZeroKeyThatDoesNotDeriveTheDeviceIdentity() async throws {
        let ufvk = try testnetUFVK()
        // The identity of another seed: the exported key does not belong to the identified device.
        let transport = device(ufvk: ufvk.stringEncoded) { _ in LedgerReplies.generatorPoint }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))
            XCTFail("A key that does not derive the device identity must be refused")
        } catch let error as ZcashError {
            XCTAssertEqual(error, .ledgerDeviceMismatch)
            XCTAssertEqual(error.ledgerIsRestartable, false)
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "every exchange succeeded, so the caller closes the connection")
    }

    func testPairAccountDoesNotCheckTheIdentityOfAnotherAccount() async throws {
        // The key of account 1 never derives the identity, so pairing it cannot check the identity.
        let ufvk = try testnetUFVK(accountIndex: 1)
        let transport = device(ufvk: ufvk.stringEncoded) { _ in LedgerReplies.generatorPoint }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let pairing = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(1))

        XCTAssertEqual(pairing.ufvk, ufvk)
        XCTAssertEqual(pairing.binding.zip32AccountIndex, Zip32AccountIndex(1))
    }

    func testAPairingCancelledBetweenExportChunksClosesTheTransportAndSendsNothingMore() async throws {
        let ufvk = try testnetUFVK()
        let chunks = LedgerReplies.viewingKeyChunks(ufvk.stringEncoded)
        XCTAssertGreaterThan(chunks.count, 1)
        // The device answers the first export chunk, and the task is cancelled before the next chunk
        // is requested: no exchange is in progress, but the device is in the middle of the export.
        let transport = ScriptedLedgerTransport { apdu, history in
            switch apdu[1] {
            case LedgerReplies.getFirmwareVersion:
                return LedgerReplies.firmwareVersion(3, 9, 3)
            case LedgerReplies.getWalletPublicKey:
                return LedgerReplies.walletPublicKey(LedgerReplies.seedIdentityPoint)
            case LedgerReplies.getVK:
                withUnsafeCurrentTask { task in task?.cancel() }
                return chunks[history.filter { $0[1] == LedgerReplies.getVK }.count]
            default:
                return LedgerReplies.status(0x6D00)
            }
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let task = Task { try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0)) }

        do {
            _ = try await task.value
            XCTFail("A cancelled pairing must fail")
        } catch is CancellationError {
            // Expected: the cancellation reaches the caller unchanged.
        }

        let instructions = await transport.instructions
        XCTAssertEqual(
            instructions,
            [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey, LedgerReplies.getVK],
            "no export chunk is sent after the cancellation"
        )
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1, "the device is in the middle of the export, so the transport is closed")
    }

    func testALedgerDeviceCallCancelledWhileItWaitsForAnotherCallClosesNothing() async throws {
        let transport = ScriptedLedgerTransport(delayNanoseconds: 500_000_000) { _, _ in
            LedgerReplies.firmwareVersion(3, 9, 3)
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let first = Task { try await ledger.appVersion() }
        // Waits for `first` to reach its (slow) exchange, so it provably holds the device when
        // `second` starts.
        await expectEventually { await transport.received.count == 1 }
        let second = Task { try await ledger.appVersion() }
        // Waits for `second` to have actually queued behind `first` on the device before cancelling
        // it: cancelling any earlier would exercise the already-cancelled-on-entry path instead of
        // the queued one this test means to cover.
        await expectEventually { await ledger.queuedCount == 1 }
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("A cancelled call must fail")
        } catch is CancellationError {
            // Expected.
        }

        let version = try await first.value
        XCTAssertEqual(version.description, "3.9.3", "the call that holds the device completes normally")
        let received = await transport.received
        XCTAssertEqual(received.count, 1, "the cancelled call never reached the device")
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a call cancelled while it waits for its turn closes nothing")
    }

    func testPairAccountRefusesAnAppThatCannotSign() async throws {
        let ufvk = try testnetUFVK()
        let transport = device(ufvk: ufvk.stringEncoded, version: LedgerReplies.firmwareVersion(3, 5, 0))
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))
            XCTFail("An app without PCZT support must be refused")
        } catch let error as ZcashError {
            XCTAssertEqual(error, .ledgerAppTooOld(""))
        }

        let instructions = await transport.instructions
        XCTAssertEqual(instructions, [LedgerReplies.getFirmwareVersion])
    }

    func testADeclinedExportIsReportedAsAUserRejectionAndNotReissued() async throws {
        let ufvk = try testnetUFVK()
        let transport = device(ufvk: ufvk.stringEncoded, vkReply: LedgerReplies.status(0x6985))
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0))
            XCTFail("A declined export must fail")
        } catch let error as ZcashError {
            XCTAssertEqual(error, .ledgerUserRejected)
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }

        let instructions = await transport.instructions
        XCTAssertEqual(instructions.filter { $0 == LedgerReplies.getVK }.count, 1)
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a device refusal leaves the connection usable")
    }

    func testACommandTheDeviceSDKRefusesIsResentUnchanged() async throws {
        let transport = ScriptedLedgerTransport { _, history in
            history.count < 2 ? LedgerReplies.status(0x6901) : LedgerReplies.firmwareVersion(3, 9, 3)
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let version = try await ledger.appVersion()

        XCTAssertEqual(version.description, "3.9.3")
        let received = await transport.received
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(Set(received).count, 1, "every resend is the identical command")
    }

    func testAnotherAppIsReportedWithItsStatusWord() async throws {
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.status(0x6E00) }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.appVersion()
            XCTFail("A device running another app must fail")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x6E00)
        }
    }

    func testATransportFailureClosesTheTransport() async throws {
        let transport = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerBluetoothDisconnected }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.deviceIdentity()
            XCTFail("A failed exchange must fail the command")
        } catch let error as ZcashError {
            XCTAssertEqual(error, .ledgerBluetoothDisconnected)
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    // MARK: Verifying the address on the device

    func testTheExpectedAddressIsTheOrchardReceiverAtIndexZeroAlone() throws {
        let ufvk = try testnetUFVK()

        let expected = try LedgerDevice.expectedUnifiedAddress(ufvk: ufvk, networkType: .testnet)

        // The vector the Rust layer pins for `Environment.seedBytes`: a revision 0 address holding only
        // the external Orchard receiver at diversifier index 0.
        XCTAssertEqual(
            expected.stringEncoded,
            "utest14hlatm89d0lufqkqnyp8v52gwsy2420nyc54zgm4w4zjnufvlfcz92a3j66sse425nwpusqvjvguq7rrh28v8vq45n5l4sdhju6qqx4x"
        )
    }

    func testDisplayUnifiedAddressReturnsTheDerivedAddressWhenTheDeviceShowsIt() async throws {
        let ufvk = try testnetUFVK()
        let expected = try LedgerDevice.expectedUnifiedAddress(ufvk: ufvk, networkType: .testnet)
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.unifiedAddress(expected.stringEncoded) }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        let confirmed = try await ledger.displayUnifiedAddress(
            ufvk: ufvk,
            zip32AccountIndex: Zip32AccountIndex(0),
            transparentAddressIndex: 7
        )

        XCTAssertEqual(confirmed, expected)
        let instructions = await transport.instructions
        XCTAssertEqual(instructions, [LedgerReplies.getShieldAddress])
        let timeouts = await transport.timeouts
        XCTAssertEqual(timeouts, [nil], "the display waits on the user")
    }

    func testDisplayUnifiedAddressRefusesAnAddressTheKeyDoesNotDerive() async throws {
        let ufvk = try testnetUFVK()
        // The device shows the address of another account: it does not hold the keys of `ufvk`.
        let other = try LedgerDevice.expectedUnifiedAddress(ufvk: try testnetUFVK(accountIndex: 1), networkType: .testnet)
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.unifiedAddress(other.stringEncoded) }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.displayUnifiedAddress(
                ufvk: ufvk,
                zip32AccountIndex: Zip32AccountIndex(0),
                transparentAddressIndex: 0
            )
            XCTFail("An address the key does not derive must be refused")
        } catch let error as ZcashError {
            XCTAssertEqual(error, .ledgerDeviceMismatch)
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "the exchange succeeded, so the connection stays open")
    }

    // MARK: Reconnecting before the export

    func testAStalledReadBeforeTheExportIsRetriedOnceOnAFreshConnection() async throws {
        let ufvk = try testnetUFVK()
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let fresh = device(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })

        XCTAssertEqual(pairing.ufvk, ufvk)
        let stalledInstructions = await stalled.instructions
        XCTAssertEqual(stalledInstructions, [LedgerReplies.getFirmwareVersion], "nothing else is sent on the stalled transport")
        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1)
        let freshInstructions = await fresh.instructions
        let chunkCount = LedgerReplies.viewingKeyChunks(ufvk.stringEncoded).count
        XCTAssertEqual(
            freshInstructions,
            [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey] + Array(repeating: LedgerReplies.getVK, count: chunkCount),
            "both reads, and the export, run from the start on the fresh transport"
        )
        let freshCloseCount = await fresh.closeCount
        XCTAssertEqual(freshCloseCount, 0, "the caller closes the reconnected transport")
        let liveTransport = await ledger.transport
        XCTAssertTrue((liveTransport as AnyObject) === (fresh as AnyObject))
    }

    func testADisconnectOnTheIdentityReadAsksBothReadsAgain() async throws {
        let ufvk = try testnetUFVK()
        let dropped = ScriptedLedgerTransport { apdu, _ in
            guard apdu[1] == LedgerReplies.getFirmwareVersion else {
                throw ZcashError.ledgerBluetoothDisconnected
            }
            return LedgerReplies.firmwareVersion(3, 9, 3)
        }
        let fresh = device(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: dropped, networkType: .testnet)

        let pairing = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { fresh })

        XCTAssertEqual(pairing.ufvk, ufvk)
        let droppedInstructions = await dropped.instructions
        XCTAssertEqual(droppedInstructions, [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey])
        let droppedCloseCount = await dropped.closeCount
        XCTAssertEqual(droppedCloseCount, 1)
        let freshInstructions = await fresh.instructions
        XCTAssertEqual(freshInstructions.first, LedgerReplies.getFirmwareVersion, "both reads are asked again from the start")
    }

    func testASecondStallBeforeTheExportFails() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let stalledAgain = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: { stalledAgain })
            XCTFail("A second stall before the export must fail")
        } catch let error as ZcashError {
            guard case .ledgerTimeout = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1)
        let stalledAgainCloseCount = await stalledAgain.closeCount
        XCTAssertEqual(stalledAgainCloseCount, 1)
        let stalledAgainReceived = await stalledAgain.received
        XCTAssertEqual(stalledAgainReceived.count, 1, "nothing is sent after the second failure")
    }

    func testAFailureAfterTheExportCommandIsNotRetried() async throws {
        let transport = ScriptedLedgerTransport { apdu, _ in
            switch apdu[1] {
            case LedgerReplies.getFirmwareVersion:
                return LedgerReplies.firmwareVersion(3, 9, 3)
            case LedgerReplies.getWalletPublicKey:
                return LedgerReplies.walletPublicKey(LedgerReplies.generatorPoint)
            default:
                throw ZcashError.ledgerTimeout
            }
        }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: noReconnect())
            XCTFail("A failure after the export command must fail")
        } catch let error as ZcashError {
            guard case .ledgerTimeout = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let instructions = await transport.instructions
        XCTAssertEqual(instructions, [LedgerReplies.getFirmwareVersion, LedgerReplies.getWalletPublicKey, LedgerReplies.getVK])
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testARefusalBeforeTheExportIsNotRetried() async throws {
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.status(0x6E00) }
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), reconnect: noReconnect())
            XCTFail("A refusal before the export must fail")
        } catch let error as ZcashError {
            guard case let .ledgerWrongApp(statusWord) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x6E00)
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a device refusal leaves the connection usable")
    }

    func testTheReadsBeforeTheExportTakeTheCallersDeadline() async throws {
        let ufvk = try testnetUFVK()
        let transport = device(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: transport, networkType: .testnet)

        _ = try await ledger.pairAccount(zip32AccountIndex: Zip32AccountIndex(0), readTimeout: 3)

        let timeouts = await transport.timeouts
        XCTAssertEqual(timeouts[0], 3)
        XCTAssertEqual(timeouts[1], 3)
        XCTAssertNil(timeouts[2], "the export request waits on the user")
        XCTAssertEqual(timeouts[3], ZcashLedgerBackend.defaultTimeout)
    }

    // MARK: Bounding the reconnect with the reconnect race

    /// The reviewer's scenario: a `reconnect` that never returns must not hang pairing.
    /// `readBeforeExport` now races its retry's `reconnect` against `readTimeout`, the same race
    /// `LedgerZcashApp` runs during the app switch, instead of awaiting it with no bound of its own.
    func testAReconnectThatNeverReturnsIsBoundedByTheReadTimeout() async throws {
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let task = Task {
            try await ledger.pairAccount(
                zip32AccountIndex: Zip32AccountIndex(0),
                readTimeout: 0.05,
                reconnect: {
                    // Cancellation-aware, like the live Bluetooth connect: a never-resumed continuation
                    // would also hang the task group's own implicit cleanup on the fixed code, not just
                    // the old code this red run is meant to exercise.
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    fatalError("unreachable: the reconnect race must cut this off well under 1 s")
                }
            )
        }
        // A test-side backstop: old code awaits `reconnect()` with no bound of its own, so without this
        // the red run would hang the whole suite instead of failing this one test.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            task.cancel()
        }
        let started = DispatchTime.now()

        do {
            _ = try await task.value
            XCTFail("A reconnect that never returns must not let pairing succeed")
        } catch let error as ZcashError {
            guard case .ledgerBluetoothConnectionFailed(nil) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        watchdog.cancel()

        let elapsedSeconds = TimeInterval(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        XCTAssertLessThan(elapsedSeconds, 1, "the reconnect race must cut this off in well under the 5 s the brief allows")
    }

    /// The reviewer's second-pass scenario: `.infinity` is a valid `readTimeout`, meaning no cap on
    /// the retry's own reconnect, and must not trap converting it to `UInt64` nanoseconds for the
    /// race's own `Task.sleep`. A reconnect that actually works still bounds nothing here, and pairing
    /// completes.
    func testAnInfiniteReadTimeoutDoesNotTrapAndStillPairs() async throws {
        let ufvk = try testnetUFVK()
        let stalled = ScriptedLedgerTransport { _, _ in throw ZcashError.ledgerTimeout }
        let fresh = device(ufvk: ufvk.stringEncoded)
        let ledger = LedgerDevice(transport: stalled, networkType: .testnet)

        let pairing = try await ledger.pairAccount(
            zip32AccountIndex: Zip32AccountIndex(0),
            readTimeout: .infinity,
            reconnect: { fresh }
        )

        XCTAssertEqual(pairing.ufvk, ufvk)
        let stalledCloseCount = await stalled.closeCount
        XCTAssertEqual(stalledCloseCount, 1, "the stalled transport is still closed before the reconnect")
    }
}

// MARK: - Error mapping

final class LedgerErrorMappingTests: XCTestCase {
    private func deviceRefusal(_ statusWord: UInt16) -> LedgerFFIError {
        LedgerFFIError(kind: .deviceRefused, statusWord: statusWord, isTransient: false, isRestartable: false, reason: "")
    }

    func testARefusalFromTheDeviceOSIsAWrongApp() {
        for statusWord: UInt16 in [0x6E01, 0x6511, 0x6D01] {
            let error = deviceRefusal(statusWord).zcashError
            guard case let .ledgerWrongApp(mappedStatusWord) = error else {
                return XCTFail("Unexpected error \(error.code) for status word \(statusWord)")
            }
            XCTAssertEqual(mappedStatusWord, statusWord)
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }
    }

    func testAnUnknownCommandOrClassKeepsTheEngineVerdict() {
        for statusWord: UInt16 in [0x6E00, 0x6D00] {
            let error = LedgerFFIError(kind: .wrongApp, statusWord: statusWord, isTransient: false, isRestartable: false, reason: "")
                .zcashError
            guard case let .ledgerWrongApp(mappedStatusWord) = error else {
                return XCTFail("Unexpected error \(error.code) for status word \(statusWord)")
            }
            XCTAssertEqual(mappedStatusWord, statusWord)
        }

        let refused = deviceRefusal(0x6985).zcashError
        guard case let .ledgerDeviceRefused(statusWord, _) = refused else {
            return XCTFail("Unexpected error \(refused.code)")
        }
        XCTAssertEqual(statusWord, 0x6985)
    }

    func testAWrongAppAndAnExhaustedDerivationBudgetAreRestartable() {
        let wrongApp = LedgerFFIError(kind: .wrongApp, statusWord: nil, isTransient: false, isRestartable: false, reason: "")
            .zcashError
        XCTAssertEqual(wrongApp.ledgerIsRestartable, true)

        let budgetExhausted = LedgerFFIError(kind: .derivationBudgetExhausted, statusWord: nil, isTransient: false, isRestartable: false, reason: "")
            .zcashError
        XCTAssertEqual(budgetExhausted.ledgerIsRestartable, true)
    }

    /// `connect(to:)` displacing a live connection with this error cannot be exercised here: it
    /// needs a real `CBPeripheral`, which only CoreBluetooth can hand out. This covers the error
    /// value itself instead.
    func testADisplacedConnectionsErrorIsNotRestartable() {
        let error = ZcashError.ledgerTransportReplaced
        XCTAssertEqual(error.ledgerIsRestartable, false)
        XCTAssertEqual(error.code, .ledgerTransportReplaced)
        XCTAssertEqual(
            error.message,
            "A later connection to the same Ledger device replaced this one before it was done being used."
        )
    }
}

// MARK: - Values

final class LedgerValueTests: XCTestCase {
    let identity = "tpk0-\(String(repeating: "ab", count: 32))"

    func testADeviceIdentityValidatesAndRoundTripsWithoutDescribingItself() throws {
        let deviceIdentity = try LedgerDeviceIdentity(encoding: identity)
        XCTAssertEqual(deviceIdentity.stringEncoded, identity)
        XCTAssertFalse(String(describing: deviceIdentity).contains("tpk0"))

        let binding = LedgerAccountBinding(deviceIdentity: deviceIdentity, zip32AccountIndex: Zip32AccountIndex(3))
        let decoded = try JSONDecoder().decode(LedgerAccountBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(decoded, binding)
    }

    func testAMalformedDeviceIdentityIsRefusedWithoutEchoingIt() {
        let malformed = "tpk0-\(String(repeating: "AB", count: 32))"
        XCTAssertThrowsError(try LedgerDeviceIdentity(encoding: malformed)) { error in
            guard case let .ledgerInvalidInput(reason) = error as? ZcashError else {
                return XCTFail("Unexpected error")
            }
            XCTAssertFalse(reason.contains("AB"))
        }

        XCTAssertThrowsError(try JSONDecoder().decode(LedgerDeviceIdentity.self, from: Data("\"tpk0-00\"".utf8)))
    }

    func testTheLedgerKeySourceIsAStableLiteral() {
        XCTAssertEqual(Account.ledgerKeySource, "ledger")
    }
}

// MARK: - Signing runner

/// A signing session that hands out a fixed list of commands and answers each reply from a script.
final class ScriptedSigningSession: LedgerSigningSession {
    private let commands: [LedgerSignCommand]
    private var statuses: [LedgerSignStatus]
    private var cursor = 0
    /// The command handed out again after a `0x6901`, which no longer announces the review.
    private var resending = false
    private(set) var replies: [Data] = []
    private(set) var finishCount = 0

    init(commands: [LedgerSignCommand], statuses: [LedgerSignStatus]) {
        self.commands = commands
        self.statuses = statuses
    }

    func nextStep() throws -> LedgerSignStep {
        guard cursor < commands.count else {
            return .done
        }

        let command = commands[cursor]
        guard resending else {
            return .send(command)
        }

        return .send(
            LedgerSignCommand(
                apdu: command.apdu,
                waitsForUser: command.waitsForUser,
                startsReview: false,
                stage: command.stage,
                streamAcknowledged: command.streamAcknowledged,
                streamTotal: command.streamTotal
            )
        )
    }

    func processResponse(_ reply: Data) throws -> LedgerSignStatus {
        replies.append(reply)
        let status = statuses.removeFirst()
        resending = status == .retrySameAPDU
        if !resending {
            cursor += 1
        }
        return status
    }

    func finish() throws -> Pczt {
        finishCount += 1
        return Data([0x5A])
    }
}

/// Collects progress reports from any thread.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LedgerSigningProgress] = []

    func record(_ event: LedgerSigningProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var recorded: [LedgerSigningProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class LedgerSignerTests: XCTestCase {
    private func command(
        _ byte: UInt8,
        stage: LedgerSignStage,
        waitsForUser: Bool = false,
        startsReview: Bool = false,
        acknowledged: Int = 0
    ) -> LedgerSignCommand {
        LedgerSignCommand(
            apdu: Data([0xE0, byte, 0, 0, 0]),
            waitsForUser: waitsForUser,
            startsReview: startsReview,
            stage: stage,
            streamAcknowledged: acknowledged,
            streamTotal: 2
        )
    }

    private func binding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-\(String(repeating: "cd", count: 32))"),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    private func signer(session: LedgerSigningSession) -> (LedgerSigner, ZcashRustBackendWeldingMock) {
        let backend = ZcashRustBackendWeldingMock()
        backend.createLedgerSignSessionAccountUUIDPcztBindingFirmwareReplyReturnValue = session
        return (LedgerSigner(rustBackend: backend, logger: OSLogger(logLevel: .debug)), backend)
    }

    private let accountUUID = AccountUUID(id: [UInt8](repeating: 1, count: 16))

    func testTheRunnerStreamsResendsAfterARefusalAndReportsProgress() async throws {
        let session = ScriptedSigningSession(
            commands: [
                command(0x40, stage: .identifyingDevice),
                command(0x52, stage: .streaming),
                command(0x56, stage: .streaming, waitsForUser: true, startsReview: true, acknowledged: 1),
                command(0x57, stage: .signingOrchard, waitsForUser: true, acknowledged: 2)
            ],
            statuses: [.moreAPDUs, .awaitingUser, .retrySameAPDU, .moreAPDUs, .complete]
        )
        let (signer, backend) = signer(session: session)
        let transport = ScriptedLedgerTransport { apdu, _ in
            apdu[1] == LedgerReplies.getFirmwareVersion ? LedgerReplies.firmwareVersion(3, 9, 3) : LedgerReplies.status(0x9000)
        }
        let recorder = ProgressRecorder()

        let signed = try await signer.sign(
            pczt: Data([1, 2, 3]),
            accountUUID: accountUUID,
            binding: try binding(),
            transport: transport,
            progress: { recorder.record($0) }
        )

        XCTAssertEqual(signed, Data([0x5A]))
        XCTAssertEqual(session.finishCount, 1)
        let sessionArguments = backend.createLedgerSignSessionAccountUUIDPcztBindingFirmwareReplyReceivedArguments
        XCTAssertEqual(sessionArguments?.firmwareReply, LedgerReplies.firmwareVersion(3, 9, 3))
        XCTAssertEqual(sessionArguments?.pczt, Data([1, 2, 3]))

        let instructions = await transport.instructions
        XCTAssertEqual(instructions, [LedgerReplies.getFirmwareVersion, 0x40, 0x52, 0x56, 0x56, 0x57], "the refused review packet is sent again")
        let timeouts = await transport.timeouts
        XCTAssertNotNil(timeouts[2])
        XCTAssertNil(timeouts[3], "the review waits on the user")
        XCTAssertNil(timeouts[5])

        XCTAssertEqual(
            recorder.recorded,
            [.identifyingDevice, .streaming(sent: 0, total: 2), .awaitingReviewOnDevice, .signing, .complete]
        )
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0)
    }

    func testTheRunnerClosesTheTransportWhenAnExchangeFails() async throws {
        let session = ScriptedSigningSession(
            commands: [command(0x40, stage: .identifyingDevice), command(0x52, stage: .streaming)],
            statuses: [.moreAPDUs, .complete]
        )
        let (signer, _) = signer(session: session)
        struct LinkLost: Error {}
        let transport = ScriptedLedgerTransport { apdu, history in
            if apdu[1] == LedgerReplies.getFirmwareVersion {
                return LedgerReplies.firmwareVersion(3, 9, 3)
            }
            if history.count == 2 {
                throw LinkLost()
            }
            return LedgerReplies.status(0x9000)
        }

        do {
            _ = try await signer.sign(pczt: Data([1]), accountUUID: accountUUID, binding: try binding(), transport: transport, progress: nil)
            XCTFail("A failed exchange must fail the ceremony")
        } catch let error as ZcashError {
            guard case .ledgerTransportFailed = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(session.finishCount, 0)
    }

    func testTheRunnerClosesTheTransportWhenCancelled() async throws {
        let session = ScriptedSigningSession(commands: [command(0x40, stage: .identifyingDevice)], statuses: [.complete])
        let (signer, _) = signer(session: session)
        let transport = ScriptedLedgerTransport(delayNanoseconds: 30_000_000_000) { _, _ in
            LedgerReplies.firmwareVersion(3, 9, 3)
        }
        let binding = try binding()
        let accountUUID = self.accountUUID

        let task = Task {
            try await signer.sign(pczt: Data([1]), accountUUID: accountUUID, binding: binding, transport: transport, progress: nil)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled ceremony must fail")
        } catch is CancellationError {
            // Expected: the cancellation reaches the caller unchanged.
        }

        // The failed exchange and the cancelled ceremony each close the transport; closing twice has
        // no effect.
        let closeCount = await transport.closeCount
        XCTAssertGreaterThanOrEqual(closeCount, 1)
    }

    func testTheRunnerClosesTheTransportWhenCancelledBetweenExchanges() async throws {
        let session = ScriptedSigningSession(
            commands: [
                command(0x40, stage: .identifyingDevice),
                command(0x52, stage: .streaming),
                command(0x53, stage: .streaming, acknowledged: 1)
            ],
            statuses: [.moreAPDUs, .moreAPDUs, .complete]
        )
        let (signer, _) = signer(session: session)
        // The device answers the first streaming command, and the task is cancelled before the runner
        // sends the next one: no exchange is in progress, but the device is in the middle of the
        // ceremony.
        let transport = ScriptedLedgerTransport { apdu, _ in
            if apdu[1] == LedgerReplies.getFirmwareVersion {
                return LedgerReplies.firmwareVersion(3, 9, 3)
            }
            if apdu[1] == 0x52 {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
            return LedgerReplies.status(0x9000)
        }
        let binding = try binding()
        let accountUUID = self.accountUUID

        let task = Task {
            try await signer.sign(pczt: Data([1]), accountUUID: accountUUID, binding: binding, transport: transport, progress: nil)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled ceremony must fail")
        } catch is CancellationError {
            // Expected: the cancellation reaches the caller unchanged.
        }

        let instructions = await transport.instructions
        XCTAssertEqual(instructions, [LedgerReplies.getFirmwareVersion, 0x40, 0x52], "nothing is sent after the cancellation")
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1, "the device is mid-ceremony, so the transport is closed")
        XCTAssertEqual(session.finishCount, 0)
    }

    func testTheRunnerClosesNothingWhenCancelledBeforeTheFirstExchange() async throws {
        let session = ScriptedSigningSession(commands: [command(0x40, stage: .identifyingDevice)], statuses: [.complete])
        let (signer, _) = signer(session: session)
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.firmwareVersion(3, 9, 3) }
        let binding = try binding()
        let accountUUID = self.accountUUID

        let task = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await signer.sign(pczt: Data([1]), accountUUID: accountUUID, binding: binding, transport: transport, progress: nil)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled ceremony must fail")
        } catch is CancellationError {
            // Expected.
        }

        let received = await transport.received
        XCTAssertTrue(received.isEmpty)
        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "a ceremony cancelled before its first command reached the device closes nothing")
    }

    func testASessionTheDeviceCannotBuildReportsTheStructuredError() async throws {
        let backend = ZcashRustBackendWeldingMock()
        backend.createLedgerSignSessionAccountUUIDPcztBindingFirmwareReplyThrowableError = LedgerFFIError(
            kind: .deviceRefused,
            statusWord: 0x5515,
            isTransient: true,
            isRestartable: true,
            reason: "the device is locked"
        )
        let signer = LedgerSigner(rustBackend: backend, logger: OSLogger(logLevel: .debug))
        let transport = ScriptedLedgerTransport { _, _ in LedgerReplies.firmwareVersion(3, 9, 3) }

        do {
            _ = try await signer.sign(pczt: Data([1]), accountUUID: accountUUID, binding: try binding(), transport: transport, progress: nil)
            XCTFail("A refused session must fail")
        } catch let error as ZcashError {
            guard case let .ledgerDeviceRefused(statusWord, isTransient) = error else {
                return XCTFail("Unexpected error \(error.code)")
            }
            XCTAssertEqual(statusWord, 0x5515)
            XCTAssertTrue(isTransient)
            XCTAssertEqual(error.ledgerIsRestartable, true)
        }

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 0, "nothing was outstanding, so the connection stays open")
    }
}

// MARK: - Session construction against a wallet database

final class LedgerSignSessionFFITests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    var account: AccountUUID!

    override func setUp() async throws {
        try await super.setUp()

        dbData = try __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )

        let dbInit = try await rustBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .testnet)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        _ = try await rustBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await rustBackend.listAccounts()
        account = try XCTUnwrap(accounts.first?.id)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
        account = nil
    }

    private func binding(accountIndex: UInt32 = 0) throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-\(String(repeating: "ef", count: 32))"),
            zip32AccountIndex: Zip32AccountIndex(accountIndex)
        )
    }

    private func assertRefused(
        _ expected: LedgerFFIError.Kind,
        accountUUID: AccountUUID? = nil,
        pczt: Pczt = Data([0x50, 0x43, 0x5A, 0x54]),
        accountIndex: UInt32 = 0,
        firmwareReply: Data = LedgerReplies.firmwareVersion(3, 9, 3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await rustBackend.createLedgerSignSession(
                accountUUID: accountUUID ?? account,
                pczt: pczt,
                binding: try binding(accountIndex: accountIndex),
                firmwareReply: firmwareReply
            )
            XCTFail("The session must be refused", file: file, line: line)
        } catch let error as LedgerFFIError {
            XCTAssertEqual(error.kind, expected, error.reason, file: file, line: line)
        }
    }

    func testAPCZTThatDoesNotParseIsRefused() async throws {
        try await assertRefused(.invalidInput)
    }

    func testAnAccountThatIsNotInTheWalletIsRefused() async throws {
        try await assertRefused(.invalidInput, accountUUID: AccountUUID(id: [UInt8](repeating: 9, count: 16)))
    }

    func testABindingForAnotherAccountIndexIsRefused() async throws {
        try await assertRefused(.invalidInput, accountIndex: 1)
    }

    func testAVersionReplyTheDeviceSDKRefusedIsNotASessionInput() async throws {
        try await assertRefused(.cmdNotAccepted, firmwareReply: LedgerReplies.status(0x6901))
    }
}
