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
    private static let gatewayHostPrefix = "ohttp-gateway"

    private static let relayByGatewayHost: [String: String] = [
        "ohttp-gateway-testnet.example": "https://testnet-simulator-relay.example.invalid/relay",
        "ohttp-gateway.example": "https://simulator-relay.example.invalid/relay"
    ]

    static func isGateway(_ host: String) -> Bool {
        return host.hasPrefix(gatewayHostPrefix)
    }

    static func relayURL(for gatewayHost: String) throws -> String {
        guard let relay = relayByGatewayHost[gatewayHost] else {
            throw OHTTPError.transportError("No OHTTP relay configured for gateway host \(gatewayHost)")
        }
        return relay
    }

    static func keyConfigURL(for gatewayHost: String) -> String {
        return "https://\(gatewayHost)/ohttp-configs"
    }
}
