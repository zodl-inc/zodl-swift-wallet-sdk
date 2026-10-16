//
//  TransactionSizeBoundTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class TransactionSizeBoundTests: XCTestCase {
    func testConsensusCapsNothing() {
        let consensus = TransactionSizeBound.consensus
        XCTAssertEqual(consensus, TransactionSizeBound())
        XCTAssertNil(consensus.maxBytes)
        XCTAssertNil(consensus.maxShieldedActions)
        XCTAssertNil(consensus.maxOrchardActions)
    }

    func testIntersectTakesTheTighterCapInEveryDimension() {
        let phone = TransactionSizeBound(maxBytes: 250_000, maxShieldedActions: 75, maxOrchardActions: 75)
        let signer = TransactionSizeBound(
            maxShieldedActions: 48,
            maxSaplingActions: 0,
            maxOrchardActions: 100,
            maxTransparentInputs: 10,
            maxShieldedPaymentOutputs: 4
        )

        let both = phone.intersect(signer)

        XCTAssertEqual(
            both,
            TransactionSizeBound(
                maxBytes: 250_000,
                maxShieldedActions: 48,
                maxSaplingActions: 0,
                maxOrchardActions: 75,
                maxTransparentInputs: 10,
                maxShieldedPaymentOutputs: 4
            )
        )
        XCTAssertEqual(both, signer.intersect(phone), "intersect is symmetric")
    }

    func testIntersectingWithConsensusChangesNothing() {
        let bound = TransactionSizeBound(maxBytes: 1, maxIronwoodActions: 2, maxTransparentOutputs: 3)
        XCTAssertEqual(bound.intersect(.consensus), bound)
        XCTAssertEqual(TransactionSizeBound.consensus.intersect(bound), bound)
    }

    private let mebibyte: UInt64 = 1024 * 1024

    func testProvingMemoryAdmitsWhatTheMemoryAffords() {
        // 550 MiB of baseline plus 20 MiB for each of 40 actions, with a little to spare.
        let bound = TransactionSizeBound.forProvingMemory(availableBytes: (550 + 40 * 20 + 19) * mebibyte)
        XCTAssertEqual(bound, TransactionSizeBound(maxShieldedActions: 40))
    }

    func testProvingMemoryIsCappedAtWhatRelaysAccept() {
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: 8 * 1024 * mebibyte).maxShieldedActions, 75)
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: .max).maxShieldedActions, 75)
    }

    func testProvingMemoryNeverCapsBelowTheFloor() {
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: 0).maxShieldedActions, 16)
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: 550 * mebibyte).maxShieldedActions, 16)
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: (550 + 16 * 20) * mebibyte).maxShieldedActions, 16)
        XCTAssertEqual(TransactionSizeBound.forProvingMemory(availableBytes: (550 + 17 * 20) * mebibyte).maxShieldedActions, 17)
    }

    func testProvingMemoryCapsOnlyShieldedActions() {
        var bound = TransactionSizeBound.forProvingMemory(availableBytes: 2_000_000_000)
        bound.maxShieldedActions = nil
        XCTAssertEqual(bound, .consensus)
    }

    func testTheFFIFormMarksUncappedFieldsAndClampsNegativeCaps() {
        let ffi = TransactionSizeBound(
            maxBytes: 250_000,
            maxShieldedActions: 75,
            maxSaplingActions: 0,
            maxOrchardActions: 32,
            maxIronwoodActions: -5,
            maxTransparentInputs: 30,
            maxTransparentOutputs: nil,
            maxShieldedPaymentOutputs: 4
        ).ffiValue

        XCTAssertEqual(ffi.max_bytes, 250_000)
        XCTAssertEqual(ffi.max_shielded_actions, 75)
        XCTAssertEqual(ffi.max_sapling_actions, 0)
        XCTAssertEqual(ffi.max_orchard_actions, 32)
        XCTAssertEqual(ffi.max_ironwood_actions, 0)
        XCTAssertEqual(ffi.max_transparent_inputs, 30)
        XCTAssertEqual(ffi.max_transparent_outputs, -1)
        XCTAssertEqual(ffi.max_shielded_payment_outputs, 4)
    }

    func testTheConsensusFFIFormCapsNothing() {
        let ffi = TransactionSizeBound.consensus.ffiValue
        let fields = [
            ffi.max_bytes, ffi.max_shielded_actions, ffi.max_sapling_actions, ffi.max_orchard_actions,
            ffi.max_ironwood_actions, ffi.max_transparent_inputs, ffi.max_transparent_outputs,
            ffi.max_shielded_payment_outputs
        ]
        XCTAssertEqual(fields, Array(repeating: -1, count: 8))
    }
}
