//
//  MigrationInstructionOpacityTests.swift
//  OfflineTests
//
//  The COMPILATION-SHAPE half of the instruction-executor capability discipline (task 4.4).
//
//  This file imports `ZODLSwiftWalletSDK` WITHOUT `@testable` — deliberately, and it is the whole
//  point: it sees exactly what an app sees. Every other migration test file reaches the internal
//  initializers of `MigrationBroadcastInstruction` / `MigrationProveTarget` through `@testable` so
//  it can drive the executors; this one proves that an app cannot.
//
//  What is asserted, and how:
//
//  1. AT COMPILE TIME, by `performDictate` below type-checking: a `.prove` step's payload is
//     exactly what `proveMigrationTransactions(accountUUID:_:maxProofs:)` accepts, and a
//     `.broadcast` step's payload exactly what `performMigrationBroadcast(accountUUID:_:options:)`
//     accepts — no unwrapping, no id extraction, no re-assembly. A drift in either payload or
//     either signature breaks this file's build.
//
//  2. AT RUNTIME, by `testNoNonEmptyInstructionIsConstructibleFromThePublicSurface`: every
//     `MigrationAdvanceStep` this file can build carries no instruction a executor could act on.
//     The two shapes differ, and the difference is worth stating precisely rather than rounding
//     off:
//
//       - `.broadcast` is UNCONSTRUCTIBLE here. Its payload is a single
//         `MigrationBroadcastInstruction`, and there is no way to produce one.
//       - `.prove` is constructible ONLY as the INERT EMPTY BATCH — `.prove(transactions: [])`
//         compiles, because an empty `Array` needs no element. It names no transaction, so it
//         grants no capability (`proveTransactions` returns `0` for it; see
//         `OrchardMigrationCompositionTests.testProveTransactionsWithAnEmptyInstructionProvesNothing`),
//         and the engine never issues an empty batch. A NON-EMPTY `.prove` is unconstructible,
//         which is the property that matters.
//
//  3. BY THE ABSENCE OF A PUBLIC INITIALIZER, which no XCTest assertion can express — a
//     non-compiling line cannot be a test case. These are the lines that must NOT compile, and a
//     reviewer adding a public initializer to either type should uncomment one to see it start to:
//
//         let forged = MigrationBroadcastInstruction(id: 7)
//         let forgedTarget = MigrationProveTarget(id: 7, kind: .transfer(crossing: 0))
//         let forgedStep = MigrationAdvanceStep.broadcast(forged)
//
//     (`MigrationAdvanceStep.prove(transactions: [])` DOES compile and is not on that list — see
//     claim 2.)
//
//     (Note that `AccountUUID` is opaque in the same way and for a related reason — an app gets
//     one from `listAccounts()`, never by construction — so the SDK already had this pattern.)
//
//  Honest boundary, restated from the surface docs: this is a Swift-surface property, not a
//  security boundary. `MigrationFFITests` covers the other half — the rust seam refusing a forged
//  id over the real FFI, which is the actual safety backstop.
//
//  ONE deliberate escape hatch exists, and it is not reachable from this file's plain import:
//  both initializers are `@_spi(Testing) public`, so a TEST target that writes
//  `@_spi(Testing) import ZODLSwiftWalletSDK` may construct instructions (downstream apps'
//  suites need genuine instructions to exercise their drivers). The SPI name is the ceremony —
//  greppable, deliberate, and never present in a production import. This file intentionally
//  keeps the plain import so the claims above stay verified against the surface an app ships on.
//

import Foundation
import XCTest
import ZODLSwiftWalletSDK

