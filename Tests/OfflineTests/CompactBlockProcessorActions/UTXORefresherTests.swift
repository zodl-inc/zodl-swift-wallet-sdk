//
//  UTXORefresherTests.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)
//  Licensed under the GNU Affero General Public License, version 3 only (AGPL-3.0-only).
//  See LICENSE, LICENSE-EXCEPTIONS.md and COMMERCIAL-LICENSE.md in this repository.
//
//  Covers the implementation behind `Synchronizer.refreshUTXOs(address:from:)` on both
//  synchronizers: the Tor branch resolves the owning account through the FFI and lets it store
//  the UTXOs, the direct branch streams and stores them here.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class UTXORefresherTests: XCTestCase {
    private let address = TransparentAddress(validatedEncoding: "t1dRJRY7GmyeykJnMH38mdQoaZtFhn1QmGz")

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

    private func makeUTXO(index: Int) -> UnspentTransactionOutputEntityMock {
        UnspentTransactionOutputEntityMock(
            address: address.stringEncoded,
            txid: Data(repeating: 0x01, count: 32),
            index: index,
            script: Data([0x76]),
            valueZat: 1000,
            height: 663150
        )
    }

    private func makeRefresher(
        downloader: BlockDownloaderServiceMock,
        service: LightWalletServiceMock,
        rustBackend: ZcashRustBackendWeldingMock,
        logger: LoggerMock
    ) -> UTXORefresher {
        UTXORefresher(
            blockDownloaderService: downloader,
            service: service,
            rustBackend: rustBackend,
            dataDb: URL(fileURLWithPath: "/tmp/data.db"),
            networkType: .testnet,
            logger: logger
        )
    }

    func testTorBranchResolvesTheAccountAndFetchesOnTheGivenMode() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()

        rustBackend.getAccountForTransparentAddressReturnValue = makeAccount()
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { _, _, _, _, _ in .found("found") }

        let result = try await makeRefresher(downloader: downloader, service: service, rustBackend: rustBackend, logger: makeLogger())
            .refresh(address: address, startHeight: 663100, mode: .uniqueTor)

        XCTAssertEqual(rustBackend.getAccountForTransparentAddressReceivedAddress?.stringEncoded, address.stringEncoded)
        let arguments = try XCTUnwrap(service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeReceivedArguments)
        XCTAssertEqual(arguments.address, address.stringEncoded)
        XCTAssertEqual(arguments.accountUUID, TestsData.mockedAccountUUID)
        XCTAssertEqual(arguments.networkType, .testnet)
        XCTAssertEqual(arguments.mode, .uniqueTor)
        XCTAssertFalse(downloader.fetchUnspentTransactionOutputsTAddressStartHeightModeCalled, "the direct stream must not be opened over Tor")
        XCTAssertFalse(rustBackend.putUnspentTransparentOutputTxidIndexScriptValueHeightCalled, "the FFI stores the UTXOs itself over Tor")
        XCTAssertTrue(result.inserted.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// An address no account exposed has nothing to fetch; the answer is empty and the reason is
    /// logged, so it cannot be mistaken for an address that simply holds no UTXOs.
    func testTorBranchDoesNothingForAnAddressNoAccountExposed() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()
        let logger = makeLogger()

        rustBackend.getAccountForTransparentAddressReturnValue = nil

        let result = try await makeRefresher(downloader: downloader, service: service, rustBackend: rustBackend, logger: logger)
            .refresh(address: address, startHeight: 663100, mode: .uniqueTor)

        XCTAssertFalse(service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeCalled)
        XCTAssertFalse(downloader.fetchUnspentTransactionOutputsTAddressStartHeightModeCalled)
        XCTAssertTrue(logger.infoFileFunctionLineCalled)
        XCTAssertTrue(result.inserted.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testTorBranchTreatsTorRequiredAsAnError() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()

        rustBackend.getAccountForTransparentAddressReturnValue = makeAccount()
        service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeClosure = { _, _, _, _, _ in .torRequired }

        do {
            _ = try await makeRefresher(downloader: downloader, service: service, rustBackend: rustBackend, logger: makeLogger())
                .refresh(address: address, startHeight: 663100, mode: .uniqueTor)
            XCTFail("a service without a Tor connection must not pass as a completed refresh")
        } catch ZcashError.serviceTorRequired {
            XCTAssertFalse(downloader.fetchUnspentTransactionOutputsTAddressStartHeightModeCalled)
        }
    }

    func testDirectBranchStreamsAndStoresReportingWhatFailedToStore() async throws {
        let downloader = BlockDownloaderServiceMock()
        let service = LightWalletServiceMock()
        let rustBackend = ZcashRustBackendWeldingMock()
        let logger = makeLogger()
        let stored = makeUTXO(index: 0)
        let rejected = makeUTXO(index: 1)

        downloader.fetchUnspentTransactionOutputsTAddressStartHeightModeClosure = { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(stored)
                continuation.yield(rejected)
                continuation.finish()
            }
        }
        rustBackend.putUnspentTransparentOutputTxidIndexScriptValueHeightClosure = { _, index, _, _, _ in
            if index == 1 {
                throw ZcashError.rustPutUnspentTransparentOutput("mocked failure")
            }
        }

        let result = try await makeRefresher(downloader: downloader, service: service, rustBackend: rustBackend, logger: logger)
            .refresh(address: address, startHeight: 663100, mode: .direct)

        let arguments = try XCTUnwrap(downloader.fetchUnspentTransactionOutputsTAddressStartHeightModeReceivedArguments)
        XCTAssertEqual(arguments.tAddress, address.stringEncoded)
        XCTAssertEqual(arguments.startHeight, 663100)
        XCTAssertEqual(arguments.mode, .direct)
        XCTAssertFalse(rustBackend.getAccountForTransparentAddressCalled, "the direct branch needs no account lookup")
        XCTAssertFalse(service.fetchUTXOsByAddressAddressDbDataNetworkTypeAccountUUIDModeCalled)
        XCTAssertEqual(result.inserted as? [UnspentTransactionOutputEntityMock], [stored])
        XCTAssertEqual(result.skipped as? [UnspentTransactionOutputEntityMock], [rejected])
        XCTAssertTrue(logger.errorFileFunctionLineCalled, "a UTXO that failed to store is logged")
    }
}
