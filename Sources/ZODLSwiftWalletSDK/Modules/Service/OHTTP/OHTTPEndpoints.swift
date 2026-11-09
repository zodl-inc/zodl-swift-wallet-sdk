//
//  OHTTPEndpoints.swift
//  ZODLSwiftWalletSDK
//
//  OHTTP (RFC 9458) endpoint mapping, from the configuration the app installs at launch
//  (`OHTTPEndpoints.configure(_:)`, see `OHTTPConfiguration.swift`).
//
//  A LightWalletEndpoint whose host is the gateway of a configured network is served through that network's
//  OHTTP relay instead of a direct gRPC connection:
//
//    app ──HPKE-encrypted──▶ relay (sees IP, not content) ──▶ gateway (sees content, not IP) ──▶ lightwalletd
//
//  The gateway's signed HPKE key configuration is fetched through the relay at
//  `https://<relay-host>/ohttp-configs/signed` (the relay passes it through from the gateway).
//
//  Non-LWD proxy hosts (CMC, NEAR, voting) also route through the same relay→gateway
//  pair. The gateway proxies these to their real backends; the destination never sees the client IP.
//  When Tor is OFF: OHTTP hides the client IP from all external services.
//  When Tor is ON:  All calls use Tor→Relay→Gateway (voting goes Tor-direct as the ZIP mandates).
//
//  OHTTP is off for a network the installed configuration leaves out, and for both until one is installed:
//  no host is that network's gateway, so its gateway host is a plain server, and the hosts its gateway
//  carries have no route.
//

import Foundation

public enum OHTTPEndpoints {
    /// The gateway host the installed configuration (``configure(_:)``) has for `network`, or nil when OHTTP is
    /// off for that network. Use this hostname when constructing a lightwalletd gateway endpoint.
    public static func gatewayHost(for network: NetworkType) -> String? {
        OHTTPNative.gatewayHost(for: network)
    }

    /// Optional client trace ID prefix for debug end-to-end tracking. When set, every outer OHTTP POST
    /// to the relay carries `X-Client-Trace-Id: <prefix>-<uuid>`.
    ///
    /// **Privacy warning:** a custom trace ID makes that wallet's requests linkable across relay
    /// and gateway logs. DEBUG ONLY. Never set in release builds. Off by default.
    public static var clientTraceIdPrefix: String?

    /// The prefix the transports actually use: ``clientTraceIdPrefix`` in DEBUG builds, always nil
    /// in release builds, so a release build never sends `X-Client-Trace-Id`.
    static var effectiveClientTraceIdPrefix: String? {
        #if DEBUG
        return clientTraceIdPrefix
        #else
        return nil
        #endif
    }

    /// Mainnet relay URL (for external API proxies that aren't in the native map).
    /// External API proxy hosts (`cmc.zodl.com`, `near.zodl.com`, etc.) share the mainnet
    /// relay→gateway pair — the gateway routes them to the real backend by authority header.
    /// The relay of the installed mainnet gateway; nil while OHTTP is off for mainnet.
    private static var mainnetRelayURL: String? { mainnetGatewayHost.flatMap { OHTTPNative.relayURL(for: $0) } }

    /// The alias hosts the gateway serves with its own credentials (cmc, near, vote, flexa). HTTP
    /// destinations only: none of them is a lightwalletd gateway (``isGateway(_:)`` is false).
    private static let aliasHosts: Set<String> = [
        "cmc.zodl.com",    // CoinMarketCap price feed
        "near.zodl.com",   // NEAR 1click intents API
        "vote.zodl.com",   // Voting config / vote servers
        "flexa.zodl.com",  // Flexa REST + SSE API (mainnet gateway only)
    ]

    /// Aliases the mainnet gateway serves and the testnet one does not.
    static let mainnetOnlyAliases: Set<String> = ["flexa.zodl.com"]

    /// Aliases whose `Authorization` is the client's own and goes through: the gateway replaces only the
    /// placeholder publishable key the app is given, and passes a user's token as it is.
    static let clientAuthorizationAliases: Set<String> = ["flexa.zodl.com"]

    /// Exact hosts the gateway forwards to (infra `ohttp-gateway` BACKENDS, mainnet): the 12 vote
    /// servers and the 3 PIR endpoints, host-bound. Exact match only: the gateway removed suffix
    /// routing, and several of these domains also serve unrelated hosts, so a suffix rule would
    /// let the app send a request the gateway can only reject (or, worse, trust a lookalike).
    ///
    /// MUST equal the predefined vote/PIR hosts of the BACKENDS list and the Rust voting route's
    /// `OHTTP_VOTE_HOSTS` (`rust/src/voting/route.rs`); a host missing here fails closed in the app.
    /// The `cmc.zodl.com` and `near.zodl.com` aliases are not listed: they carry gateway-injected
    /// credentials (``isAliasHost(_:)``) and are reached through `proxyHostMapping`.
    public static let proxyAllowedHosts: Set<String> = [
        // Vote servers
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
        // PIR endpoints (delegation)
        "lb-pir-primary.valargroup.org",
        "lb-pir-backup.valargroup.org",
        "zpir-1.stardust.rest",
    ]

