import Combine
import XCTest

@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardCleanupTests: ZcashTestCase {
    func testCleanupWaitsForGiftSlipstreamStartToFinish() async throws {
        try await assertCleanupWaitsForActivePass(.starting)
    }

    func testCleanupWaitsForActiveGiftSlipstreamToStopQuiescently() async throws {
        try await assertCleanupWaitsForActivePass(.syncing)
    }

    private enum ActivePassPhase: Equatable {
        case starting
        case syncing
    }

    private func assertCleanupWaitsForActivePass(_ phase: ActivePassPhase) async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing
        )
        defer {
            fixture.engine.startGate.open()
            fixture.engine.stopGate.open()
        }
        fixture.repository.findForResubmissionUpToReturnValue = []
        await fixture.engine.setSnapshotOnStart(SlipstreamSnapshot.testSyncing(progressPermille: 100, chainTip: 3_000_010))
        let entered = XCTestExpectation(description: "gift Slipstream reached active \(phase) phase")
        switch phase {
        case .starting:
            fixture.engine.startGate.close()
            await fixture.engine.onCall("start") { entered.fulfill() }
        case .syncing:
            fixture.engine.stopGate.close()
            await fixture.engine.onCall("start:done") { entered.fulfill() }
        }
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("active-pass-marker")
        let check = Task { try await fixture.redeemer.check() }
        defer { check.cancel() }
        await fulfillment(of: [entered], timeout: 5)
        try Data([1]).write(to: marker)
        let stopEntered = XCTestExpectation(description: "gift cleanup reached engine stop")
        if phase == .syncing {
            await fixture.engine.onCall("stopForWalletChange") { stopEntered.fulfill() }
        }
        let deadline = clock.expectSleep(at: 30_000_000_000)
        let cleanup = startCleanup(fixture.redeemer)
        if phase == .syncing {
            await fulfillment(of: [stopEntered, deadline], timeout: 5)
        } else {
            await fulfillment(of: [deadline], timeout: 5)
        }
        clock.advance(to: 30_000_000_000)
        do {
            try await cleanup.value
            XCTFail("Cleanup must wait for the active pass beyond this caller's budget")
        } catch {
            XCTAssertEqual(error as? ZcashError, .giftCardCleanupTimedOut)
        }
        let callsBeforeRelease = await fixture.engine.calls
        XCTAssertFalse(callsBeforeRelease.contains("close"))
        if phase == .starting {
            XCTAssertFalse(callsBeforeRelease.contains(where: GatedFakeSlipstreamEngine.isStop))
        } else {
            XCTAssertFalse(callsBeforeRelease.contains { $0 == "stop:done" || $0 == "stopForWalletChange:done" })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: fixture.card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)

        fixture.engine.startGate.open()
        fixture.engine.stopGate.open()
        _ = try? await check.value
        try await waitForRelease(card: fixture.card)
        try await fixture.redeemer.cleanup()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.filter { $0 == "stopForWalletChange" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let replacement = try makeReplacement(card: fixture.card)
        withExtendedLifetime(replacement) {}
    }

    func testCleanupJoinsCancelledBackgroundResubmissionBeforeClosingWallet() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let gate = GiftCardCleanupTestGate()
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing
        )
        let reading = XCTestExpectation(description: "background resubmission entered repository read")
        let cancelled = XCTestExpectation(description: "wipe cancelled background resubmission")
        fixture.repository.findForResubmissionUpToClosure = { _ in
            await withTaskCancellationHandler {
                reading.fulfill()
                await gate.wait()
                return []
            } onCancel: {
                cancelled.fulfill()
            }
        }

        do {
            _ = try await fixture.redeemer.check()
            let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
            let marker = root.appendingPathComponent("resubmission-marker")
            try Data([1]).write(to: marker)
            await fulfillment(of: [reading], timeout: 5)
            let cleanup = startCleanup(fixture.redeemer)
            await fulfillment(of: [cancelled, clock.expectSleep(at: 30_000_000_000)], timeout: 5)
            clock.advance(to: 30_000_000_000)
            do {
                try await cleanup.value
                XCTFail("The caller budget must expire while the owned wipe waits for resubmission")
            } catch {
                XCTAssertEqual(error as? ZcashError, .giftCardCleanupTimedOut)
            }

            let callsDuringRead = await fixture.engine.calls
            XCTAssertFalse(callsDuringRead.contains(where: GatedFakeSlipstreamEngine.isStop))
            XCTAssertFalse(callsDuringRead.contains("close"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            assertAlreadyActive(card: fixture.card)
            XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)

            await gate.open()
            try await waitForRelease(card: fixture.card)
            try await fixture.redeemer.cleanup()
            let calls = await fixture.engine.calls
            XCTAssertEqual(calls.filter { $0 == "stopForWalletChange" }.count, 1)
            XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
            XCTAssertEqual(fixture.repository.findForResubmissionUpToCallsCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            let replacement = try makeReplacement(card: fixture.card)
            withExtendedLifetime(replacement) {}
        } catch {
            await gate.open()
            throw error
        }
    }

    func testNonQuiescentCleanupProtectsWalletAndAlias() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("wallet-marker")
        try Data([1]).write(to: marker)
        fixture.engine.stopReport = .passStillRunning
        do {
            try await fixture.redeemer.cleanup()
            XCTFail("A refused wipe must propagate its error")
        } catch {
            XCTAssertEqual((error as? ZcashError)?.code, .slipstreamEngineNotQuiescent)
        }
        let isOpen = await fixture.engine.isOpen
        XCTAssertTrue(isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try makeReplacement(card: fixture.card)) { error in
            XCTAssertEqual(error as? ZcashError, .giftCardRedeemerAlreadyActive)
        }
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        fixture.engine.stopReport = .quiescent
        try await fixture.redeemer.cleanup()
    }

    func testCancelledCleanupCallerLeavesOwnedTeardownAndCanDropRedeemer() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing
        )
        let card = try XCTUnwrap(fixture).card
        _ = try await fixture?.redeemer.check()
        let engine = try XCTUnwrap(fixture).engine
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("owned-marker")
        try Data([1]).write(to: marker)
        engine.stopGate.close()
        let entered = XCTestExpectation(description: "wipe reached stop")
        await engine.onCall("stopForWalletChange") { entered.fulfill() }
        let cleanup = startCleanup(try XCTUnwrap(fixture).redeemer)
        await fulfillment(of: [entered], timeout: 5)
        cleanup.cancel()
        let returned = XCTestExpectation(description: "cancelled waiter returned")
        let observer = Task {
            _ = try? await cleanup.value
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        weak var old = fixture?.redeemer
        fixture = nil
        XCTAssertNil(old, "The coordinator must own teardown without retaining the redeemer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        engine.stopGate.open()
        _ = await observer.value
        do {
            try await cleanup.value
            XCTFail("Cancellation must detach only this cleanup waiter")
        } catch is CancellationError {
        }
        try await waitForRelease(card: card)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnusedCancelledCleanupRetainsOwnershipAfterRedeemerIsDropped() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("Unused cleanup must not send traffic")
                return nil
            },
            isolateRuntime: { _ in
                XCTFail("Unused cleanup must not isolate a runtime")
                return nil
            },
            freeRuntime: { _ in XCTFail("Unused cleanup must not free a runtime it never opened") },
            createRuntime: { _, _ in
                XCTFail("Unused cleanup must not create a runtime")
                return nil
            }
        )
        let tor = TorClient(torDir: testTempDirectory.appendingPathComponent("unused-card-tor"), httpGetNative: native)
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing,
            torClient: tor
        )
        let card = try XCTUnwrap(fixture).card
        let engine = try XCTUnwrap(fixture).engine
        let service = try XCTUnwrap(fixture).service
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("unused-wallet-marker")
        try Data([1]).write(to: marker)
        engine.stopGate.close()
        let entered = XCTestExpectation(description: "unused wallet wipe reached stop")
        await engine.onCall("stopForWalletChange") { entered.fulfill() }
        let cleanup = startCleanup(try XCTUnwrap(fixture).redeemer)
        await fulfillment(of: [entered], timeout: 5)
        cleanup.cancel()
        do {
            try await cleanup.value
            XCTFail("Cancellation must detach the unused redeemer's waiter")
        } catch is CancellationError {
        }
        weak var old = fixture?.redeemer
        fixture = nil
        XCTAssertNil(old)
        assertAlreadyActive(card: card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        engine.stopGate.open()
        try await waitForRelease(card: card)
        let replacement = try makeReplacement(card: card)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacementMarker = root.appendingPathComponent("replacement-marker")
        try Data([2]).write(to: replacementMarker)
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
        XCTAssertEqual(service.closeConnectionsCallsCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testTempDirectory.appendingPathComponent("unused-card-tor").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementMarker.path))
        assertAlreadyActive(card: card)
        withExtendedLifetime(replacement) {}
    }

    func testCleanupTimeoutIncludesQueuedWorkAndLateSuccessReleasesOwnership() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, cleanupTiming: clock.timing)
        _ = try await fixture.redeemer.check()
        let proposalEntered = XCTestExpectation(description: "predecessor entered proposal")
        let gate = GiftCardCleanupTestGate()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
            proposalEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]).inner
        }
        let predecessor = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [proposalEntered], timeout: 5)
        let cleanup = startCleanup(fixture.redeemer)
        await fulfillment(of: [clock.expectSleep(at: 30_000_000_000)], timeout: 5)
        do {
            _ = try await fixture.redeemer.check()
            XCTFail("Cleanup must immediately close admission")
        } catch ZcashError.giftCardRedeemerCleanedUp {
        }
        clock.advance(to: 30_000_000_000)
        let returned = XCTestExpectation(description: "timed-out waiter returned")
        let observer = Task {
            _ = try? await cleanup.value
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        assertAlreadyActive(card: fixture.card)
        let callsBeforeJoin = await fixture.engine.calls
        XCTAssertFalse(callsBeforeJoin.contains("close"))
        await gate.open()
        _ = try? await predecessor.value
        _ = await observer.value
        do {
            try await cleanup.value
            XCTFail("The caller budget includes time behind the predecessor")
        } catch {
            XCTAssertEqual(error as? ZcashError, .giftCardCleanupTimedOut)
        }
        try await fixture.redeemer.cleanup()
        let replacement = try makeReplacement(card: fixture.card)
        withExtendedLifetime(replacement) {}
    }

    func testCleanupAdmissionBudgetCountsCancellationCallbacks() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, cleanupTiming: clock.timing)
        _ = try await fixture.redeemer.check()
        let entered = XCTestExpectation(description: "predecessor installed cancellation callback")
        let cancelled = XCTestExpectation(description: "cancellation callback consumed twenty seconds")
        let gate = GiftCardCleanupTestGate()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
            await withTaskCancellationHandler {
                entered.fulfill()
                await gate.wait()
                return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]).inner
            } onCancel: {
                clock.advance(to: 20_000_000_000)
                cancelled.fulfill()
            }
        }
        let predecessor = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [entered], timeout: 5)
        let cleanup = startCleanup(fixture.redeemer)
        await fulfillment(of: [cancelled, clock.expectSleep(at: 30_000_000_000)], timeout: 5)
        // Release both correct and incorrect deadline timers so a RED cannot strand the test.
        clock.advance(to: 50_000_000_000)
        do { try await cleanup.value } catch { XCTAssertEqual(error as? ZcashError, .giftCardCleanupTimedOut) }
        await gate.open()
        _ = try? await predecessor.value
        try await fixture.redeemer.cleanup()
    }

    func testAlreadyCancelledCleanupClosesAdmissionAndStillWipes() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let gate = GiftCardCleanupTestGate()
        let cleanup = Task {
            await gate.wait()
            try await fixture.redeemer.cleanup()
        }
        cleanup.cancel()
        await gate.open()
        do {
            try await cleanup.value
            XCTFail("An already-cancelled cleanup caller must get cancellation")
        } catch is CancellationError {
        }
        do {
            _ = try await fixture.redeemer.check()
            XCTFail("Cancelled cleanup must close admission")
        } catch ZcashError.giftCardRedeemerCleanedUp {
        }
        try await fixture.redeemer.cleanup()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
    }

    func testSimultaneousCleanupCallersAndOldDeinitPreserveReplacement() async throws {
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let card = try XCTUnwrap(fixture).card
        _ = try await fixture?.redeemer.check()
        let engine = try XCTUnwrap(fixture).engine
        engine.stopGate.close()
        let entered = XCTestExpectation(description: "owned wipe entered stop")
        await engine.onCall("stopForWalletChange") { entered.fulfill() }
        let first = startCleanup(try XCTUnwrap(fixture).redeemer)
        await fulfillment(of: [entered], timeout: 5)
        let second = startCleanup(try XCTUnwrap(fixture).redeemer)
        engine.stopGate.open()
        try await first.value
        try await second.value
        let replacement = try makeReplacement(card: card)
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("replacement-marker")
        try Data([1]).write(to: marker)
        try await fixture?.redeemer.cleanup()
        weak var old = fixture?.redeemer
        fixture = nil
        XCTAssertNil(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: card)
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
        withExtendedLifetime(replacement) {}
    }

    func testDroppedUsedRedeemerRetriesRefusedWipeBeforeRelease() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        var fixture: GiftCardCancellationFixture? = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing
        )
        let card = try XCTUnwrap(fixture).card
        _ = try await fixture?.redeemer.check()
        let engine = try XCTUnwrap(fixture).engine
        engine.stopReport = .passStillRunning
        weak var old = fixture?.redeemer
        fixture = nil
        XCTAssertNil(old)
        await fulfillment(of: [clock.expectSleep(at: 1_000_000_000)], timeout: 5)
        assertAlreadyActive(card: card)
        let open = await engine.isOpen
        XCTAssertTrue(open)
        engine.stopReport = .quiescent
        clock.advance(to: 1_000_000_000)
        try await waitForRelease(card: card)
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
    }

    func testStorageFailureAfterSafeWipeRetainsAliasAndRetriesOnlyRemoval() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, cleanupTiming: clock.timing)
        _ = try await fixture.redeemer.check()
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        try Data([1]).write(to: root.appendingPathComponent("marker"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: testTempDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTempDirectory.path) }
        do {
            try await fixture.redeemer.cleanup()
            XCTFail("Storage deletion errors must propagate")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        assertAlreadyActive(card: fixture.card)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let closed = await fixture.engine.isOpen
        XCTAssertFalse(closed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTempDirectory.path)
        try await fixture.redeemer.cleanup()
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.filter { $0 == "close" }.count, 1)
        let replacement = try makeReplacement(card: fixture.card)
        withExtendedLifetime(replacement) {}
    }

    func testInaccessibleWalletRootIsNotTreatedAsAbsent() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, cleanupTiming: clock.timing)
        _ = try await fixture.redeemer.check()
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("inaccessible-marker")
        try Data([1]).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: testTempDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTempDirectory.path) }
        do {
            try await fixture.redeemer.cleanup()
            XCTFail("An inaccessible root has not been proven absent or deleted")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        assertAlreadyActive(card: fixture.card)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testTempDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try await fixture.redeemer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let replacement = try makeReplacement(card: fixture.card)
        withExtendedLifetime(replacement) {}
    }

    func testServiceConnectionsCloseAfterSafeWipeBeforeHostRuntimeAndRootRemoval() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let serviceGate = GiftCardCleanupTestGate()
        defer { Task { await serviceGate.open() } }
        let runtimes = TorTestRuntimes()
        let card = try GiftCard(link: GiftCardTests.zodlTestnetLink)
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("tor-marker")
        let disposed = XCTestExpectation(description: "host runtime disposed")
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("Cleanup must not send traffic")
                return nil
            },
            isolateRuntime: { _ in
                XCTFail("Cleanup must not bootstrap or isolate a runtime")
                return nil
            },
            freeRuntime: { pointer in
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Host runtime disposal precedes root deletion")
                runtimes.free(pointer)
                disposed.fulfill()
            }
        )
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: root.appendingPathComponent("tor"), httpGetNative: native)
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing,
            torClient: tor
        )
        let serviceEntered = XCTestExpectation(description: "card service disposal entered after wipe")
        let engine = fixture.engine
        fixture.service.closeConnectionsClosure = {
            let calls = await engine.calls
            XCTAssertTrue(calls.contains("stopForWalletChange:done"))
            XCTAssertTrue(calls.contains("close"))
            serviceEntered.fulfill()
            await serviceGate.wait()
        }
        _ = try await fixture.redeemer.check()
        try Data([1]).write(to: marker)
        fixture.engine.stopReport = .passStillRunning
        do { try await fixture.redeemer.cleanup() } catch {}
        XCTAssertEqual(fixture.service.closeConnectionsCallsCount, 0, "Refused wipe must preserve service connections")
        XCTAssertTrue(runtimes.isAlive(runtimes.parent), "Refused wipe must preserve the host runtime")
        fixture.engine.stopReport = .quiescent
        let cleanup = startCleanup(fixture.redeemer)
        await fulfillment(of: [serviceEntered, clock.expectSleep(at: 30_000_000_000)], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(runtimes.isAlive(runtimes.parent))
        assertAlreadyActive(card: card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        let cancelled = startCleanup(fixture.redeemer)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancelling a waiter must leave service disposal owned")
        } catch is CancellationError {
        }
        clock.advance(to: 30_000_000_000)
        do {
            try await cleanup.value
            XCTFail("The cleanup waiter must time out while service disposal is held")
        } catch {
            XCTAssertEqual(error as? ZcashError, .giftCardCleanupTimedOut)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(runtimes.isAlive(runtimes.parent))
        assertAlreadyActive(card: card)
        await serviceGate.open()
        try await waitForRelease(card: card)
        try await fixture.redeemer.cleanup()
        await fulfillment(of: [disposed], timeout: 5)
        XCTAssertEqual(fixture.service.closeConnectionsCallsCount, 1)
        XCTAssertFalse(runtimes.isAlive(runtimes.parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCleanupDisposesActualCachedTorConnectionsBeforeFinalRuntimeAndRootRemoval() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let runtimes = TorTestRuntimes()
        let events = CleanupEvents()
        let card = try GiftCard(link: GiftCardTests.zodlTestnetLink)
        let root = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description)
        let marker = root.appendingPathComponent("cached-tor-owner")
        var native = TorHTTPGetNative()
        native.createRuntime = { _, _ in
            XCTFail("Gift cleanup must not create a runtime")
            return nil
        }
        native.isolateRuntime = { _ in
            XCTFail("Gift cleanup must not isolate a runtime")
            return nil
        }
        native.get = { _, _, _, _, _, _ in
            XCTFail("Gift cleanup must not send traffic")
            return nil
        }
        native.connectLightwalletd = { pointer, _ in
            XCTAssertTrue(runtimes.isAlive(pointer))
            if events.appendOnce("connect:default") { return OpaquePointer(bitPattern: 2) }
            events.append("connect:group")
            return OpaquePointer(bitPattern: 3)
        }
        native.freeLightwalletd = { pointer in
            XCTAssertTrue(events.events.contains("engine:close"), "Cache owners must survive until safe wipe")
            XCTAssertTrue(runtimes.isAlive(runtimes.parent), "Cache owners must be freed before the root runtime")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            if pointer == OpaquePointer(bitPattern: 2) {
                events.append("free:default")
            } else {
                XCTAssertEqual(pointer, OpaquePointer(bitPattern: 3))
                events.append("free:group")
            }
        }
        native.freeRuntime = { pointer in
            XCTAssertEqual(events.events.filter { $0 == "free:default" }.count, 1)
            XCTAssertEqual(events.events.filter { $0 == "free:group" }.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            events.append("free:runtime")
            runtimes.free(pointer)
        }
        let tor = TorClient(runtimePtr: runtimes.parent, torDir: root.appendingPathComponent("tor"), httpGetNative: native)
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cleanupTiming: clock.timing,
            torClient: tor
        )
        defer { fixture.engine.stopGate.open() }
        _ = try await fixture.redeemer.check()
        try Data([1]).write(to: marker)
        // Seed the real retained service caches without sending RPC traffic through synthetic pointers.
        let service = LightWalletGRPCServiceOverTor(endpoint: LightWalletEndpointBuilder.default, tor: tor)
        fixture.initializer.lightWalletService = service
        _ = try await service.serviceConnections.connectToLightwalletd(.defaultTor)
        _ = try await service.serviceConnections.connectToLightwalletd(.torInGroup("card-test"))
        _ = try await service.serviceConnections.connectToLightwalletd(.defaultTor)
        _ = try await service.serviceConnections.connectToLightwalletd(.torInGroup("card-test"))
        XCTAssertEqual(events.events, ["connect:default", "connect:group"])
        await fixture.engine.onCall("close") { events.append("engine:close") }

        fixture.engine.stopReport = .passStillRunning
        do {
            try await fixture.redeemer.cleanup()
            XCTFail("Refused wipe must retain the cached native owners")
        } catch {
            XCTAssertEqual((error as? ZcashError)?.code, .slipstreamEngineNotQuiescent)
        }
        XCTAssertEqual(events.events, ["connect:default", "connect:group"])
        XCTAssertTrue(runtimes.isAlive(runtimes.parent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        assertAlreadyActive(card: card)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)

        fixture.engine.stopReport = .quiescent
        fixture.engine.stopGate.close()
        let stopEntered = XCTestExpectation(description: "safe cleanup attempt reached engine stop")
        await fixture.engine.onCall("stopForWalletChange") { stopEntered.fulfill() }
        let cleanup = startCleanup(fixture.redeemer)
        await fulfillment(of: [stopEntered], timeout: 5)
        cleanup.cancel()
        do {
            try await cleanup.value
            XCTFail("Cancelled caller must detach from the owned cache teardown")
        } catch is CancellationError {
        }
        XCTAssertEqual(events.events, ["connect:default", "connect:group"])
        XCTAssertTrue(runtimes.isAlive(runtimes.parent))
        assertAlreadyActive(card: card)
        fixture.engine.stopGate.open()
        try await waitForRelease(card: card)
        try await fixture.redeemer.cleanup()
        XCTAssertEqual(Set(events.events), Set([
            "connect:default", "connect:group", "engine:close", "free:default", "free:group", "free:runtime"
        ]))
        XCTAssertEqual(events.events.count, 6)
        XCTAssertFalse(runtimes.isAlive(runtimes.parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let replacement = try makeReplacement(card: card)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacementMarker = root.appendingPathComponent("replacement-after-tor")
        try Data([2]).write(to: replacementMarker)
        try await fixture.redeemer.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementMarker.path))
        XCTAssertEqual(events.events.count, 6, "Repeated cleanup must not dispose an owner twice")
        withExtendedLifetime(replacement) {}
    }

    func testUnusedCleanupWithActualServiceCreatesNoRuntimeOrConnection() async throws {
        let events = CleanupEvents()
        var native = TorHTTPGetNative()
        native.createRuntime = { _, _ in
            events.append("create")
            return nil
        }
        native.connectLightwalletd = { _, _ in
            events.append("connect")
            return nil
        }
        native.isolateRuntime = { _ in
            events.append("isolate")
            return nil
        }
        native.get = { _, _, _, _, _, _ in
            events.append("get")
            return nil
        }
        native.freeRuntime = { _ in events.append("free:runtime") }
        native.freeLightwalletd = { _ in events.append("free:connection") }
        let torDirectory = testTempDirectory.appendingPathComponent("unused-native-tor")
        let tor = TorClient(torDir: torDirectory, httpGetNative: native)
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, torClient: tor)
        let service = LightWalletGRPCServiceOverTor(endpoint: LightWalletEndpointBuilder.default, tor: tor)
        fixture.initializer.lightWalletService = service
        try await fixture.redeemer.cleanup()
        try await fixture.redeemer.cleanup()
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: torDirectory.path))
    }

    private func startCleanup(_ redeemer: GiftCardRedeemer) -> Task<Void, Error> {
        Task { try await redeemer.cleanup() }
    }

    private func assertAlreadyActive(card: GiftCard) {
        XCTAssertThrowsError(try makeReplacement(card: card)) { error in
            XCTAssertEqual(error as? ZcashError, .giftCardRedeemerAlreadyActive)
        }
    }

    private func waitForRelease(card: GiftCard) async throws {
        let released = XCTestExpectation(description: "owner lease released")
        let poll = Task {
            let owner = UUID()
            while !Task.isCancelled {
                if GiftCardRedeemerRegistry.claim(card.synchronizerAlias, owner: owner) {
                    GiftCardRedeemerRegistry.release(card.synchronizerAlias, owner: owner)
                    released.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [released], timeout: 5)
        poll.cancel()
        await poll.value
    }

    private func makeReplacement(card: GiftCard) throws -> GiftCardRedeemer {
        try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
    }

    func testBridgeObservesSuccessCompletedBeforeSubscription() async throws {
        let subject = PassthroughSubject<Void, Error>()
        subject.send(completion: .finished)
        let finished = XCTestExpectation(description: "already completed publisher observed")
        let task = Task {
            defer { finished.fulfill() }
            try await GiftCardRedeemer.awaitCompletion(of: subject.eraseToAnyPublisher())
        }
        try await waitFor(finished)
        try await task.value
    }

    func testBridgeObservesFailureCompletedBeforeSubscription() async throws {
        let subject = PassthroughSubject<Void, Error>()
        subject.send(completion: .failure(CleanupTestError.wipeFailed))
        let finished = XCTestExpectation(description: "already failed publisher observed")
        let task = Task {
            defer { finished.fulfill() }
            try await GiftCardRedeemer.awaitCompletion(of: subject.eraseToAnyPublisher())
        }
        try await waitFor(finished)
        do {
            try await task.value
            XCTFail("The bridge must preserve terminal failure")
        } catch {
            XCTAssertEqual(error as? CleanupTestError, .wipeFailed)
        }
    }

    private func waitFor(_ expectation: XCTestExpectation) async throws {
        await fulfillment(of: [expectation], timeout: 5)
    }
}
private enum CleanupTestError: Error { case wipeFailed }
