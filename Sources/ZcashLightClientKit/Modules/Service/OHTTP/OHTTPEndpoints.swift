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
//  Non-LWD proxy hosts (CMC, NEAR, voting, Sapling params) also route through the same relay→gateway
//  pair. The gateway proxies these to their real backends; the destination never sees the client IP.
//  When Tor is OFF: OHTTP hides the client IP from all external services.
//  When Tor is ON:  LWD uses Tor→OHTTP; other calls use Tor directly (no double-wrapping needed).
//

import Foundation

enum OHTTPEndpoints {
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
        "params.zodl.com": "https://simulator-relay.example.invalid/relay",  // Sapling params download
    ]

    /// True only for hosts that have a configured relay. Case-insensitive.
    static func isGateway(_ host: String) -> Bool {
        return relayByGatewayHost[host.lowercased()] != nil
    }

    static func relayURL(for gatewayHost: String) throws -> String {
        guard let relay = relayByGatewayHost[gatewayHost.lowercased()] else {
            throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
        }
        return relay
    }

    /// Key config URL. Proxy hosts share the mainnet gateway's HPKE key config — the gateway
    /// decrypts on their behalf regardless of which backend it eventually calls.
    static func keyConfigURL(for gatewayHost: String) -> String {
        let canonical = gatewayHost.hasPrefix("ohttp-gateway") ? gatewayHost : "ohttp-gateway.example"
        return "https://\(canonical)/ohttp-configs"
    }

    /// Maps a real external-service URL to its OHTTP proxy hostname.
    /// Returns nil if the host has no configured proxy (caller should fall through to clearnet or Tor).
    static func proxyHost(for url: URL) -> String? {
        let mapping: [String: String] = [
            "pro-api.coinmarketcap.com": "cmc.zodl.com",
            "1click.chaindefuser.com":   "near.zodl.com",
            "voting.valargroup.dev":     "vote.zodl.com",
            "download.z.cash":           "params.zodl.com",
        ]
        guard let host = url.host else { return nil }
        return mapping[host.lowercased()]
    }

    /// Rewrites `url` to go through the OHTTP proxy (substitutes the hostname).
    /// Returns nil when the host has no proxy mapping (e.g. Tor is already active).
    static func proxyURL(for url: URL) -> URL? {
        guard let proxyHost = proxyHost(for: url) else { return nil }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.host = proxyHost
        return comps.url
    }
}
