//
//  VotingProvingIntentTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

private let intentNetworkId: UInt32 = 1
private let intentWalletId = "intent-test-wallet"
private let intentRoundId = String(format: "%02x", 0x0B) + String(repeating: "00", count: 31)
private let intentSnapshotHeight: UInt64 = 100
private let intentMatchingURL = "https://intent.example"

final class VotingProvingIntentTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
        dbPath = nil
        super.tearDown()
    }

    /// Every endpoint reports a match immediately — resolution never suspends on a gate.
    private struct ImmediatelyMatchingProbe: PirSnapshotProbing {
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            PirSnapshotProbeOutcome(url: url, status: .matching(height: expectedSnapshotHeight))
        }
    }

    /// What the prove entry observed: the boost count relative to the test's baseline, and the
    /// priority of the task that entered it.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var boostDelta: Int32?
        private var priority: TaskPriority?

        func record(boostDelta: Int32, priority: TaskPriority) {
            lock.lock()
            self.boostDelta = boostDelta
            self.priority = priority
            lock.unlock()
        }

        var values: (boostDelta: Int32?, priority: TaskPriority?) {
            lock.lock()
            defer { lock.unlock() }
            return (boostDelta, priority)
        }
    }

    /// Runs the proof from inside a utility-priority detached task and bridges back to the
    /// (`.high`-priority) XCTest task through a continuation rather than a task handle. Swift
    /// escalates a task's priority to match a higher-priority awaiter of its *task handle*
    /// (`.value`/`.result`); a continuation resume carries no such handle, so it does not
    /// propagate escalation back onto the detached task. That is what lets the speculative case
    /// below observe the un-escalated `.utility` priority `buildAndProveDelegation` actually used.
    private func observeProof(intent: VotingProvingIntent?) async throws -> Observation {
        let backend = try makeOpenVotingBackend()
        let params = try makeParams()
        let observation = Observation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) {
                do {
                    try await Self.runProof(backend: backend, params: params, intent: intent, observation: observation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return observation
    }

    /// The actual proof call and observation, static and given everything it needs as arguments so
    /// the detached task above needs no `self`.
    private static func runProof(
        backend: VotingRustBackend,
        params: VotingDelegationProofParams,
        intent: VotingProvingIntent?,
        observation: Observation
    ) async throws {
        let baseline = VotingRustBackend.interactiveProvingBoostCount()
        let entry: @Sendable (VotingDelegationProofParams, String, VotingPirLayout, (@Sendable (Double) -> Void)?) throws -> VotingDelegationProofResult = { [observation, baseline] _, _, _, _ in
            observation.record(
                boostDelta: VotingRustBackend.interactiveProvingBoostCount() - baseline,
                priority: Task.currentPriority
            )
            return Self.makeFixtureResult(tag: 0x0A)
        }
        if let intent {
            _ = try await backend.buildAndProveDelegation(
                params,
                pirEndpoints: [intentMatchingURL],
                expectedSnapshotHeight: intentSnapshotHeight,
                pirResolver: PirSnapshotResolver(probe: ImmediatelyMatchingProbe()),
                intent: intent,
                proveEntry: entry
            )
        } else {
            _ = try await backend.buildAndProveDelegation(
                params,
                pirEndpoints: [intentMatchingURL],
                expectedSnapshotHeight: intentSnapshotHeight,
                pirResolver: PirSnapshotResolver(probe: ImmediatelyMatchingProbe()),
                proveEntry: entry
            )
        }
    }

    func testSpeculativeIntentEntersTheProofWithoutTheBoostAtUtilityPriority() async throws {
        let observed = try await observeProof(intent: .speculative).values
        XCTAssertEqual(observed.boostDelta, 0)
        XCTAssertEqual(observed.priority, .utility)
    }

    func testInteractiveIntentHoldsTheBoostAtUserInitiatedPriority() async throws {
        let observed = try await observeProof(intent: .interactive).values
        XCTAssertEqual(observed.boostDelta, 1)
        XCTAssertEqual(observed.priority, .userInitiated)
    }

    func testDefaultIntentIsInteractive() async throws {
        let observed = try await observeProof(intent: nil).values
        XCTAssertEqual(observed.boostDelta, 1)
        XCTAssertEqual(observed.priority, .userInitiated)
    }

    func testBoostIsReleasedAfterTheProofReturns() async throws {
        let baseline = VotingRustBackend.interactiveProvingBoostCount()
        _ = try await observeProof(intent: .interactive)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), baseline)
    }

    // MARK: - Helpers

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingProvingIntentTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenVotingBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: intentNetworkId)
        try backend.setWalletId(intentWalletId)
        return backend
    }

    private func makeParams() throws -> VotingDelegationProofParams {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: intentNetworkId)
        return VotingDelegationProofParams(
            roundId: intentRoundId,
            bundleIndex: 0,
            notes: [],
            keys: VotingDelegationKeyInputs(
                fvk: [UInt8](repeating: 0x03, count: votingOrchardFvkByteCount),
                hotkeyStoredSecret: hotkey.storedSecret,
                seedFingerprint: [UInt8](repeating: 0x04, count: votingSeedFingerprintByteCount),
                accountIndex: 0,
                roundName: "intent-round"
            )
        )
    }

    private static func makeFixtureResult(tag: UInt8) -> VotingDelegationProofResult {
        VotingDelegationProofResult(
            proof: [UInt8](repeating: tag, count: 4),
            publicInputs: [[UInt8](repeating: tag, count: 4)],
            nfSigned: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            cmxNew: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            govNullifiers: [[UInt8](repeating: tag, count: votingFieldElementByteCount)],
            vanComm: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            randomizedKey: [UInt8](repeating: tag, count: votingRandomizedKeyByteCount)
        )
    }
}
