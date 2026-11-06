import XCTest
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthBindingTests: XCTestCase {
    private let endpoint = LightWalletEndpoint(address: "health.test", port: 443, secure: true)

    private func candidate(_ binding: OHTTPHealthBinding, token: UUID? = nil) throws -> OHTTPHealthSession {
        try OHTTPHealthSession(
            route: OHTTPHealthRoute(network: .testnet, gatewayHost: UUID().uuidString, relayURL: "https://relay.test", viaTor: false),
            generation: UUID(),
            bindingID: token ?? binding.readyToken(),
            ownerID: binding.ownerID
        )
    }

    func testRetainedBindingPublicationAndSubscriberCancellation() async throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let first = binding.snapshot()
        var updates = binding.updates().makeAsyncIterator()
        let retained = await updates.next()
        XCTAssertEqual(retained, first)
        let cancelled = Task { for await _ in binding.updates() { } }
        cancelled.cancel()
        await cancelled.value
        let transition = binding.beginTransition()
        binding.settle(transition: transition, endpoint: endpoint)
        let newest = await updates.next()
        XCTAssertEqual(newest, binding.snapshot())
        XCTAssertEqual(newest?.phase, .ready)
        XCTAssertNotEqual(newest?.bindingID, first.bindingID)
        XCTAssertEqual(newest?.continuityID, first.continuityID)
        binding.retire()
    }

    func testBeginClosesDeliveryBeforeReturningWithoutConsumerProgress() async throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let session = try candidate(binding)
        try binding.admit(session)
        var updates = session.updates().makeAsyncIterator()
        for _ in 0..<64 {
            let operation = OHTTPHealthOperation()
            await OHTTPHealthContext.withOperation(operation) {
                _ = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
            }
            await OHTTPHealthContext.complete(operation, failed: true)
        }
        let operation = OHTTPHealthOperation()
        await OHTTPHealthContext.withOperation(operation) {
            _ = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd)
        }
        let entered = expectation(description: "publisher entered")
        let released = expectation(description: "publisher released")
        let premature = expectation(description: "publisher stays blocked")
        premature.isInverted = true
        let publisher = Task {
            entered.fulfill()
            await OHTTPHealthContext.complete(operation, failed: true)
            premature.fulfill()
            released.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        await fulfillment(of: [premature], timeout: 0.05)
        _ = binding.beginTransition()
        XCTAssertFalse(session.isValid)
        let end = await updates.next()
        XCTAssertNil(end)
        await fulfillment(of: [released], timeout: 2)
        await publisher.value
        binding.retire()
    }

    func testStaleAdmissionClosesCandidate() throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let token = try binding.readyToken()
        let transition = binding.beginTransition()
        binding.settle(transition: transition, endpoint: endpoint)
        let stale = try candidate(binding, token: token)
        XCTAssertThrowsError(try binding.admit(stale)) { XCTAssertEqual($0 as? OHTTPHealthError, .bindingUnavailable) }
        XCTAssertFalse(stale.isValid)
        let current = try candidate(binding)
        try binding.admit(current)
        XCTAssertTrue(binding.accepts(current))
        binding.retire()
        XCTAssertFalse(current.isValid)
    }

    func testStaleSettlementCannotReviveOwner() throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let old = binding.beginTransition()
        let current = binding.beginTransition()
        binding.settle(transition: old, endpoint: endpoint)
        XCTAssertEqual(binding.snapshot().phase, .replacing)
        XCTAssertThrowsError(try binding.readyToken())
        binding.retire()
        binding.settle(transition: current, endpoint: endpoint)
        XCTAssertEqual(binding.snapshot().phase, .unavailable)
    }

    func testContinuityChangesOnlyForWalletOrActualEndpoint() {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let original = binding.snapshot()
        var transition = binding.beginTransition()
        binding.settle(transition: transition, endpoint: endpoint)
        XCTAssertEqual(binding.snapshot().continuityID, original.continuityID)
        for endpoint in [
            LightWalletEndpoint(address: "health.test", port: 80, secure: true),
            LightWalletEndpoint(address: "health.test", port: 80, secure: false)
        ] {
            let previous = binding.snapshot()
            transition = binding.beginTransition()
            binding.settle(transition: transition, endpoint: endpoint)
            XCTAssertNotEqual(binding.snapshot().continuityID, previous.continuityID)
        }
        let previous = binding.snapshot()
        transition = binding.beginTransition(walletReset: true)
        binding.settle(transition: transition, endpoint: LightWalletEndpoint(address: "health.test", port: 80, secure: false))
        XCTAssertNotEqual(binding.snapshot().continuityID, previous.continuityID)
        binding.retire()
    }
    func testBeginJoinsConcurrentCloseBeforeReplacingResources() async throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let entered = expectation(description: "first close holds native fence")
        let firstFinished = expectation(description: "first close finished")
        let transitionFinished = expectation(description: "transition finished")
        let premature = expectation(description: "replacement waits for native fence")
        premature.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let session = try OHTTPHealthSession(
            route: OHTTPHealthRoute(network: .testnet, gatewayHost: UUID().uuidString, relayURL: "https://relay.test", viaTor: false),
            generation: UUID(),
            bindingID: binding.readyToken(),
            ownerID: binding.ownerID,
            closeNative: { native in
                let first = calls.withLock { count in
                    count += 1
                    return count == 1
                }
                if first {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                native.close()
            }
        )
        try binding.admit(session)
        defer { release.signal() }
        DispatchQueue.global().async {
            session.close()
            firstFinished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(session.isValid)
        DispatchQueue.global().async {
            _ = binding.beginTransition()
            premature.fulfill()
            transitionFinished.fulfill()
        }
        await fulfillment(of: [premature], timeout: 0.05)
        release.signal()
        await fulfillment(of: [firstFinished, transitionFinished], timeout: 2)
        session.close()
        binding.retire()
        XCTAssertEqual(calls.withLock { $0 }, 1, "Native teardown has one owner and every close joins it")
    }

    func testOverlappingTransitionsJoinSessionRetirement() async throws {
        let binding = OHTTPHealthBinding(endpoint: endpoint)
        let entered = expectation(description: "first close holds native fence")
        let firstFinished = expectation(description: "first close finished")
        let transitionFinished = expectation(description: "transition finished")
        let premature = expectation(description: "replacement waits for native fence")
        premature.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let session = try OHTTPHealthSession(
            route: OHTTPHealthRoute(network: .testnet, gatewayHost: UUID().uuidString, relayURL: "https://relay.test", viaTor: false),
            generation: UUID(),
            bindingID: binding.readyToken(),
            ownerID: binding.ownerID,
            closeNative: { native in
                let first = calls.withLock { count in
                    count += 1
                    return count == 1
                }
                if first {
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                native.close()
            }
        )
        try binding.admit(session)
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = binding.beginTransition()
            firstFinished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(session.isValid)
        DispatchQueue.global().async {
            _ = binding.beginTransition()
            premature.fulfill()
            transitionFinished.fulfill()
        }
        await fulfillment(of: [premature], timeout: 0.05)
        release.signal()
        await fulfillment(of: [firstFinished, transitionFinished], timeout: 2)
        session.close()
        binding.retire()
        XCTAssertEqual(calls.withLock { $0 }, 1, "Native teardown has one owner and every close joins it")
    }
}
