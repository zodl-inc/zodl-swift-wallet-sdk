//
//  SlipstreamWipeEndpointTests.swift
//  ZODLSwiftWalletSDK
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// Which server a wallet prepared after `wipe()` talks to first.
///
/// A `prepare` that finds no account provisions one, and asks a server for its anchor: the chain tip a restore
/// recovers up to, or the tree state a new wallet starts from. It asks the server the synchronizer is on, and a wipe
/// leaves that server as it was. A host that resets the wallet in order to leave that server has to name the next
/// one before the next `prepare`, and `switchTo` is how it names a server. But a switch reopens the engine, and
/// between a wipe and the next `prepare` a reopen opens the wallet database the wipe has just deleted (SQLite creates
/// the file) before `prepare` has initialized it.
///
/// So in that window a switch only records the server, and `prepare` provisions from it and opens the engine there.
/// Everywhere else a switch reopens the engine at once, as it always has.
final class SlipstreamWipeEndpointTests: ZcashTestCase {
    private let constructionServer = LightWalletEndpoint(address: "construction.example.com", port: 443, secure: true)
    private let preWipeServer = LightWalletEndpoint(address: "pre-wipe.example.com", port: 443, secure: true)
    private let nextWalletServer = LightWalletEndpoint(address: "next-wallet.example.com", port: 443, secure: true)
    private let laterServer = LightWalletEndpoint(address: "later.example.com", port: 443, secure: true)
    /// A testnet height the bundled checkpoints cover, so a restore provisions without a network.
    private let restoreBirthday: BlockHeight = 3_000_000

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - A switch between a wipe and the next prepare

