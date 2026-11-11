//
//  OHTTPTransparentAddressChecksTests.swift
//  OfflineTests
//
//  The transparent-address checks of a gateway endpoint ride the OHTTP transport: the wallet decides what to
//  ask, the relay sees the sealed request, and the Tor gRPC connector is never reached.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class OHTTPTransparentAddressChecksTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var gets: [URLRequest] = []
        var posts: [URLRequest] = []
    }

    private var dbData: URL!
    private var rustBackend: ZcashRustBackendWelding!
    private var account: AccountUUID!
    private var otherAccount: AccountUUID!

    override func setUp() async throws {
        try await super.setUp()
        OHTTPTestSupport.installExampleConfiguration()

        dbData = try __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )
        guard case .success = try await rustBackend.initDataDb(seed: nil) else {
            return XCTFail("initDataDb did not succeed")
        }
        let treeState = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().treeState()
        _ = try await rustBackend.createAccount(seed: Environment.seedBytes, treeState: treeState, recoverUntil: nil, name: "a", keySource: nil)
        _ = try await rustBackend.createAccount(seed: [UInt8](repeating: 7, count: 32), treeState: treeState, recoverUntil: nil, name: "b", keySource: nil)
        let accounts = try await rustBackend.listAccounts()
        account = try XCTUnwrap(accounts.first?.id)
        otherAccount = try XCTUnwrap(accounts.last?.id)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData)
        rustBackend = nil
    }

    /// A service on the testnet gateway, Tor off, whose relay answers the key GET and refuses every POST with
    /// 503, so each check reaches the relay and fails there.
    private func makeService(recorder: Recorder) -> LightWalletOHTTPService {
        let service = LightWalletOHTTPService(
            endpoint: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true),
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: TorClient(torDir: FileManager.default.temporaryDirectory),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        service.walletNetwork = .testnet
        service.testKeyVerifier = OHTTPTestSupport.makeKeyVerifier()
        service.testClearnetSender = { request, _ in
            if request.httpMethod == "GET" {
                recorder.gets.append(request)
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            recorder.posts.append(request)
            return (Data(), OHTTPTestSupport.response(for: request.url, status: 503))
        }
        return service
    }

    private func transparentAddress(of account: AccountUUID) async throws -> String {
        let unified = try await rustBackend.getCurrentAddress(accountUUID: account)
        return try DerivationTool(networkType: .testnet).transparentReceiver(from: unified).stringEncoded
    }

    func testUpdateTransparentAddressTransactionsIsAskedOfTheGatewayThroughTheRelay() async throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let address = try await transparentAddress(of: account)

        do {
            _ = try await service.updateTransparentAddressTransactions(
                address: address,
                start: 0,
                end: -1,
                dbData: dbData.osStr(),
                networkType: .testnet,
                mode: .direct
            )
            XCTFail("the relay refused the request")
        } catch ZcashError.serviceGetTaddressTxidsFailed(let serviceError) {
            guard case .failed(let code, _) = serviceError else {
                return XCTFail("a refused exchange is a gRPC status, got \(serviceError)")
            }
            XCTAssertEqual(code, 14)
        }
        // The key configuration may already sit in the process-wide cache from an earlier test; the POST is the proof.
        let relay = try XCTUnwrap(OHTTPNative.relayURL(for: OHTTPTestSupport.testnetHost))
        XCTAssertEqual(recorder.posts.map { $0.url?.absoluteString }, [relay], "the GetTaddressTxids exchange is posted to the relay, sealed")
    }

    func testFetchUTXOsByAddressStartsFromTheWalletAndIsAskedThroughTheRelay() async throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let address = try await transparentAddress(of: account)

        do {
            _ = try await service.fetchUTXOsByAddress(address: address, dbData: dbData.osStr(), networkType: .testnet, accountUUID: account, mode: .direct)
            XCTFail("the relay refused the request")
        } catch ZcashError.serviceFetchUTXOsFailed {
        }
        XCTAssertEqual(recorder.posts.count, 1, "the GetAddressUtxosStream exchange is posted to the relay, sealed")

        let start = try await TransparentAddressWalletStore.utxoStartHeight(
            address: address,
            dbData: dbData.osStr(),
            networkType: .testnet,
            accountUUID: account
        )
        let checkpoint = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(start), checkpoint, "the range starts at the exposure height, else the account's birthday")
    }

    func testFetchUTXOsByAddressOfAnotherAccountIsNotAskedAtAll() async throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let foreign = try await transparentAddress(of: otherAccount)

        let result = try await service.fetchUTXOsByAddress(address: foreign, dbData: dbData.osStr(), networkType: .testnet, accountUUID: account, mode: .direct)

        XCTAssertEqual(result, .notFound)
        XCTAssertTrue(recorder.gets.isEmpty && recorder.posts.isEmpty, "an address the account does not own is never asked of the server")
    }

    func testCheckSingleUseTransparentAddressesWithNoneDueIsNotAskedAtAll() async throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        let result = try await service.checkSingleUseTransparentAddresses(dbData: dbData.osStr(), networkType: .testnet, accountUUID: account, mode: .direct)

        XCTAssertEqual(result, .notFound)
        XCTAssertTrue(recorder.gets.isEmpty && recorder.posts.isEmpty, "with no single-use address due, nothing is sent")
    }

    /// The relay sees a sealed Chunked OHTTP request, never the plain gRPC call: the proof is the body and its
    /// media type, not the URL, which a plaintext request to the same relay would share.
    func testTheRelayPostIsTheSealedRequestNotThePlainRPC() async throws {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        let address = try await transparentAddress(of: account)

        _ = try? await service.updateTransparentAddressTransactions(
            address: address,
            start: 0,
            end: -1,
            dbData: dbData.osStr(),
            networkType: .testnet,
            mode: .direct
        )

        XCTAssertEqual(recorder.posts.count, 1)
        let post = try XCTUnwrap(recorder.posts.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "message/ohttp-chunked-req", "the body is a sealed request")
        let body = try XCTUnwrap(post.httpBody)
        XCTAssertFalse(body.isEmpty)
        XCTAssertNil(body.range(of: Data(address.utf8)), "the address never crosses the relay in the clear")
        XCTAssertNil(body.range(of: Data("GetTaddressTxids".utf8)), "nor does the RPC name")
        XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
    }

    /// In Tor mode every wallet-identifying call asks for `.uniqueTor` and gets a client on a Tor circuit of its
    /// own (ZIP: each such request SHOULD use an isolated circuit), while `.direct` calls share one circuit.
    func testEachUniqueTorCallRidesItsOwnIsolatedCircuit() async throws {
        final class Circuits: @unchecked Sendable {
            var isolations = 0
            var clientsOfPosts: [TorClient] = []
        }
        let circuits = Circuits()
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("no plain GET over Tor is made")
                return nil
            },
            freeResponse: { _ in },
            isolateRuntime: { runtime in
                circuits.isolations += 1
                return runtimes.clone(runtime)
            },
            freeRuntime: { runtimes.free($0) }
        )
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let service = LightWalletOHTTPService(
            endpoint: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true),
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: tor,
            sdkFlags: SDKFlags(torEnabled: true, exchangeRateEnabled: false)
        )
        service.walletNetwork = .testnet
        service.testKeyVerifier = OHTTPTestSupport.makeKeyVerifier()
        service.testTorSender = { (isolated: TorClient) -> OHTTPTransport.HTTPSender in
            { request, _ in
                if request.httpMethod == "GET" {
                    return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
                }
                circuits.clientsOfPosts.append(isolated)
                return (Data(), OHTTPTestSupport.response(for: request.url, status: 503))
            }
        }
        let address = try await transparentAddress(of: account)

        for _ in 0..<2 {
            _ = try? await service.updateTransparentAddressTransactions(
                address: address,
                start: 0,
                end: -1,
                dbData: dbData.osStr(),
                networkType: .testnet,
                mode: .uniqueTor
            )
        }
        XCTAssertEqual(circuits.isolations, 2, "each .uniqueTor call isolates a circuit of its own")
        XCTAssertEqual(circuits.clientsOfPosts.count, 2)
        XCTAssertTrue(circuits.clientsOfPosts[0] !== circuits.clientsOfPosts[1], "the two posts rode different clients")

        for _ in 0..<2 {
            _ = try? await service.updateTransparentAddressTransactions(
                address: address,
                start: 0,
                end: -1,
                dbData: dbData.osStr(),
                networkType: .testnet,
                mode: .direct
            )
        }
        XCTAssertEqual(circuits.isolations, 3, ".direct calls in Tor mode share one circuit")
        XCTAssertEqual(circuits.clientsOfPosts.count, 4)
        XCTAssertTrue(circuits.clientsOfPosts[2] === circuits.clientsOfPosts[3])
        try await tor.close()
    }

    /// lightwalletd marks a transaction that is not in the main chain with a height of 0 or `u64::MAX`; any other
    /// value a block height cannot hold is a malformed answer and fails, as it does on the Tor gRPC path.
    func testOnlyZeroAndTheU64SentinelMeanUnmined() throws {
        XCTAssertEqual(try TransparentAddressWalletStore.minedHeight(of: 0), 0)
        XCTAssertEqual(try TransparentAddressWalletStore.minedHeight(of: UInt64.max), 0)
        XCTAssertEqual(try TransparentAddressWalletStore.minedHeight(of: 2_500_000), 2_500_000)
        XCTAssertEqual(try TransparentAddressWalletStore.minedHeight(of: UInt64(UInt32.max)), Int64(UInt32.max))
        XCTAssertThrowsError(try TransparentAddressWalletStore.minedHeight(of: UInt64(UInt32.max) + 1))
    }

    func testAClearnetServerKeepsTheTorRequiredAnswerWithTorOff() async throws {
        let service = LightWalletOHTTPService(
            endpoint: LightWalletEndpoint(address: "lwd.example.com", port: 443, secure: true),
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: TorClient(torDir: FileManager.default.temporaryDirectory),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        service.walletNetwork = .testnet
        let address = try await transparentAddress(of: account)

        let result = try await service.updateTransparentAddressTransactions(
            address: address,
            start: 0,
            end: -1,
            dbData: dbData.osStr(),
            networkType: .testnet,
            mode: .direct
        )
        XCTAssertEqual(result, .torRequired, "plain gRPC has no transparent-address check: only a gateway or Tor does")
    }
}
