import Foundation
import os
import libzcashlc
import GRPC
import NIO
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SubmissionBudgetTests: ZcashTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await clearGatewayKey()
    }

    override func tearDown() async throws {
        await clearGatewayKey()
        try await super.tearDown()
    }

    private func clearGatewayKey() async {
        let host = OHTTPTestSupport.testnetHost
        let relay = try! OHTTPEndpoints.relayURL(for: host)
        await OHTTPKeyCache.shared.store(nil, for: "\(relay)|\(host)|tor")
    }

    func testHeightReadConsumesSendBudget() async throws {
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.latestBlockHeightModeClosure = { _ in
            try await Task.sleep(nanoseconds: 80_000_000)
            return 100_000
        }
        service.submitSpendTransactionModeReturnValue = SendResponse()
        let submitter = try makeSubmitter(service: service)
        do {
            try await submitter.submit(transaction: transaction(), to: endpoint(milliseconds: 30))
            XCTFail("An exhausted height budget must not allow a fresh send timeout")
        } catch {}
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(service.closeConnectionsCallsCount, 1)
    }

    func testRejectedSendCannotStartKnownLookupAfterBudgetExpires() async throws {
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.latestBlockHeightModeReturnValue = 100_000
        service.submitSpendTransactionModeClosure = { _, _ in
            try await Task.sleep(nanoseconds: 80_000_000)
            return SendResponse.with { $0.errorCode = -1 }
        }
        service.fetchTransactionTxIdModeReturnValue = (nil, .txidNotRecognized)
        let submitter = try makeSubmitter(service: service)
        do {
            try await submitter.submit(transaction: transaction(), to: endpoint(milliseconds: 30))
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 0)
        XCTAssertEqual(service.closeConnectionsCallsCount, 1)
    }

    func testProductionOHTTPTorKeyAndHeightShareRemainingNativeDeadline() async throws {
        let runtimes = TorTestRuntimes()
        let timeouts = OSAllocatedUnfairLock(initialState: [UInt64]())
        let envelope = NativeKeyEnvelope()
        var native = TorHTTPGetNative(
            freeResponse: { _ in envelope.free() },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) }
        )
        native.classifiedGet = { _, _, _, _, _, _, timeout, outcome in
            timeouts.withLock { $0.append(timeout) }
            Thread.sleep(forTimeInterval: 0.06)
            outcome?.pointee = FfiTorHttpOutcome(kind: 0, http_status: 200, retry_not_before_ns: 0)
            return envelope.pointer
        }
        native.postOnce = { _, _, _, _, _, _, _, timeout, outcome in
            timeouts.withLock { $0.append(timeout) }
            outcome?.pointee = FfiTorHttpOutcome(kind: 5, http_status: 0, retry_not_before_ns: 0)
            return nil
        }
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: try __torDirURL(), httpGetNative: native)
        let submitter = makeOHTTPSubmitter(tor: tor)
        let gateway = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true, singleCallTimeoutInMillis: 180)
        do {
            try await submitter.submit(transaction: transaction(), to: gateway)
            XCTFail("The height request is deliberately rejected")
        } catch {}
        let observed = timeouts.withLock { $0 }
        XCTAssertEqual(observed.count, 2, "Key GET and height POST must use the bounded production sender")
        if observed.count == 2 {
            XCTAssertLessThanOrEqual(observed[0], 180)
            XCTAssertLessThanOrEqual(observed[1], 120, "Key fetch time must be deducted before the height POST")
            XCTAssertGreaterThan(observed[1], 0)
        }
        try await tor.close()
    }

    func testProductionOHTTPTorCancellationDrainsActiveNativeKeyFetch() async throws {
        let runtimes = TorTestRuntimes()
        let entered = expectation(description: "native key GET entered")
        let exited = OSAllocatedUnfairLock(initialState: false)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var native = TorHTTPGetNative(
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) }
        )
        native.classifiedGet = { _, _, _, _, _, _, timeout, outcome in
            XCTAssertLessThanOrEqual(timeout, 500)
            entered.fulfill()
            _ = release.wait(timeout: .now() + .milliseconds(Int(timeout)))
            exited.withLock { $0 = true }
            outcome?.pointee = FfiTorHttpOutcome(kind: 5, http_status: 0, retry_not_before_ns: 0)
            return nil
        }
        native.postOnce = { _, _, _, _, _, _, _, _, _ in
            XCTFail("Cancelled key work cannot proceed to a POST")
            return nil
        }
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: try __torDirURL(), httpGetNative: native)
        let submitter = makeOHTTPSubmitter(tor: tor)
        let gateway = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true, singleCallTimeoutInMillis: 500)
        let task = Task {
            defer { returned.withLock { $0 = true } }
            try? await submitter.submit(transaction: transaction(), to: gateway)
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        XCTAssertFalse(returned.withLock { $0 }, "Native owner must remain admitted until it exits")
        release.signal()
        await task.value
        XCTAssertTrue(exited.withLock { $0 })
        try await tor.close()
    }

    private func makeOHTTPSubmitter(tor: TorClient) -> GRPCEndpointSubmitter {
        let flags = SDKFlags(torEnabled: true, exchangeRateEnabled: false)
        let backend = ZcashRustBackendWeldingMock()
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        return GRPCEndpointSubmitter(
            torClient: tor, sdkFlags: flags, rustBackend: backend, logger: NullLogger(), networkType: .testnet,
            serviceFactory: { endpoint, isolated in
                let service = LightWalletOHTTPService(endpoint: endpoint, tor: isolated)
                service.sdkFlags = flags
                service.walletNetwork = .testnet
                service.testKeyVerifier = OHTTPTestSupport.makeKeyVerifier()
                return service
            }
        )
    }

    private final class NativeKeyEnvelope: @unchecked Sendable {
        let pointer = UnsafeMutablePointer<FfiHttpResponseBytes>.allocate(capacity: 1)
        let body: UnsafeMutablePointer<UInt8>
        let headers = UnsafeMutablePointer<FfiHttpResponseHeader>.allocate(capacity: 1)
        let version = strdup("HTTP/1.1")!
        init() {
            let bytes = OHTTPTestSupport.stubEnvelope
            body = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            _ = bytes.copyBytes(to: UnsafeMutableBufferPointer(start: body, count: bytes.count))
            pointer.initialize(to: FfiHttpResponseBytes(status: 200, version: version, headers_ptr: headers, headers_len: 0,
                                                       body_ptr: body, body_len: UInt(bytes.count)))
        }
        func free() {
            pointer.deallocate()
            headers.deallocate()
            body.deallocate()
            Darwin.free(version)
        }
    }

    func testDirectAdmissionHeightSendAndKnownLookupShareOneDeadline() async throws {
        let server = try DelayedSubmissionServer(sendResponse: SendResponse.with { $0.errorCode = -1 })
        defer { try? server.stop() }
        let backend = ZcashRustBackendWeldingMock()
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        let tor = TorClient(torDir: try __torDirURL())
        let flags = SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        let submitter = GRPCEndpointSubmitter(
            torClient: tor, sdkFlags: flags, rustBackend: backend, logger: NullLogger(), networkType: .testnet,
            serviceFactory: { endpoint, tor in
                Thread.sleep(forTimeInterval: 0.06)
                let service = LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: tor)
                service.sdkFlags = flags
                return service
            }
        )
        let endpoint = LightWalletEndpoint(address: server.endpoint.host, port: server.endpoint.port, secure: false,
                                           singleCallTimeoutInMillis: 400)
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await submitter.submit(transaction: transaction(), to: endpoint)
            XCTFail("The delayed known-transaction reply is outside the original attempt budget")
        } catch {}
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertLessThan(elapsed, 650_000_000, "Admission and both earlier RPCs must reduce the known-lookup deadline")
        XCTAssertEqual(server.stages.withLock { $0 }, ["height", "send", "known"])
    }

    private final class DelayedSubmissionServer: HeightReportingLightwalletd {
        let stages = OSAllocatedUnfairLock(initialState: [String]())
        override func getLatestBlock(request: ChainSpec, context: StatusOnlyCallContext) -> EventLoopFuture<BlockID> {
            stages.withLock { $0.append("height") }
            return context.eventLoop.scheduleTask(in: .milliseconds(80)) { BlockID(height: 100_000) }.futureResult
        }
        override func sendTransaction(request: RawTransaction, context: StatusOnlyCallContext) -> EventLoopFuture<SendResponse> {
            stages.withLock { $0.append("send") }
            return context.eventLoop.scheduleTask(in: .milliseconds(80)) { SendResponse.with { $0.errorCode = -1 } }.futureResult
        }
        override func getTransaction(request: TxFilter, context: StatusOnlyCallContext) -> EventLoopFuture<RawTransaction> {
            stages.withLock { $0.append("known") }
            return context.eventLoop.scheduleTask(in: .milliseconds(500)) {
                RawTransaction.with { $0.height = 100_000 }
            }.futureResult
        }
    }

    func testProductionPublicTorConnectorUsesRemainingBudgetAndDrainsOnCancellation() async throws {
        let runtimes = TorTestRuntimes()
        let entered = expectation(description: "bounded Tor gRPC connector entered")
        let exited = OSAllocatedUnfairLock(initialState: false)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var native = TorHTTPGetNative(
            isolateRuntime: {
                Thread.sleep(forTimeInterval: 0.05)
                return runtimes.clone($0)
            },
            freeRuntime: { runtimes.free($0) },
            connectLightwalletd: { _, _ in
                XCTFail("Submission must not enter the ordinary unbounded connector")
                return nil
            }
        )
        native.connectLightwalletdWithTimeout = { _, _, timeout in
            calls.withLock { $0 += 1 }
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, 150, "Runtime admission must consume the original 200 ms budget")
            entered.fulfill()
            _ = release.wait(timeout: .now() + .milliseconds(Int(timeout)))
            exited.withLock { $0 = true }
            return nil
        }
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: try __torDirURL(), httpGetNative: native)
        let backend = ZcashRustBackendWeldingMock()
        let submitter = GRPCEndpointSubmitter(
            torClient: tor, sdkFlags: SDKFlags(torEnabled: true, exchangeRateEnabled: false),
            rustBackend: backend, logger: NullLogger(), networkType: .testnet
        )
        let task = Task {
            defer { returned.withLock { $0 = true } }
            try? await submitter.submit(transaction: transaction(), to: endpoint(milliseconds: 200))
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        XCTAssertFalse(returned.withLock { $0 })
        release.signal()
        await task.value
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertTrue(exited.withLock { $0 })
        try await tor.close()
    }

    private func endpoint(milliseconds: Int64) -> LightWalletEndpoint {
        LightWalletEndpoint(address: "budget.example.com", port: 443, secure: true, singleCallTimeoutInMillis: milliseconds)
    }

    private func transaction() -> CreatedTransaction {
        CreatedTransaction(txId: Data(repeating: 1, count: 32), raw: Data([5, 0, 0, 128, 1]), expiryHeight: 200_000)
    }

    private func makeSubmitter(service: LightWalletService) throws -> GRPCEndpointSubmitter {
        let backend = ZcashRustBackendWeldingMock()
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        return GRPCEndpointSubmitter(
            torClient: TorClient(torDir: try __torDirURL()),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false),
            rustBackend: backend,
            logger: NullLogger(),
            networkType: .testnet,
            serviceFactory: { _, _ in service }
        )
    }
}
