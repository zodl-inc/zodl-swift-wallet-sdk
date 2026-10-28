//
//  Checkpoint+helpers.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 7/28/21.
//

import Foundation

extension Checkpoint {
    static func birthday(with height: BlockHeight, network: ZcashNetwork) -> Checkpoint {
        let checkpointDirectoryURL = BundleCheckpointURLProvider.default.url(network.networkType)

        switch network.networkType {
        case .mainnet:
            return birthday(with: height, checkpointDirectory: checkpointDirectoryURL) ?? .mainnetMin
        case .testnet:
            return birthday(with: height, checkpointDirectory: checkpointDirectoryURL) ?? .testnetMin
        case .regtest:
            return birthday(with: height, checkpointDirectory: checkpointDirectoryURL)
                ?? .regtestMin(saplingHeight: network.saplingActivationHeight)
        }
    }
}

extension Checkpoint {
    static func birthday(with height: BlockHeight, checkpointDirectory: URL) -> Checkpoint? {
        birthday(with: height, among: bundledHeights(checkpointDirectory: checkpointDirectory), checkpointDirectory: checkpointDirectory)
    }

    /// The highest of `heights` (the directory's bundled heights, ascending) at or below `height`, loaded
    /// from the directory. Taking the heights lets a caller doing several lookups list the directory once.
    /// The result is nil when no height is at or below `height`, or when the file at that height cannot be loaded.
    static func birthday(with height: BlockHeight, among heights: [BlockHeight], checkpointDirectory: URL) -> Checkpoint? {
        heights.last { $0 <= height }.flatMap { checkpoint(height: $0, directory: checkpointDirectory) }
    }

    /// The checkpoint at `index` of `heights` (the directory's bundled heights, ascending), loaded from the
    /// directory. A walk that steps through indexes is bounded by `heights`, whatever the checkpoint files hold.
    /// The result is nil when `index` is outside `heights`, or when the file at that height cannot be loaded.
    static func bundledCheckpoint(at index: Int, among heights: [BlockHeight], checkpointDirectory: URL) -> Checkpoint? {
        guard heights.indices.contains(index) else {
            return nil
        }
        return checkpoint(height: heights[index], directory: checkpointDirectory)
    }

    /// The bundled checkpoint heights in `checkpointDirectory`, ascending, or none if it cannot be read.
    static func bundledHeights(checkpointDirectory: URL) -> [BlockHeight] {
        guard let checkPointURLs = try? FileManager.default.contentsOfDirectory(
            at: checkpointDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return checkPointURLs.map { $0.deletingPathExtension() }.map(\.lastPathComponent).compactMap(Int.init).sorted()
    }

    /// The checkpoint stored in the file for `height`, or `nil` when that file cannot be read or decoded.
    static func checkpoint(height: BlockHeight, directory checkpointDirectory: URL) -> Checkpoint? {
        let url = checkpointDirectory
            .appendingPathComponent(String(height))
            .appendingPathExtension("json")

        return try? checkpoint(at: url)
    }

    /// - Throws:
    ///     - `checkpointCantLoadFromDisk` if can't load JSON with checkpoint from disk.
    private static func checkpoint(at url: URL) throws -> Checkpoint {
        do {
            let data = try Data(contentsOf: url)
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: data)
            return checkpoint
        } catch {
            throw ZcashError.checkpointCantLoadFromDisk(error)
        }
    }
}
