//
//  SlipstreamImportAnchorTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// [MOB-2184] `importAccount` asks the synchronizer's anchor resolver for its restore anchor, as
/// `prepare` does, instead of calling the engine's `restore_anchor` itself. The resolver a shipped
/// synchronizer is built with is exactly that call, so nothing changes for a host; what changes is
/// that a test can now drive an import without a server, which is what lets the import's stop be
/// tested at all.
final class SlipstreamImportAnchorTests: ZcashTestCase {
    func testImportAccountTakesItsRestoreAnchorFromTheInjectedResolver() async throws {
        let requests = AnchorRequests()
        let welding = ZcashRustBackendWeldingMock()
        welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceClosure = { _, _, _, _, _, _, _, _ in
            TestsData.mockedAccountUUID
        }
        let sync = try makeSlipstreamSynchronizer(
            engine: GatedFakeSlipstreamEngine(),
            welding: welding,
            restoreAnchor: { isRestore, birthday, _, server, _, _ in
                requests.append(AnchorRequest(isRestore: isRestore, birthday: birthday, host: server.host, port: server.port))
                return SlipstreamRestoreAnchor(height: 2_000_000, treeState: nil)
            }
        )
        await sync.setInternalSyncStatusForTesting(.disconnected)

        _ = try await sync.importAccount(
            ufvk: "not-a-viewing-key",
            seedFingerprint: nil,
            zip32AccountIndex: nil,
            purpose: .viewOnly,
            name: "Imported",
            keySource: nil,
            birthday: 1_000_000
        )

        let endpoint = LightWalletEndpointBuilder.default
        XCTAssertEqual(
            requests.all,
            [AnchorRequest(isRestore: true, birthday: 1_000_000, host: endpoint.host, port: endpoint.port)],
            "the import asks the injected resolver once, for a restore anchor at the current endpoint"
        )
        let imported = try XCTUnwrap(
            welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReceivedArguments
        )
        XCTAssertEqual(imported.recoverUntil, 2_000_000, "the resolver's anchor is the account's recover-until height")
    }
}

private struct AnchorRequest: Equatable {
    let isRestore: Bool
    let birthday: BlockHeight
    let host: String
    let port: Int
}

/// The anchor requests a resolver received. `NSLock`, as in the other test recorders.
private final class AnchorRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AnchorRequest] = []

    var all: [AnchorRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func append(_ request: AnchorRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
