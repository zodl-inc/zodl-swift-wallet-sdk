//
//  WitnessesFixGateTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import ZODLSwiftWalletSDK

class WitnessesFixGateTests: XCTestCase {
    private struct VersionCase {
        let recorded: String
        let current: String
        let shouldRunFix: Bool
        let note: String
    }

    private var suiteName = ""
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "WitnessesFixGateTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        try super.tearDownWithError()
    }

    private func makeGate(currentVersion: String?, alias: ZcashSynchronizerAlias = .default) -> WitnessesFixGate {
        WitnessesFixGate(currentVersion: currentVersion, userDefaults: userDefaults, alias: alias)
    }

    /// Replays "the fix last ran under `recorded`, the app now reports `current`" through the
    /// gate's own API, so the tests exercise the persistence rather than a hand-seeded key.
    private func decision(
        recorded: String?,
        current: String?,
        alias: ZcashSynchronizerAlias = .default
    ) -> WitnessesFixGate.Decision {
        if let recorded {
            makeGate(currentVersion: recorded, alias: alias).recordCurrentVersion()
        }

        return makeGate(currentVersion: current, alias: alias).decide()
    }

    func testRunsWhenNoVersionIsRecorded() {
        XCTAssertEqual(makeGate(currentVersion: "2.9.0").decide(), .firstRun(current: "2.9.0"))
    }

    func testVersionPairsAreComparedNumerically() {
        let cases: [VersionCase] = [
            // Plain upgrades keep running the fix.
            VersionCase(recorded: "2.9.0", current: "3.0.0", shouldRunFix: true, note: "major bump"),
            VersionCase(recorded: "2.9.0", current: "2.9.1", shouldRunFix: true, note: "patch bump"),
            // Differing digit counts are the regression this pins: a lexicographic String
            // comparison orders "2.10.0" before "2.9.0", and "2.100.0" before "2.99.0".
            VersionCase(recorded: "2.9.0", current: "2.10.0", shouldRunFix: true, note: "minor single→double digit"),
            VersionCase(recorded: "2.4.9", current: "2.4.10", shouldRunFix: true, note: "patch single→double digit"),
            VersionCase(recorded: "2.99.0", current: "2.100.0", shouldRunFix: true, note: "minor double→triple digit"),
            // Same version runs only once.
            VersionCase(recorded: "2.10.0", current: "2.10.0", shouldRunFix: false, note: "same version"),
            // Downgrades do not re-run the fix.
            VersionCase(recorded: "2.10.0", current: "2.9.0", shouldRunFix: false, note: "downgrade"),
            VersionCase(recorded: "3.0.0", current: "2.99.0", shouldRunFix: false, note: "downgrade across major"),
            // Missing components count as zero. The first row is the one that makes the padding
            // load-bearing — without it "3.8" sorts before "3.8.0" and this upgrade is skipped.
            VersionCase(recorded: "3.8", current: "3.8.1", shouldRunFix: true, note: "padded upgrade"),
            VersionCase(recorded: "3.8.1", current: "3.8", shouldRunFix: false, note: "padded downgrade"),
            VersionCase(recorded: "3.8", current: "3.8.0", shouldRunFix: false, note: "3.8 equals 3.8.0"),
            VersionCase(recorded: "3.8", current: "3.9", shouldRunFix: true, note: "two-component upgrade")
        ]

        for testCase in cases {
            XCTAssertEqual(
                decision(recorded: testCase.recorded, current: testCase.current).shouldRunFix,
                testCase.shouldRunFix,
                "(\(testCase.recorded) → \(testCase.current)) expected shouldRunFix == \(testCase.shouldRunFix) — \(testCase.note)"
            )
        }
    }

    func testUnorderableVersionsRunTheFixOncePerVersionString() {
        // Versions that cannot be parsed numerically cannot be ordered; the gate must fail open
        // (run the fix) rather than risk skipping a repair…
        XCTAssertTrue(decision(recorded: "unknown", current: "3.9.0").shouldRunFix)
        XCTAssertTrue(decision(recorded: "3.9.0", current: "unknown").shouldRunFix)
        XCTAssertTrue(decision(recorded: "2.9.0-beta", current: "2.9.0").shouldRunFix)
        // …but an identical recorded string means this exact version already ran.
        XCTAssertFalse(decision(recorded: "unknown", current: "unknown").shouldRunFix)
    }

    func testSignPrefixedComponentsAreNotTreatedAsNumbers() {
        // Int("+9") is 9, so a bare Int conversion reads "1.+9.0" as 1.9.0 and skips the repair.
        // Both sign forms have to fail open instead.
        XCTAssertTrue(decision(recorded: "1.9.0", current: "1.+9.0").shouldRunFix)
        XCTAssertTrue(decision(recorded: "1.9.0", current: "1.-9.0").shouldRunFix)
    }

    func testUnknownAppVersionRunsTheFixAndRecordsNothing() {
        makeGate(currentVersion: "2.9.0").recordCurrentVersion()

        // A host that reports no CFBundleShortVersionString must not overwrite the record with an
        // empty sentinel — that would both destroy the history and latch the gate shut.
        let gate = makeGate(currentVersion: nil)
        XCTAssertEqual(gate.decide(), .unknownAppVersion)
        gate.recordCurrentVersion()

        XCTAssertEqual(makeGate(currentVersion: "2.9.0").decide(), .sameVersion(current: "2.9.0"))
        // And such a host keeps failing open on every launch rather than running exactly once.
        XCTAssertTrue(makeGate(currentVersion: nil).decide().shouldRunFix)
    }

    func testEachAliasIsGatedIndependently() {
        // Every alias owns its own data DB, so repairing one must not mark the others as done.
        makeGate(currentVersion: "2.10.0", alias: .default).recordCurrentVersion()

        XCTAssertEqual(makeGate(currentVersion: "2.10.0", alias: .default).decide(), .sameVersion(current: "2.10.0"))
        XCTAssertEqual(
            makeGate(currentVersion: "2.10.0", alias: .custom("second")).decide(),
            .firstRun(current: "2.10.0")
        )
    }

    func testADowngradeDoesNotLatchOutLaterReleases() {
        // A beta the user rolls back from must not leave a high-water mark that suppresses the
        // repair for every release below it.
        makeGate(currentVersion: "2.10.0").recordCurrentVersion()

        let downgrade = makeGate(currentVersion: "2.9.0")
        XCTAssertEqual(downgrade.decide(), .downgrade(recorded: "2.10.0", current: "2.9.0"))
        downgrade.recordCurrentVersion()

        XCTAssertEqual(makeGate(currentVersion: "2.9.1").decide(), .upgrade(recorded: "2.9.0", current: "2.9.1"))
    }
}
