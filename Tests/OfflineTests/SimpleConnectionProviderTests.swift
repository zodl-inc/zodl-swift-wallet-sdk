//
//  SimpleConnectionProviderTests.swift
//  OfflineTests
//
//  Pins the provider's lazy-init single-flight: since the DBActor read/write split, off-actor
//  readers hit `connection()` from arbitrary threads, and a racing pair of first-touches used
//  to be able to construct two `Connection`s (checked-then-assigned `var` with no lock). The
//  old race cannot be made deterministically red without scheduling hooks, so this test pins
//  the fixed invariant instead: any number of concurrent first-touches observe one identical
//  instance.
//

import XCTest
import SQLite
@testable import ZODLSwiftWalletSDK

final class SimpleConnectionProviderTests: XCTestCase {
    var dbPath: String!

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleConnectionProviderTests-\(UUID().uuidString).db")
        dbPath = url.path
    }

    override func tearDown() {
        super.tearDown()
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
    }

    func testConcurrentFirstTouchesYieldOneConnection() async throws {
        let provider = SimpleConnectionProvider(path: dbPath)

        let identifiers = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let conn = try? provider.connection()
                    return conn.map(ObjectIdentifier.init)
                }
            }

            var collected: [ObjectIdentifier?] = []
            for await identifier in group {
                collected.append(identifier)
            }
            return collected
        }

        let resolved = identifiers.compactMap { $0 }
        XCTAssertEqual(resolved.count, 16, "every concurrent first-touch must resolve a connection")
        XCTAssertEqual(
            Set(resolved).count,
            1,
            "all concurrent first-touches must observe the same lazily-created Connection instance"
        )
    }

    func testCloseThenReconnectYieldsFreshConnection() throws {
        let provider = SimpleConnectionProvider(path: dbPath)

        let first = try provider.connection()
        XCTAssertTrue(try provider.connection() === first, "steady-state calls serve the cached instance")

        provider.close()
        let second = try provider.connection()
        XCTAssertFalse(second === first, "close() drops the cached instance; the next call re-creates")
    }
}
