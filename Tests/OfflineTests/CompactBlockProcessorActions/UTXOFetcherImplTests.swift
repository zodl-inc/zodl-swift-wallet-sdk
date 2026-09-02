//
//  UTXOFetcherImplTests.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)
//  Licensed under the GNU Affero General Public License, version 3 only (AGPL-3.0-only).
//  See LICENSE, LICENSE-EXCEPTIONS.md and COMMERCIAL-LICENSE.md in this repository.
//
//  Verifies the transport `UTXOFetcherImpl` picks for the sync-time UTXO discovery: with Tor
//  enabled every transparent receiver is looked up through the FFI's Tor path on a circuit of its
//  own, and the direct gRPC request that would hand the server all receivers at once is never
//  made; with Tor disabled the direct request is the path, exactly as before.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Collects values from the generated mock closures, which are not isolated, without a data race.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class UTXOFetcherImplTests: XCTestCase {
    private let firstAddress = TransparentAddress(validatedEncoding: "t1dRJRY7GmyeykJnMH38mdQoaZtFhn1QmGz")
    private let secondAddress = TransparentAddress(validatedEncoding: "t1Vr6e8S9QjQJ1d8ZhAUjNZzQ3CfX8z8Z9D")

    private func makeAccount() -> Account {
        Account(
            id: TestsData.mockedAccountUUID,
            name: "test",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
    }

    private func makeLogger() -> LoggerMock {
        let logger = LoggerMock()
        logger.debugFileFunctionLineClosure = { _, _, _, _ in }
        logger.infoFileFunctionLineClosure = { _, _, _, _ in }
        logger.warnFileFunctionLineClosure = { _, _, _, _ in }
        logger.errorFileFunctionLineClosure = { _, _, _, _ in }
        return logger
    }

    private func makeFetcher(
        downloader: BlockDownloaderServiceMock,
        service: LightWalletServiceMock,
        rustBackend: ZcashRustBackendWeldingMock,
        torEnabled: Bool,
        logger: Logger = OSLogger(logLevel: .debug)
    ) -> UTXOFetcherImpl {
        UTXOFetcherImpl(
            blockDownloaderService: downloader,
            service: service,
            config: UTXOFetcherConfig(
                walletBirthdayProvider: { 0 },
                dataDb: URL(fileURLWithPath: "/tmp/data.db"),
                networkType: .testnet
            ),
            rustBackend: rustBackend,
            metrics: SDKMetricsImpl(),
            logger: logger,
            sdkFlags: SDKFlags(torEnabled: torEnabled, exchangeRateEnabled: false)
        )
    }

    func testTorEnabledQueriesEachReceiverOnItsOwnCircuit() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()
        let calls = Recorder<(address: String, accountUUID: AccountUUID, mode: ServiceMode)>()

        rustBackend.listAccountsReturnValue = [makeAccount()]
        rustBackend.listTransparentReceiversAccountUUIDReturnValue = [firstAddress, secondAddress]
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { address, _, networkType, accountUUID, mode in
            XCTAssertEqual(networkType, .testnet)
            calls.record((address: address, accountUUID: accountUUID, mode: mode))
            return .notFound
        }

        var progress: [Float] = []
        let result = try await makeFetcher(downloader: downloader, service: service, rustBackend: rustBackend, torEnabled: true)
            .fetch { progress.append($0) }

        XCTAssertFalse(
            downloader.fetchUnspentTransactionOutputsTAddressesStartHeightModeCalled,
            "the direct request carrying every receiver must not be made with Tor enabled"
        )
        XCTAssertFalse(rustBackend.putUnspentTransparentOutputTxidIndexScriptValueHeightCalled, "the FFI stores the UTXOs itself on the Tor path")

        // The lookups run concurrently, so the calls are compared in address order.
        let recorded = calls.all.sorted { $0.address < $1.address }
        let expected = [firstAddress, secondAddress].sorted { $0.stringEncoded < $1.stringEncoded }
        XCTAssertEqual(recorded.map(\.address), expected.map(\.stringEncoded))
        XCTAssertEqual(recorded.map(\.accountUUID), [TestsData.mockedAccountUUID, TestsData.mockedAccountUUID])
        XCTAssertEqual(
            recorded.map(\.mode),
            expected.map { ServiceMode.torInGroup("utxo-\($0.stringEncoded)") },
            "each receiver gets a circuit of its own"
        )
        XCTAssertEqual(progress, [0.5, 1.0])
        XCTAssertTrue(result.inserted.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// One failing receiver must not stop the others from being queried, on this cycle or the next.
    func testTorEnabledContinuesPastAFailingReceiver() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()
        let logger = makeLogger()
        let queried = Recorder<String>()

        rustBackend.listAccountsReturnValue = [makeAccount()]
        rustBackend.listTransparentReceiversAccountUUIDReturnValue = [firstAddress, secondAddress]
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { [firstAddress] address, _, _, _, _ in
            queried.record(address)
            if address == firstAddress.stringEncoded {
                throw ZcashError.torServiceUnresolvedMode
            }
            return .notFound
        }

        var progress: [Float] = []
        let result = try await makeFetcher(downloader: downloader, service: service, rustBackend: rustBackend, torEnabled: true, logger: logger)
            .fetch { progress.append($0) }

        XCTAssertEqual(Set(queried.all), [firstAddress.stringEncoded, secondAddress.stringEncoded], "the receiver after the failing one is still queried")
        XCTAssertEqual(progress, [0.5, 1.0])
        XCTAssertTrue(result.inserted.isEmpty)
        XCTAssertTrue(logger.errorFileFunctionLineCalled, "the skipped receiver is logged")
        XCTAssertFalse(downloader.fetchUnspentTransactionOutputsTAddressesStartHeightModeCalled)
    }

    /// When every receiver fails there is nothing to continue with, and the failure surfaces so the
    /// processor retries the action instead of reporting a completed discovery.
    func testTorEnabledFailsClosedWhenEveryTorLookupFails() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()

        rustBackend.listAccountsReturnValue = [makeAccount()]
        rustBackend.listTransparentReceiversAccountUUIDReturnValue = [firstAddress]
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { _, _, _, _, _ in
            throw ZcashError.torServiceUnresolvedMode
        }

        do {
            _ = try await makeFetcher(downloader: downloader, service: service, rustBackend: rustBackend, torEnabled: true)
                .fetch { _ in }
            XCTFail("a failing Tor lookup must surface as an error, never as a direct retry")
        } catch ZcashError.unspentTransactionFetcherStream {
            XCTAssertFalse(downloader.fetchUnspentTransactionOutputsTAddressesStartHeightModeCalled)
        }
    }

    /// A service that answers `.torRequired` did nothing; that is a failed lookup, not a fetched one.
    func testTorEnabledTreatsTorRequiredAsAFailedLookup() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()

        rustBackend.listAccountsReturnValue = [makeAccount()]
        rustBackend.listTransparentReceiversAccountUUIDReturnValue = [firstAddress]
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { _, _, _, _, _ in .torRequired }

        do {
            _ = try await makeFetcher(downloader: downloader, service: service, rustBackend: rustBackend, torEnabled: true)
                .fetch { _ in }
            XCTFail("a service without a Tor connection must not pass as a completed discovery")
        } catch ZcashError.unspentTransactionFetcherStream(let underlying) {
            guard case ZcashError.serviceTorRequired = underlying else {
                return XCTFail("expected serviceTorRequired, got \(type(of: underlying))")
            }
        }
    }

    func testTorDisabledKeepsTheDirectRequest() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()
        let utxo = UnspentTransactionOutputEntityMock(
            address: firstAddress.stringEncoded,
            txid: Data(repeating: 0x01, count: 32),
            index: 0,
            script: Data([0x76]),
            valueZat: 1000,
            height: 663150
        )

        rustBackend.listAccountsReturnValue = [makeAccount()]
        rustBackend.listTransparentReceiversAccountUUIDReturnValue = [firstAddress, secondAddress]
        rustBackend.putUnspentTransparentOutputTxidIndexScriptValueHeightClosure = { _, _, _, _, _ in }
        downloader.fetchUnspentTransactionOutputsTAddressesStartHeightModeClosure = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(utxo)
                continuation.finish()
            }
        }

        let result = try await makeFetcher(downloader: downloader, service: service, rustBackend: rustBackend, torEnabled: false)
            .fetch { _ in }

        let arguments = try XCTUnwrap(downloader.fetchUnspentTransactionOutputsTAddressesStartHeightModeReceivedArguments)
        XCTAssertEqual(arguments.tAddresses, [firstAddress.stringEncoded, secondAddress.stringEncoded])
        XCTAssertEqual(arguments.mode, .direct)
        XCTAssertFalse(service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeCalled)
        XCTAssertEqual(result.inserted.count, 1)
        XCTAssertTrue(result.skipped.isEmpty)
    }
}
