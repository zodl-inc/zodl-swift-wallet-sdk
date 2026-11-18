//
//  OHTTPNativeThirdPartyHostsTests.swift
//  OfflineTests
//
//  The Swift wrappers of the gateway's third-party host lists.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPNativeThirdPartyHostsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    override func tearDown() {
        OHTTPTestSupport.installExampleConfiguration()
        super.tearDown()
    }

    func testABootstrapHostIsCarriedInLowerCase() {
        XCTAssertEqual(OHTTPNative.thirdPartyCarriedAuthority(host: "VOTE.ZODL.COM", network: .mainnet), "vote.zodl.com")
        XCTAssertEqual(OHTTPNative.thirdPartyCarriedAuthority(host: "VOTE.ZODL.COM", network: .testnet), "vote.zodl.com")
        XCTAssertNil(OHTTPNative.thirdPartyCarriedAuthority(host: "unknown.example.org", network: .mainnet))
    }

    func testARefreshCarriesTheGatewaysRequestAndInstallsTheList() throws {
        let refresh = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        XCTAssertEqual(refresh.authority, OHTTPTestSupport.mainnetHost)
        XCTAssertEqual(refresh.path, "/ohttp-gateway/v1/third-party-hosts")
        XCTAssertNil(refresh.ifNoneMatch)
        XCTAssertTrue(OHTTPNative.thirdPartyIsRefreshing(network: .mainnet))

        XCTAssertEqual(refresh.finish(status: 200, body: OHTTPTestSupport.hostListBody(["vote.example.org"])), .updated)

        XCTAssertEqual(
            OHTTPNative.thirdPartyCarriedAuthority(host: "vote.example.org", network: .mainnet),
            "vote.example.org"
        )
        XCTAssertNil(OHTTPNative.thirdPartyCarriedAuthority(host: "vote.zodl.com", network: .mainnet))
        XCTAssertEqual(
            OHTTPNative.thirdPartyCarriedAuthority(host: "vote.zodl.com", network: .testnet),
            "vote.zodl.com"
        )
        XCTAssertEqual(refresh.finish(status: 200, body: Data()), .superseded)
    }

    func testAFailedRefreshKeepsTheBootstrap() throws {
        let refresh = try XCTUnwrap(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        XCTAssertEqual(refresh.fail(), .kept)
        XCTAssertEqual(OHTTPNative.thirdPartyCarriedAuthority(host: "vote.zodl.com", network: .mainnet), "vote.zodl.com")
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
    }

    func testAnUnfinishedHandleFailsItsRefreshWhenReleased() {
        do {
            let refresh = OHTTPNative.thirdPartyBeginRefresh(network: .mainnet)
            XCTAssertNotNil(refresh)
        }
        XCTAssertFalse(OHTTPNative.thirdPartyIsRefreshing(network: .mainnet))
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
    }

    func testNoteAnswerAsksForARefreshOnlyForAListedHost() {
        OHTTPTestSupport.installHostList(["vote.example.org"])
        let body = Data("unknown authority".utf8)
        XCTAssertTrue(OHTTPNative.thirdPartyNoteAnswer(host: "vote.example.org", network: .mainnet, status: 403, body: body))
        XCTAssertFalse(OHTTPNative.thirdPartyNoteAnswer(host: "vote.example.org", network: .mainnet, status: 403, body: body))
        XCTAssertFalse(OHTTPNative.thirdPartyNoteAnswer(host: "vote.example.org", network: .mainnet, status: 200, body: body))
    }

    func testOHTTPOffAnswersNothing() throws {
        try OHTTPEndpoints.configure(nil)
        XCTAssertNil(OHTTPNative.thirdPartyCarriedAuthority(host: "vote.zodl.com", network: .mainnet))
        XCTAssertNil(OHTTPNative.thirdPartyBeginRefresh(network: .mainnet))
        XCTAssertFalse(OHTTPNative.thirdPartyRefreshBeforeRefusing(network: .mainnet))
    }
}
