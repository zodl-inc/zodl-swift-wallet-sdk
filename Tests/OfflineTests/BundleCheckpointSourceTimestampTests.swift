//
//  BundleCheckpointSourceTimestampTests.swift
//  OfflineTests
//
//  `BundleCheckpointSource.estimateTimestamp(for:)` walks down the checkpoint intervals until a checkpoint
//  loads. It once never returned when none did, and it has to settle a huge height by the checkpoint files
//  there are, not by the number of intervals below it. Every lookup here runs on a thread of its own under a
//  deadline, so a lookup that hangs again fails its test instead of hanging the suite.
//

import os
import XCTest
@testable import ZODLSwiftWalletSDK

final class BundleCheckpointSourceTimestampTests: XCTestCase {
    /// The lookups here read a directory a handful of times at most, so they take milliseconds. A second is generous,
    /// and short enough for a hung lookup to fail fast.
    private static let deadline: TimeInterval = 1

    private let networks: [NetworkType] = [.mainnet, .testnet]

    // MARK: - Checkpoints that cannot be loaded

    func testEmptyDirectoryHasNoTimestamp() throws {
        for network in networks {
            let source = makeSource(for: network, reading: try makeDirectory())

            for height in heightsToLookUp(in: network) {
                try assertEstimatedTimestamp(of: source, for: height, is: nil)
            }
        }
    }

    func testMissingDirectoryHasNoTimestamp() throws {
        let missing = try makeDirectory().appendingPathComponent("never-created", isDirectory: true)

        for network in networks {
            let source = makeSource(for: network, reading: missing)

            for height in heightsToLookUp(in: network) {
                try assertEstimatedTimestamp(of: source, for: height, is: nil)
            }
        }
    }

    func testDirectoryWithOnlyACheckpointAboveTheHeightHasNoTimestamp() throws {
        for network in networks {
            let directory = try makeDirectory()
            try writeCheckpoint(height: 1_000_000, time: 1_600_000_000, network: network, in: directory)
            let source = makeSource(for: network, reading: directory)

            // The checkpoint is above both heights: the first is below Sapling activation, the second above it.
            for height in [100_000, 800_000] {
                try assertEstimatedTimestamp(of: source, for: height, is: nil)
            }
        }
    }

    func testDirectoryWhoseOnlyCheckpointCannotBeDecodedHasNoTimestamp() throws {
        for network in networks {
            let directory = try makeDirectory()
            try writeUndecodableCheckpoint(height: saplingActivationHeight(of: network), in: directory)
            let source = makeSource(for: network, reading: directory)

            for height in heightsToLookUp(in: network) {
                try assertEstimatedTimestamp(of: source, for: height, is: nil)
            }
        }
    }

    func testDirectoryWhereNoCheckpointCanBeDecodedHasNoTimestamp() throws {
        for network in networks {
            let directory = try makeDirectory()
            for height in [saplingActivationHeight(of: network), 500_000, 510_000, 1_000_000, 2_000_000] {
                try writeUndecodableCheckpoint(height: height, in: directory)
            }
            let source = makeSource(for: network, reading: directory)

            for height in heightsToLookUp(in: network) {
                try assertEstimatedTimestamp(of: source, for: height, is: nil)
            }
        }
    }

    func testLookupStepsDownPastNewestCheckpointThatCannotBeDecoded() throws {
        let saplingTime: UInt32 = 1_540_000_000
        let olderTime: UInt32 = 1_600_000_000

        for network in networks {
            let directory = try makeDirectory()
            try writeCheckpoint(height: saplingActivationHeight(of: network), time: saplingTime, network: network, in: directory)
            try writeCheckpoint(height: 500_000, time: olderTime, network: network, in: directory)
            try writeUndecodableCheckpoint(height: 510_000, in: directory)
            let source = makeSource(for: network, reading: directory)

            // The 510_000 checkpoint is the newest at or below each of these heights and it cannot be decoded. The
            // lookup has to go on to the 500_000 one: neither give up nor stop at Sapling activation.
            for height in [510_000, 515_000, 1_000_000, BlockHeight(Int32.max), .max] {
                try assertEstimatedTimestamp(of: source, for: height, is: TimeInterval(olderTime))
            }
        }
    }

