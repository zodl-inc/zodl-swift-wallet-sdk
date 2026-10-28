//
//  BundleCheckpointSource.swift
//
//
//  Created by Francisco Gindre on 2023-10-30.
//

import Foundation

struct BundleCheckpointSource: CheckpointSource {
    var network: NetworkType

    var saplingActivation: Checkpoint

    /// Resolves the directory the checkpoint files are read from. Tests inject their own to cover a
    /// checkpoint directory that is missing, empty or damaged.
    private let urlProvider: BundleCheckpointURLProvider

    init(network: NetworkType, urlProvider: BundleCheckpointURLProvider = .default) {
        self.network = network
        self.urlProvider = urlProvider
        self.saplingActivation = if network == .mainnet { Checkpoint.mainnetMin } else { Checkpoint.testnetMin }
    }

    func latestKnownCheckpoint() -> Checkpoint {
        Checkpoint.birthday(
            with: .max,
            checkpointDirectory: urlProvider.url(self.network)
        ) ?? saplingActivation
    }

    func birthday(for height: BlockHeight) -> Checkpoint {
        Checkpoint.birthday(
            with: height,
            checkpointDirectory: urlProvider.url(self.network)
        ) ?? saplingActivation
    }

    /// The height of the newest bundled checkpoint strictly before `date`, the newest checkpoint for a date at
    /// or after its time, or Sapling activation when none precedes `date`. Checkpoint times decide; the target
    /// spacing only picks where the walk starts.
    func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        let directory = urlProvider.url(network)
        let heights = Checkpoint.bundledHeights(checkpointDirectory: directory)
        let dateTime = date.timeIntervalSince1970
        let latestCheckpoint = Checkpoint.birthday(with: .max, among: heights, checkpointDirectory: directory) ?? saplingActivation

        guard dateTime < TimeInterval(latestCheckpoint.time) else {
            return latestCheckpoint.height
        }

        // The guess assumes every block since the date took exactly its target spacing; real blocks drift, so
        // it only picks where to start reading checkpoint times.
        let guess = TargetBlockSpacing(networkType: network).height(
            reachedAfter: dateTime - TimeInterval(latestCheckpoint.time),
            from: latestCheckpoint.height
        )
        // The walk steps through indexes of `heights`, never through the heights the files decode to, so it ends
        // however the files are named or what they hold.
        var index = heights.lastIndex { $0 <= guess } ?? 0
        guard var candidate = Checkpoint.bundledCheckpoint(at: index, among: heights, checkpointDirectory: directory) else {
            return saplingActivation.height
        }

        while TimeInterval(candidate.time) >= dateTime {
            guard let earlier = Checkpoint.bundledCheckpoint(at: index - 1, among: heights, checkpointDirectory: directory) else {
                return saplingActivation.height
            }
            index -= 1
            candidate = earlier
        }

        while
            let next = Checkpoint.bundledCheckpoint(at: index + 1, among: heights, checkpointDirectory: directory),
            TimeInterval(next.time) < dateTime {
            index += 1
            candidate = next
        }

        return candidate.height
    }

    /// The time of the newest bundled checkpoint at or below the start of the checkpoint interval that `height` falls
    /// in. When that checkpoint cannot be decoded the lookup goes on at the first interval start below the checkpoint's
    /// own height, but never below Sapling activation, and it returns `nil` once no checkpoint can be loaded. Its work is
    /// bounded by the number of checkpoint files, not by `height`.
    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        let blockInterval: BlockHeight = network == .mainnet ? 2500 : 10_000
        var checkpointHeight = (height / blockInterval) * blockInterval

        // Ensure sapling activation is the lowest possible
        let saplingActivationHeight = network == .mainnet
        ? ZcashMainnet().constants.saplingActivationHeight
        : ZcashTestnet().constants.saplingActivationHeight

        if checkpointHeight < saplingActivationHeight {
            checkpointHeight = saplingActivationHeight
        }

        let directory = urlProvider.url(self.network)
        let heights = Checkpoint.bundledHeights(checkpointDirectory: directory)

        while true {
            // No checkpoint file at or below this height means there is none at any lower height either.
            guard let fileHeight = heights.last(where: { $0 <= checkpointHeight }) else {
                return nil
            }

            if let checkpoint = Checkpoint.checkpoint(height: fileHeight, directory: directory) {
                return TimeInterval(checkpoint.time)
            }

            // Nothing is bundled below Sapling activation, so a checkpoint that does not decode there ends the lookup.
            guard fileHeight > saplingActivationHeight else {
                return nil
            }

            // Stepping down one interval at a time would pick this same file at every interval start from here down to its
            // own height, so go on at the first interval start below it instead.
            checkpointHeight = max(((fileHeight - 1) / blockInterval) * blockInterval, saplingActivationHeight)
        }
    }
}
