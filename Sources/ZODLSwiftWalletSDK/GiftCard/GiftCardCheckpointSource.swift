//
//  GiftCardCheckpointSource.swift
//  ZODLSwiftWalletSDK
//
//  A gift card's link carries the height its funds were received at (or just below it), so its
//  wallet should start scanning there. The bundled checkpoints only exist every 2,500 blocks on
//  mainnet and every 10,000 on testnet, so a card restored from them scans days of blocks it
//  cannot contain. This source serves a checkpoint built from the server's tree state for the
//  exact height when the redeemer managed to fetch one, and the bundled grid otherwise.
//

import Foundation

final class GiftCardCheckpointSource: CheckpointSource {
    private let bundled: CheckpointSource
    private let lock = NSLock()
    private var exact: Checkpoint?

    init(bundled: CheckpointSource) {
        self.bundled = bundled
    }

    var network: NetworkType { bundled.network }

    var saplingActivation: Checkpoint { bundled.saplingActivation }

    /// Remembers the server's tree state for the block before the card's birthday, which
    /// `birthday(for:)` can serve as prior-chain state for a later birthday.
    ///
    /// The state is only used when its height is exactly `birthday - 1`, the height it was
    /// requested for. A server that answers with another height, by mistake or on purpose, would
    /// otherwise move the start of the scan: past the card's funds, making a funded card look
    /// empty, or far before them. Such a state is ignored and the bundled checkpoint applies. So is a
    /// state at a height the SDK can't use.
    ///
    /// - Returns: whether the state was used.
    @discardableResult
    func use(_ treeState: TreeState, forBirthday birthday: BlockHeight) -> Bool {
        guard birthday > 0, treeState.height == UInt64(birthday - 1), let checkpoint = Checkpoint(treeState: treeState) else {
            return false
        }
        lock.lock()
        exact = checkpoint
        lock.unlock()
        return true
    }

    func latestKnownCheckpoint() -> Checkpoint {
        bundled.latestKnownCheckpoint()
    }

    func birthday(for height: BlockHeight) -> Checkpoint {
        lock.lock()
        let exact = self.exact
        lock.unlock()
        if let exact, exact.height < height {
            return exact
        }

        // A wallet birthday is the first block that may contain funds. Its checkpoint must
        // describe an earlier block so scanning includes that birthday. Preserve the minimum
        // representable height without subtracting past the integer boundary.
        let priorHeight = height > Int.min ? height - 1 : height
        return bundled.birthday(for: priorHeight)
    }

    func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        bundled.estimateBirthdayHeight(for: date)
    }

    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        bundled.estimateTimestamp(for: height)
    }
}

extension Checkpoint {
    /// A checkpoint from a server tree state; the optional trees are absent when the server
    /// sends them empty. `nil` if the state's height is one the SDK can't use.
    init?(treeState: TreeState) {
        guard let height = BlockHeight(serverHeight: treeState.height) else {
            return nil
        }
        self.init(
            height: height,
            hash: treeState.hash,
            time: treeState.time,
            saplingTree: treeState.saplingTree,
            orchardTree: treeState.orchardTree.isEmpty ? nil : treeState.orchardTree,
            ironwoodTree: treeState.ironwoodTree.isEmpty ? nil : treeState.ironwoodTree
        )
    }
}