    func testLookupKeepsToTheIntervalGridWhenItStepsPastAnUndecodableCheckpointOffTheGrid() throws {
        // The undecodable checkpoint and the valid one just below it are off the grid of both networks. Each network's
        // grid leads to another checkpoint: mainnet's, in steps of 2,500 blocks, to 1,685,000, and testnet's, in steps of
        // 10,000 blocks, to 1,680,000.
        struct Case {
            let network: NetworkType
            let queried: BlockHeight
            let landing: BlockHeight
        }
        let cases = [
            Case(network: .mainnet, queried: 1_687_600, landing: 1_685_000),
            Case(network: .testnet, queried: 1_690_500, landing: 1_680_000)
        ]

        for testCase in cases {
            let directory = try makeDirectory()
            // Each valid checkpoint's time is its height, so the result names the checkpoint the lookup ended up at.
            for height in [1_680_000, 1_685_000, 1_686_871] {
                try writeCheckpoint(height: height, time: UInt32(height), network: testCase.network, in: directory)
            }
            try writeUndecodableCheckpoint(height: 1_687_104, in: directory)
            let source = makeSource(for: testCase.network, reading: directory)

            // The interval start of the queried height is above the undecodable checkpoint. The lookup goes on at the first
            // interval start below it, as it always has, and does not land on the valid checkpoint just below it.
            try assertEstimatedTimestamp(of: source, for: testCase.queried, is: TimeInterval(testCase.landing))
        }
    }

    /// Mainnet's Sapling activation, 419_200, is off the grid of 2,500 blocks, so the first interval start below a
    /// checkpoint just above it, 417_500, is below Sapling activation. The lookup has to go on at Sapling activation
    /// then, where the checkpoint is.
    func testLookupNeverJumpsBelowSaplingActivation_Mainnet() throws {
        let saplingTime: UInt32 = 1_540_000_000
        let directory = try makeDirectory()
        try writeCheckpoint(height: saplingActivationHeight(of: .mainnet), time: saplingTime, network: .mainnet, in: directory)
        try writeUndecodableCheckpoint(height: 420_000, in: directory)
        let source = makeSource(for: .mainnet, reading: directory)

        for height in [420_000, 1_000_000] {
            try assertEstimatedTimestamp(of: source, for: height, is: TimeInterval(saplingTime))
        }
    }

    // MARK: - The bundled checkpoints

    func testBundledCheckpointsKeepGivingTheSameTimestamps_Mainnet() throws {
        try assertBundledTimestamps(for: .mainnet)
    }

    func testBundledCheckpointsKeepGivingTheSameTimestamps_Testnet() throws {
        try assertBundledTimestamps(for: .testnet)
    }

