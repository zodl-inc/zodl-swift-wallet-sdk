import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class LegacyPrivateRetryRoutingTests: ZcashTestCase {
    private let txId = Data(repeating: 0x51, count: 32)

    func testInitialCustomBudgetReachesLegacyHeightAndSend() async throws {
        let endpoint = LightWalletEndpoint(address: "public.example.com", port: 443, singleCallTimeoutInMillis: 750)
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory, endpoint: endpoint)
        let action = try await retryAction(fixture)
        configureLegacySend(fixture, maximumBudget: 750)
        try await retry(action)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
        try await fixture.cleanup()
    }

    func testSuccessfulSwitchRebindsLegacyBudget() async throws {
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory)
        let action = try await retryAction(fixture)
        await configureValidation(fixture)
        let endpoint = LightWalletEndpoint(address: "manual.example.com", port: 443, singleCallTimeoutInMillis: 0)
        try await fixture.synchronizer.switchTo(endpoint: endpoint)
        configureLegacySend(fixture, maximumBudget: 1)
        try await retry(action)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        try await fixture.cleanup()
    }

    func testFailedSwitchRetainsPreviousLegacyBudgetAndService() async throws {
        let oldEndpoint = LightWalletEndpoint(address: "manual.example.com", port: 443, singleCallTimeoutInMillis: 0)
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory, endpoint: oldEndpoint)
        let action = try await retryAction(fixture)
        await fixture.synchronizer.updateStatus(.unprepared)
        // A non-singleton override leaves the normal factory observable after validation.
        fixture.container.mock(type: LightWalletService.self, isSingleton: false) { _ in fixture.service }
        fixture.service.getInfoModeThrowableError = URLError(.cannotConnectToHost)
        do {
            try await fixture.synchronizer.switchTo(endpoint: LightWalletEndpoint(address: "other.example.com", port: 443))
            XCTFail("Validation must fail")
        } catch { XCTAssertEqual((error as? ZcashError)?.code, .synchronizerServerSwitch) }
        // Check the production factory too, without the fixture's validation override.
        fixture.container.isTestEnvironment = false
        let restoredService = fixture.container.resolve(LightWalletService.self)
        fixture.container.isTestEnvironment = true
        XCTAssertTrue((restoredService as AnyObject) === fixture.service)
        configureLegacySend(fixture, maximumBudget: 1)
        try await retry(action)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        try await fixture.cleanup()
    }

    func testSuccessfulPrivateSwitchOverridesPublicHistoryAndFailedSwitchKeepsGateway() async throws {
        let submitter = EndpointSubmitterMock()
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory, endpointSubmitter: submitter)
        let action = try await retryAction(fixture)
        let store = action.resubmitter.submitPlanStore
        let recorded = LightWalletEndpoint(address: "public.example.com", port: 443)
        await store.recordPlan(txId: txId, endpoints: [recorded])
        await configureValidation(fixture)
        let gateway = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443)
        try await fixture.synchronizer.switchTo(endpoint: gateway)
        fixture.service.getInfoModeThrowableError = URLError(.cannotConnectToHost)
        do {
            try await fixture.synchronizer.switchTo(endpoint: recorded)
            XCTFail("Validation must fail")
        } catch { XCTAssertEqual((error as? ZcashError)?.code, .synchronizerServerSwitch) }
        try await retry(action)
        XCTAssertEqual(submitter.recordedSubmissions(), [gateway])
        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .ready([recorded], acceptedBy: "\(gateway.host):443"))
        try await fixture.cleanup()
    }

    func testSwitchWaitsForEarlierPublicRetryToDrain() async throws {
        let recorded = LightWalletEndpoint(address: "public.example.com", port: 443)
        let submitter = EndpointSubmitterMock()
        let gate = Gate()
        defer { gate.open() }
        submitter.set(behavior: .gated(gate, then: .succeed), for: recorded)
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory, endpointSubmitter: submitter)
        let action = try await retryAction(fixture)
        await action.resubmitter.submitPlanStore.recordPlan(txId: txId, endpoints: [recorded])
        await configureValidation(fixture)
        let processor = fixture.synchronizer.blockProcessor
        action.latestResolvedTime = 0
        await processor.updateEventClosure(identifier: "retry") { event in
            if case .startedSyncing = event {
                await processor.context.update(syncControlData: SyncControlData(
                    latestBlockHeight: 100_000,
                    latestScannedHeight: nil,
                    firstUnenhancedHeight: nil
                ))
                await processor.context.update(state: .txResubmission)
            }
        }
        await processor.start()
        await submitter.awaitSubmissionStarted(to: recorded)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let finished = expectation(description: "switch cannot finish before retry releases")
        finished.isInverted = true
        let switching = Task {
            defer {
                completed.withLock { $0 = true }
                finished.fulfill()
            }
            try await fixture.synchronizer.switchTo(endpoint: LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443))
        }
        await fulfillment(of: [finished], timeout: 0.1)
        XCTAssertFalse(completed.withLock { $0 })
        gate.open()
        _ = try? await switching.value
        XCTAssertTrue(completed.withLock { $0 })
        try await fixture.cleanup()
    }

    private func retryAction(_ fixture: ClassicProcessorCleanupFixture) async throws -> TxResubmissionAction {
        await fixture.synchronizer.stopAndWait()
        let processor = fixture.synchronizer.blockProcessor
        // Inspect only while stopped; no production-only test accessors are needed.
        let actions = try XCTUnwrap(Mirror(reflecting: processor).children.first { $0.label == "actions" }?.value as? [CBPState: Action])
        let action = try XCTUnwrap(actions[.txResubmission] as? TxResubmissionAction)
        let candidate = CreatedTransactionTests.makeTransaction(raw: Data([1, 2, 3]), rawID: txId)
        fixture.repository.findForResubmissionUpToClosure = { _ in [candidate] }
        fixture.repository.findRawIDClosure = { _ in candidate }
        return action
    }

    private func configureLegacySend(_ fixture: ClassicProcessorCleanupFixture, maximumBudget: UInt64) {
        fixture.service.latestBlockHeightModeClosure = { _ in
            let remaining = try XCTUnwrap(SubmissionBudget.current).remainingMilliseconds()
            XCTAssertLessThanOrEqual(remaining, maximumBudget)
            return 3_000_010
        }
        fixture.backend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        fixture.service.submitSpendTransactionModeReturnValue = SendResponse()
    }

    private func configureValidation(_ fixture: ClassicProcessorCleanupFixture) async {
        await fixture.synchronizer.updateStatus(.unprepared)
        let config = await fixture.synchronizer.blockProcessor.config
        var info = LightdInfo()
        info.chainName = "test"
        info.saplingActivationHeight = UInt64(config.saplingActivation)
        info.blockHeight = 2_000_000
        info.consensusBranchID = "c2d6d0b4"
        fixture.backend.consensusBranchIdForHeightReturnValue = Int32(bitPattern: 0xc2d6d0b4)
        fixture.service.getInfoModeReturnValue = info
    }

    private func retry(_ action: TxResubmissionAction) async throws {
        action.latestResolvedTime = 0
        let context = ActionContextMock.default()
        context.prevState = .enhance
        context.underlyingSyncControlData = SyncControlData(latestBlockHeight: 100_000, latestScannedHeight: nil, firstUnenhancedHeight: nil)
        _ = try await action.run(with: context) { _ in }
    }
}
