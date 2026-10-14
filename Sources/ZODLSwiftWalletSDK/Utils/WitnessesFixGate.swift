//
//  WitnessesFixGate.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// Decides whether the note-commitment-witness repair should run for the host app's current
/// version, and records that version once the decision has been acted on.
///
/// The record is scoped per synchronizer alias, because every alias owns its own data DB and so
/// has to be repaired independently.
///
/// Versions are compared numerically component-wise, so "2.10.0" is newer than "2.9.0". A plain
/// String comparison orders them lexicographically instead, which skips the repair whenever the
/// shorter number's leading digit is the larger one — "2.9.0" before "2.10.0", but also "2.99.0"
/// before "2.100.0". Missing components count as zero, so "3.8" and "3.8.0" are the same version.
///
/// The gate fails open — it runs the repair — whenever it cannot establish that the repair has
/// already run for this version: on the first launch, after an upgrade, when either version
/// cannot be ordered numerically, and when the host reports no version at all. Running the repair
/// again is idempotent; skipping one that was needed leaves notes unspendable.
struct WitnessesFixGate {
    /// The outcome of the gate, carrying the versions that produced it so that a skipped repair
    /// still leaves a trace in the log.
    enum Decision: Equatable {
        /// The host reports no version. Nothing can be ordered, so the repair runs and no version
        /// is recorded — the next launch decides afresh.
        case unknownAppVersion
        /// Nothing recorded yet for this alias.
        case firstRun(current: String)
        /// The current version is numerically newer than the recorded one.
        case upgrade(recorded: String, current: String)
        /// At least one of the two versions is not a dotted list of numbers.
        case unorderable(recorded: String, current: String)
        /// The repair already ran for this exact version.
        case sameVersion(current: String)
        /// The current version is numerically older than the recorded one.
        case downgrade(recorded: String, current: String)

        var shouldRunFix: Bool {
            switch self {
            case .unknownAppVersion, .firstRun, .upgrade, .unorderable:
                return true
            case .sameVersion, .downgrade:
                return false
            }
        }
    }

    private let currentVersion: String?
    private let userDefaults: UserDefaults
    private let key: String

    init(currentVersion: String?, userDefaults: UserDefaults, alias: ZcashSynchronizerAlias) {
        self.currentVersion = currentVersion
        self.userDefaults = userDefaults
        self.key = "ud_fixWitnessesLastVersionCall_\(alias.description)"
    }

    func decide() -> Decision {
        guard let currentVersion else { return .unknownAppVersion }
        guard let recordedVersion = userDefaults.string(forKey: key) else { return .firstRun(current: currentVersion) }
        guard recordedVersion != currentVersion else { return .sameVersion(current: currentVersion) }

        guard
            let recorded = Self.numericComponents(of: recordedVersion),
            let current = Self.numericComponents(of: currentVersion)
        else {
            return .unorderable(recorded: recordedVersion, current: currentVersion)
        }

        return Self.isNewer(current, than: recorded)
            ? .upgrade(recorded: recordedVersion, current: currentVersion)
            : .downgrade(recorded: recordedVersion, current: currentVersion)
    }

    /// Records the version the gate has just decided for, whether or not the repair ran.
    ///
    /// Recording on the skip path too keeps the record tracking the version that is actually
    /// running. If the record only ever moved forward, one higher version — a beta the user later
    /// rolled back from — would suppress the repair for every release below it.
    ///
    /// Call this only after the repair has been attempted, so that a launch interrupted part-way
    /// through leaves nothing recorded and retries next time.
    func recordCurrentVersion() {
        guard let currentVersion else { return }

        userDefaults.set(currentVersion, forKey: key)
    }

    private static func isNewer(_ current: [Int], than recorded: [Int]) -> Bool {
        let width = max(current.count, recorded.count)

        return zeroPadded(recorded, to: width).lexicographicallyPrecedes(zeroPadded(current, to: width))
    }

    /// Missing trailing components count as zero. The padding is what makes that true — comparing
    /// the raw arrays would order [3, 8] before [3, 8, 0].
    private static func zeroPadded(_ components: [Int], to width: Int) -> [Int] {
        components + Array(repeating: 0, count: width - components.count)
    }

    /// Parses a dotted version into its numeric components, or returns nil when any component is
    /// not a plain ASCII number. `Int(_:)` on its own is too permissive here: it accepts a leading
    /// sign, so "1.+9.0" would parse as 1.9.0 and compare equal to it.
    private static func numericComponents(of version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { component -> Int? in
            guard component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

            return Int(component)
        }

        guard numbers.count == components.count else { return nil }

        return numbers
    }
}

extension WitnessesFixGate.Decision: CustomStringConvertible {
    var description: String {
        switch self {
        case .unknownAppVersion:
            return "the host app reports no version, running the repair defensively"
        case let .firstRun(current):
            return "nothing recorded yet, running the repair for \(current)"
        case let .upgrade(recorded, current):
            return "upgraded from \(recorded) to \(current), running the repair"
        case let .unorderable(recorded, current):
            return "\(recorded) and \(current) cannot be ordered numerically, running the repair defensively"
        case let .sameVersion(current):
            return "the repair already ran for \(current), skipping"
        case let .downgrade(recorded, current):
            return "downgraded from \(recorded) to \(current), skipping the repair"
        }
    }
}