    /// Returns true if the host is allowlisted for passthrough OHTTP proxying: an exact,
    /// case-insensitive match against `proxyAllowedHosts`. No suffix matching.
    public static func isProxyAllowlisted(host: String) -> Bool {
        proxyAllowedHosts.contains(host.lowercased())
    }

    /// True only for the lightwalletd gateway hosts of the installed configuration (``configure(_:)``), those
    /// with a relay; false for every host while OHTTP is off. Case-insensitive.
    /// Exact host match only, so custom LWD hosts are never forced through OHTTP, and the alias hosts
    /// (``isAliasHost(_:)``) can never become a lightwalletd endpoint.
    public static func isGateway(_ host: String) -> Bool {
        OHTTPNative.relayURL(for: host) != nil
    }

    /// True for an alias host the gateway serves with gateway-injected credentials (CMC, NEAR, voting,
    /// Flexa): a destination of the HTTP paths (`httpRequestOverOHTTP`, `httpStreamOverOHTTP`), never
    /// a lightwalletd endpoint. Case-insensitive.
    public static func isAliasHost(_ host: String) -> Bool {
        aliasHosts.contains(host.lowercased())
    }

    /// The relay a request to `gatewayHost` is posted to: a configured lightwalletd gateway's own relay, or the
    /// mainnet gateway's relay for the hosts that gateway carries (aliases, allowlisted and path-restricted
    /// hosts). Throws for any other host: while OHTTP is off for a network, that includes its gateway host, and
    /// while it is off for mainnet, the hosts the mainnet gateway carries.
    public static func relayURL(for gatewayHost: String) throws -> String {
        let lowerHost = gatewayHost.lowercased()
        // Try native relay map first
        if let relay = OHTTPNative.relayURL(for: gatewayHost) {
            return relay
        }
        // Alias hosts ride the mainnet gateway's relay
        if aliasHosts.contains(lowerHost) {
            guard let relay = mainnetRelayURL else {
                throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
            }
            return relay
        }
        // Third-party proxy hosts (path-restricted) use mainnet relay
        if isThirdPartyProxyHost(host: gatewayHost) {
            guard let relay = mainnetRelayURL else {
                throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
            }
            return relay
        }
        // Allowlisted hosts use mainnet relay
        if isProxyAllowlisted(host: gatewayHost) {
            guard let relay = mainnetRelayURL else {
                throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
            }
            return relay
        }
        throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
    }

    /// Maps a real external-service URL to its OHTTP proxy hostname.
    /// For allowlisted hosts, returns the SAME host (no rewrite — gateway proxies by `:authority`).
    /// For static mappings, returns the rewritten proxy host.
    /// Returns nil if the host has no configured proxy (caller should fall through to clearnet or Tor).
    /// Static hostname mappings — checked BEFORE the host allowlist so that hosts with a gateway
    /// alias (credential injection happens only for aliases) are never sent as their real name.
    static let proxyHostMapping: [String: String] = [
        "pro-api.coinmarketcap.com": "cmc.zodl.com",
        "1click.chaindefuser.com":   "near.zodl.com",
        "voting.valargroup.dev":     "vote.zodl.com",
        "api.flexa.co":              "flexa.zodl.com",
    ]

    public static func proxyHost(for url: URL) -> String? {
        guard let host = url.host else { return nil }

        // Static hostname mappings first (aliases carry gateway-injected credentials)
        if let mapped = proxyHostMapping[host.lowercased()] {
            return mapped
        }

        // Path-based routing for raw.githubusercontent.com: only /valargroup/token-holder-voting-config/* is allowed
        // Return the host itself (passthrough by :authority) for allowed paths; nil for others.
        if host.lowercased() == "raw.githubusercontent.com" {
            let path = url.path
            if path.hasPrefix("/valargroup/token-holder-voting-config/") {
                return "raw.githubusercontent.com"
            }
            // Other paths on raw.githubusercontent.com are rejected (nil return = unsupportedPrivateDestination)
            return nil
        }

        // Allowlisted hosts pass through unchanged (vote servers learned at run time)
        if isProxyAllowlisted(host: host) {
            return host
        }
        return nil
    }

    /// Returns true if the host is a third-party host that routes through OHTTP with path restrictions.
    /// Currently only raw.githubusercontent.com with the valargroup voting config path prefix.
    /// Not a gateway: `isGateway` stays false so it can never become a lightwalletd endpoint.
    static func isThirdPartyProxyHost(host: String) -> Bool {
        return host.lowercased() == "raw.githubusercontent.com"
    }

