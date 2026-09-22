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
        "ohttp-gateway-testnet.example": "https://testnet-simulator-relay.example.invalid/relay",
        "ohttp-gateway.example":         "https://simulator-relay.example.invalid/relay",
        // External API proxies — all through the mainnet relay→gateway
        "cmc.zodl.com":    "https://simulator-relay.example.invalid/relay",  // CoinMarketCap price feed
        "near.zodl.com":   "https://simulator-relay.example.invalid/relay",  // NEAR 1click intents API
        "vote.zodl.com":   "https://simulator-relay.example.invalid/relay",  // Voting config / vote servers
    ]

    /// Proxy allowlist suffixes. Gateway v1.4.5+ proxies inner requests whose `:authority` ends
    /// with one of these suffixes to `https://<authority>` — no hostname rewrite needed.
    public static let proxyAllowedSuffixes = [".valargroup.org", ".valargroup.dev", "chaindefuser.com"]

    /// Returns true if the host is allowlisted for passthrough OHTTP proxying.
    /// Suffix rule: leading-dot suffix (`.valargroup.org`) matches `x.valargroup.org` but NOT `valargroup.org`.
    /// Bare domain (`chaindefuser.com`) matches itself or `*.chaindefuser.com`.
    public static func isProxyAllowlisted(host: String) -> Bool {
        let lower = host.lowercased()
        for suffix in proxyAllowedSuffixes {
            if suffix.hasPrefix(".") {
                // Leading-dot suffix: only matches subdomains
                if lower.hasSuffix(suffix) && lower != suffix.dropFirst() {
                    return true
                }
            } else {
                // Bare domain: matches itself or any subdomain
                if lower == suffix || lower.hasSuffix(".\(suffix)") {
                    return true
                }
            }
        }
        return false
    }

    /// True only for hosts that have a configured relay (static mappings or allowlisted). Case-insensitive.
    public static func isGateway(_ host: String) -> Bool {
        return relayByGatewayHost[host.lowercased()] != nil || isProxyAllowlisted(host: host)
    }

    public static func relayURL(for gatewayHost: String) throws -> String {
        if let relay = relayByGatewayHost[gatewayHost.lowercased()] {
            return relay
        }
        if isProxyAllowlisted(host: gatewayHost) {
            return "https://simulator-relay.example.invalid/relay"  // allowlisted hosts use mainnet relay
        }
        throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
    }

    /// Key config URL. Proxy hosts (static mappings and allowlisted) share the mainnet gateway's
    /// HPKE key config — the gateway decrypts on their behalf regardless of which backend it eventually calls.
    public static func keyConfigURL(for gatewayHost: String) -> String {
        if gatewayHost.hasPrefix("ohttp-gateway") {
            return "https://\(gatewayHost)/ohttp-configs"
        }
        // Static mappings and allowlisted hosts use mainnet gateway config
        return "https://ohttp-gateway.example/ohttp-configs"
    }

    /// Maps a real external-service URL to its OHTTP proxy hostname.
    /// For allowlisted hosts, returns the SAME host (no rewrite — gateway proxies by `:authority`).
    /// For static mappings, returns the rewritten proxy host.
    /// Returns nil if the host has no configured proxy (caller should fall through to clearnet or Tor).
    /// Static hostname mappings — checked BEFORE the suffix allowlist so that hosts with a gateway
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
}
