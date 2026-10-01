//
//  OHTTPEndpoints.swift
//  ZcashLightClientKit
//
//  Static OHTTP (RFC 9458) endpoint mapping.
//
//  A LightWalletEndpoint whose host is one of the ZODL OHTTP gateways is served through an OHTTP
//  relay instead of a direct gRPC connection:
//
//    app ──HPKE-encrypted──▶ relay (sees IP, not content) ──▶ gateway (sees content, not IP) ──▶ lightwalletd
//
//  The gateway's HPKE key configuration is fetched through the relay at `https://<relay-host>/ohttp-configs`
//  (the relay passes it through from the gateway).
//
//  Non-LWD proxy hosts (CMC, NEAR, voting) also route through the same relay→gateway
//  pair. The gateway proxies these to their real backends; the destination never sees the client IP.
//  When Tor is OFF: OHTTP hides the client IP from all external services.
//  When Tor is ON:  LWD uses Tor→OHTTP; other calls use Tor directly (no double-wrapping needed).
//

import Foundation

public enum OHTTPEndpoints {
    /// Optional client trace ID prefix for debug end-to-end tracking. When set, every outer OHTTP POST
    /// to the relay carries `X-Client-Trace-Id: <prefix>-<uuid>`.
    ///
    /// **Privacy warning:** a custom trace ID makes that wallet's requests linkable across relay
    /// and gateway logs. DEBUG ONLY. Never set in release builds. Off by default.
    public static var clientTraceIdPrefix: String?

    /// Gateway host → relay URL.
    /// LWD gateways (mainnet/testnet) have dedicated relays with matching HPKE keys.
    /// External API proxy hosts (`cmc.zodl.com`, `near.zodl.com`, etc.) share the mainnet
    /// relay→gateway pair — the gateway routes them to the real backend by authority header.
    private static let relayByGatewayHost: [String: String] = [
        // LWD gateways
        "ohttp-gateway-testnet.example": "https://testnet-relay.example.invalid/relay",
        "ohttp-gateway.example":         "https://mainnet-relay.example.invalid/relay",
        // External API proxies — all through the mainnet relay→gateway
        "cmc.zodl.com":    "https://mainnet-relay.example.invalid/relay",  // CoinMarketCap price feed
        "near.zodl.com":   "https://mainnet-relay.example.invalid/relay",  // NEAR 1click intents API
        "vote.zodl.com":   "https://mainnet-relay.example.invalid/relay",  // Voting config / vote servers
    ]

    /// Exact hosts the gateway forwards to (infra `ohttp-gateway` BACKENDS, mainnet): the 12 vote
    /// servers and the 3 PIR endpoints, host-bound. Exact match only: the gateway removed suffix
    /// routing, and several of these domains also serve unrelated hosts, so a suffix rule would
    /// let the app send a request the gateway can only reject (or, worse, trust a lookalike).
    ///
    /// MUST equal the predefined vote/PIR hosts of the BACKENDS list and the Rust voting route's
    /// `OHTTP_VOTE_HOSTS` (`rust/src/voting/route.rs`); a host missing here fails closed in the app.
    /// The `cmc.zodl.com` and `near.zodl.com` aliases are not listed: they are gateways
    /// (`relayByGatewayHost`) that carry gateway-injected credentials, reached through
    /// `proxyHostMapping`.
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

    /// True only for hosts that have a configured relay (static mappings). Case-insensitive.
    /// F-13 fix: exact host match only, so custom LWD hosts are never forced through OHTTP.
    public static func isGateway(_ host: String) -> Bool {
        return relayByGatewayHost[host.lowercased()] != nil
    }

    public static func relayURL(for gatewayHost: String) throws -> String {
        if let relay = relayByGatewayHost[gatewayHost.lowercased()] {
            return relay
        }
        if isProxyAllowlisted(host: gatewayHost) {
            // TODO(COR-1830): Switch to Fastly prod once it serves /ohttp-configs
            return "https://mainnet-relay.example.invalid/relay"  // allowlisted hosts use mainnet relay
        }
        throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
    }
    /// Key config URL, derived from the gateway's relay URL by replacing the path `/relay` with `/ohttp-configs`.
    /// The relay proxies `/ohttp-configs` to the gateway's key endpoint.
    public static func keyConfigURL(for gatewayHost: String) -> String {
        guard var relayURL = try? relayURL(for: gatewayHost) else {
            fatalError("keyConfigURL called for gateway \(gatewayHost) with no relay mapping")
        }
        // Replace only the path suffix, not the hostname (relay-simulator stays relay-simulator)
        if relayURL.hasSuffix("/relay") {
            relayURL.removeLast("/relay".count)
            relayURL = "\(relayURL)/ohttp-configs"
        }
        return relayURL
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
    ]

    public static func proxyHost(for url: URL) -> String? {
        guard let host = url.host else { return nil }

        // Static hostname mappings first (aliases carry gateway-injected credentials)
        if let mapped = proxyHostMapping[host.lowercased()] {
            return mapped
        }

        // Allowlisted hosts pass through unchanged (vote servers learned at run time)
        if isProxyAllowlisted(host: host) {
            return host
        }
        return nil
    }

    /// Returns true if the host is an alias that carries gateway-injected secrets (CMC, NEAR, voting).
    /// These hosts require header stripping before sending to the gateway.
    /// Case-insensitive check.
    public static func needsHeaderStripping(host: String) -> Bool {
        let lowerHost = host.lowercased()
        // Check if it's one of the alias hosts (values in proxyHostMapping)
        let aliasHosts = Set(proxyHostMapping.values.map { $0.lowercased() })
        return aliasHosts.contains(lowerHost)
    }

    /// Rewrites `url` to go through the OHTTP proxy.
    /// For allowlisted hosts: returns the SAME URL (no hostname rewrite; gateway proxies by `:authority`).
    /// For static mappings: substitutes the proxy hostname.
    /// Returns nil when the host has no proxy mapping (e.g. Tor is already active).
    public static func proxyURL(for url: URL) -> URL? {
        guard let proxyHost = proxyHost(for: url) else { return nil }

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

    /// Returns the network identifier ("mainnet" or "testnet") for a given gateway host.
    /// Testnet gateway hosts contain "-testnet"; all others default to mainnet. `OHTTPTransport` does not
    /// call this: the shared core applies the same rule to the gateway host when it verifies the signed
    /// key configuration.
    public static func network(for gatewayHost: String) -> String {
        return gatewayHost.lowercased().contains("-testnet") ? "testnet" : "mainnet"
    }
}
