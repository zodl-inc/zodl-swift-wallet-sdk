//
//  SlipstreamWalletChangeStopTests.swift
//  OfflineTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// [MOB-2184] Which stop each lifecycle operation makes.
///
/// A plain stop lets a scan call in progress run to its end, by default the end of its chunk, and
/// that can outlast the ten-second budget the engine gives its wait for the pass. When it does, the
/// stop cannot prove the wallet file quiescent and every operation that changes the wallet refuses
/// with ZRUST0155, which is how adding several accounts in quick succession failed. The stop for a
/// wallet change asks the scan to end at its next block first, so every operation that changes the
/// wallet, or reopens a handle onto it, must make that one. The background stop changes nothing in
/// the wallet, so it keeps the plain stop.
///
/// Each test starts a pass, runs one operation, and reads which stops the engine was asked for
/// before anything else stops it.
final class SlipstreamWalletChangeStopTests: ZcashTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    func testImportAccountStopsForAWalletChange() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceClosure = { _, _, _, _, _, _, _, _ in
            TestsData.mockedAccountUUID
        }
        let (sync, engine) = try await runningSynchronizer(welding: welding)

        _ = try await sync.importAccount(
            ufvk: "not-a-viewing-key",
            seedFingerprint: nil,
            zip32AccountIndex: nil,
            purpose: .viewOnly,
            name: "Imported",
            keySource: nil,
            birthday: 1_000_000
        )

        await assertStoppedOnlyForAWalletChange(engine)
        XCTAssertTrue(welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceCalled)
        sync.stop()
    }

    func testDeleteAccountStopsForAWalletChange() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let (sync, engine) = try await runningSynchronizer(welding: welding)

        try await sync.deleteAccount(TestsData.mockedAccountUUID)

        await assertStoppedOnlyForAWalletChange(engine)
        XCTAssertTrue(welding.deleteAccountCalled)
        sync.stop()
    }

    func testRewindStopsForAWalletChange() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.truncateToChainStateChainStateClosure = { _ in }
        let (sync, engine) = try await runningSynchronizer(welding: welding)

        try await awaitCompletion(of: sync.rewind(.birthday))

        await assertStoppedOnlyForAWalletChange(engine)
        XCTAssertTrue(welding.truncateToChainStateChainStateCalled)
        sync.stop()
    }

    func testWipeStopsForAWalletChange() async throws {
        let (sync, engine) = try await runningSynchronizer()

        try await awaitCompletion(of: sync.wipe())

        await assertStoppedOnlyForAWalletChange(engine)
        XCTAssertEqual(sync.latestState.internalSyncStatus, .unprepared)
    }

    func testSwitchToStopsForAWalletChange() async throws {
        let (sync, engine) = try await runningSynchronizer()

        try await sync.switchTo(endpoint: LightWalletEndpoint(address: "other.example.com", port: 443, secure: true))

        await assertStoppedOnlyForAWalletChange(engine)
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("reopen(other.example.com:443)"), "\(calls)")
        sync.stop()
    }

    func testRestartSyncStopsForAWalletChange() async throws {
        let (sync, engine) = try await runningSynchronizer()

        let endpoint = await sync.currentEndpointForTesting()
        try await sync.restartSync(at: endpoint)

        await assertStoppedOnlyForAWalletChange(engine)
        sync.stop()
    }

    func testStallRecoveryStopsForAWalletChange() async throws {
        let (sync, engine) = try await runningSynchronizer()

        await sync.runStallRecovery(
            expectedPassGeneration: await sync.passGenerationForTesting(),
            expectedStopRequestGeneration: await sync.stopRequestGenerationForTesting(),
            attempt: 1
        )

        await assertStoppedOnlyForAWalletChange(engine)
        let calls = await engine.calls
        XCTAssertTrue(calls.contains { $0.hasPrefix("reopen(") }, "the recovery reopened the handle: \(calls)")
        sync.stop()
    }

    /// The background stop changes nothing in the wallet, so it keeps the plain stop, which lets a
    /// scan call finish its chunk instead of discarding the work.
    func testTheBackgroundStopKeepsThePlainStop() async throws {
        let (sync, engine) = try await runningSynchronizer()

        await sync.stopAndWait()

        let stops = await engine.calls.filter(GatedFakeSlipstreamEngine.isStop)
        XCTAssertEqual(stops, ["stop"], "the background stop asks for the plain stop, once")
    }

    /// A refused change still names the wait that ran out: the stop before a wallet change reports
    /// exactly as the plain stop does.
    func testARefusedWalletChangeThrowsZRUST0155WithTheReason() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let (sync, engine) = try await runningSynchronizer(welding: welding)
        engine.stopReport = .passStillRunning

        do {
            try await sync.deleteAccount(TestsData.mockedAccountUUID)
            XCTFail("a stop for a wallet change that is not quiescent must refuse the change")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code, .slipstreamEngineNotQuiescent)
            XCTAssertEqual(error.detail, "a sync pass was still running after 10.0 s")
        }

        XCTAssertFalse(welding.deleteAccountCalled, "the wallet must not change on top of a live writer")
        await assertStoppedOnlyForAWalletChange(engine)
        sync.stop()
    }

    // MARK: - Helpers

    /// A synchronizer over a gated fake engine with a pass already running, the state every
    /// wallet-changing operation is reached in.
    private func runningSynchronizer(
        welding: ZcashRustBackendWeldingMock? = nil
    ) async throws -> (SlipstreamSynchronizer, GatedFakeSlipstreamEngine) {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(
            engine: engine,
            welding: welding,
            restoreAnchor: { _, _, _, _, _, _ in nil }
        )
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start(retry: false)
        return (sync, engine)
    }

    /// The engine was stopped exactly once, and with the stop for a wallet change.
    private func assertStoppedOnlyForAWalletChange(
        _ engine: GatedFakeSlipstreamEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let calls = await engine.calls
        XCTAssertEqual(
            calls.filter(GatedFakeSlipstreamEngine.isStop),
            ["stopForWalletChange"],
            "the operation stopped the engine once, for a wallet change: \(calls)",
            file: file,
            line: line
        )
    }

    /// Waits for a Combine-based lifecycle operation (`rewind`, `wipe`) and rethrows its failure.
    private func awaitCompletion(of publisher: AnyPublisher<Void, Error>) async throws {
        let finished = XCTestExpectation(description: "the operation completed")
        var failure: Error?
        publisher
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        failure = error
                    }
                    finished.fulfill()
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
        await fulfillment(of: [finished], timeout: 5)
        if let failure {
            throw failure
        }
    }
}