    /// In the intact bundle the first height a lookup tries always loads, so the fix cannot change these results. The
    /// expectations were taken from the code as it was before the fix.
    private func assertBundledTimestamps(for network: NetworkType, file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = BundleCheckpointURLProvider.default.url(network)
        let sapling = saplingActivationHeight(of: network)
        let latest = try XCTUnwrap(Checkpoint.birthday(with: .max, checkpointDirectory: directory), file: file, line: line)
        let source = BundleCheckpointSource(network: network)

        // Each height is paired with the height of the bundled checkpoint whose time it has always resolved to.
        let expectations: [(height: BlockHeight, checkpointHeight: BlockHeight)] = [
            // Below Sapling activation, which resolves to the Sapling activation checkpoint. That includes negative heights.
            (.min, sapling),
            (-1, sapling),
            (0, sapling),
            (100_000, sapling),
            (sapling - 1, sapling),
            // At and just above it.
            (sapling, sapling),
            (sapling + 1, sapling),
            // Exactly at a checkpoint.
            (500_000, 500_000),
            (510_000, 510_000),
            // Between two checkpoints.
            (505_000, 500_000),
            (507_499, 500_000),
            // Above the latest checkpoint.
            (latest.height + 10_000, latest.height),
            (latest.height + 1_000_000, latest.height),
            (.max, latest.height)
        ]

        for (height, checkpointHeight) in expectations {
            let expected = try XCTUnwrap(
                Checkpoint.birthday(with: checkpointHeight, checkpointDirectory: directory),
                file: file,
                line: line
            )
            XCTAssertEqual(expected.height, checkpointHeight, "the bundle has no checkpoint at \(checkpointHeight)", file: file, line: line)

            try assertEstimatedTimestamp(of: source, for: height, is: TimeInterval(expected.time), file: file, line: line)
        }
    }

    // MARK: - Helpers

    private struct LookupDidNotReturn: Error {}

    private func makeSource(for network: NetworkType, reading directory: URL) -> BundleCheckpointSource {
        BundleCheckpointSource(network: network, urlProvider: BundleCheckpointURLProvider(url: { _ in directory }))
    }

    private func saplingActivationHeight(of network: NetworkType) -> BlockHeight {
        ZcashNetworkBuilder.network(for: network).saplingActivationHeight
    }

    /// A height below Sapling activation, Sapling activation itself, one well above it, and two that no chain will reach
    /// and a lookup must not walk down to one interval at a time.
    private func heightsToLookUp(in network: NetworkType) -> [BlockHeight] {
        [100_000, saplingActivationHeight(of: network), 1_000_000, BlockHeight(Int32.max), .max]
    }

    /// Asserts that `source.estimateTimestamp(for:)` returns `expected`, with `nil` standing for no timestamp.
    ///
    /// The lookup runs on a thread of its own and has `Self.deadline` seconds to return. A lookup that has not returned
    /// by then fails the test and is left running, abandoned, instead of blocking the suite. The test ends right there, by
    /// a thrown error, so the heights after a hung one do not each wait out the deadline as well.
    private func assertEstimatedTimestamp(
        of source: BundleCheckpointSource,
        for height: BlockHeight,
        is expected: TimeInterval?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let finished = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

        let thread = Thread {
            let timestamp = source.estimateTimestamp(for: height)
            result.withLock { $0 = timestamp }
            finished.signal()
        }
        thread.name = "estimateTimestamp(for: \(height))"
        thread.start()

        guard finished.wait(timeout: .now() + Self.deadline) == .success else {
            XCTFail(
                "\(source.network): estimateTimestamp(for: \(height)) did not return within \(Self.deadline) seconds",
                file: file,
                line: line
            )
            throw LookupDidNotReturn()
        }

        XCTAssertEqual(result.withLock { $0 }, expected, "\(source.network) at height \(height)", file: file, line: line)
    }

    /// A new empty directory, removed when the test ends.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleCheckpointSourceTimestampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Writes a checkpoint file shaped like the ones the SDK bundles, such as `checkpoints/testnet/280000.json`.
    private func writeCheckpoint(height: BlockHeight, time: UInt32, network: NetworkType, in directory: URL) throws {
        let json = """
        {
            "network": "\(network.chainName)",
            "height": "\(height)",
            "hash": "000420e7fcc3a49d729479fb0b560dd7b8617b178a08e9e389620a9d1dd6361a",
            "time": \(time),
            "saplingTree": "000000"
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(height).json"))
    }

    /// Writes a checkpoint file that is cut off in the middle, so the checkpoint at that height cannot be decoded.
    private func writeUndecodableCheckpoint(height: BlockHeight, in directory: URL) throws {
        let json = """
        {
            "height": "\(height)",
            "hash": "000420e7fcc3a49d
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(height).json"))
    }
}