    /// True for a URL on a path-restricted third-party host whose path the gateway serves
    /// (the bundled voting-config mirror). Other paths on that host are not routable.
    public static func isPathRestrictedProxyURL(_ url: URL) -> Bool {
        guard let host = url.host, isThirdPartyProxyHost(host: host) else { return false }
        return proxyHost(for: url) != nil
    }

    /// Returns true if the host is an alias that carries gateway-injected secrets (CMC, NEAR, voting).
    /// These hosts require header stripping before sending to the gateway.
    /// Case-insensitive check.
    public static func needsHeaderStripping(host: String) -> Bool {
        let lowerHost = host.lowercased()
        // Check if it's one of the alias hosts (values in proxyHostMapping)
        let aliasHosts = Set(proxyHostMapping.values.map { $0.lowercased() })
        return aliasHosts.contains(lowerHost) && !clientAuthorizationAliases.contains(lowerHost)
    }

    /// Rewrites `url` to go through the OHTTP proxy.
    /// For allowlisted hosts: returns the SAME URL (no hostname rewrite; gateway proxies by `:authority`).
    /// For static mappings: substitutes the proxy hostname.
    /// Returns nil when the host has no proxy mapping (e.g. Tor is already active), and for every URL while OHTTP
    /// is off for both networks: no gateway would carry the request.
    public static func proxyURL(for url: URL) -> URL? {
        guard isConfigured, let proxyHost = proxyHost(for: url) else { return nil }

        // Allowlisted hosts without a static mapping: return unchanged URL (proxyHost == original host)
        guard let originalHost = url.host else { return nil }
        if proxyHost.lowercased() == originalHost.lowercased() {
            return url
        }

        // Static mappings: rewrite hostname
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.host = proxyHost
        return comps.url
    }

    static var mainnetGatewayHost: String? { gatewayHost(for: .mainnet) }
    static var testnetGatewayHost: String? { gatewayHost(for: .testnet) }

    /// The gateway and relay a request to `host` goes through for a wallet on `network`. A lightwalletd
    /// gateway host is its own gateway; every other host the gateways carry (the CMC and NEAR aliases,
    /// vote and PIR servers, the voting-config mirror) goes through the gateway of the wallet's network,
    /// never the other network's. Throws, as for a host no gateway carries, while OHTTP is off for the
    /// wallet's network.
    static func proxyRoute(for host: String, network: NetworkType) throws -> (gatewayHost: String, relayURL: String) {
        if let relay = OHTTPNative.relayURL(for: host) {
            // `host` is a configured gateway, a value that never goes into an error: the errors name the condition.
            guard let gatewayNetwork = self.network(for: host) else {
                throw OHTTPError.transportError("No OHTTP network is configured for the gateway")
            }
            guard gatewayNetwork == (network == .mainnet ? "mainnet" : "testnet"), let gateway = gatewayHost(for: network) else {
                throw OHTTPError.transportError("The gateway does not serve the wallet's network")
            }
            return (gateway, relay)
        }
        if network != .mainnet, mainnetOnlyAliases.contains(host.lowercased()) {
            throw OHTTPError.transportError("\(host) is served by the mainnet gateway only")
        }
        guard let gateway = network == .mainnet ? mainnetGatewayHost : testnetGatewayHost,
              let relay = OHTTPNative.relayURL(for: gateway) else {
            throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(host)")
        }
        return (gateway, relay)
    }

    /// Refuses a gateway `host` of the other network than the wallet's `network`, before any request is
    /// made to it: a testnet wallet never calls the mainnet gateway, nor the other way round. Any other
    /// host passes; its network is checked against the server's chain name when it is validated.
    public static func checkGatewayNetwork(host: String, network: NetworkType) throws {
        guard OHTTPNative.relayURL(for: host) != nil else { return }
        // `host` is a configured gateway from here on, so it is kept out of the errors.
        guard let gatewayNetwork = self.network(for: host) else {
            throw OHTTPError.transportError("No OHTTP network is configured for the gateway")
        }
        guard gatewayNetwork == (network == .mainnet ? "mainnet" : "testnet") else {
            throw ZcashError.compactBlockProcessorChainName(gatewayNetwork)
        }
    }

    /// Returns the network identifier ("mainnet" or "testnet") of a gateway host of the installed configuration,
    /// and nil for every host while OHTTP is off.
    /// Network identity comes from the configuration, never from a hostname suffix or substring.
    /// Caller host matching ignores ASCII case and leaves every unknown host unrecognized.
    public static func network(for gatewayHost: String) -> String? {
        let normalized = asciiLowercased(gatewayHost)
        if let mainnet = mainnetGatewayHost, normalized == asciiLowercased(mainnet) {
            return "mainnet"
        }
        if let testnet = testnetGatewayHost, normalized == asciiLowercased(testnet) {
            return "testnet"
        }
        return nil
    }

    private static func asciiLowercased(_ host: String) -> [UInt8] {
        host.utf8.map { byte in
            (65...90).contains(byte) ? byte + 32 : byte
        }
    }
}
