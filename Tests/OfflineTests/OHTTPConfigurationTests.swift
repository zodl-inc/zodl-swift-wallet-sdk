//
//  OHTTPConfigurationTests.swift
//  OfflineTests
//
//  The OHTTP configuration the app installs at launch (`OHTTPEndpoints.configure(_:)`): what installing it turns
//  on, what nil turns off, what is refused, and that a new configuration replaces the old one whole.
//

import XCTest
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPConfigurationTests: XCTestCase {
    private let example = OHTTPTestSupport.exampleConfiguration
    private let mainnet = OHTTPTestSupport.exampleMainnet
    private let testnet = OHTTPTestSupport.exampleTestnet

    /// URLs of the hosts the gateways carry: the aliases with gateway-held credentials, an allowlisted vote
    /// server and the path-restricted voting-config mirror.
    private let proxiedURLs = [
        "https://api.flexa.co/accounts",
        "https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest",
        "https://1click.chaindefuser.com/v0/quote",
        "https://vote.zodl.com/round",
        "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/config.json"
    ]

    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    override func tearDown() {
        // The tests here install other configurations; the tests run after them find the example again.
        OHTTPTestSupport.installExampleConfiguration()
        super.tearDown()
    }

    func testConfigureInstallsGatewayHosts() throws {
        try OHTTPEndpoints.configure(nil)
        try OHTTPEndpoints.configure(example)

        XCTAssertEqual(OHTTPEndpoints.configuration, example)
        XCTAssertEqual(OHTTPEndpoints.gatewayHost(for: .mainnet), mainnet.gatewayHost)
        XCTAssertEqual(OHTTPEndpoints.gatewayHost(for: .testnet), testnet.gatewayHost)
        for (network, name, configuration) in [(NetworkType.mainnet, "mainnet", mainnet), (NetworkType.testnet, "testnet", testnet)] {
            let host = configuration.gatewayHost
            XCTAssertTrue(OHTTPEndpoints.isGateway(host))
            XCTAssertEqual(try OHTTPEndpoints.relayURL(for: host), configuration.relayURL)
            XCTAssertEqual(OHTTPEndpoints.network(for: host), name)
            XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: host, network: network))
            let route = try OHTTPEndpoints.proxyRoute(for: "vote.zodl.com", network: network)
            XCTAssertEqual(route.gatewayHost, host)
            XCTAssertEqual(route.relayURL, configuration.relayURL)
            let dnsQueries = try OHTTPNative.dohQueryURLs(gatewayHost: host)
            XCTAssertTrue(dnsQueries.allSatisfy { $0.contains(configuration.keysDNSName) })
        }
        for url in try proxiedURLs.map({ try XCTUnwrap(URL(string: $0)) }) {
            XCTAssertNotNil(OHTTPEndpoints.proxyURL(for: url), url.absoluteString)
        }
    }

    func testConfigureNilTurnsOHTTPOff() throws {
        let offConfigurations: [OHTTPConfiguration?] = [nil, OHTTPConfiguration(mainnet: nil, testnet: nil)]
        for configuration in offConfigurations {
            try OHTTPEndpoints.configure(configuration)

            XCTAssertEqual(OHTTPEndpoints.configuration, configuration)
            XCTAssertNil(OHTTPEndpoints.gatewayHost(for: .mainnet))
            XCTAssertNil(OHTTPEndpoints.gatewayHost(for: .testnet))
            for host in [mainnet.gatewayHost, testnet.gatewayHost] {
                XCTAssertFalse(OHTTPEndpoints.isGateway(host))
                XCTAssertNil(OHTTPEndpoints.network(for: host))
                XCTAssertThrowsError(try OHTTPEndpoints.relayURL(for: host)) { self.assertNoRelay($0) }
                // What was a gateway is a plain server now, of either network.
                XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: host, network: .mainnet))
                XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: host, network: .testnet))
            }
            for url in try proxiedURLs.map({ try XCTUnwrap(URL(string: $0)) }) {
                XCTAssertNil(OHTTPEndpoints.proxyURL(for: url), url.absoluteString)
            }
            for network in [NetworkType.mainnet, NetworkType.testnet] {
                XCTAssertThrowsError(try OHTTPEndpoints.proxyRoute(for: "vote.zodl.com", network: network)) { self.assertNoRelay($0) }
            }
        }
    }

    /// A configuration `configure` must refuse, and what its error names: the field, and the network or the pair.
    private struct Refused {
        let field: String
        let network: String
        let configuration: OHTTPConfiguration
    }

    func testConfigureRejectsInvalidValueWithoutEchoingIt() throws {
        let refused = [
            Refused(
                field: "gateway_host",
                network: "mainnet",
                configuration: OHTTPConfiguration(mainnet: replacing(mainnet, gatewayHost: "OHTTP-GATEWAY.example"), testnet: testnet)
            ),
            Refused(
                field: "relay_url",
                network: "mainnet",
                configuration: OHTTPConfiguration(mainnet: replacing(mainnet, relayURL: "https://relay-mainnet.example/relay?via=1"), testnet: testnet)
            ),
            Refused(
                field: "keys_dns_name",
                network: "mainnet",
                configuration: OHTTPConfiguration(mainnet: replacing(mainnet, keysDNSName: ""), testnet: testnet)
            ),
            Refused(
                field: "keys_dns_name",
                network: "testnet",
                configuration: OHTTPConfiguration(mainnet: mainnet, testnet: replacing(testnet, keysDNSName: "testnet.ohttp-keys.example."))
            ),
            Refused(
                field: "signing_pubkey",
                network: "testnet",
                configuration: OHTTPConfiguration(
                    mainnet: mainnet,
                    testnet: replacing(testnet, signingPublicKey: String(testnet.signingPublicKey.dropLast()))
                )
            ),
            // Both networks with one relay: the error is about the pair, not one network.
            Refused(
                field: "relay_url",
                network: "mainnet and testnet",
                configuration: OHTTPConfiguration(mainnet: mainnet, testnet: replacing(testnet, relayURL: mainnet.relayURL))
            )
        ]
        for refusal in refused {
            let values = [refusal.configuration.mainnet, refusal.configuration.testnet]
                .compactMap { $0 }
                .flatMap { [$0.gatewayHost, $0.relayURL, $0.keysDNSName, $0.signingPublicKey] }
                .filter { !$0.isEmpty }
            XCTAssertThrowsError(try OHTTPEndpoints.configure(refusal.configuration), refusal.field) { error in
                guard case let ZcashError.ohttpConfigurationInvalid(message) = error else {
                    return XCTFail("Expected ohttpConfigurationInvalid for \(refusal.field), got another error")
                }
                XCTAssertTrue(message.contains(refusal.field), message)
                XCTAssertTrue(message.contains(refusal.network), message)
                for value in values {
                    XCTAssertFalse(message.lowercased().contains(value.lowercased()), "The error for \(refusal.field) quotes a value")
                }
            }
            // The configuration installed before stays, in the native layer as well.
            XCTAssertEqual(OHTTPEndpoints.configuration, example)
            XCTAssertEqual(OHTTPEndpoints.gatewayHost(for: .mainnet), mainnet.gatewayHost)
            XCTAssertEqual(try OHTTPEndpoints.relayURL(for: testnet.gatewayHost), testnet.relayURL)
        }
    }

    func testReconfigureReplacesPreviousConfiguration() async throws {
        let cache = OHTTPKeyCache()
        let keyFetches = OSAllocatedUnfairLock(initialState: 0)
        let mainnet = self.mainnet
        func mainnetGatewayTransport() -> OHTTPTransport {
            OHTTPTransport(
                gatewayHost: mainnet.gatewayHost,
                relayURL: mainnet.relayURL,
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
                keyCache: cache,
                httpSender: { request, _ in
                    keyFetches.withLock { $0 += 1 }
                    return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
                }
            )
        }
        _ = try await mainnetGatewayTransport().keyConfig()
        _ = try await mainnetGatewayTransport().keyConfig()
        XCTAssertEqual(keyFetches.withLock { $0 }, 1, "A transport of the same configuration finds the key in the cache")

        // The mainnet values, installed as testnet's, with mainnet off.
        let replacement = OHTTPConfiguration(mainnet: nil, testnet: mainnet)
        try OHTTPEndpoints.configure(replacement)

        XCTAssertEqual(OHTTPEndpoints.configuration, replacement)
        XCTAssertNil(OHTTPEndpoints.gatewayHost(for: .mainnet))
        XCTAssertEqual(OHTTPEndpoints.gatewayHost(for: .testnet), mainnet.gatewayHost)
        XCTAssertEqual(OHTTPEndpoints.network(for: mainnet.gatewayHost), "testnet")
        XCTAssertEqual(try OHTTPEndpoints.relayURL(for: mainnet.gatewayHost), mainnet.relayURL)
        XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: mainnet.gatewayHost, network: .testnet))
        XCTAssertThrowsError(try OHTTPEndpoints.checkGatewayNetwork(host: mainnet.gatewayHost, network: .mainnet))
        XCTAssertEqual(try OHTTPEndpoints.proxyRoute(for: "vote.zodl.com", network: .testnet).gatewayHost, mainnet.gatewayHost)
        XCTAssertThrowsError(try OHTTPEndpoints.proxyRoute(for: "vote.zodl.com", network: .mainnet)) { self.assertNoRelay($0) }
        // Nothing of the previous testnet configuration is left.
        XCTAssertFalse(OHTTPEndpoints.isGateway(testnet.gatewayHost))
        XCTAssertNil(OHTTPEndpoints.network(for: testnet.gatewayHost))
        XCTAssertThrowsError(try OHTTPEndpoints.relayURL(for: testnet.gatewayHost)) { self.assertNoRelay($0) }
        XCTAssertFalse(try OHTTPNative.dohQueryURLs(gatewayHost: mainnet.gatewayHost).contains { $0.contains(testnet.keysDNSName) })

        // The key cached while this gateway was mainnet's is not served under the new configuration.
        _ = try await mainnetGatewayTransport().keyConfig()
        XCTAssertEqual(keyFetches.withLock { $0 }, 2, "A key cached under the previous configuration was served")
    }

    func testGatewayMatchingIgnoresCase() throws {
        for (network, name, otherNetwork, configuration) in [
            (NetworkType.mainnet, "mainnet", NetworkType.testnet, mainnet),
            (NetworkType.testnet, "testnet", NetworkType.mainnet, testnet)
        ] {
            let host = configuration.gatewayHost
            let callers = [
                host.uppercased(),
                host.capitalized,
                host.replacingOccurrences(of: "ohttp-gateway", with: "OHTTP-GATEWAY")
            ]
            for caller in callers {
                XCTAssertNotEqual(caller, host)
                XCTAssertTrue(OHTTPEndpoints.isGateway(caller), caller)
                XCTAssertEqual(try OHTTPEndpoints.relayURL(for: caller), configuration.relayURL)
                XCTAssertEqual(OHTTPEndpoints.network(for: caller), name)
                XCTAssertEqual(try OHTTPEndpoints.proxyRoute(for: caller, network: network).gatewayHost, host)
                XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: caller, network: network))
                // The other network's gateway is refused without its host in the error, in any case.
                XCTAssertThrowsError(try OHTTPEndpoints.checkGatewayNetwork(host: caller, network: otherNetwork)) {
                    self.assertNamesNoGatewayHost($0)
                }
                XCTAssertThrowsError(try OHTTPEndpoints.proxyRoute(for: caller, network: otherNetwork)) {
                    self.assertNamesNoGatewayHost($0)
                }
            }
            for lookalike in ["\(host).attacker.example", "attacker-\(host)", "\(host)."] {
                XCTAssertFalse(OHTTPEndpoints.isGateway(lookalike), lookalike)
                XCTAssertNil(OHTTPEndpoints.network(for: lookalike), lookalike)
            }
        }
    }

    func testDescriptionHidesValues() {
        let values = [mainnet, testnet].flatMap { [$0.gatewayHost, $0.relayURL, $0.keysDNSName, $0.signingPublicKey] }
        var dumped = ""
        dump(example, to: &dumped)
        let texts = [
            example.description,
            String(describing: example),
            String(reflecting: example),
            "\(example)",
            String(describing: mainnet),
            String(reflecting: testnet),
            dumped
        ]
        for text in texts {
            for value in values {
                XCTAssertFalse(text.lowercased().contains(value.lowercased()), "A description shows a configured value")
            }
        }

        let allSet = "OHTTPNetworkConfiguration(gatewayHost: <set>, relayURL: <set>, keysDNSName: <set>, signingPublicKey: <set>)"
        XCTAssertEqual(example.description, "OHTTPConfiguration(mainnet: \(allSet), testnet: \(allSet))")
        let partial = OHTTPConfiguration(mainnet: replacing(mainnet, relayURL: "", signingPublicKey: ""), testnet: nil)
        let partlySet = "OHTTPNetworkConfiguration(gatewayHost: <set>, relayURL: <empty>, keysDNSName: <set>, signingPublicKey: <empty>)"
        XCTAssertEqual(partial.description, "OHTTPConfiguration(mainnet: \(partlySet), testnet: nil)")
    }

    /// `network` with the values passed in place of its own.
    private func replacing(
        _ network: OHTTPNetworkConfiguration,
        gatewayHost: String? = nil,
        relayURL: String? = nil,
        keysDNSName: String? = nil,
        signingPublicKey: String? = nil
    ) -> OHTTPNetworkConfiguration {
        OHTTPNetworkConfiguration(
            gatewayHost: gatewayHost ?? network.gatewayHost,
            relayURL: relayURL ?? network.relayURL,
            keysDNSName: keysDNSName ?? network.keysDNSName,
            signingPublicKey: signingPublicKey ?? network.signingPublicKey
        )
    }

    /// Checks that `error` is the error of a host no installed gateway carries.
    private func assertNoRelay(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let OHTTPError.transportError(message) = error else {
            return XCTFail("Expected an OHTTP transport error, got another error", file: file, line: line)
        }
        XCTAssertTrue(message.hasPrefix("No OHTTP relay configured for gateway host"), message, file: file, line: line)
    }

    /// Checks that the text of `error`, its associated values included, names no configured gateway host in any
    /// letter case: a configured host is a value and never goes into an error.
    private func assertNamesNoGatewayHost(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let text = String(describing: error).lowercased()
        for host in [mainnet.gatewayHost, testnet.gatewayHost] {
            XCTAssertFalse(text.contains(host), "An error text names a configured gateway host", file: file, line: line)
        }
    }
}
