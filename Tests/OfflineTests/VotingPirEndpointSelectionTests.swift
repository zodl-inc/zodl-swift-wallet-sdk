//
//  VotingPirEndpointSelectionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class VotingPirEndpointSelectionTests: XCTestCase {
    private let endpointA = "https://a.invalid"
    private let endpointB = "https://b.invalid"
    private let snapshotHeight: BlockHeight = 100
    private let layout = VotingPirLayout(pirDepth: 32, tier0Layers: 8, tier1Layers: 4, polyLen: 2048)
    private var dbPaths: [String] = []

    override func tearDown() {
        dbPaths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        dbPaths = []
        super.tearDown()
    }

    func testPreferredMatchingEndpointReturnsWithoutProbingFallbacks() async throws {
        let recorder = RecordingPirSnapshotProbe(
            statuses: [
                endpointA: .matching(height: snapshotHeight),
                endpointB: .matching(height: snapshotHeight)
            ]
        )
        let resolver = PirSnapshotResolver(
            probe: recorder,
            matchingEndpointSelector: { $0.last }
        )

        let selected = try await resolver.resolve(
            endpoints: [endpointA, endpointB],
            expectedSnapshotHeight: snapshotHeight,
            preferredEndpoint: endpointA
        )

        let probedURLs = await recorder.probedURLs()
        XCTAssertEqual(selected, endpointA)
        XCTAssertEqual(probedURLs, [endpointA])
    }

    func testUnavailablePreferredEndpointFallsBackWithoutProbingItTwice() async throws {
        let recorder = RecordingPirSnapshotProbe(
            statuses: [
                endpointA: .unreachable(reason: "offline"),
                endpointB: .matching(height: snapshotHeight)
            ]
        )
        let resolver = PirSnapshotResolver(
            probe: recorder,
            matchingEndpointSelector: { $0.last }
        )

        let selected = try await resolver.resolve(
            endpoints: [endpointA, endpointB],
            expectedSnapshotHeight: snapshotHeight,
            preferredEndpoint: endpointA
        )

        let probedURLs = await recorder.probedURLs()
        XCTAssertEqual(selected, endpointB)
        XCTAssertEqual(probedURLs, [endpointA, endpointB])
    }

    func testFailedPreferredEndpointRemainsInNoMatchDiagnosticsInInputOrder() async throws {
        let recorder = RecordingPirSnapshotProbe(
            statuses: [
                endpointA: .mismatched(height: snapshotHeight - 1),
                endpointB: .unreachable(reason: "offline")
            ]
        )
        let resolver = PirSnapshotResolver(probe: recorder)

        do {
            _ = try await resolver.resolve(
                endpoints: [endpointB, endpointA, endpointA],
                expectedSnapshotHeight: snapshotHeight,
                preferredEndpoint: endpointA
            )
            XCTFail("expected noMatchingEndpoint")
        } catch PirSnapshotResolverError.noMatchingEndpoint(let expected, let details) {
            XCTAssertEqual(expected, snapshotHeight)
            XCTAssertEqual(details.map(\.url), [endpointB, endpointA, endpointA])
            XCTAssertEqual(details[0].status, .unreachable(reason: "offline"))
            XCTAssertEqual(details[1].status, .mismatched(height: snapshotHeight - 1))
            XCTAssertEqual(details[2].status, .mismatched(height: snapshotHeight - 1))
            let probedURLs = await recorder.probedURLs()
            XCTAssertEqual(probedURLs, [endpointA, endpointB])
        } catch {
            XCTFail("unexpected error: \(error.localizedDescription)")
        }
    }

    func testEmptyEndpointListRetainsExistingErrorWithPreferredEndpoint() async throws {
        let recorder = RecordingPirSnapshotProbe(statuses: [:])
        let resolver = PirSnapshotResolver(probe: recorder)

        do {
            _ = try await resolver.resolve(
                endpoints: [],
                expectedSnapshotHeight: snapshotHeight,
                preferredEndpoint: endpointA
            )
            XCTFail("expected noEndpointsConfigured")
        } catch PirSnapshotResolverError.noEndpointsConfigured {
            let probedURLs = await recorder.probedURLs()
            XCTAssertTrue(probedURLs.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error.localizedDescription)")
        }
    }

    func testPrecomputeAndProofReuseTheSameHealthyEndpoint() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA, endpointB])
        let resolver = PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last })
        let enteredURLs = LockedURLs()

        _ = try await precompute(backend: backend, resolver: resolver, enteredURLs: enteredURLs)
        await recorder.clearRecordedURLs()
        _ = try await prove(backend: backend, resolver: resolver, enteredURLs: enteredURLs)

        let proofProbes = await recorder.probedURLs()
        XCTAssertEqual(enteredURLs.values, [endpointB, endpointB])
        XCTAssertEqual(proofProbes, [endpointB])
    }

    func testBackendReplacesFailedPreferenceAndReusesTheFallback() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA, endpointB])
        let resolver = PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last })
        let enteredURLs = LockedURLs()

        _ = try await prove(backend: backend, resolver: resolver, enteredURLs: enteredURLs)
        await recorder.setStatus(.unreachable(reason: "offline"), for: endpointB)
        await recorder.clearRecordedURLs()
        _ = try await prove(backend: backend, resolver: resolver, enteredURLs: enteredURLs)
        var probedURLs = await recorder.probedURLs()
        XCTAssertEqual(enteredURLs.values, [endpointB, endpointA])
        XCTAssertEqual(probedURLs, [endpointB, endpointA])

        await recorder.clearRecordedURLs()
        _ = try await prove(backend: backend, resolver: resolver, enteredURLs: enteredURLs)
        probedURLs = await recorder.probedURLs()
        XCTAssertEqual(enteredURLs.last, endpointA)
        XCTAssertEqual(probedURLs, [endpointA])
    }

    func testRoundHeightLayoutAndEndpointListChangesInvalidatePreference() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA, endpointB])
        let enteredURLs = LockedURLs()

        _ = try await prove(
            backend: backend,
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointB)

        await recorder.clearRecordedURLs()
        _ = try await prove(
            backend: backend,
            roundId: roundId(0x22),
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.first }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointA)
        var probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)

        await recorder.clearRecordedURLs()
        _ = try await prove(
            backend: backend,
            roundId: roundId(0x22),
            height: UInt64(snapshotHeight + 1),
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointB)
        probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)

        await recorder.clearRecordedURLs()
        let otherLayout = VotingPirLayout(pirDepth: 32, tier0Layers: 7, tier1Layers: 5, polyLen: 2048)
        _ = try await prove(
            backend: backend,
            roundId: roundId(0x22),
            height: UInt64(snapshotHeight + 1),
            layout: otherLayout,
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.first }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointA)
        probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)

        await recorder.clearRecordedURLs()
        _ = try await prove(
            backend: backend,
            roundId: roundId(0x22),
            height: UInt64(snapshotHeight + 1),
            layout: otherLayout,
            endpoints: [endpointB, endpointA],
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.first }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointB)
        probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)
    }

    func testWalletAndOpenHandleChangesInvalidatePreference() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA, endpointB])
        let enteredURLs = LockedURLs()

        _ = try await prove(
            backend: backend,
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointB)

        try backend.setWalletId("replacement-wallet")
        await recorder.clearRecordedURLs()
        _ = try await prove(
            backend: backend,
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.first }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointA)
        var probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)

        backend.close()
        try backend.open(path: makeTempDbPath(), networkId: 1)
        try backend.setWalletId("replacement-wallet")
        await recorder.clearRecordedURLs()
        _ = try await prove(
            backend: backend,
            resolver: PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last }),
            enteredURLs: enteredURLs
        )
        XCTAssertEqual(enteredURLs.last, endpointB)
        probeCount = await recorder.probeCount()
        XCTAssertEqual(probeCount, 2)
    }

    func testConcurrentCallsForOneContextConvergeOnOneEndpoint() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA, endpointB])
        let enteredURLs = LockedURLs()
        let firstResolver = PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.first })
        let lastResolver = PirSnapshotResolver(probe: recorder, matchingEndpointSelector: { $0.last })

        async let precomputed = precompute(
            backend: backend,
            resolver: firstResolver,
            enteredURLs: enteredURLs
        )
        async let proved = prove(
            backend: backend,
            resolver: lastResolver,
            enteredURLs: enteredURLs
        )
        _ = try await (precomputed, proved)

        XCTAssertEqual(enteredURLs.values.count, 2)
        XCTAssertEqual(enteredURLs.values[0], enteredURLs.values[1])
    }

    func testCancellingOneCoalescedCallerDoesNotPoisonTheOtherCaller() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let probeGate = Gate()
        let recorder = GatedRecordingPirSnapshotProbe(
            status: .matching(height: snapshotHeight),
            gate: probeGate
        )
        let resolver = PirSnapshotResolver(probe: recorder)
        let enteredURLs = LockedURLs()

        let survivingTask = Task {
            try await self.prove(
                backend: backend,
                endpoints: [self.endpointA],
                resolver: resolver,
                enteredURLs: enteredURLs
            )
        }
        await recorder.waitUntilProbeCount(1)
        let cancelledTask = Task {
            try await self.prove(
                backend: backend,
                endpoints: [self.endpointA],
                resolver: resolver,
                enteredURLs: enteredURLs
            )
        }
        cancelledTask.cancel()
        probeGate.open()

        _ = try await survivingTask.value
        let cancelledResult = await cancelledTask.result
        XCTAssertThrowsError(try cancelledResult.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(enteredURLs.values, [endpointA])
    }

    func testCancellationDuringResolutionNeverEntersNativeWork() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let probeGate = Gate()
        let recorder = GatedRecordingPirSnapshotProbe(
            status: .matching(height: snapshotHeight),
            gate: probeGate
        )
        let enteredURLs = LockedURLs()

        let task = Task {
            try await self.prove(
                backend: backend,
                endpoints: [self.endpointA],
                resolver: PirSnapshotResolver(probe: recorder),
                enteredURLs: enteredURLs
            )
        }
        await recorder.waitUntilProbeCount(1)
        task.cancel()
        probeGate.open()

        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(enteredURLs.values.isEmpty)
    }

    func testCloseAndReopenWhileResolutionIsBlockedRejectsObsoleteCompletion() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let probeGate = Gate()
        let recorder = GatedRecordingPirSnapshotProbe(
            status: .matching(height: snapshotHeight),
            gate: probeGate
        )
        let enteredURLs = LockedURLs()

        let task = Task {
            try await self.prove(
                backend: backend,
                endpoints: [self.endpointA],
                resolver: PirSnapshotResolver(probe: recorder),
                enteredURLs: enteredURLs
            )
        }
        await recorder.waitUntilProbeCount(1)
        backend.close()
        try backend.open(path: makeTempDbPath(), networkId: 1)
        try backend.setWalletId("replacement-wallet")
        probeGate.open()

        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(enteredURLs.values.isEmpty)
    }

    func testHandleChangeAfterResolutionBeforeEntryRejectsObsoleteCompletion() async throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }
        let entryGate = Gate()
        let entryReached = AsyncMarker()
        let recorder = RecordingPirSnapshotProbe(matching: [endpointA])
        let enteredURLs = LockedURLs()

        let task = Task {
            try await backend.buildAndProveDelegation(
                makeProofParams(roundId: roundId(0x11)),
                pirEndpoints: [endpointA],
                expectedSnapshotHeight: UInt64(snapshotHeight),
                pirLayout: layout,
                pirResolver: PirSnapshotResolver(probe: recorder),
                beforeNativeEntry: {
                    await entryReached.mark()
                    await entryGate.wait()
                },
                proveEntry: { _, url, _, _ in
                    enteredURLs.append(url)
                    return self.makeProofResult()
                }
            )
        }
        await entryReached.waitUntilMarked()
        backend.close()
        try backend.open(path: makeTempDbPath(), networkId: 1)
        try backend.setWalletId("replacement-wallet")
        entryGate.open()

        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(enteredURLs.values.isEmpty)
    }

    private func precompute(
        backend: VotingRustBackend,
        roundId: String? = nil,
        height: UInt64? = nil,
        layout: VotingPirLayout? = nil,
        endpoints: [String]? = nil,
        resolver: PirSnapshotResolver,
        enteredURLs: LockedURLs
    ) async throws -> VotingDelegationPirPrecomputeResult {
        try await backend.precomputeDelegationPir(
            roundId: roundId ?? self.roundId(0x11),
            bundleIndex: 0,
            notes: [],
            pirEndpoints: endpoints ?? [endpointA, endpointB],
            expectedSnapshotHeight: height ?? UInt64(snapshotHeight),
            pirLayout: layout ?? self.layout,
            pirResolver: resolver,
            precomputeEntry: { _, _, _, _, url, _ in
                enteredURLs.append(url)
                return VotingDelegationPirPrecomputeResult(cachedCount: 0, fetchedCount: 1)
            }
        )
    }

    private func prove(
        backend: VotingRustBackend,
        roundId: String? = nil,
        height: UInt64? = nil,
        layout: VotingPirLayout? = nil,
        endpoints: [String]? = nil,
        resolver: PirSnapshotResolver,
        enteredURLs: LockedURLs
    ) async throws -> VotingDelegationProofResult {
        try await backend.buildAndProveDelegation(
            makeProofParams(roundId: roundId ?? self.roundId(0x11)),
            pirEndpoints: endpoints ?? [endpointA, endpointB],
            expectedSnapshotHeight: height ?? UInt64(snapshotHeight),
            pirLayout: layout ?? self.layout,
            pirResolver: resolver,
            proveEntry: { _, url, _, _ in
                enteredURLs.append(url)
                return self.makeProofResult()
            }
        )
    }

    private func makeOpenBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: 1)
        try backend.setWalletId("wallet")
        return backend
    }

    private func makeTempDbPath() -> String {
        let path = "\(NSTemporaryDirectory())VotingPirEndpointSelectionTests-\(UUID().uuidString).sqlite"
        dbPaths.append(path)
        return path
    }

    private func roundId(_ tag: UInt8) -> String {
        String(format: "%02x", tag) + String(repeating: "00", count: 31)
    }

    private func makeProofParams(roundId: String) -> VotingDelegationProofParams {
        VotingDelegationProofParams(
            roundId: roundId,
            bundleIndex: 0,
            notes: [],
            keys: VotingDelegationKeyInputs(
                fvk: [UInt8](repeating: 0x03, count: votingOrchardFvkByteCount),
                hotkeyStoredSecret: [UInt8](repeating: 0x04, count: 32),
                seedFingerprint: [UInt8](repeating: 0x05, count: votingSeedFingerprintByteCount),
                accountIndex: 0,
                roundName: "Round"
            )
        )
    }

    private func makeProofResult() -> VotingDelegationProofResult {
        VotingDelegationProofResult(
            proof: [0x01],
            publicInputs: [[0x02]],
            nfSigned: [UInt8](repeating: 0x03, count: votingFieldElementByteCount),
            cmxNew: [UInt8](repeating: 0x04, count: votingFieldElementByteCount),
            govNullifiers: [],
            vanComm: [UInt8](repeating: 0x05, count: votingFieldElementByteCount),
            randomizedKey: [UInt8](repeating: 0x06, count: votingRandomizedKeyByteCount)
        )
    }
}

