//
//  LRUKeyedCache.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)
//  Licensed under the GNU Affero General Public License, version 3 only (AGPL-3.0-only).
//  See LICENSE, LICENSE-EXCEPTIONS.md and COMMERCIAL-LICENSE.md in this repository.
//

import Foundation

/// A keyed cache holding at most `capacity` entries. Inserting a new key at capacity evicts the
/// least recently used entry; every read counts as a use. Small enough that a linear recency list
/// is the whole implementation.
struct LRUKeyedCache<Key: Hashable, Value> {
    let capacity: Int

    private var storage: [Key: Value] = [:]
    /// Least recently used first.
    private var recency: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0, "an LRU cache needs room for at least one entry")
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// The value stored under `key`, marking it as the most recently used.
    mutating func value(forKey key: Key) -> Value? {
        guard let value = storage[key] else {
            return nil
        }

        touch(key)
        return value
    }

    /// Stores `value` under `key`, returning the entry evicted to make room, if any. Storing under
    /// an existing key replaces its value and marks it as the most recently used.
    @discardableResult
    mutating func insert(_ value: Value, forKey key: Key) -> (key: Key, value: Value)? {
        if storage.updateValue(value, forKey: key) != nil {
            touch(key)
            return nil
        }

        recency.append(key)

        guard storage.count > capacity, let evictedKey = recency.first, let evictedValue = storage.removeValue(forKey: evictedKey) else {
            return nil
        }

        recency.removeFirst()
        return (key: evictedKey, value: evictedValue)
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        recency.removeAll { $0 == key }
        return storage.removeValue(forKey: key)
    }

    mutating func removeAll() {
        storage.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let index = recency.firstIndex(of: key) else {
            return
        }

        recency.remove(at: index)
        recency.append(key)
    }
}
