import XCTest
@testable import ZODLSwiftWalletSDK

final class CheckpointBirthdayEstimateTests: XCTestCase {
    /// A floor under half of the smaller bundle, which has 424 checkpoints on testnet against 846 on mainnet. It
    /// rules out an unreadable or truncated directory, which would let every comparison below pass vacuously.
    private let minimumBundledCheckpoints = 200

    /// The oracle takes "newest before a date" to be the highest checkpoint whose time is before it, which
    /// matches the walk only while times never decrease with height; a refresh that broke this fails here.
    func testBundledCheckpointTimesNeverDecreaseWithHeight() {
        for network in [NetworkType.mainnet, .testnet] {
            let checkpoints = bundledCheckpoints(network)
            for (earlier, later) in zip(checkpoints, checkpoints.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.time, later.time, "\(network): \(earlier.height) is later than \(later.height)")
            }
        }
    }

    func testEstimateMatchesTheOracleOnMainnet() {
        assertMatchesOracle(.mainnet)
    }

    func testEstimateMatchesTheOracleOnTestnet() {
        assertMatchesOracle(.testnet)
    }

    func testTheEndsOfTheBundle() {
        for network in [NetworkType.mainnet, .testnet] {
            let source = BundleCheckpointSource(network: network)
            let latest = source.latestKnownCheckpoint()
            // A source that cannot read its bundle falls back to Sapling activation, where the ends below all agree.
            XCTAssertEqual(latest.height, bundledCheckpoints(network).last?.height, "\(network)")
            XCTAssertGreaterThan(latest.height, source.saplingActivation.height, "\(network)")

            XCTAssertEqual(source.estimateBirthdayHeight(for: date(latest.time)), latest.height, "\(network)")
            XCTAssertEqual(source.estimateBirthdayHeight(for: Date.distantFuture), latest.height, "\(network)")
            XCTAssertEqual(
                source.estimateBirthdayHeight(for: Date(timeIntervalSince1970: 0)),
                source.saplingActivation.height,
                "\(network)"
            )
            XCTAssertEqual(
                source.estimateBirthdayHeight(for: date(source.saplingActivation.time)),
                source.saplingActivation.height,
                "\(network)"
            )
        }
    }

    /// A date equal to a checkpoint's time is not after it, so the checkpoint before it answers.
    func testADateOnACheckpointTimeIsTheCheckpointBeforeIt() throws {
        let checkpoints = bundledCheckpoints(.testnet)
        let index = try XCTUnwrap(checkpoints.firstIndex { $0.height == 4_490_000 })
        let source = BundleCheckpointSource(network: .testnet)
        XCTAssertEqual(source.estimateBirthdayHeight(for: date(checkpoints[index].time)), checkpoints[index - 1].height)
    }

    private func assertMatchesOracle(_ network: NetworkType, file: StaticString = #filePath, line: UInt = #line) {
        let checkpoints = bundledCheckpoints(network, file: file, line: line)
        let source = BundleCheckpointSource(network: network)
        // Every tenth checkpoint and the last three: on, just before and after its time, and halfway to the next.
        var sampled = Array(stride(from: 0, to: checkpoints.count, by: 10))
        sampled.append(contentsOf: max(0, checkpoints.count - 3)..<checkpoints.count)
        for index in sampled {
            let time = TimeInterval(checkpoints[index].time)
            var times = [time - 1, time, time + 1]
            if index + 1 < checkpoints.count {
                times.append((time + TimeInterval(checkpoints[index + 1].time)) / 2)
            }
            for dateTime in times {
                // Every estimate lists the bundle directory; without a pool per date those listings pile up until the test ends.
                autoreleasepool {
                    XCTAssertEqual(
                        source.estimateBirthdayHeight(for: Date(timeIntervalSince1970: dateTime)),
                        oracle(dateTime, checkpoints: checkpoints, saplingHeight: source.saplingActivation.height),
                        "\(network) at \(dateTime)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    private func oracle(_ dateTime: TimeInterval, checkpoints: [Checkpoint], saplingHeight: BlockHeight) -> BlockHeight {
        if let latest = checkpoints.last, dateTime >= TimeInterval(latest.time) {
            return latest.height
        }
        return checkpoints.filter { TimeInterval($0.time) < dateTime }.map(\.height).max() ?? saplingHeight
    }

    /// The checkpoints bundled for `network`, ascending by height, read with `FileManager` and `JSONDecoder` alone.
    /// The test fails when the directory is unreadable, a file does not decode, a file is not named after the height
    /// it holds (the source finds a checkpoint's file by its height) or too few checkpoints load, so a comparison
    /// against the result cannot pass for want of data.
    private func bundledCheckpoints(_ network: NetworkType, file: StaticString = #filePath, line: UInt = #line) -> [Checkpoint] {
        let directory = BundleCheckpointURLProvider.default.url(network)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        let decoded = files.compactMap { url -> (name: String, checkpoint: Checkpoint)? in
            guard let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url)) else {
                return nil
            }
            return (url.deletingPathExtension().lastPathComponent, checkpoint)
        }
        for (name, checkpoint) in decoded {
            XCTAssertEqual(
                name,
                String(checkpoint.height),
                "\(network): \(name).json holds height \(checkpoint.height)",
                file: file,
                line: line
            )
        }
        let checkpoints = decoded.map(\.checkpoint).sorted { $0.height < $1.height }
        XCTAssertEqual(checkpoints.count, files.count, "\(network): a bundled file did not decode", file: file, line: line)
        XCTAssertGreaterThan(
            checkpoints.count,
            minimumBundledCheckpoints,
            "\(network): only \(checkpoints.count) bundled checkpoints loaded",
            file: file,
            line: line
        )
        return checkpoints
    }

    private func date(_ time: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time))
    }
}
