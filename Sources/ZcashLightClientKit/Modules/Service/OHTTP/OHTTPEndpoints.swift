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
//  The gateway's HPKE key configuration is fetched from `https://<gateway-host>/ohttp-configs`.
//

import Foundation

enum OHTTPEndpoints {
    /// Gateway host → relay URL. One relay per gateway: mainnet and testnet gateways have different
    /// HPKE keys and an RFC 9458 relay has a single fixed gateway target. Regional gateways
    /// (`ohttp-gateway-eu.zodl.com`, …) are steered behind the two hostnames below; add an entry
    /// here only when a new gateway gets its own relay.
    private static let relayByGatewayHost: [String: String] = [
        "ohttp-gateway-testnet.example": "https://testnet-simulator-relay.example.invalid/relay",
        "ohttp-gateway.example": "https://simulator-relay.example.invalid/relay"
    ]

    /// True only for hosts that have a configured relay, so callers that dispatch on this can
    /// construct `LightWalletOHTTPService` without a failure path. Case-insensitive.
    static func isGateway(_ host: String) -> Bool {
        return relayByGatewayHost[host.lowercased()] != nil
    }

    static func relayURL(for gatewayHost: String) throws -> String {
        guard let relay = relayByGatewayHost[gatewayHost.lowercased()] else {
            throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
        }
        return relay
    }

    static func keyConfigURL(for gatewayHost: String) -> String {
        return "https://\(gatewayHost)/ohttp-configs"
    }
}