    /// The break this catches: a switch after a wipe that reopens the engine. On the real engine that reopen is the
    /// one that recreates the deleted database, which is why a host could not name the next wallet's server before
    /// `prepare` at all.
    func testASwitchAfterAWipeRecordsTheServerWithoutTouchingTheEngine() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        try await wipe(fixture.synchronizer)
        let callsBeforeTheSwitch = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: nextWalletServer)

        let switchCalls = await engineCalls(of: fixture, since: callsBeforeTheSwitch)
        XCTAssertTrue(switchCalls.isEmpty, "a switch after a wipe must leave the engine closed until prepare: \(switchCalls)")
        let recorded = await fixture.synchronizer.currentEndpointForTesting()
        XCTAssertEqual(recorded, nextWalletServer, "and record the server for the next prepare")
    }

    /// The reset as a host performs it: the wallet was on one server, the wipe ends it, the host names another, and
    /// the next wallet's provisioning request goes there. The engine is opened once after the wipe, by `prepare`, at
    /// that server: opening it with the server it had before the wipe would put the first sync pass back on the
    /// server the host has just left.
    func testThePrepareAfterAWipeProvisionsAndOpensTheEngineAtTheServerNamedAfterTheWipe() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        try await fixture.synchronizer.switchTo(endpoint: preWipeServer)
        try await wipe(fixture.synchronizer)
        let callsBeforeTheReset = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: nextWalletServer)
        try await prepare(fixture, restoringFrom: restoreBirthday)

        let anchorServers = await fixture.anchor.servers
        XCTAssertEqual(
            anchorServers,
            [constructionServer, nextWalletServer],
            "the reset wallet's provisioning request goes to the server named after the wipe, not to the one before it"
        )
        let resetCalls = await engineCalls(of: fixture, since: callsBeforeTheReset)
        XCTAssertEqual(
            Self.engineOpens(resetCalls),
            ["reopen(next-wallet.example.com:443)"],
            "the engine is opened once after the wipe, by prepare, at the server named after the wipe: \(resetCalls)"
        )
    }

    /// What a wipe alone does to the server, written down because it is a decision: nothing. Without a switch the
    /// next wallet is provisioned from the server in use before the wipe. The SDK does not choose a server for the
    /// host, and in particular does not fall back to the one it was constructed with, which may be the very server a
    /// user has moved away from.
    func testWithoutASwitchThePrepareAfterAWipeStaysOnTheServerInUse() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        try await fixture.synchronizer.switchTo(endpoint: preWipeServer)
        try await wipe(fixture.synchronizer)

        try await prepare(fixture, restoringFrom: restoreBirthday)

        let anchorServers = await fixture.anchor.servers
        XCTAssertEqual(anchorServers, [constructionServer, preWipeServer])
    }

    /// A `prepare` that fails has not created the database, so the window is still open and a switch the host makes
    /// before trying again must still only record. The break: closing the window when `prepare` begins rather than
    /// once it has opened the engine.
    func testASwitchAfterAFailedPrepareStillOnlyRecordsTheServer() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        try await wipe(fixture.synchronizer)
        fixture.backend.initDataDbSeedThrowableError = SimulatedFailure()
        do {
            try await prepare(fixture, restoringFrom: restoreBirthday)
            XCTFail("the prepare was meant to fail")
        } catch {
            XCTAssertTrue(error is SimulatedFailure, "\(error)")
        }
        fixture.backend.initDataDbSeedThrowableError = nil
        let callsBeforeTheSwitch = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: nextWalletServer)

        let switchCalls = await engineCalls(of: fixture, since: callsBeforeTheSwitch)
        XCTAssertTrue(switchCalls.isEmpty, "the database is still missing, so the engine must stay closed: \(switchCalls)")
    }

    /// Once `prepare` has opened the engine the window is closed, and a switch is the ordinary one again, which a
    /// prepared wallet needs to move its sync pass. The break: a window that outlives the `prepare` that closes it,
    /// turning every later switch into a record the engine never sees.
    func testASwitchAfterThePostWipePrepareReopensTheEngine() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        try await wipe(fixture.synchronizer)
        try await fixture.synchronizer.switchTo(endpoint: nextWalletServer)
        try await prepare(fixture, restoringFrom: restoreBirthday)
        let callsBeforeTheSwitch = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: laterServer)

        let switchCalls = await engineCalls(of: fixture, since: callsBeforeTheSwitch)
        XCTAssertEqual(Self.engineOpens(switchCalls), ["reopen(later.example.com:443)"], "\(switchCalls)")
    }

    // MARK: - Unchanged without a completed wipe

    /// A wallet that was never wiped switches as it always has: the engine is reopened at the new server at once.
    func testASwitchOnAWalletThatWasNeverWipedReopensTheEngine() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        let callsBeforeTheSwitch = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: preWipeServer)

        let switchCalls = await engineCalls(of: fixture, since: callsBeforeTheSwitch)
        XCTAssertEqual(Self.engineOpens(switchCalls), ["reopen(pre-wipe.example.com:443)"], "\(switchCalls)")
    }

    /// The first `prepare` provisions from the server the synchronizer was built with and opens the engine as it
    /// always has, without the reopen a post-wipe `prepare` makes: a reopen would first close a handle the host may
    /// already have opened with a switch.
    func testPrepareOnAWalletThatWasNeverWipedOpensTheEngine() async throws {
        let fixture = try makeFixture()

        try await prepare(fixture, restoringFrom: nil)

        let anchorServers = await fixture.anchor.servers
        XCTAssertEqual(anchorServers, [constructionServer])
        let calls = await fixture.engine.calls
        XCTAssertEqual(Self.engineOpens(calls), ["open"], "\(calls)")
    }

    /// A wipe the engine refused (its stop could not be proved quiescent) deleted nothing and left the wallet
    /// prepared, so a switch after it is an ordinary switch. The break: opening the window when the wipe begins
    /// rather than when it completes.
    func testASwitchAfterARefusedWipeReopensTheEngine() async throws {
        let fixture = try makeFixture()
        try await prepare(fixture, restoringFrom: nil)
        fixture.engine.stopQuiescent = false
        do {
            try await wipe(fixture.synchronizer)
            XCTFail("the wipe was meant to be refused")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code, .slipstreamEngineNotQuiescent)
        }
        fixture.engine.stopQuiescent = true
        let callsBeforeTheSwitch = await fixture.engine.calls.count

        try await fixture.synchronizer.switchTo(endpoint: preWipeServer)

        let switchCalls = await engineCalls(of: fixture, since: callsBeforeTheSwitch)
        XCTAssertEqual(Self.engineOpens(switchCalls), ["reopen(pre-wipe.example.com:443)"], "\(switchCalls)")
    }

    // MARK: - The real engine

    /// The hazard itself, on the real engine: opening a handle opens the wallet database, and SQLite creates a missing
    /// file on open, so a switch that reopened the engine after a wipe would bring back an empty `data.db` before
    /// `prepare` initializes it.
    func testASwitchAfterAWipeDoesNotRecreateTheWalletDatabase() async throws {
        let directory = testTempDirectory.appendingPathComponent("real-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataDbURL = directory.appendingPathComponent("data.db")
        let initializer = Initializer(
            cacheDbURL: nil,
            fsBlockDbRoot: directory.appendingPathComponent("blocks", isDirectory: true),
            generalStorageURL: directory.appendingPathComponent("general", isDirectory: true),
            dataDbURL: dataDbURL,
            torDirURL: directory.appendingPathComponent("tor", isDirectory: true),
            endpoint: preWipeServer,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let synchronizer = SlipstreamSynchronizer(initializer: initializer)
        // Stands in for the wallet database the wipe deletes.
        try Data("wallet".utf8).write(to: dataDbURL)
        try await wipe(synchronizer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDbURL.path), "the wipe deleted the wallet database")

        try await synchronizer.switchTo(endpoint: nextWalletServer)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dataDbURL.path),
            "a switch after a wipe must not open the engine onto the deleted wallet database"
        )
    }

    // MARK: - Fixture

    /// A `SlipstreamSynchronizer` whose `prepare` runs for real over test doubles: a fake engine, a rust backend whose
    /// account lives in `data.db`, and an anchor resolver that records which server each provisioning request went to
    /// instead of dialling it.
    private struct Fixture {
        let synchronizer: SlipstreamSynchronizer
        let engine: GatedFakeSlipstreamEngine
        let backend: ZcashRustBackendWeldingMock
        let anchor: AnchorRequests
    }

    /// The servers the provisioning anchor was requested from, in order. Answers nil, the offline answer: which server
    /// was asked is what these tests follow, not what it said.
    private actor AnchorRequests {
        private(set) var servers: [LightWalletEndpoint] = []

        func record(_ server: LightWalletEndpoint) -> SlipstreamRestoreAnchor? {
            servers.append(server)
            return nil
        }
    }

    private struct SimulatedFailure: Error {}

    private func makeFixture() throws -> Fixture {
        let directory = testTempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataDbURL = directory.appendingPathComponent("data.db")
        let network = ZcashNetworkBuilder.network(for: .testnet)
        let account = Account(
            id: TestsData.mockedAccountUUID,
            name: "",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )

        let backend = ZcashRustBackendWeldingMock()
        backend.initDataDbSeedReturnValue = DbInitResult.success
        // The account lives in `data.db`, the file `wipe()` deletes, so a `prepare` after a wipe finds no account and
        // provisions one again: the request these tests follow.
        backend.listAccountsClosure = {
            FileManager.default.fileExists(atPath: dataDbURL.path) ? [account] : []
        }
        backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure = { _, _, _, _, _ in
            FileManager.default.createFile(atPath: dataDbURL.path, contents: Data())
            return UnifiedSpendingKey(network: network.networkType, bytes: [])
        }
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        let storage = CompactBlockRepositoryMock()
        storage.createClosure = {}
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        mockContainer.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: directory.appendingPathComponent("blocks", isDirectory: true),
            generalStorageURL: directory.appendingPathComponent("general", isDirectory: true),
            dataDbURL: dataDbURL,
            torDirURL: directory.appendingPathComponent("tor", isDirectory: true),
            endpoint: constructionServer,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let engine = GatedFakeSlipstreamEngine()
        let anchor = AnchorRequests()
        let synchronizer = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: engine,
            restoreAnchor: { _, _, _, server, _, _ in
                await anchor.record(server)
            }
        )
        return Fixture(synchronizer: synchronizer, engine: engine, backend: backend, anchor: anchor)
    }

    /// Prepares the wallet with a seed: a new wallet for a nil birthday, a restore otherwise.
    private func prepare(_ fixture: Fixture, restoringFrom birthday: BlockHeight?) async throws {
        let result = try await fixture.synchronizer.prepare(
            with: Environment.seedBytes,
            walletBirthday: birthday,
            name: "",
            keySource: nil
        )
        guard case .success = result else {
            return XCTFail("expected a prepared wallet, got \(result)")
        }
    }

    /// Runs `wipe()` to completion and rethrows its failure.
    private func wipe(_ synchronizer: SlipstreamSynchronizer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            synchronizer.wipe()
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    },
                    receiveValue: { _ in }
                )
                .store(in: &cancellables)
        }
    }

    /// The engine calls recorded since the log held `count` entries.
    private func engineCalls(of fixture: Fixture, since count: Int) async -> [String] {
        let calls = await fixture.engine.calls
        return Array(calls.dropFirst(count))
    }

    /// The engine calls that open a handle: `open`, or `reopen(host:port)` naming the server it was pointed at.
    private static func engineOpens(_ calls: [String]) -> [String] {
        calls.filter { $0 == "open" || $0.hasPrefix("reopen(") }
    }
}
