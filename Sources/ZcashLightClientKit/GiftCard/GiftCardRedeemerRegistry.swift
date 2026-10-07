import Foundation

/// The aliases of the redeemers alive in this process.
///
/// `UsedAliasesChecker` exists but nothing calls it, so two synchronizers can share an alias and
/// overwrite each other's files. A gift card's alias is unique to the card, so this registry is
/// what keeps two redeemers of the same card apart.
enum GiftCardRedeemerRegistry {
    private static let lock = NSLock()
    private struct Claim {
        let owner: UUID
        var coordinator: GiftCardCleanupCoordinator?
    }
    private static var active: [ZcashSynchronizerAlias: Claim] = [:]

    static func claim(_ alias: ZcashSynchronizerAlias, owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active[alias] == nil else {
            return false
        }
        active[alias] = Claim(owner: owner, coordinator: nil)
        return true
    }

    static func retainCleanup(alias: ZcashSynchronizerAlias, owner: UUID, coordinator: GiftCardCleanupCoordinator) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active[alias]?.owner == owner else { return false }
        active[alias]?.coordinator = coordinator
        return true
    }

    static func release(_ alias: ZcashSynchronizerAlias, owner: UUID) {
        lock.lock()
        guard active[alias]?.owner == owner else {
            lock.unlock()
            return
        }
        let released = active.removeValue(forKey: alias)
        lock.unlock()
        // Drop retained resources outside the registry lock.
        withExtendedLifetime(released) {}
    }

    /// Runs `body` with the active aliases, holding off every claim and release until it returns.
    static func withActiveAliases<T>(_ body: (Set<ZcashSynchronizerAlias>) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(Set(active.keys))
    }
}
