//
//  OHTTPConfiguration.swift
//  ZODLSwiftWalletSDK
//
//  The OHTTP configuration the app installs at launch with `OHTTPEndpoints.configure(_:)`: for mainnet and
//  testnet, the gateway host, the relay URL, the DNS name of the gateway's signed key configuration and the key
//  that signs it. The SDK carries none of these values, so OHTTP is off until the app installs them.
//

import os

/// The OHTTP configuration of one network, as the app has it.
///
/// ``OHTTPEndpoints/configure(_:)`` checks every value against the rule its property states. The values are
/// never shown: the description, and what reflection shows (`dump`, test failure messages), says only whether
/// each one is set.
public struct OHTTPNetworkConfiguration: Equatable, Sendable, CustomStringConvertible {
    /// The gateway's host name, which is also the `:authority` of the lightwalletd requests sent through it:
    /// a lower-case bare DNS host name (no scheme, port, path or trailing dot).
    public let gatewayHost: String
    /// The URL sealed requests are posted to: `https://`, a host (a DNS name or an IP literal), an optional numeric
    /// port and an optional path, without userinfo, query, fragment, backslash, whitespace or control characters.
    public let relayURL: String
    /// The DNS TXT name of the gateway's signed key configuration, its last-resort source: a lower-case bare DNS
    /// host name.
    public let keysDNSName: String
    /// The key the gateway's key configuration is signed with: a raw Ed25519 public key as 64 hex digits (either
    /// case), a valid curve point not of small order.
    public let signingPublicKey: String

    public init(gatewayHost: String, relayURL: String, keysDNSName: String, signingPublicKey: String) {
        self.gatewayHost = gatewayHost
        self.relayURL = relayURL
        self.keysDNSName = keysDNSName
        self.signingPublicKey = signingPublicKey
    }

    public var description: String {
        let fields = shownValues.map { "\($0.key): \($0.value)" }
        return "OHTTPNetworkConfiguration(\(fields.joined(separator: ", ")))"
    }

    /// Each value's name, with `<set>` or `<empty>` in place of the value.
    private var shownValues: KeyValuePairs<String, Any> {
        [
            "gatewayHost": Self.shown(gatewayHost),
            "relayURL": Self.shown(relayURL),
            "keysDNSName": Self.shown(keysDNSName),
            "signingPublicKey": Self.shown(signingPublicKey)
        ]
    }

    private static func shown(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<set>"
    }
}

extension OHTTPNetworkConfiguration: CustomReflectable {
    /// Reflection shows what ``description`` shows: whether each value is set, never the value.
    public var customMirror: Mirror {
        Mirror(self, children: shownValues, displayStyle: .struct)
    }
}

/// The OHTTP configuration of mainnet and testnet that the app installs at launch with
/// ``OHTTPEndpoints/configure(_:)``. A network left nil has OHTTP off. The two networks must not share a value
/// (host names and URLs compared ignoring ASCII case).
///
/// The description says which networks and values are set, never a value.
public struct OHTTPConfiguration: Equatable, Sendable, CustomStringConvertible {
    /// The configuration of mainnet, or nil for OHTTP off on mainnet.
    public let mainnet: OHTTPNetworkConfiguration?
    /// The configuration of testnet, or nil for OHTTP off on testnet.
    public let testnet: OHTTPNetworkConfiguration?

    public init(mainnet: OHTTPNetworkConfiguration?, testnet: OHTTPNetworkConfiguration?) {
        self.mainnet = mainnet
        self.testnet = testnet
    }

    public var description: String {
        "OHTTPConfiguration(mainnet: \(mainnet?.description ?? "nil"), testnet: \(testnet?.description ?? "nil"))"
    }
}

extension OHTTPEndpoints {
    /// What ``configure(_:)`` installed last, and how many configurations it has installed.
    private struct Installed: Sendable {
        var configuration: OHTTPConfiguration?
        var generation: UInt64 = 0
    }

    private static let installed = OSAllocatedUnfairLock(initialState: Installed())

    /// Installs the OHTTP configuration of mainnet and testnet for the whole process, replacing the one installed
    /// before.
    ///
    /// Call it once at launch, before anything else in the SDK: OHTTP is off until it is called. Every OHTTP route
    /// reads this configuration: the lightwalletd gateways, the hosts the gateways carry (``proxyURL(for:)``),
    /// the Slipstream engine and voting sessions. A Slipstream sync pass and a voting session keep the
    /// configuration they started with; a new one applies from the next start or session.
    ///
    /// `nil`, like a network the configuration leaves nil, turns OHTTP off: that network's gateway host is then a
    /// plain server, ``gatewayHost(for:)`` returns nil for the network and ``isGateway(_:)`` is false for the host.
    /// With no network configured, ``proxyURL(for:)`` returns nil for every URL. A voting session on a network with
    /// OHTTP off reaches the predefined vote and PIR servers on a plain direct connection when Tor is off, where
    /// with OHTTP on it rides the gateway and fails closed; with Tor on it uses Tor either way.
    ///
    /// - Throws: ``ZcashError/ohttpConfigurationInvalid(_:)`` when a value breaks the rule its
    ///   ``OHTTPNetworkConfiguration`` property states, or when mainnet and testnet share a value. The message
    ///   names the network, the field and the rule, never the value, and the configuration installed before stays.
    public static func configure(_ configuration: OHTTPConfiguration?) throws {
        try installed.withLock { state in
            // The native layer checks the values and installs them first; the copy here changes only once they
            // are accepted, under the same lock, so both layers always hold the same configuration.
            try OHTTPNative.configure(mainnet: configuration?.mainnet, testnet: configuration?.testnet)
            state.configuration = configuration
            state.generation += 1
        }
    }

    /// The configuration ``configure(_:)`` installed last, or nil while there is none and OHTTP is off.
    public static var configuration: OHTTPConfiguration? {
        installed.withLock { $0.configuration }
    }

    /// Whether the installed configuration turns OHTTP on for mainnet, testnet or both.
    static var isConfigured: Bool {
        installed.withLock { $0.configuration?.mainnet != nil || $0.configuration?.testnet != nil }
    }

    /// Changes with every configuration ``configure(_:)`` installs, so that what was cached under one configuration
    /// (the gateways' verified keys in ``OHTTPKeyCache``) is never used under another.
    static var configurationGeneration: UInt64 {
        installed.withLock { $0.generation }
    }
}
