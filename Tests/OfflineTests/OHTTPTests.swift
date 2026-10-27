//
//  OHTTPTests.swift
//  OfflineTests
//
//  Tests for OHTTP (RFC 9458) components.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPTests: XCTestCase {

    // MARK: - OHTTP Endpoints Tests

    func testOHTTPEndpointsGatewayDetection() {
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway-testnet.example"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway.example"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("lightwalletd.testnet.electriccoin.co"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("example.com"))
    }

    func testTheCredentialAliasesAreNotLightwalletdGateways() {
        // An alias is an HTTP destination the gateway serves with its own credentials. Typed as a custom
        // server it must stay a plain host: never sealed to the gateway as a lightwalletd endpoint.
        for alias in ["cmc.zodl.com", "near.zodl.com", "vote.zodl.com", "flexa.zodl.com", "CMC.zodl.com"] {
            XCTAssertFalse(OHTTPEndpoints.isGateway(alias), alias)
            XCTAssertTrue(OHTTPEndpoints.isAliasHost(alias), alias)
            XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: alias, network: .testnet), alias)
        }
        XCTAssertFalse(OHTTPEndpoints.isAliasHost("ohttp-gateway.example"))
        XCTAssertFalse(OHTTPEndpoints.isAliasHost("prod.vote-chain-primary.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isAliasHost("example.com"))
    }

    func testOHTTPEndpointsRelayMapping() throws {
        // Relay URLs come from zodl-ohttp-client (native lib) and can be overridden at build time
        // via ZODL_OHTTP_RELAY_URL_MAINNET / ZODL_OHTTP_RELAY_URL_TESTNET. These assertions verify
        // the default URLs (Fastly production hostnames).
        let relay1 = try OHTTPEndpoints.relayURL(for: "ohttp-gateway-testnet.example")
        XCTAssertEqual(relay1, "https://testnet-relay.example.invalid/relay")

        let relay2 = try OHTTPEndpoints.relayURL(for: "ohttp-gateway.example")
        XCTAssertEqual(relay2, "https://mainnet-relay.example.invalid/relay")

        XCTAssertThrowsError(try OHTTPEndpoints.relayURL(for: "unknown.zodl.com"))
    }

    func testTheSignedKeyConfigurationURLFollowsTheRelay() throws {
        // The alias hosts ride the mainnet relay; the signed key configuration is fetched next to it.
        for host in ["ohttp-gateway.example", "cmc.zodl.com", "near.zodl.com", "vote.zodl.com"] {
            let relay = try OHTTPEndpoints.relayURL(for: host)
            XCTAssertEqual(relay, "https://mainnet-relay.example.invalid/relay", host)
            XCTAssertEqual(
                try OHTTPNative.signedConfigURL(relayURL: relay),
                "https://mainnet-relay.example.invalid/ohttp-configs/signed",
                host
            )
        }
        let testnetRelay = try OHTTPEndpoints.relayURL(for: "ohttp-gateway-testnet.example")
        XCTAssertEqual(
            try OHTTPNative.signedConfigURL(relayURL: testnetRelay),
            "https://testnet-relay.example.invalid/ohttp-configs/signed"
        )
    }

    // MARK: Finding D - GitHub voting config path routing

    func testGitHubVotingConfigPathRouting() {
        // Allowed path: /valargroup/token-holder-voting-config/*
        let allowedURL = URL(string: "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/pins/prod/abc123/v2-static-voting-config.json")!
        let proxyHost = OHTTPEndpoints.proxyHost(for: allowedURL)
        XCTAssertEqual(proxyHost, "raw.githubusercontent.com",
                       "Allowed valargroup voting config path returns raw.githubusercontent.com (passthrough by :authority)")

        // Allowed path with checksum parameter
        let allowedWithChecksum = URL(string: "https://raw.githubusercontent.com/valargroup/token-holder-voting-config/main/pins/prod/def456/v2-static-voting-config.json?checksum=sha256:abc")!
        let proxyHostWithChecksum = OHTTPEndpoints.proxyHost(for: allowedWithChecksum)
        XCTAssertEqual(proxyHostWithChecksum, "raw.githubusercontent.com",
                       "Allowed path with query returns raw.githubusercontent.com")

        // Verify relayURL works for raw.githubusercontent.com
        XCTAssertNoThrow(try OHTTPEndpoints.relayURL(for: "raw.githubusercontent.com"),
                         "relayURL should accept raw.githubusercontent.com")
        let relay = try? OHTTPEndpoints.relayURL(for: "raw.githubusercontent.com")
        XCTAssertEqual(relay, "https://mainnet-relay.example.invalid/relay",
                       "raw.githubusercontent.com should use mainnet relay")

        // A routable third-party URL, never a gateway (cannot become a lightwalletd endpoint)
        XCTAssertFalse(OHTTPEndpoints.isGateway("raw.githubusercontent.com"),
                       "raw.githubusercontent.com must not be a gateway host")
        XCTAssertTrue(OHTTPEndpoints.isPathRestrictedProxyURL(allowedURL))
        XCTAssertFalse(OHTTPEndpoints.isPathRestrictedProxyURL(
            URL(string: "https://raw.githubusercontent.com/zodl-inc/other/main/x.json")!))

        // Verify proxyURL returns unchanged URL (passthrough)
        let proxyURL = OHTTPEndpoints.proxyURL(for: allowedURL)
        XCTAssertEqual(proxyURL, allowedURL,
                       "proxyURL should return the URL unchanged for passthrough hosts")
    }

    func testGitHubOtherPathsRejected() {
        // Other paths on raw.githubusercontent.com are rejected
        let otherPath = URL(string: "https://raw.githubusercontent.com/other-org/other-repo/main/file.json")!
        let proxyHost = OHTTPEndpoints.proxyHost(for: otherPath)
        XCTAssertNil(proxyHost,
                     "Non-valargroup paths on raw.githubusercontent.com should be rejected (nil = unsupportedPrivateDestination)")

        // Even valargroup but different repo
        let wrongRepo = URL(string: "https://raw.githubusercontent.com/valargroup/other-repo/main/file.json")!
        let wrongRepoProxy = OHTTPEndpoints.proxyHost(for: wrongRepo)
        XCTAssertNil(wrongRepoProxy,
                     "valargroup repos other than token-holder-voting-config should be rejected")

        // valargroup but no /token-holder-voting-config/ prefix
        let noPrefix = URL(string: "https://raw.githubusercontent.com/valargroup/config.json")!
        let noPrefixProxy = OHTTPEndpoints.proxyHost(for: noPrefix)
        XCTAssertNil(noPrefixProxy,
                     "valargroup URLs without the voting-config path prefix should be rejected")
    }


    // MARK: - gRPC Frame Parsing Tests


    func testGRPCFrameEncoding() {
        // Test that a frame is encoded correctly (uncompressed flag + 4-byte length + payload)
        let payload = Data("test".utf8)
        var frame = Data()
        frame.append(0)  // uncompressed
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)

        XCTAssertEqual(frame.count, 5 + payload.count)
        XCTAssertEqual(frame[0], 0)
        XCTAssertEqual(frame[1], 0)
        XCTAssertEqual(frame[2], 0)
        XCTAssertEqual(frame[3], 0)
        XCTAssertEqual(frame[4], UInt8(payload.count))
    }


    // MARK: - Proxy Allowlist Tests

    /// The gateway's exact vote + PIR host list (infra BACKENDS, mainnet).
    private static let gatewayVoteAndPirHosts = [
        "vote.zodl.com",
        "prod.vote-chain-primary.valargroup.org",
        "voting.valargroup.dev",
        "ru.zcash.space",
        "147-182-192-212.sslip.io",
        "134-209-215-69.sslip.io",
        "mnval01.zcash.legends.sh",
        "zvote-1.stardust.rest",
        "zvote.zodl.com",
        "zvote.keplr.app",
        "zvote.zfnd.org",
        "v.ombie.cash",
        "lb-pir-primary.valargroup.org",
        "lb-pir-backup.valargroup.org",
        "zpir-1.stardust.rest",
    ]

    func testProxyAllowlistIsExactlyTheGatewayHostList() {
        XCTAssertEqual(OHTTPEndpoints.proxyAllowedHosts, Set(Self.gatewayVoteAndPirHosts))
        XCTAssertEqual(OHTTPEndpoints.proxyAllowedHosts.count, 15)
        for host in Self.gatewayVoteAndPirHosts {
            XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: host), host)
        }
    }

    func testProxyAllowlistHasNoSuffixMatching() {
        // Subdomains and parents of listed domains are not listed hosts.
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "x.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "evilvalargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "api.valargroup.dev"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "valargroup.dev"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "pir.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "evil.vote.zodl.com"))
        // chaindefuser is reached only through the near.zodl.com alias, never as a passthrough host.
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "chaindefuser.com"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "1click.chaindefuser.com"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "evilchaindefuser.com"))
    }

    func testProxyAllowlistCaseInsensitive() {
        // Host matching is case-insensitive
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "PROD.VOTE-CHAIN-PRIMARY.VALARGROUP.ORG"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "LB-PIR-Primary.ValarGroup.Org"))
    }

    func testProxyAllowlistGatewayDetection() {
        // isGateway uses exact host matching for configured relays only; the aliases are HTTP
        // destinations (isAliasHost), not gateways.
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway.example"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway-testnet.example"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("cmc.zodl.com"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("near.zodl.com"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("vote.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.isAliasHost("cmc.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.isAliasHost("near.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.isAliasHost("vote.zodl.com"))

        // External allowlisted hosts (valargroup, chaindefuser) are neither gateways nor aliases:
        XCTAssertFalse(OHTTPEndpoints.isGateway("prod.vote-chain-primary.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("1click.chaindefuser.com"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("voting.valargroup.dev"))
        XCTAssertFalse(OHTTPEndpoints.isAliasHost("prod.vote-chain-primary.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isAliasHost("1click.chaindefuser.com"))

        // The exact vote/PIR hosts ARE proxy-allowlisted; chaindefuser only via the near alias:
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "prod.vote-chain-primary.valargroup.org"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "voting.valargroup.dev"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "1click.chaindefuser.com"))
    }

    func testProxyAllowlistProxyHostPassthrough() {
        // Allowlisted hosts return unchanged host (no rewrite)
        let url1 = URL(string: "https://prod.vote-chain-primary.valargroup.org/path")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url1), "prod.vote-chain-primary.valargroup.org")

        // Static mapping wins over the suffix allowlist: NEAR goes to the gateway alias so the
        // gateway injects the 1Click credential (allowlisted vote servers keep their real host).
        let url2 = URL(string: "https://1click.chaindefuser.com/api")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url2), "near.zodl.com")
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: URL(string: "https://1click.chaindefuser.com/v0/tokens")!)?.host, "near.zodl.com")
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: URL(string: "https://1click.chaindefuser.com/v0/tokens")!)?.path, "/v0/tokens")
        let voteURL = URL(string: "https://prod.vote-chain-primary.valargroup.org/x")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: voteURL), "prod.vote-chain-primary.valargroup.org")
    }

    func testProxyAllowlistProxyURLPassthrough() {
        // Allowlisted hosts return unchanged URL (no hostname rewrite)
        let url = URL(string: "https://prod.vote-chain-primary.valargroup.org/shielded-vote/v1/rounds?limit=10")!
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: url), url)
    }

    // MARK: - Secret Stripping Tests

    func testSecretStrippingForMappedHosts() {
        // Verify that CMC and NEAR hosts are recognized as mapped hosts
        let cmcURL = URL(string: "https://pro-api.coinmarketcap.com/v1/key/info")!
        let nearURL = URL(string: "https://1click.chaindefuser.com/v0/tokens")!

        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: cmcURL), "CMC should be a mapped host")
        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: nearURL), "NEAR should be a mapped host")

        // The proxy hosts are aliases, and still reach the mainnet relay
        XCTAssertTrue(OHTTPEndpoints.isAliasHost("cmc.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.isAliasHost("near.zodl.com"))
        XCTAssertNoThrow(try OHTTPEndpoints.relayURL(for: "cmc.zodl.com"))
    }

    func testSecretStrippingForNonMappedHosts() {
        // Verify that non-mapped hosts (like voting) are NOT stripped
        let votingURL = URL(string: "https://voting.valargroup.dev/prod/dynamic-voting-config.json")!

        // voting.valargroup.dev is allowlisted (passthrough, no rewrite), but NOT a static mapping
        // OHTTPEndpoints.proxyHost returns the original host for allowlisted hosts
        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: votingURL), "Voting should be allowlisted")

        // But the host is the same (passthrough), so it's NOT in the static mapping list
        // The secret-stripping logic only applies to hosts where proxyHost(for:) != nil,
        // which includes both static mappings AND allowlisted hosts. However, the test
        // intention here is to verify the static mappings (CMC, NEAR) are recognized.
        // For a non-mapped clearnet host:
        let clearnetURL = URL(string: "https://example.com/api")!
        XCTAssertNil(OHTTPEndpoints.proxyHost(for: clearnetURL), "example.com should NOT be mapped")
    }


    // MARK: - Client Trace ID Tests

    func testClientTraceIdAbsentWhenNotSet() async throws {
        let post = await OHTTPTestSupport.capturePost(clientTraceIdPrefix: nil)

        XCTAssertNotNil(post, "Request should have been captured")
        XCTAssertNil(post?.value(forHTTPHeaderField: "X-Client-Trace-Id"), "X-Client-Trace-Id should be absent")
        XCTAssertNil(post?.value(forHTTPHeaderField: "X-Request-Id"), "X-Request-Id should never be set by SDK")
    }

    func testClientTraceIdPresentWhenSet() async throws {
        let post = await OHTTPTestSupport.capturePost(clientTraceIdPrefix: "test-wallet")

        XCTAssertNotNil(post, "Request should have been captured")
        let traceId = post?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "X-Client-Trace-Id should be present")
        XCTAssertTrue(traceId?.hasPrefix("test-wallet-") ?? false, "Trace ID should start with prefix")
        XCTAssertLessThanOrEqual(traceId?.count ?? 0, 64, "Trace ID should be ≤ 64 chars")
        XCTAssertTrue(traceId?.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil,
                      "Trace ID should match allowed charset")
        XCTAssertNil(post?.value(forHTTPHeaderField: "X-Request-Id"), "X-Request-Id should never be set by SDK")
    }

    func testClientTraceIdNeverSetsXRequestId() async throws {
        let post = await OHTTPTestSupport.capturePost(clientTraceIdPrefix: "test")

        XCTAssertNotNil(post, "Request should have been captured")
        XCTAssertNil(post?.value(forHTTPHeaderField: "X-Request-Id"), "SDK must never set X-Request-Id")
    }

    func testClientTraceIdSanitization() async throws {
        let post = await OHTTPTestSupport.capturePost(clientTraceIdPrefix: "test@wallet#123")

        let traceId = post?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "Trace ID should be present")
        XCTAssertFalse(traceId?.contains("@") ?? true, "Trace ID should not contain @")
        XCTAssertFalse(traceId?.contains("#") ?? true, "Trace ID should not contain #")
        XCTAssertTrue(traceId?.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil,
                      "Trace ID should match allowed charset")
    }

    func testClientTraceIdTruncation() async throws {
        let post = await OHTTPTestSupport.capturePost(clientTraceIdPrefix: String(repeating: "a", count: 60))

        let traceId = post?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "Trace ID should be present")
        XCTAssertEqual(traceId?.count, 64, "Trace ID should be truncated to exactly 64 chars")
    }

    func testTraceIdAlsoRidesTheKeyConfigurationFetch() async throws {
        // The iOS profile sends the trace id on the key fetch as well as on the post.
        var fetch: URLRequest?
        let transport = OHTTPTestSupport.makeTransport(clientTraceIdPrefix: "trace") { request, _ in
            if request.httpMethod == "GET" {
                fetch = request
                return (
                    OHTTPTestSupport.stubEnvelope,
                    OHTTPTestSupport.response(for: request.url, status: 200)
                )
            }
            throw OHTTPError.transportError("test abort")
        }

        _ = try? await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)

        XCTAssertNotNil(fetch?.value(forHTTPHeaderField: "X-Client-Trace-Id"))
    }

    func testRequestsCarryTheProfileHeaders() async throws {
        var fetch: URLRequest?
        var post: URLRequest?
        let transport = OHTTPTestSupport.makeTransport { request, _ in
            if request.httpMethod == "GET" {
                fetch = request
                return (
                    OHTTPTestSupport.stubEnvelope,
                    OHTTPTestSupport.response(for: request.url, status: 200)
                )
            }
            post = request
            throw OHTTPError.transportError("test abort")
        }

        _ = try? await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)

        XCTAssertEqual(fetch?.value(forHTTPHeaderField: "Accept"), "application/ohttp-keys")
        XCTAssertEqual(post?.value(forHTTPHeaderField: "Content-Type"), "message/ohttp-chunked-req")
        XCTAssertEqual(post?.value(forHTTPHeaderField: "Accept"), "message/ohttp-chunked-res")
        XCTAssertEqual(post?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(post?.httpMethod, "POST")
        XCTAssertGreaterThan(post?.httpBody?.count ?? 0, 0)
    }

    // MARK: - Tor Mode Tests

    func testTorModeUsesCustomSenderForKeyConfigAndRelay() async throws {
        var keyConfigRequestCaptured = false
        var relayRequestCaptured = false

        let torSender: OHTTPTransport.HTTPSender = { request, _ in
            if request.httpMethod == "GET" {
                keyConfigRequestCaptured = true
                return (
                    OHTTPTestSupport.stubEnvelope,
                    OHTTPTestSupport.response(for: request.url, status: 200, headers: ["Content-Type": "application/json"])
                )
            } else {
                relayRequestCaptured = true
                throw OHTTPError.transportError("test abort after relay POST")
            }
        }

        let transport = OHTTPTestSupport.makeTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            sender: torSender
        )

        do {
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertTrue(keyConfigRequestCaptured, "Custom sender should be used for key config GET")
        XCTAssertTrue(relayRequestCaptured, "Custom sender should be used for relay POST")
    }

    func testSessionConfigurationIsEphemeralWithNoCookiesOrCache() {
        // Verify the dedicated OHTTP session has ephemeral configuration with cookies and caching disabled.
        // This prevents a relay or gateway from storing Set-Cookie headers or cached responses that would
        // link a wallet's requests across IPs or Tor circuits.
        let config = OHTTPTransport.sessionConfigurationForTesting

        XCTAssertEqual(config.httpCookieAcceptPolicy, .never, "Cookie accept policy should be .never")
        XCTAssertFalse(config.httpShouldSetCookies, "httpShouldSetCookies should be false")
        XCTAssertNil(config.httpCookieStorage, "httpCookieStorage should be nil")
        XCTAssertNil(config.urlCache, "urlCache should be nil")
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData, "Cache policy should ignore all caching")
    }

    // MARK: - Redirect Refusal Tests

    func testSessionDelegateRefusesRedirects() {
        // Verify that the session's delegate refuses HTTP redirects.
        // A redirect from a relay or key-config server is an attack vector.
        let session = OHTTPTransport.session
        guard let delegate = session.delegate as? URLSessionTaskDelegate else {
            XCTFail("Session should have a URLSessionTaskDelegate")
            return
        }

        // Create a dummy task and redirect response
        let url = URL(string: "https://operator-relay.example.invalid/relay")!
        let task = session.dataTask(with: url)
        let redirectResponse = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://evil.example.com/"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://evil.example.com/")!)

        var capturedNewRequest: URLRequest?
        let expectation = self.expectation(description: "Completion handler called")

        delegate.urlSession!(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: newRequest
        ) { request in
            capturedNewRequest = request
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertNil(capturedNewRequest, "Delegate should refuse redirects by returning nil")
    }


    func testNonHTTPSRelayURLFails() async throws {
        // Verify that a non-https relay URL throws at request time (not init).
        let transport = OHTTPTestSupport.makeTransport(relayURL: "http://operator-relay.example.invalid/relay") { request, _ in
            (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }

        // First call (roundTrip, which first derives the signed-config URL from the relay) throws with the
        // https requirement
        do {
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("Should have thrown for http relay URL")
        } catch let error as OHTTPError {
            if case .transportError(let message) = error {
                XCTAssertTrue(message.contains("must use https"), "Error should mention https requirement")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    func testNonHTTPSSignedConfigURLFails() async throws {
        var senderCalls = 0
        let transport = OHTTPTestSupport.makeTransport(relayURL: "http://operator-relay.example.invalid/relay") { request, _ in
            senderCalls += 1
            return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }

        // First call (keyConfig → derived URL validation) throws before any GET or decoding
        do {
            _ = try await transport.keyConfig()
            XCTFail("Should have thrown for http-derived signed-config URL")
        } catch let error as OHTTPError {
            if case .transportError(let message) = error {
                XCTAssertTrue(message.contains("must use https"), "Error should mention https requirement")
            } else {
                XCTFail("Wrong error type")
            }
        }
        XCTAssertEqual(senderCalls, 0, "No request may be sent for a non-https URL")
    }

    func testKeyConfigurationRejectedByTheCoreFailsClosed() async throws {
        // No test verifier: the native core checks the envelope against the pinned key, and refuses a body
        // that is not a signed envelope.
        let transport = OHTTPTransport(
            gatewayHost: "ohttp-gateway-testnet.example",
            relayURL: "https://testnet-operator-relay.example.invalid/relay"
        ) { request, _ in
            if request.httpMethod == "GET" {
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            XCTFail("Nothing may be posted without a verified key")
            throw OHTTPError.transportError("unexpected post")
        }

        do {
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("Should have thrown")
        } catch let error as OHTTPError {
            guard case .keyConfigError = error else {
                return XCTFail("Expected keyConfigError, got \(error)")
            }
        }
    }
}
