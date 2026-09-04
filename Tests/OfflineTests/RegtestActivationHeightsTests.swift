//
//  RegtestActivationHeightsTests.swift
//  ZODLSwiftWalletSDK
//
//  Offline coverage for configurable NU activation heights (regtest / custom network).
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class RegtestActivationHeightsTests: XCTestCase {
    // MARK: - Network model

    func testRegtestNetworkIdentity() {
        XCTAssertEqual(NetworkType.regtest.networkId, 2)
        XCTAssertEqual(NetworkType.regtest.chainName, "regtest")
        XCTAssertEqual(NetworkType.forChainName("regtest"), .regtest)
        XCTAssertEqual(NetworkType.forNetworkId(2), .regtest)
    }

    func testRegtestBuilderCarriesActivationHeights() {
        let heights = NetworkActivationHeights(sapling: 1, nu5: 100, nu6: 200, nu6_3: 700)
        let network = ZcashNetworkBuilder.regtest(activationHeights: heights)

        XCTAssertEqual(network.networkType, .regtest)
        XCTAssertEqual(network.saplingActivationHeight, 1)
        XCTAssertEqual(network.customActivationHeights, heights)
    }

    func testRegtestSaplingActivationDefaultsToOneWhenUnset() {
        let network = ZcashNetworkBuilder.regtest(activationHeights: NetworkActivationHeights(nu5: 100))
        XCTAssertEqual(network.saplingActivationHeight, 1)
    }

    func testMainnetTestnetAreUnaffected() {
        let mainnet = ZcashNetworkBuilder.network(for: .mainnet)
        let testnet = ZcashNetworkBuilder.network(for: .testnet)

        XCTAssertNil(mainnet.customActivationHeights)
        XCTAssertNil(testnet.customActivationHeights)
        XCTAssertEqual(mainnet.saplingActivationHeight, 419_200)
        XCTAssertEqual(testnet.saplingActivationHeight, 280_000)
    }

    // MARK: - Checkpoints

    func testRegtestCheckpointFloorIsEmptyTreeAtSaplingHeight() {
        let source = CheckpointSourceFactory.fromBundle(
            for: .regtest,
            regtestActivationHeights: NetworkActivationHeights(sapling: 7)
        )

        XCTAssertEqual(source.network, .regtest)
        XCTAssertEqual(source.saplingActivation.height, 7)
        XCTAssertEqual(source.saplingActivation.saplingTree, "000000")
        XCTAssertNil(source.saplingActivation.orchardTree)
        XCTAssertNil(source.saplingActivation.ironwoodTree)
        // Regtest ships no bundled checkpoints, so any requested birthday resolves to the floor.
        XCTAssertEqual(source.birthday(for: 10_000).height, 7)
        XCTAssertEqual(source.latestKnownCheckpoint().height, 7)
    }

    // MARK: - FFI integration: consensus branch id honors the configured heights

    func testRegtestConsensusBranchIdReflectsCustomActivationHeights() throws {
        // Configure a regtest network with NU5 at 100 and NU6 at 200.
        ZcashRustBackend.setCustomNetwork(
            base: .regtest,
            NetworkActivationHeights(
                overwinter: 1,
                sapling: 1,
                blossom: 1,
                heartwood: 1,
                canopy: 1,
                nu5: 100,
                nu6: 200
            )
        )

        let backend = ZcashRustBackend.makeForTests(
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .regtest
        )

        // Well-known Zcash consensus branch ids (see zcash_protocol LocalNetwork docs / zcash.conf nuparams).
        let nu5BranchId = Int32(bitPattern: 0xc2d6_d0b4)
        let nu6BranchId = Int32(bitPattern: 0xc8e7_1055)

        // Below the configured NU5 height the branch id is not NU5's...
        XCTAssertNotEqual(try backend.consensusBranchIdFor(height: 50), nu5BranchId)
        // ...at/after the configured NU5 height it is NU5's...
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 100), nu5BranchId)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 150), nu5BranchId)
        // ...and at/after the configured NU6 height it is NU6's.
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 200), nu6BranchId)
        XCTAssertEqual(try backend.consensusBranchIdFor(height: 5000), nu6BranchId)
    }
}