private actor RecordingPirSnapshotProbe: PirSnapshotProbing {
    private var statuses: [String: PirSnapshotProbeOutcome.Status]
    private var urls: [String] = []

    init(statuses: [String: PirSnapshotProbeOutcome.Status]) {
        self.statuses = statuses
    }

    init(matching urls: [String]) {
        statuses = Dictionary(uniqueKeysWithValues: urls.map { ($0, .matching(height: 100)) })
    }

    func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
        urls.append(url)
        let configuredStatus = statuses[url] ?? .unreachable(reason: "not configured")
        let status: PirSnapshotProbeOutcome.Status
        if case .matching = configuredStatus {
            status = .matching(height: expectedSnapshotHeight)
        } else {
            status = configuredStatus
        }
        return PirSnapshotProbeOutcome(
            url: url,
            status: status
        )
    }

    func probedURLs() -> [String] {
        urls
    }

    func probeCount() -> Int {
        urls.count
    }

    func clearRecordedURLs() {
        urls = []
    }

    func setStatus(_ status: PirSnapshotProbeOutcome.Status, for url: String) {
        statuses[url] = status
    }
}

private actor GatedRecordingPirSnapshotProbe: PirSnapshotProbing {
    private let status: PirSnapshotProbeOutcome.Status
    private let gate: Gate
    private var urls: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(status: PirSnapshotProbeOutcome.Status, gate: Gate) {
        self.status = status
        self.gate = gate
    }

    func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
        urls.append(url)
        let ready = waiters.filter { urls.count >= $0.0 }
        waiters.removeAll { urls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        await gate.wait()
        return PirSnapshotProbeOutcome(url: url, status: status)
    }

    func waitUntilProbeCount(_ count: Int) async {
        if urls.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor AsyncMarker {
    private var marked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        marked = true
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume() }
    }

    func waitUntilMarked() async {
        if marked {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    func append(_ url: String) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    var last: String? {
        values.last
    }
}