final class MigrationInstructionOpacityTests: XCTestCase {
    /// Nothing this file can build names a transaction for an executor to act on.
    ///
    /// The steps that carry no instruction at all — everything a driver performs by *reading*
    /// rather than by discharging an executor — are freely constructible, so a host can still model
    /// and test its own waiting/attention/rebuild UI with no SDK-internal access. `.broadcast` is
    /// absent because it cannot be written here at all. `.prove` appears only as the inert EMPTY
    /// batch, the one instruction-shaped value an `Array` literal can produce without an element:
    /// it names nothing, so it commands nothing.
    func testNoNonEmptyInstructionIsConstructibleFromThePublicSurface() {
        let instructionFree: [MigrationAdvanceStep] = [
            .waiting,
            .complete,
            .rebuild(id: 6),
            .replan,
            .reevaluate
        ]

        for step in instructionFree {
            XCTAssertNil(
                Self.executorArm(for: step),
                "\(step) carries no instruction, so no instruction executor discharges it"
            )
        }

        // The one instruction-shaped step a plain `import` can construct, and the reason it is
        // harmless: an empty batch routes to the prove executor but names no transaction, so the
        // capability it confers is nil. `.broadcast` has no such loophole — a single opaque
        // payload cannot be conjured the way an empty `Array` can.
        let emptyProve = MigrationAdvanceStep.prove(transactions: [])
        XCTAssertEqual(Self.executorArm(for: emptyProve), "proveMigrationTransactions")
        guard case .prove(let instruction) = emptyProve else {
            return XCTFail("the empty prove batch must still match the .prove arm")
        }
        XCTAssertTrue(instruction.isEmpty, "an empty batch instructs nothing; the executor answers 0")

        // The public `MigrationAdvance` initializer accepts these unchanged.
        XCTAssertEqual(
            MigrationAdvance(step: .waiting, next: MigrationNextWork(height: 850_000, kind: .broadcast)).step,
            .waiting
        )
    }

    /// Which instruction executor a step routes to, or `nil` for the steps that route to none.
    /// Exhaustive over `MigrationAdvanceStep` from the PUBLIC vantage, so adding a case (or
    /// re-shaping one) fails this file's build rather than silently falling through.
    private static func executorArm(for step: MigrationAdvanceStep) -> String? {
        switch step {
        case .prove:
            return "proveMigrationTransactions"
        case .broadcast:
            return "performMigrationBroadcast"
        case .rebuild, .replan, .reevaluate, .waiting, .complete:
            return nil
        }
    }
}

/// COMPILE-TIME FIXTURE, never invoked (see this file's header, claim 1): the reference driver
/// dispatch exactly as the `migrationAdvanceStep(accountUUID:)` documentation prescribes it,
/// written against the public surface alone. Its value is that it type-checks: each actionable arm
/// hands the step's OWN payload straight to an executor, with nothing in between — including the
/// prove arm's full handoff (prove -> take-by-txid -> submit -> mark), so a change to any link in
/// that chain has to come back through this fixture.
///
/// `submitRawTransaction` stands in for whatever raw-transaction machinery the host already has;
/// the SDK deliberately supplies none, since a proved preparation's submission is the host's
/// ordinary path.
private func performDictate(
    of advance: MigrationAdvance?,
    for accountUUID: AccountUUID,
    on synchronizer: Synchronizer,
    options: MigrationNetworkPrivacyOptions,
    maxProofs: Int,
    submitRawTransaction: (Data) async -> String?
) async throws {
    switch advance?.step {
    case .prove(let instruction):
        let outcome = try await synchronizer.proveMigrationTransactions(
            accountUUID: accountUUID,
            instruction,
            maxProofs: maxProofs
        )
        // The preparations this pass proved are the host's to submit. No kind judgement here: the
        // return names preparations only, and the accessor refuses anything else.
        for txid in outcome.preparationTxids {
            let prepared = try await synchronizer.takeMigrationPreparation(accountUUID: accountUUID, byTxid: txid)
            guard let landedTxId = await submitRawTransaction(prepared.pczt) else { continue }
            try await synchronizer.recordMigrationPreparationBroadcast(
                accountUUID: accountUUID,
                prepared,
                result: .success(txId: landedTxId)
            )
        }
    case .broadcast(let instruction):
        _ = try await synchronizer.performMigrationBroadcast(accountUUID: accountUUID, instruction, options: options)
    case .rebuild:
        // The third executor, unchanged by this task: it already discharged the `.rebuild` dictate.
        _ = try await synchronizer.refreshStaleMigrationTransfers(accountUUID: accountUUID, usk: nil)
    case .replan, .reevaluate, .waiting, .complete, .none:
        break
    }
}
