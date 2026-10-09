//
//  CheckpointIronwoodTreeTests.swift
//  OfflineTests
//
//  Verifies the optional `ironwoodTree` checkpoint field decodes and flows into `TreeState`. Every
//  bundled checkpoint omits it today (pre-NU6.3), so the absent case must decode to nil — the field
//  exists so checkpoints can carry the Ironwood commitment tree once NU6.3 activates.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class CheckpointIronwoodTreeTests: XCTestCase {
    func testCheckpointDecodesIronwoodTreeIntoTreeState() throws {
        let json = Data(
            """
            {
                "height": "3000000",
                "hash": "0000000000abc",
                "time": 1700000000,
                "saplingTree": "sapling-tree-state",
                "orchardTree": "orchard-tree-state",
                "ironwoodTree": "ironwood-tree-state"
            }
            """.utf8
        )

        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: json)

        XCTAssertEqual(checkpoint.ironwoodTree, "ironwood-tree-state")
        XCTAssertEqual(checkpoint.treeState().ironwoodTree, "ironwood-tree-state")
    }

    func testCheckpointWithoutIronwoodTreeDecodesToNil() throws {
        // Mirrors every bundled checkpoint today: no `ironwoodTree` key (pre-NU6.3).
        let json = Data(
            """
            {
                "height": "3000000",
                "hash": "0000000000abc",
                "time": 1700000000,
                "saplingTree": "sapling-tree-state",
                "orchardTree": "orchard-tree-state"
            }
            """.utf8
        )

        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: json)

        XCTAssertNil(checkpoint.ironwoodTree)
        // `treeState()` leaves the proto field at its default empty string when the checkpoint has no
        // Ironwood tree.
        XCTAssertEqual(checkpoint.treeState().ironwoodTree, "")
    }
}
