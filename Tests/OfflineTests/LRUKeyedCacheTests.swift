//
//  LRUKeyedCacheTests.swift
//  ZcashLightClientKit
//
//  Copyright © 2026 Znewco, Inc. (d/b/a Zcash Open Development Lab)
//  Licensed under the GNU Affero General Public License, version 3 only (AGPL-3.0-only).
//  See LICENSE, LICENSE-EXCEPTIONS.md and COMMERCIAL-LICENSE.md in this repository.
//

import XCTest
@testable import ZcashLightClientKit

final class LRUKeyedCacheTests: XCTestCase {
    func testInsertingPastCapacityEvictsTheLeastRecentlyUsedEntry() {
        var cache = LRUKeyedCache<String, Int>(capacity: 2)

        XCTAssertNil(cache.insert(1, forKey: "a"))
        XCTAssertNil(cache.insert(2, forKey: "b"))

        let evicted = cache.insert(3, forKey: "c")
        XCTAssertEqual(evicted?.key, "a")
        XCTAssertEqual(evicted?.value, 1)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.value(forKey: "c"), 3)
    }

    func testReadingAnEntryMakesItMostRecentlyUsed() {
        var cache = LRUKeyedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")

        XCTAssertEqual(cache.value(forKey: "a"), 1, "the read refreshes 'a'")

        let evicted = cache.insert(3, forKey: "c")
        XCTAssertEqual(evicted?.key, "b", "'b' is now the least recently used entry")
        XCTAssertEqual(cache.value(forKey: "a"), 1)
    }

    func testReplacingAnExistingKeyEvictsNothingAndRefreshesIt() {
        var cache = LRUKeyedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")

        XCTAssertNil(cache.insert(10, forKey: "a"))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(forKey: "a"), 10)

        let evicted = cache.insert(3, forKey: "c")
        XCTAssertEqual(evicted?.key, "b")
    }

    func testRemovingEntries() {
        var cache = LRUKeyedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")

        XCTAssertEqual(cache.removeValue(forKey: "a"), 1)
        XCTAssertNil(cache.removeValue(forKey: "a"))
        XCTAssertEqual(cache.count, 1)

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(forKey: "b"))
    }
}
